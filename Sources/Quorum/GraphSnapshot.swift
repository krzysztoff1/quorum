import SwiftUI
import AppKit
import QuorumCore

@MainActor
enum GraphSnapshot {
    static let fixtureRecord = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("engine/fixtures/record/mock-run.run.json")

    static func write(to path: String, record: URL = fixtureRecord, width: CGFloat = 1900, height: CGFloat = 2100) -> Bool {
        guard let data = try? Data(contentsOf: record),
              let decoded = try? JSONDecoder().decode(RunRecord.self, from: data) else { return false }
        let run = StoredRun(runDir: record.deletingLastPathComponent(), record: decoded)
        let renderer = ImageRenderer(content:
            ResearchGraphView(graph: run.graph, scrolls: false)
                .frame(width: width, height: height)
                .environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
