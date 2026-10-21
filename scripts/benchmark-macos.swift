#!/usr/bin/env swift
// benchmark-macos — measure a running Breeze TTS server on Apple Silicon
//
//   swift scripts/benchmark-macos.swift                                # server from .env
//   swift scripts/benchmark-macos.swift --url http://host:7860 --runs 5
//   swift scripts/benchmark-macos.swift --label "M4, mlx" --notes "idle"

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
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
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

// MARK: - Hardware

func chipInfo() -> (chip: String, memGB: Int, gpuCores: Int) {
    let (chip, _) = shell(["sysctl", "-n", "machdep.cpu.brand_string"])
    let (memStr, _) = shell(["sysctl", "-n", "hw.memsize"])
    let memGB = Int(UInt64(memStr) ?? 0) / (1024 * 1024 * 1024)
    var gpuCores = 0
    let (sp, _) = shell(["system_profiler", "SPDisplaysDataType"])
    for line in sp.components(separatedBy: "\n") where line.contains("Total Number of Cores") {
        if let r = line.range(of: #"\d+"#, options: .regularExpression) { gpuCores = Int(line[r]) ?? 0 }
        break
    }
    return (chip, memGB, gpuCores)
}

// MARK: - Benchmark

let bytesPerSecond = 24000 * 2

struct SpeechResult {
    let ttfa: Double
    let wall: Double
    let audio: Double
    var rtf: Double { wall / max(audio, 0.001) }
}

func measureSpeech(url: String, text: String) -> SpeechResult? {
    let writeOut = #"{"ttfa":%{time_starttransfer},"wall":%{time_total},"size":%{size_download}}"#
    let body = "text=\(text)&instruction=A+calm,+friendly+adult+voice+speaking+clearly.&cfg_scale=4&seed=7"
    let (out, status) = shell(["curl", "-sS", "-w", writeOut, "-o", "/dev/null",
                               "-X", "POST", "-d", body, "\(url)/v1/audio/speech"])
    guard status == 0, let data = out.data(using: .utf8),
          let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let ttfa = j["ttfa"] as? Double,
          let wall = j["wall"] as? Double,
          let size = j["size"] as? Double else { return nil }
    let audio = size / Double(bytesPerSecond)
    return SpeechResult(ttfa: ttfa, wall: wall, audio: audio)
}

struct WarmResult {
    let idMs: Int
    let waitFirstAudio: Double
    let audio: Double
    let wall: Double
}

func measureWarm(url: String, text: String) -> WarmResult? {
    let body = "text=\(text)&instruction=A+calm,+friendly+adult+voice+speaking+clearly.&cfg_scale=4&seed=7"
    let t0 = CFAbsoluteTimeGetCurrent()
    let (warmOut, warmStatus) = shell(["curl", "-sS", "-X", "POST", "-d", body, "\(url)/v1/audio/speech/warm"])
    guard warmStatus == 0 else { return nil }
    let idMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
    guard let data = warmOut.data(using: .utf8),
          let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let respURL = j["url"] as? String else { return nil }

    let writeOut = #"{"ttfa":%{time_starttransfer},"wall":%{time_total},"size":%{size_download}}"#
    let (out, status) = shell(["curl", "-sS", "-w", writeOut, "-o", "/dev/null", "\(url)\(respURL)"])
    guard status == 0, let d2 = out.data(using: .utf8),
          let j2 = try? JSONSerialization.jsonObject(with: d2) as? [String: Any],
          let ttfa = j2["ttfa"] as? Double,
          let wall = j2["wall"] as? Double,
          let size = j2["size"] as? Double else { return nil }
    let audio = max(0, size - 44) / Double(bytesPerSecond)
    return WarmResult(idMs: idMs, waitFirstAudio: ttfa, audio: audio, wall: wall)
}

func rangeStr(_ values: [Double]) -> String {
    guard let lo = values.min(), let hi = values.max() else { return "-" }
    if values.count == 1 { return String(format: "%.3g", lo) }
    return String(format: "%.3g-%.3g", lo, hi)
}

// MARK: - Parse args

let cliArgs = CommandLine.arguments
let cfg = settings()
var serverURL = "http://127.0.0.1:\(cfg["BREEZE_PORT"] ?? "7860")"
var runs = 3
var label = ""
var notes = ""
var i = 1
while i < cliArgs.count {
    switch cliArgs[i] {
    case "--url": i += 1; serverURL = cliArgs[i]
    case "--runs": i += 1; runs = Int(cliArgs[i]) ?? 3
    case "--label": i += 1; label = cliArgs[i]
    case "--notes": i += 1; notes = cliArgs[i]
    default: break
    }
    i += 1
}

let shortText = "The deployment finished a minute ago and every check came back green, so we are good to go."
let longText = "I just finished reviewing the deployment logs, and everything looks healthy. The new build passed all tests, response times dropped by about twenty percent, and there were no errors overnight. I would suggest we roll it out to the remaining servers this afternoon, then keep an eye on memory usage until tomorrow morning."

// MARK: - Run

let (healthOut, healthStatus) = shell(["curl", "-fsS", "\(serverURL)/health"])
guard healthStatus == 0 else {
    fputs("Server not reachable at \(serverURL)/health\n", stderr); exit(1)
}
print("Server: \(serverURL) -- \(healthOut)")

let hw = chipInfo()
print("Hardware: \(hw.chip), \(hw.memGB) GB, \(hw.gpuCores) GPU cores\n")

print("Warming up...")
_ = measureSpeech(url: serverURL, text: shortText)

print("Running \(runs) iterations...")
var shortResults: [SpeechResult] = []
var longResults: [SpeechResult] = []
for n in 1...runs {
    print("  short \(n)/\(runs)")
    if let r = measureSpeech(url: serverURL, text: shortText) { shortResults.append(r) }
    print("  long  \(n)/\(runs)")
    if let r = measureSpeech(url: serverURL, text: longText) { longResults.append(r) }
}

var warmResults: [WarmResult] = []
for n in 1...max(1, runs - 1) {
    print("  warm  \(n)/\(max(1, runs - 1))")
    if let r = measureWarm(url: serverURL, text: longText) { warmResults.append(r) }
}

// MARK: - Output

let configKeys = ["COMPOSE_PROFILES", "BREEZE_MLX_REPO", "BREEZE_MLX_MODEL_DIR", "BREEZE_MLX_COMPILE"]
var config: [String: String] = [:]
for k in configKeys { if let v = cfg[k] { config[k] = v } }

let pv = ProcessInfo.processInfo.operatingSystemVersion
let results: [String: Any] = [
    "date": ISO8601DateFormatter().string(from: Date()),
    "label": label, "notes": notes, "url": serverURL,
    "system": ["chip": hw.chip, "gpu": "\(hw.chip) (\(hw.gpuCores) GPU cores)",
               "memory_gb": hw.memGB, "os": "macOS \(pv.majorVersion).\(pv.minorVersion).\(pv.patchVersion)"],
    "config": config,
    "unified_memory_gb": hw.memGB,
    "short_line": shortResults.map { ["ttfa_s": round($0.ttfa * 1000) / 1000, "wall_s": round($0.wall * 100) / 100,
                                       "audio_s": round($0.audio * 100) / 100, "rtf": round($0.rtf * 1000) / 1000] },
    "words_50": longResults.map { ["ttfa_s": round($0.ttfa * 1000) / 1000, "wall_s": round($0.wall * 100) / 100,
                                    "audio_s": round($0.audio * 100) / 100, "rtf": round($0.rtf * 1000) / 1000] },
    "warm": warmResults.map { ["id_ms": $0.idMs, "wait_first_audio_s": round($0.waitFirstAudio * 100) / 100,
                                "audio_s": round($0.audio * 100) / 100, "wall_s": round($0.wall * 100) / 100] },
]

let chipSlug = hw.chip.lowercased().replacingOccurrences(of: " ", with: "-")
let runtime = config["COMPOSE_PROFILES"] ?? "mlx"
let dateStr = ISO8601DateFormatter().string(from: Date()).prefix(10)
let outDir = repo.appending(path: "benchmarks/results")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let outFile = outDir.appending(path: "\(dateStr)_\(chipSlug)_\(runtime).json")

if let jsonData = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
    try? jsonData.write(to: outFile)
    print("\nSaved \(outFile.path(percentEncoded: false))\n")
}

print("| Test | Time to first audio (s) | Wall (s) | Audio (s) | RTF |")
print("|---|---|---|---|---|")
print("| short line | \(rangeStr(shortResults.map(\.ttfa))) | \(rangeStr(shortResults.map(\.wall))) | \(rangeStr(shortResults.map(\.audio))) | \(rangeStr(shortResults.map(\.rtf))) |")
print("| 50 words | \(rangeStr(longResults.map(\.ttfa))) | \(rangeStr(longResults.map(\.wall))) | \(rangeStr(longResults.map(\.audio))) | \(rangeStr(longResults.map(\.rtf))) |")

if !warmResults.isEmpty {
    print("\n| Warm (50 words) | id (ms) | wait first audio (s) | wall (s) |")
    print("|---|---|---|---|")
    for w in warmResults {
        print("| | \(w.idMs) | \(String(format: "%.2f", w.waitFirstAudio)) | \(String(format: "%.2f", w.wall)) |")
    }
}

print("\nApple Silicon: \(hw.chip), \(hw.memGB) GB unified memory, \(hw.gpuCores) GPU cores")
