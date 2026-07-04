import Foundation

// `@main` normally lives on QuorumApp, but a benchmark run must never open a window — so the real
// entry point lives here and only hands off to the SwiftUI app when `--benchmark` isn't present.
if CommandLine.arguments.dropFirst().first == "--benchmark" {
    await BenchmarkRunner.run(arguments: Array(CommandLine.arguments.dropFirst(2)))
} else {
    QuorumApp.main()
}
