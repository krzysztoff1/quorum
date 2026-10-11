import SwiftUI
import AppKit
import QuorumCore

extension NSAttributedString.Key {
    static let quorumCite = NSAttributedString.Key("QuorumCitation")
}

struct ChipPeekState: Equatable {
    let cite: String
    let paragraph: String
    let rect: CGRect
}

struct ReadingStyle {
    let size: CGFloat
    let lineHeight: CGFloat
    let color: NSColor

    static let lead = ReadingStyle(size: 21, lineHeight: 1.48, color: NSColor(Ink.text1))
    static let claim = ReadingStyle(size: 16.5, lineHeight: 1.62, color: NSColor(Ink.claimText))
    static let claimLit = ReadingStyle(size: 16.5, lineHeight: 1.62, color: NSColor(Ink.text1))

    var font: NSFont {
        let base = NSFont.systemFont(ofSize: size)
        return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }
}

enum ChipImage {
    static func make(number: Int, tier: CitationTier, hot: Bool, opened: Bool) -> NSImage {
        let label = "\(number)\(tier.mark)"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        let foreground = opened ? NSColor(Ink.ink0) : NSColor(tier.chipForeground)
        let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: foreground])
        let width = max(17, ceil(text.size().width) + 8)
        let size = NSSize(width: width + 2, height: 17)
        return NSImage(size: size, flipped: false) { _ in
            let box = NSRect(x: 1, y: 0, width: width, height: 17)
            let shape = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            (opened ? NSColor(Ink.iris) : NSColor(tier.chipBackground)).setFill()
            shape.fill()
            let border: NSColor? = hot || opened ? foreground : tier == .close ? NSColor(Ink.jade.opacity(0.38)) : tier == .unresolved ? NSColor(Ink.text4) : nil
            if let border {
                border.setStroke()
                shape.lineWidth = 1
                if tier == .unresolved && !hot && !opened { shape.setLineDash([2, 2], count: 2, phase: 0) }
                shape.stroke()
            }
            let textSize = text.size()
            text.draw(at: NSPoint(x: box.midX - textSize.width / 2, y: (17 - textSize.height) / 2 + 0.5))
            return true
        }
    }
}

enum ReadingAttributed {
    static func build(_ text: String, style: ReadingStyle, context: AnswerContext, hot: Set<String>, opened: String?) -> NSAttributedString {
        let font = style.font
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = (style.size * style.lineHeight).rounded()
        paragraph.maximumLineHeight = (style.size * style.lineHeight).rounded()
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: style.color, .paragraphStyle: paragraph,
                                                   .baselineOffset: (style.size * (style.lineHeight - 1.2) / 2).rounded()]
        let out = NSMutableAttributedString()
        let source = text as NSString
        var cursor = 0
        let markers = CitationMarkers.markers(in: text)
        for marker in markers {
            let range = NSRange(marker.range, in: text)
            if range.location > cursor {
                out.append(NSAttributedString(string: source.substring(with: NSRange(location: cursor, length: range.location - cursor)), attributes: base))
            }
            if let number = context.number(marker.id) {
                let attachment = NSTextAttachment()
                attachment.image = ChipImage.make(number: number, tier: context.tier(marker.id),
                                                  hot: hot.contains(marker.id), opened: opened == marker.id)
                attachment.image?.accessibilityDescription = "Source \(number), \(context.tier(marker.id).spoken)"
                let size = attachment.image?.size ?? .zero
                attachment.bounds = CGRect(x: 0, y: font.descender + 1, width: size.width, height: size.height)
                let chip = NSMutableAttributedString(attachment: attachment)
                chip.addAttributes(base, range: NSRange(location: 0, length: chip.length))
                chip.addAttribute(.quorumCite, value: marker.id, range: NSRange(location: 0, length: chip.length))
                out.append(chip)
            }
            cursor = range.upperBound
        }
        if cursor < source.length {
            out.append(NSAttributedString(string: source.substring(from: cursor), attributes: base))
        }
        return out
    }
}

