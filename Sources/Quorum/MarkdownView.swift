import SwiftUI
import AppKit
import MarkdownEngine
import MarkdownEngineCodeBlocks

private let sharedHighlighter = HighlighterSwiftBridge()

private extension MarkdownEditorConfiguration {
    static func quorum(readingWidth: CGFloat? = nil,
                       textInsets: TextInsets = .default,
                       heightBehavior: HeightBehavior = .scrolls,
                       bus: MarkdownEditorBus = .default) -> MarkdownEditorConfiguration {
        MarkdownEditorConfiguration(
            services: MarkdownEditorServices(syntaxHighlighter: sharedHighlighter, bus: bus),
            textInsets: textInsets,
            readingWidth: readingWidth,
            heightBehavior: heightBehavior)
    }
}

struct MarkdownView: View {
    let markdown: String
    var documentId: String? = nil

    var body: some View {
        NativeTextViewWrapper(
            text: .constant(markdown),
            configuration: .quorum(heightBehavior: .fitsContent),
            documentId: documentId ?? "read-\(markdown.hashValue)",
            isEditable: false
        )
    }
}
