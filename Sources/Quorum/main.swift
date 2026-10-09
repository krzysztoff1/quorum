import Foundation

// `@main` normally lives on QuorumApp, but a benchmark run must never open a window — so the real
// entry point lives here and only hands off to the SwiftUI app when `--benchmark` isn't present.
// Match `--benchmark` anywhere in argv (SwiftPM may or may not strip the `--` separator, depending on
// how the run is invoked), then pass everything after it to the runner.
if let i = CommandLine.arguments.firstIndex(of: "--benchmark") {
    await BenchmarkRunner.run(arguments: Array(CommandLine.arguments[(i + 1)...]))
} else if let i = CommandLine.arguments.firstIndex(of: "--snapshot"),
          let path = CommandLine.arguments.dropFirst(i + 1).first {
    exit(GraphSnapshot.write(to: path) ? 0 : 1)
} else {
    QuorumApp.main()
}