final class ReadingTextView: NSTextView {
    var onHover: ((String?, CGRect) -> Void)?
    var onOpen: ((String) -> Void)?
    private var hovered: String?

    override var isFlipped: Bool { true }

    private lazy var hoverArea = NSTrackingArea(rect: .zero,
                                                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                                owner: self, userInfo: nil)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(hoverArea) { addTrackingArea(hoverArea) }
    }

    func cite(at point: CGPoint) -> (String, CGRect)? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let index = characterIndexForInsertion(at: point)
        for candidate in [index, index - 1] where candidate >= 0 && candidate < storage.length {
            guard let id = storage.attribute(.quorumCite, at: candidate, effectiveRange: nil) as? String else { continue }
            let rect = chipRect(at: candidate)
            if rect.insetBy(dx: -2, dy: -3).contains(point) { return (id, rect) }
        }
        return nil
    }

    func chipRect(at index: Int) -> CGRect {
        guard let layout = textLayoutManager, let content = layout.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: index),
              let end = content.location(start, offsetBy: 1),
              let range = NSTextRange(location: start, end: end) else { return .zero }
        var found = CGRect.zero
        layout.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
            found = frame
            return false
        }
        return found.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    func firstChipRect(for id: String) -> CGRect? {
        guard let storage = textStorage else { return nil }
        var found: CGRect?
        storage.enumerateAttribute(.quorumCite, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if value as? String == id {
                found = chipRect(at: range.location)
                stop.pointee = true
            }
        }
        return found
    }

    override func mouseMoved(with event: NSEvent) {
        let hit = cite(at: convert(event.locationInWindow, from: nil))
        if hit?.0 != hovered {
            hovered = hit?.0
            onHover?(hit?.0, hit?.1 ?? .zero)
        }
        if hit != nil { NSCursor.pointingHand.set() } else { NSCursor.iBeam.set() }
    }

    override func mouseExited(with event: NSEvent) {
        if hovered != nil {
            hovered = nil
            onHover?(nil, .zero)
        }
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        if let (id, _) = cite(at: convert(event.locationInWindow, from: nil)) {
            onOpen?(id)
            return
        }
        super.mouseDown(with: event)
    }
}

struct ReadingTextRepresentable: NSViewRepresentable {
    let paragraph: String
    let text: String
    let style: ReadingStyle
    let context: AnswerContext
    @ObservedObject var focus: AnswerFocus

    private var cites: Set<String> { Set(CitationMarkers.ids(in: text)) }
    private var signature: String {
        let hot = focus.hotCites.intersection(cites).sorted().joined(separator: ",")
        let opened = cites.contains(focus.opened ?? "") ? focus.opened! : ""
        return "\(text)|\(hot)|\(opened)|\(style.size)|\(style.color)"
    }

    final class Coordinator {
        var signature = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ReadingTextView {
        let view = ReadingTextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.selectedTextAttributes = [.backgroundColor: NSColor(Ink.iris.opacity(0.28))]
        return view
    }

