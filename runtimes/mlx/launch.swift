#!/usr/bin/env swift
// launch — set up Python venv, install dependencies, and start the MLX TTS server
//
//   swift runtimes/mlx/launch.swift          # setup (if needed) + start server
//   swift runtimes/mlx/launch.swift setup    # only install deps, don't start

import Foundation
import Darwin

// MARK: - Repo and .env

func findRepo() -> URL {
    var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    for _ in 0..<10 {
        if FileManager.default.fileExists(atPath: dir.appending(path: ".env.example").path(percentEncoded: false)) {
            return dir
        }
        dir = dir.deletingLastPathComponent()
    }
    // Try from script location
    dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
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

// MARK: - Shell helpers

@discardableResult
func run(_ args: [String], cwd: URL? = nil) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = Array(args.dropFirst())
    if let cwd { p.currentDirectoryURL = cwd }
    do { try p.run() } catch {
        fputs("Failed to run \(args[0]): \(error)\n", stderr)
        return 1
    }
    p.waitUntilExit()
    return p.terminationStatus
}

@discardableResult
func shell(_ args: [String]) -> (String, Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return ("", 1) }
    p.waitUntilExit()
    let out = (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return (out, p.terminationStatus)
}

// MARK: - Find Python 3.12+

func findPython() -> String? {
    let candidates = [
        "/opt/homebrew/bin/python3.12",
        "/opt/homebrew/bin/python3.13",
        "/opt/homebrew/bin/python3.14",
        "/usr/local/bin/python3.12",
        "/usr/local/bin/python3.13",
    ]
    for c in candidates {
        if FileManager.default.isExecutableFile(atPath: c) {
            let (ver, status) = shell([c, "--version"])
            if status == 0 && ver.contains("3.1") { return c }
        }
    }
    let (path, status) = shell(["which", "python3"])
    if status == 0 {
        let (ver, _) = shell([path, "--version"])
        if let range = ver.range(of: #"3\.(\d+)"#, options: .regularExpression) {
            let minor = Int(ver[range].split(separator: ".").last ?? "0") ?? 0
            if minor >= 12 { return path }
        }
    }
    return nil
}

// MARK: - Venv management

let venvDir = repo.appending(path: ".venv")
let venvPython = venvDir.appending(path: "bin/python")
let venvPip = venvDir.appending(path: "bin/pip")
let stampFile = venvDir.appending(path: ".requirements-stamp")
let requirementsFile = repo.appending(path: "runtimes/mlx/requirements.txt")

func sha256(_ path: URL) -> String {
    let (hash, _) = shell(["shasum", "-a", "256", path.path(percentEncoded: false)])
    return String(hash.split(separator: " ").first ?? "")
}

func ensureVenv(python: String) {
    let fm = FileManager.default
    if !fm.fileExists(atPath: venvPython.path(percentEncoded: false)) {
        print("Creating Python venv at .venv/ ...")
        let status = run([python, "-m", "venv", venvDir.path(percentEncoded: false)])
        guard status == 0 else { fputs("Failed to create venv\n", stderr); exit(1) }
    }
}

func installRequirements() {
    let currentHash = sha256(requirementsFile)
    let stampHash = (try? String(contentsOf: stampFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if currentHash == stampHash && !currentHash.isEmpty {
        print("Dependencies up to date (stamp matches)")
        return
    }
    print("Installing Python dependencies...")
    let status = run([venvPip.path(percentEncoded: false), "install", "-q",
                      "-r", requirementsFile.path(percentEncoded: false)])
    guard status == 0 else { fputs("pip install failed\n", stderr); exit(1) }
    try? currentHash.write(to: stampFile, atomically: true, encoding: .utf8)
}

func ensureBreezeTTSMLX() {
    let (_, status) = shell([venvPython.path(percentEncoded: false), "-c", "import breeze_tts_mlx"])
    if status == 0 { return }

    print("Installing breeze-tts-mlx from source...")
    let cloneDir = repo.appending(path: "breeze-tts-mlx")
    if !FileManager.default.fileExists(atPath: cloneDir.path(percentEncoded: false)) {
        let s = run(["/usr/bin/env", "git", "clone", "https://github.com/rishikksh20/breeze-tts-mlx.git",
                     cloneDir.path(percentEncoded: false)])
        guard s == 0 else { fputs("git clone failed\n", stderr); exit(1) }
    }
    let s = run([venvPip.path(percentEncoded: false), "install", "-e", cloneDir.path(percentEncoded: false)])
    guard s == 0 else { fputs("pip install breeze-tts-mlx failed\n", stderr); exit(1) }
}

// MARK: - Main

let setupOnly = CommandLine.arguments.contains("setup")
let cfg = settings()

guard let python = findPython() else {
    fputs("Python 3.12+ required but not found.\n", stderr)
    fputs("Install with: brew install python@3.12\n", stderr)
    exit(1)
}

let (pyVer, _) = shell([python, "--version"])
print("Python:  \(pyVer) (\(python))")

let host = cfg["BREEZE_BIND"] ?? "0.0.0.0"
let port = cfg["BREEZE_PORT"] ?? "7860"
let mlxRepo = cfg["BREEZE_MLX_REPO"] ?? "Shoof/Gust-MLX"
let mlxDir = cfg["BREEZE_MLX_MODEL_DIR"] ?? "mlx-gust"
print("Runtime: MLX (\(mlxRepo))")
print("Address: \(host):\(port)\n")

ensureVenv(python: python)
installRequirements()
ensureBreezeTTSMLX()

if setupOnly {
    print("\nSetup complete. Start with: swift runtimes/mlx/launch.swift")
    print("Or directly: .venv/bin/python runtimes/mlx/mlx_api.py")
    exit(0)
}

// Check model exists
var modelsRoot = cfg["BREEZE_MODELS_DIR"] ?? "./models"
if !modelsRoot.hasPrefix("/") { modelsRoot = repo.appending(path: modelsRoot).path(percentEncoded: false) }
let modelPath = URL(fileURLWithPath: modelsRoot).appending(path: mlxDir)
let modelContents = (try? FileManager.default.contentsOfDirectory(atPath: modelPath.path(percentEncoded: false))) ?? []
if !modelContents.contains(where: { $0.hasSuffix(".safetensors") }) {
    fputs("Model not found at \(modelPath.path(percentEncoded: false))\n", stderr)
    fputs("Run: swift scripts/download-models.swift\n", stderr)
    exit(1)
}

print("\nStarting Breeze TTS MLX server...")
print("Health check: curl http://\(host == "0.0.0.0" ? "127.0.0.1" : host):\(port)/health\n")

// Set env vars from .env for the server process
for (k, v) in cfg { setenv(k, v, 1) }

// Change to repo root so relative paths work
FileManager.default.changeCurrentDirectoryPath(repo.path(percentEncoded: false))

// exec replaces this process with the Python server
let pyPath = venvPython.path(percentEncoded: false)
let apiPath = repo.appending(path: "runtimes/mlx/mlx_api.py").path(percentEncoded: false)
let cArgs = [pyPath, apiPath].map { strdup($0) } + [nil]
execv(pyPath, cArgs)
perror("execv")
exit(1)
