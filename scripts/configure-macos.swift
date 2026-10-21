#!/usr/bin/env swift
// configure-macos — detect Apple Silicon hardware, write MLX settings into .env
//
//   swift scripts/configure-macos.swift              # detect + write
//   swift scripts/configure-macos.swift --model int8 # choose model
//   swift scripts/configure-macos.swift --dry-run    # print only

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
let envFile = repo.appending(path: ".env")
let envExample = repo.appending(path: ".env.example")

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

func writeEnv(_ changes: [String: String]) {
    let fm = FileManager.default
    if !fm.fileExists(atPath: envFile.path(percentEncoded: false)) {
        try! fm.copyItem(at: envExample, to: envFile)
    }
    var lines = (try! String(contentsOf: envFile, encoding: .utf8)).components(separatedBy: "\n")
    var pending = changes
    for i in lines.indices {
        let s = lines[i].trimmingCharacters(in: .whitespaces)
        guard !s.hasPrefix("#"), let eq = s.firstIndex(of: "=") else { continue }
        let k = String(s[..<eq]).trimmingCharacters(in: .whitespaces)
        if let v = pending.removeValue(forKey: k) { lines[i] = "\(k)=\(v)" }
    }
    for (k, v) in pending.sorted(by: { $0.key < $1.key }) { lines.append("\(k)=\(v)") }
    try! lines.joined(separator: "\n").write(to: envFile, atomically: true, encoding: .utf8)
}

// MARK: - Shell

@discardableResult
func shell(_ args: String...) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = Array(args)
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return "" }
    p.waitUntilExit()
    return (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Hardware detection

func detectChip() -> (name: String, memGB: Int, gpuCores: Int, ane: Int, macOS: String) {
    let pv = ProcessInfo.processInfo.operatingSystemVersion
    let macOS = "\(pv.majorVersion).\(pv.minorVersion).\(pv.patchVersion)"
    let name = shell("sysctl", "-n", "machdep.cpu.brand_string")
    let memGB = Int(UInt64(shell("sysctl", "-n", "hw.memsize")) ?? 0) / (1024 * 1024 * 1024)

    var gpuCores = 0
    let sp = shell("system_profiler", "SPDisplaysDataType")
    for line in sp.components(separatedBy: "\n") where line.contains("Total Number of Cores") {
        if let r = line.range(of: #"\d+"#, options: .regularExpression) {
            gpuCores = Int(line[r]) ?? 0
        }
        break
    }

    let ane = shell("ioreg", "-r", "-c", "AppleARMIODevice", "-n", "ane0")
    let aneCores = ane.lowercased().contains("ane0") ? 16 : 0

    return (name.isEmpty ? "Apple Silicon" : name, memGB, gpuCores, aneCores, macOS)
}

// MARK: - Models

struct MLXModel {
    let repo, dir, desc: String
    let minGB: Int
}

let models: [String: MLXModel] = [
    "int8": MLXModel(repo: "rishikksh20/Breeze-TTS-2-mlx", dir: "mlx-int8",
                     desc: "INT8 quantized (3.72 GB, RTF ~0.53, ~4 GB unified)", minGB: 8),
]

// MARK: - Main

guard shell("uname", "-m") == "arm64" else {
    fputs("Apple Silicon (ARM64) required. Intel Macs not supported.\n", stderr); exit(1)
}

let args = CommandLine.arguments
let dryRun = args.contains("--dry-run")
var choice = "auto"
if let i = args.firstIndex(of: "--model"), i + 1 < args.count { choice = args[i + 1] }
guard ["int8", "auto"].contains(choice) else {
    fputs("--model must be int8 or auto\n", stderr); exit(1)
}

let chip = detectChip()
print("Chip:    \(chip.name)")
print("Memory:  \(chip.memGB) GB unified")
print("GPU:     \(chip.gpuCores > 0 ? "\(chip.gpuCores) cores" : "(detecting)")")
print("ANE:     \(chip.ane > 0 ? "\(chip.ane) cores" : "present")")
print("macOS:   \(chip.macOS)")

let selected: String
if choice == "auto" {
    selected = "int8"
    print("\nauto-selected model: int8 (\(chip.memGB) GB memory)")
} else {
    selected = choice
}

guard let model = models[selected] else { fputs("Unknown model\n", stderr); exit(1) }
if chip.memGB < model.minGB {
    print("warning: \(selected) needs \(model.minGB)+ GB; you have \(chip.memGB) GB")
}
print("Model:   \(model.desc)\n")

let changes: [String: String] = [
    "COMPOSE_PROFILES": "mlx",
    "BREEZE_MLX_REPO": model.repo,
    "BREEZE_MLX_MODEL_DIR": model.dir,
    "BREEZE_MLX_COMPILE": "1",
    "BREEZE_MLX_FAST_FIRST": "6",
    "BREEZE_MLX_CACHE_GB": "1",
]

print("Settings:")
for (k, v) in changes.sorted(by: { $0.key < $1.key }) { print("  \(k)=\(v)") }

if dryRun {
    print("\n(dry run: .env not changed)")
} else {
    writeEnv(changes)
    print("\nWrote \(envFile.path(percentEncoded: false))")
    print("Next: swift scripts/download-models.swift")
}
