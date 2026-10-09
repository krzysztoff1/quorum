import Foundation
import QuorumCore

if let i = CommandLine.arguments.firstIndex(of: "--snapshot"),
   let path = CommandLine.arguments.dropFirst(i + 1).first {
    let record = CommandLine.arguments.dropFirst(i + 2).first.map { URL(fileURLWithPath: $0) }
    let written = MainActor.assumeIsolated { GraphSnapshot.write(to: path, record: record ?? GraphSnapshot.fixtureRecord) }
    exit(written ? 0 : 1)
} else if CommandLine.arguments.contains("--doctor") {
    let report = DoctorReport(engine: QuorumEngine.resolve(), claude: Preflight.check(ClaudeCLIProbe()),
                              appBuild: Bundle.main.object(forInfoDictionaryKey: "QuorumAppBuild") as? String)
    print(report.text, terminator: "")
    exit(report.ok ? 0 : 1)
} else {
    QuorumApp.main()
}
