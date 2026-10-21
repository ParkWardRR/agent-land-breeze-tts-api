#!/usr/bin/env swift
// download-models — fetch MLX model weights from HuggingFace
//
//   swift scripts/download-models.swift           # download model from .env
//   swift scripts/download-models.swift --force   # re-download even if present

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
func shell(_ args: [String], passthrough: Bool = false) -> (String, Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    let pipe = passthrough ? nil : Pipe()
    if let pipe { p.standardOutput = pipe }
    if !passthrough { p.standardError = Pipe() }
    do { try p.run() } catch { return ("", 1) }
    p.waitUntilExit()
    let out = pipe.map { String(data: $0.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "" } ?? ""
    return (out.trimmingCharacters(in: .whitespacesAndNewlines), p.terminationStatus)
}

// MARK: - HuggingFace API

func listFiles(hfRepo: String) -> [(path: String, size: Int)] {
    let url = "https://huggingface.co/api/models/\(hfRepo)"
    let (json, status) = shell(["curl", "-fsSL", url])
    guard status == 0,
          let data = json.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let siblings = obj["siblings"] as? [[String: Any]] else {
        fputs("Failed to list files for \(hfRepo). Check the repo name and network.\n", stderr)
        exit(1)
    }
    return siblings.compactMap { sib in
        guard let path = sib["rfilename"] as? String else { return nil }
        let size: Int
        if let lfs = sib["lfs"] as? [String: Any], let lfsSize = lfs["size"] as? Int {
            size = lfsSize
        } else {
            size = sib["size"] as? Int ?? 0
        }
        return (path, size)
    }.filter { !$0.path.hasPrefix(".git") }
}

func humanSize(_ bytes: Int) -> String {
    if bytes >= 1_000_000_000 { return String(format: "%.2f GB", Double(bytes) / 1e9) }
    if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1e6) }
    if bytes >= 1_000 { return String(format: "%.0f KB", Double(bytes) / 1e3) }
    return "\(bytes) B"
}

// MARK: - Download

func downloadFile(hfRepo: String, file: String, dest: URL) {
    let dir = dest.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let url = "https://huggingface.co/\(hfRepo)/resolve/main/\(file)?download=true"
    var args = ["curl", "-fSL", "--progress-bar", "-C", "-", "--create-dirs", "-o", dest.path(percentEncoded: false)]
    if let token = ProcessInfo.processInfo.environment["HF_TOKEN"] {
        args += ["-H", "Authorization: Bearer \(token)"]
    }
    args.append(url)

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    do { try p.run() } catch {
        fputs("  failed to start curl\n", stderr)
        return
    }
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        fputs("  download failed (curl exit \(p.terminationStatus))\n", stderr)
    }
}

// MARK: - Main

let args = CommandLine.arguments
let force = args.contains("--force")
let cfg = settings()
let runtime = cfg["COMPOSE_PROFILES"] ?? "gguf"

guard runtime == "mlx" else {
    fputs("COMPOSE_PROFILES=\(runtime), not mlx. Run swift scripts/configure-macos.swift first,\n", stderr)
    fputs("or use python scripts/download_models.py for NVIDIA runtimes.\n", stderr)
    exit(1)
}

let hfRepo = cfg["BREEZE_MLX_REPO"] ?? "Shoof/Gust-MLX"
let modelDir = cfg["BREEZE_MLX_MODEL_DIR"] ?? "mlx-gust"
var modelsRoot = cfg["BREEZE_MODELS_DIR"] ?? "./models"
if !modelsRoot.hasPrefix("/") { modelsRoot = repo.appending(path: modelsRoot).path(percentEncoded: false) }
let destDir = URL(fileURLWithPath: modelsRoot).appending(path: modelDir)

if !force && FileManager.default.fileExists(atPath: destDir.path(percentEncoded: false)) {
    let contents = (try? FileManager.default.contentsOfDirectory(atPath: destDir.path(percentEncoded: false))) ?? []
    let hasSafetensors = contents.contains { $0.hasSuffix(".safetensors") }
    if hasSafetensors {
        print("Model already downloaded at \(destDir.path(percentEncoded: false))")
        print("Use --force to re-download.")
        exit(0)
    }
}

print("Repository: \(hfRepo)")
print("Destination: \(destDir.path(percentEncoded: false))")
print("Listing files...")

let files = listFiles(hfRepo: hfRepo)
let totalSize = files.reduce(0) { $0 + $1.size }
print("Found \(files.count) files (\(humanSize(totalSize)))\n")

for (i, file) in files.enumerated() {
    let dest = destDir.appending(path: file.path)
    let exists = FileManager.default.fileExists(atPath: dest.path(percentEncoded: false))
    if exists && !force {
        print("[\(i + 1)/\(files.count)] \(file.path) (\(humanSize(file.size))) -- already present")
        continue
    }
    print("[\(i + 1)/\(files.count)] \(file.path) (\(humanSize(file.size)))")
    downloadFile(hfRepo: hfRepo, file: file.path, dest: dest)
}

let finalContents = (try? FileManager.default.contentsOfDirectory(atPath: destDir.path(percentEncoded: false))) ?? []
let safetensors = finalContents.filter { $0.hasSuffix(".safetensors") }
if safetensors.isEmpty {
    fputs("\nWarning: no .safetensors files found in \(destDir.path(percentEncoded: false))\n", stderr)
    exit(1)
}

print("\nDone. \(safetensors.count) safetensors file(s) in \(destDir.path(percentEncoded: false))")
print("Next: swift runtimes/mlx/launch.swift")