    func updateNSView(_ view: ReadingTextView, context: Context) {
        let focus = self.focus
        let paragraph = self.paragraph
        let answer = self.context
        view.onHover = { id, rect in
            if let id {
                focus.peek = ChipPeekState(cite: id, paragraph: paragraph, rect: rect)
                focus.light(cites: answer.lit([id]))
            } else if focus.peek?.paragraph == paragraph {
                focus.peek = nil
                focus.light(cites: [])
            }
        }
        view.onOpen = { id in focus.opened = focus.opened == id ? nil : id }
        if context.coordinator.signature != signature {
            context.coordinator.signature = signature
            view.textStorage?.setAttributedString(ReadingAttributed.build(text, style: style, context: self.context,
                                                                         hot: focus.hotCites, opened: focus.opened))
        }
        if let pending = focus.pendingPeek, cites.contains(pending), focus.peek == nil {
            DispatchQueue.main.async {
                view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)
                if let rect = view.firstChipRect(for: pending), focus.peek == nil {
                    focus.pendingPeek = nil
                    focus.peek = ChipPeekState(cite: pending, paragraph: paragraph, rect: rect)
                    focus.light(cites: answer.lit([pending]))
                }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: ReadingTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 688
        guard width.isFinite, width > 0, let layout = view.textLayoutManager, let container = view.textContainer else { return nil }
        container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: layout.documentRange)
        var bottom: CGFloat = 0
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
            for line in fragment.textLineFragments where line.characterRange.length > 0 {
                bottom = max(bottom, fragment.layoutFragmentFrame.minY + line.typographicBounds.maxY)
            }
            return true
        }
        let height = ceil(bottom > 0 ? bottom : layout.usageBoundsForTextContainer.height)
        view.frame.size = CGSize(width: width, height: height)
        return CGSize(width: width, height: height)
    }
}

struct ReadingText: View {
    let paragraph: String
    let text: String
    let style: ReadingStyle
    let context: AnswerContext
    @ObservedObject var focus: AnswerFocus
    var columnWidth: CGFloat = 688

    var body: some View {
        ReadingTextRepresentable(paragraph: paragraph, text: text, style: style, context: context, focus: focus)
            .overlay(alignment: .topLeading) {
                if let peek = focus.peek, peek.paragraph == paragraph {
                    ChipPeek(cite: peek.cite, context: context)
                        .offset(x: min(max(peek.rect.minX - 24, 0), columnWidth - ChipPeek.width), y: peek.rect.maxY + 8)
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .offset(y: 3)))
                }
            }
            .zIndex(focus.peek?.paragraph == paragraph ? 10 : 0)
    }
}

struct SourceFavicon: View {
    let host: String
    var size: CGFloat = 18

    var body: some View {
        Text(String(host.first.map { String($0).uppercased() } ?? "?"))
            .font(.system(size: size * 0.55, weight: .bold))
            .foregroundStyle(Ink.ink0)
            .frame(width: size, height: size)
            .background(color, in: RoundedRectangle(cornerRadius: 4))
    }

    private var color: Color {
        let palette: [Color] = [Ink.jade, Ink.iris, Ink.amber, Color(hex: 0x9BC4E2), Color(hex: 0xD6A6E0), Color(hex: 0xC9D17F)]
        let sum = host.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count]
    }
}

struct ChipPeek: View {
    static let width: CGFloat = 340
    let cite: String
    let context: AnswerContext

    var body: some View {
        let citation = context.citation(cite)
        let document = context.document(cite)
        let tier = context.tier(cite)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                SourceFavicon(host: document?.host ?? "?")
                Text(document?.host ?? "source not captured").font(Typeface.meta).foregroundStyle(Ink.text2)
            }
            .padding(.bottom, 6)
            if let title = document?.displayTitle, title != document?.host {
                Text(title).font(Typeface.ui(13, .semibold)).foregroundStyle(Ink.text1).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
            }
            Text("„\(citation?.quote.trimmingCharacters(in: .whitespacesAndNewlines) ?? "no stored quote")”")
                .font(Typeface.read(13.5)).foregroundStyle(Ink.text2).lineSpacing(3)
                .lineLimit(6).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(tier.label.prefix(1).uppercased() + tier.label.dropFirst()).foregroundStyle(tier.chipForeground)
                Spacer()
                Text("click to open").foregroundStyle(Ink.text3)
            }
            .font(Typeface.ui(11.5)).padding(.top, 10)
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 13)
        .frame(width: Self.width, alignment: .leading)
        .background(Ink.ink2, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.lineStrong))
        .shadow(color: .black.opacity(0.6), radius: 16, y: 12)
    }
}
