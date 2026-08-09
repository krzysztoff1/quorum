import SwiftUI
import AppKit
import PDFKit
import WebKit
import QuorumCore

/// PDFKit's own text search over the real page layout, driven by `QuoteLocator.pdfSearchCandidates`.
enum PDFQuoteSearch {
    static func selections(in document: PDFDocument, quote: String) -> [PDFSelection] {
        for candidate in QuoteLocator.pdfSearchCandidates(for: quote) {
            let found = document.findString(candidate, withOptions: [.caseInsensitive, .diacriticInsensitive])
            if !found.isEmpty { return found }
        }
        return []
    }
}

/// The JavaScript that finds a quote on a live page. The page is HTML nobody here controls, so the quote is
/// matched whitespace-loosely inside a single text node and wrapped in a `<mark>`; a quote broken across
/// inline tags falls back to `window.find`, which at least scrolls the reader to it.
enum LiveQuoteHighlight {
    static func script(for quote: String) -> String {
        """
        (function(){
          const norm = s => s.replace(/\\s+/g, ' ').trim();
          const target = norm(\(jsLiteral(quote)));
          if (target.length < 4) return false;
          const words = target.split(' ');
          const tries = [target, words.slice(0, 12).join(' '), words.slice(0, 6).join(' ')]
            .filter((t, i, all) => t.length >= 12 && all.indexOf(t) === i);
          const escape = s => s.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&').replace(/\\s+/g, '\\\\s+');
          for (const attempt of tries) {
            const pattern = new RegExp(escape(attempt), 'i');
            const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
            let node;
            while ((node = walker.nextNode())) {
              const hit = pattern.exec(node.data);
              if (!hit) continue;
              const range = document.createRange();
              range.setStart(node, hit.index);
              range.setEnd(node, hit.index + hit[0].length);
              const mark = document.createElement('mark');
              mark.style.background = '#ffd60a';
              mark.style.color = 'inherit';
              try { range.surroundContents(mark); } catch (error) { continue; }
              mark.scrollIntoView({ block: 'center' });
              return true;
            }
            if (window.find && window.find(attempt, false, false, true)) return true;
          }
          return false;
        })();
        """
    }

