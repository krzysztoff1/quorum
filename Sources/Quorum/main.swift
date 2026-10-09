import Foundation

if let i = CommandLine.arguments.firstIndex(of: "--snapshot"),
   let path = CommandLine.arguments.dropFirst(i + 1).first {
    let written = MainActor.assumeIsolated { GraphSnapshot.write(to: path) }
    exit(written ? 0 : 1)
} else {
    QuorumApp.main()
}
