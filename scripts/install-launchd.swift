#!/usr/bin/env swift
// install-launchd — install (or remove) a launchd agent for the MLX TTS server
//
//   swift scripts/install-launchd.swift            # install and load
//   swift scripts/install-launchd.swift --remove   # unload and remove

import Foundation

// MARK: - Repo and .env

func findRepo() -> URL {
    var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    for _ in 0..<10 {
        if FileManager.default.fileExists(atPath: dir.appending(path: ".env.example").path(percentEncoded: false)) {
            return dir
        }
        dir = dir.deletingLastPathComponent()
    }
    fputs("Cannot find repo root (.env.example). Run from the repo directory.\n", stderr)
    exit(1)
}

let repo = findRepo()

func readEnv(_ url: URL) -> [String: String] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
    var d: [String: String] = [:]
    for line in text.components(separatedBy: "\n") {
        let s = line.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !s.hasPrefix("#"), let i = s.firstIndex(of: "=") else { continue }
        let k = s[..<i].trimmingCharacters(in: .whitespaces)
        var v = String(s[s.index(after: i)...]).trimmingCharacters(in: .whitespaces)
        if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
        }
        d[k] = v
    }
    return d
}

func settings() -> [String: String] {
    var s = readEnv(repo.appending(path: ".env.example"))
    for (k, v) in readEnv(repo.appending(path: ".env")) { s[k] = v }
    return s
}

// MARK: - Shell

@discardableResult
func run(_ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    p.standardOutput = Pipe()
    p.standardError = Pipe()
    do { try p.run() } catch { return 1 }
    p.waitUntilExit()
    return p.terminationStatus
}

// MARK: - Constants

let label = "com.breeze-tts.mlx"
let plistDir = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: "Library/LaunchAgents")
let plistPath = plistDir.appending(path: "\(label).plist")
let uid = getuid()

// MARK: - Main

let remove = CommandLine.arguments.contains("--remove")

if remove {
    run(["launchctl", "bootout", "gui/\(uid)", plistPath.path(percentEncoded: false)])
    if FileManager.default.fileExists(atPath: plistPath.path(percentEncoded: false)) {
        try? FileManager.default.removeItem(at: plistPath)
        print("Removed \(plistPath.path(percentEncoded: false))")
    } else {
        print("Plist not found; nothing to remove.")
    }
    exit(0)
}

let cfg = settings()
let logsDir = repo.appending(path: "logs")
try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

let venvPython = repo.appending(path: ".venv/bin/python").path(percentEncoded: false)
guard FileManager.default.isExecutableFile(atPath: venvPython) else {
    fputs("Venv not found at .venv/. Run: swift runtimes/mlx/launch.swift setup\n", stderr)
    exit(1)
}

let envKeys = [
    "BREEZE_PORT", "BREEZE_BIND", "BREEZE_VOICES_DIR", "BREEZE_RESPONSES_DIR",
    "BREEZE_MODELS_DIR", "BREEZE_MLX_MODEL_DIR", "BREEZE_MLX_REPO",
    "BREEZE_MLX_COMPILE", "BREEZE_MLX_FAST_FIRST", "BREEZE_MLX_CACHE_GB",
    "BREEZE_SYNC_WAIT_SECONDS", "BREEZE_MAX_PENDING", "BREEZE_RESPONSE_TTL_SECONDS",
    "BREEZE_MIN_LEAD_SECONDS", "BREEZE_MAX_NEW_TOKENS",
]
var envDict: [String: String] = [:]
for k in envKeys { if let v = cfg[k] { envDict[k] = v } }

let plist: [String: Any] = [
    "Label": label,
    "ProgramArguments": [venvPython, repo.appending(path: "runtimes/mlx/mlx_api.py").path(percentEncoded: false)],
    "WorkingDirectory": repo.path(percentEncoded: false),
    "EnvironmentVariables": envDict,
    "RunAtLoad": true,
    "KeepAlive": ["SuccessfulExit": false],
    "StandardOutPath": logsDir.appending(path: "launchd-stdout.log").path(percentEncoded: false),
    "StandardErrorPath": logsDir.appending(path: "launchd-stderr.log").path(percentEncoded: false),
    "ProcessType": "Interactive",
]

try? FileManager.default.createDirectory(at: plistDir, withIntermediateDirectories: true)
run(["launchctl", "bootout", "gui/\(uid)", plistPath.path(percentEncoded: false)])

let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
try! data.write(to: plistPath)

let status = run(["launchctl", "bootstrap", "gui/\(uid)", plistPath.path(percentEncoded: false)])
guard status == 0 else {
    fputs("launchctl bootstrap failed (exit \(status))\n", stderr)
    exit(1)
}

print("Installed and loaded \(plistPath.path(percentEncoded: false))")
print("Logs: \(logsDir.path(percentEncoded: false))/launchd-{stdout,stderr}.log")
print("Stop:   launchctl bootout gui/\(uid) \(plistPath.path(percentEncoded: false))")
print("Remove: swift scripts/install-launchd.swift --remove")