    private static func jsLiteral(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"":  out += "\\\""
            case "\\":  out += "\\\\"
            case "\n":  out += "\\n"
            case "\r":  out += "\\r"
            case "\t":  out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

/// A citation's source, shown the way its medium allows: the stored snapshot highlighted by the recorded
/// offsets (the offline ground truth and the default), the original PDF with the quote located in the real
/// page layout, or the live page — clearly labelled, because it may have changed since capture.
struct CitedSourceInspector: View {
    let citation: Citation
    let document: SourceDocument?
    let evidenceDir: URL
    /// What the run that produced this citation could check anything against (PRD 07). An unvalidated run
    /// shows the same tier here as its chip does, so the two can never tell the reader different stories.
    var grounding: RunGrounding = .captured
    var onClose: () -> Void = {}

    enum Mode: String, CaseIterable, Identifiable {
        case snapshot, pdf, live
        var id: String { rawValue }
        var label: String {
            switch self {
            case .snapshot: return "Snapshot"
            case .pdf:      return "PDF"
            case .live:     return "Live page"
            }
        }
        var icon: String {
            switch self {
            case .snapshot: return "doc.plaintext"
            case .pdf:      return "doc.richtext"
            case .live:     return "globe"
            }
        }
    }

    /// The snapshot and the passages located in it, kept as one value — a range only means something
    /// against the exact string it was found in.
    struct LocatedSnapshot {
        let text: String
        let passages: [Range<String.Index>]
    }

    @State private var chosenMode: Mode?
    @State private var snapshot: LocatedSnapshot?
    @State private var passageIndex = 0
    @State private var pdf: PDFDocument?
    @State private var pdfSelections: [PDFSelection] = []
    @State private var loadFailure: String?

    private var snapshotURL: URL? { existingFile(document?.snapshotPath) }
    private var originalURL: URL? { existingFile(document?.originalPath) }

    private var liveURL: URL? {
        guard let raw = document?.url, let url = URL(string: raw),
              url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }

    private var isPDF: Bool { document?.contentType == .pdf && originalURL != nil }

    private var availableModes: [Mode] {
        var modes: [Mode] = []
        if snapshotURL != nil { modes.append(.snapshot) }
        if isPDF { modes.append(.pdf) }
        if liveURL != nil { modes.append(.live) }
        return modes
    }

    /// The snapshot leads, then the original PDF. The live page is never opened on the reader's behalf — it
    /// is the escape hatch, chosen deliberately.
    private var mode: Mode? {
        if let chosenMode, availableModes.contains(chosenMode) { return chosenMode }
        return availableModes.first { $0 != .live }
    }

    private var matchCount: Int {
        switch mode {
        case .snapshot: return snapshot?.passages.count ?? 0
        case .pdf:      return pdfSelections.count
        default:        return 0
        }
    }

    private var pageLabel: Int? {
        if mode == .pdf, let page = pdfSelections[safe: passageIndex]?.pages.first, let pdf {
            return pdf.index(for: page) + 1
        }
        return citation.page
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: citation.id) { load() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: mode?.icon ?? "doc.questionmark").foregroundStyle(.secondary)
                Text(document?.displayTitle ?? "Uncaptured source")
                    .font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Close the source")
            }
            HStack(spacing: 10) {
                let seal = NodeStyle.seal(verified: shownMatch.isVerified)
                Label(shownMatch == .unresolved && grounding == .none
                        ? "unvalidated — no evidence was captured" : shownMatch.label,
                      systemImage: seal.icon)
                    .foregroundStyle(seal.color)
                if let host = document?.host, !host.isEmpty { Text(host) }
                if let page = pageLabel { Text("p. \(page)") }
                if let captured = capturedLabel { Text(captured) }
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)

            if !citation.quote.isEmpty {
                Text("“\(citation.quote)”")
                    .font(.callout).italic()
                    .lineLimit(4).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let caveat = matchCaveat {
                Label(caveat, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            controls
        }
        .padding(12)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if availableModes.count > 1 {
                Picker("", selection: Binding(get: { mode ?? availableModes[0] },
                                              set: { chosenMode = $0; passageIndex = 0 })) {
                    ForEach(availableModes) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            Spacer(minLength: 0)
            if matchCount > 1 {
                HStack(spacing: 2) {
                    Button { step(-1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                    Text("\(passageIndex + 1)/\(matchCount)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Button { step(1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                }
                .help("The quote occurs \(matchCount) times in this source")
            }
            if let url = liveURL {
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(.borderless).help("Open the live page in your browser")
            }
            if let file = snapshotURL ?? originalURL {
                Button { NSWorkspace.shared.activateFileViewerSelecting([file]) } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless).help("Reveal what was captured from this source in Finder")
            }
        }
    }

    private var capturedLabel: String? {
        guard let stamp = document?.fetchedAt, !stamp.isEmpty else { return nil }
        guard let date = ISO8601DateFormatter().date(from: stamp) else { return nil }
        return "captured " + date.formatted(date: .abbreviated, time: .shortened)
    }

    private var shownMatch: QuoteMatch { grounding == .none ? .unresolved : citation.match }

    private var matchCaveat: String? {
        if grounding == .none {
            return "This run captured no evidence — its sources were read through built-in web search, which keeps no snapshot. Nothing here has been checked."
        }
        switch citation.match {
        case .fuzzy:
            return "Approximate match — the snapshot says this in close but not identical words, so the highlighted span is where it best lines up."
        case .unresolved:
            guard snapshotURL != nil else { return nil }
            return "This quote was not found in the stored snapshot, so nothing is highlighted. Read the source yourself before relying on the sentence."
        case .exact, .normalized:
            return nil
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let loadFailure {
            ContentUnavailableView("Couldn’t open the source", systemImage: "exclamationmark.triangle",
                                   description: Text(loadFailure))
        } else {
            switch mode {
            case .snapshot: snapshotContent
            case .pdf:      pdfContent
            case .live:     liveContent
            case .none:     unverifiableState
            }
        }
    }

    @ViewBuilder private var snapshotContent: some View {
        if let snapshot {
            VStack(spacing: 0) {
                if snapshot.passages.isEmpty {
                    banner("The quote isn’t in this snapshot, so nothing is highlighted — this is the text as it was captured.")
                }
                SnapshotTextView(text: snapshot.text, highlight: snapshot.passages[safe: passageIndex])
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var pdfContent: some View {
        if let pdf {
            VStack(spacing: 0) {
                if pdfSelections.isEmpty {
                    banner("The quote isn’t findable in the PDF’s own text layer — showing the page it was captured from.")
                }
                PDFQuoteView(document: pdf, selection: pdfSelections[safe: passageIndex], fallbackPage: citation.page)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var liveContent: some View {
        if let url = liveURL {
            VStack(spacing: 0) {
                banner("The live page as it is right now — it may have changed since this research ran. The snapshot is the record.")
                LiveQuoteWebView(url: url, quote: citation.quote)
            }
        }
    }

    @ViewBuilder private var unverifiableState: some View {
        if document == nil {
            ContentUnavailableView("Source wasn’t captured", systemImage: "questionmark.folder",
                                   description: Text("This citation points at a source the run never registered, so there is nothing to open."))
        } else {
            VStack(spacing: 14) {
                ContentUnavailableView {
                    Label(citation.isVerified ? "Snapshot not kept" : "No snapshot",
                          systemImage: citation.isVerified ? "checkmark.seal" : "doc.badge.ellipsis")
                } description: {
                    // A quote can be verified against text the engine held in memory and never wrote to
                    // disk (a run given no evidence directory). Saying "unverifiable" there would report a
                    // check that did happen as one that didn't.
                    Text(citation.isVerified
                         ? "This quote was matched against the source when the research ran, but the page itself wasn’t kept, so it can’t be shown highlighted here. The live page may have changed since."
                         : "No snapshot was captured for this source — the quote can’t be verified. Only the live page is available, and it may have changed since the research ran.")
                }
                if citation.isVerified {
                    quoteCard
                }
                if let url = liveURL {
                    Button { chosenMode = .live } label: { Label("Open the live page here", systemImage: "globe") }
                    Button { NSWorkspace.shared.open(url) } label: { Label("Open live ↗", systemImage: "arrow.up.forward.app") }
                        .buttonStyle(.link)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The quote itself, for the case where it was verified but the page wasn't retained — the reader can
    /// still read the passage that was matched and search for it on the live page.
    private var quoteCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The matched passage")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text("“\(citation.quote)”")
                .font(.callout).italic()
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func banner(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Color.secondary.opacity(0.10))
    }

    // MARK: Loading

    private func step(_ delta: Int) {
        guard matchCount > 0 else { return }
        passageIndex = ((passageIndex + delta) % matchCount + matchCount) % matchCount
    }

    private func existingFile(_ relativePath: String?) -> URL? {
        guard let relativePath, !relativePath.isEmpty else { return nil }
        let url = evidenceDir.appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func load() {
        chosenMode = nil
        passageIndex = 0
        snapshot = nil
        pdf = nil
        pdfSelections = []
        loadFailure = nil

        if let url = snapshotURL {
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let located = grounding == .none
                    ? (ranges: [Range<String.Index>](), index: 0)
                    : QuoteLocator.passages(for: citation, in: text)
                snapshot = LocatedSnapshot(text: text, passages: located.ranges)
                passageIndex = located.index
            } catch {
                loadFailure = error.localizedDescription
            }
        }
        if let url = originalURL, isPDF, let opened = PDFDocument(url: url) {
            pdf = opened
            pdfSelections = PDFQuoteSearch.selections(in: opened, quote: citation.quote)
        }
    }
}

/// The stored extraction, highlighted by the offsets that index into it and scrolled so the passage sits in
/// the middle of the view. TextKit 1 on purpose: it is the layout manager that can say where a character
/// range ended up on screen.
struct SnapshotTextView: NSViewRepresentable {
    let text: String
    let highlight: Range<String.Index>?

    final class Coordinator {
        var appliedText: String?
        var appliedHighlight: NSRange?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 16, height: 14)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let range = highlight.map { NSRange($0, in: text) }
        guard context.coordinator.appliedText != text || context.coordinator.appliedHighlight != range else { return }
        context.coordinator.appliedText = text
        context.coordinator.appliedHighlight = range

        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.textColor,
        ])
        if let range, range.upperBound <= attributed.length {
            attributed.addAttributes([
                .backgroundColor: NSColor.systemYellow.withAlphaComponent(0.45),
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            ], range: range)
        }
        textView.textStorage?.setAttributedString(attributed)

        guard let range, range.upperBound <= attributed.length else { return }
        DispatchQueue.main.async {
            center(range, in: textView, of: scrollView)
            textView.showFindIndicator(for: range)
        }
    }

    private func center(_ range: NSRange, in textView: NSTextView, of scrollView: NSScrollView) {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.y += textView.textContainerInset.height
        let visible = scrollView.contentView.bounds.height
        let top = max(0, min(rect.midY - visible / 2, textView.bounds.height - visible))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: top))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

/// The original PDF with the quote highlighted where a person would point at it: PDFKit's own text search
/// finds it in the real page layout, which is the only thing markdown character offsets cannot do.
struct PDFQuoteView: NSViewRepresentable {
    let document: PDFDocument
    let selection: PDFSelection?
    let fallbackPage: Int?

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
        if let selection {
            selection.color = NSColor.systemYellow.withAlphaComponent(0.5)
            view.highlightedSelections = [selection]
            view.go(to: selection)
        } else {
            view.highlightedSelections = nil
            if let fallbackPage, let page = document.page(at: max(0, fallbackPage - 1)) { view.go(to: page) }
        }
    }
}

/// The live page with the quote found and marked by injected JavaScript. Best-effort by nature: the page
/// may have been rewritten, paywalled, or lazily rendered since it was captured.
struct LiveQuoteWebView: NSViewRepresentable {
    let url: URL
    let quote: String

    final class Coordinator: NSObject, WKNavigationDelegate {
        var quote: String

        init(quote: String) { self.quote = quote }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript(LiveQuoteHighlight.script(for: quote))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(quote: quote) }

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: url))
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.quote = quote
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
