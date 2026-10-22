import ArgumentParser

@main
struct Breeze: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "breeze",
        abstract: "Breeze TTS — manage the MLX speech server on Apple Silicon.",
        version: "1.0.0",
        subcommands: [
            Configure.self,
            Download.self,
            Launch.self,
            Benchmark.self,
            Service.self,
        ]
    )
}
