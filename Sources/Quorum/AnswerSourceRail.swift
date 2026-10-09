import SwiftUI
import AppKit
import QuorumCore

struct AnswerSourceRail: View {
    static let width: CGFloat = 460
    let cite: String
    let context: AnswerContext
    let evidenceDirectory: URL?
    @ObservedObject var focus: AnswerFocus

    private var citation: Citation? { context.citation(cite) }
    private var document: SourceDocument? { context.document(cite) }
    private var tier: CitationTier { context.tier(cite) }
    private var claim: AnswerClaimRow? { context.page.claim(citing: cite) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            Ink.line.frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let claim, claim.cites.count > 1 { inClaim(claim) }
                    if let claim {
                        Text("Cited for").font(Typeface.ui(12)).foregroundStyle(Ink.text3).padding(.bottom, 8)
                        Text(CitationMarkers.stripping(claim.text)).font(Typeface.bodyUI).foregroundStyle(Ink.text1)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 12)
                            .overlay(alignment: .leading) { Ink.lineStrong.frame(width: 2) }
                            .padding(.bottom, 22)
                    }
                    passage
                    if let why = why {
                        Text(why).font(Typeface.ui(12.5)).foregroundStyle(Ink.text2)
                            .padding(.horizontal, 13).padding(.vertical, 11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Ink.ink2, in: RoundedRectangle(cornerRadius: 8))
                            .padding(.top, 6)
                    }
                    facts.padding(.top, 22)
                }
                .padding(.horizontal, 22).padding(.vertical, 20)
            }
            Ink.line.frame(height: 1)
            HStack(spacing: 16) {
                Text("esc close").foregroundStyle(Ink.text3)
                Spacer()
                if let url = document.flatMap({ URL(string: $0.url) }) {
                    Button("Open the page") { NSWorkspace.shared.open(url) }.buttonStyle(.plain).foregroundStyle(Ink.iris)
                }
            }
            .font(Typeface.ui(12)).padding(.horizontal, 22).frame(height: 42)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Ink.ink0)
        .overlay(alignment: .leading) { Ink.line.frame(width: 1) }
        .environment(\.colorScheme, .dark)
    }

    private var head: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let number = context.number(cite) { ChipLabel(number: number, tier: tier) }
                Text(tier.label.prefix(1).uppercased() + tier.label.dropFirst()).font(Typeface.ui(12, .medium)).foregroundStyle(tier.chipForeground)
                Spacer()
                Button { focus.opened = nil } label: { Text("Close").font(Typeface.ui(12)).foregroundStyle(Ink.text3) }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 9) {
                SourceFavicon(host: document?.host ?? "?")
                Text(document?.host ?? "source not captured").font(Typeface.meta).foregroundStyle(Ink.text2)
            }
            .padding(.top, 16)
            Text(document?.displayTitle ?? "Source not captured").font(Typeface.ui(16, .semibold)).foregroundStyle(Ink.text1)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 8).padding(.bottom, 10)
            if let url = document?.url {
                Text(url).font(Typeface.ui(12.5)).foregroundStyle(Ink.text3).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 16)
    }

    private func inClaim(_ claim: AnswerClaimRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("In this claim").font(Typeface.ui(12)).foregroundStyle(Ink.text3).padding(.bottom, 6)
            ForEach(claim.cites, id: \.self) { id in
                let document = context.document(id)
                let hot = focus.hotCites.contains(id)
                HStack(spacing: 9) {
                    if let number = context.number(id) { ChipLabel(number: number, tier: context.tier(id), hot: hot) }
                    SourceFavicon(host: document?.host ?? "?", size: 16)
                    Text(document?.displayTitle ?? id).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(context.tier(id).label).font(Typeface.ui(11.5)).foregroundStyle(Ink.text3)
                }
                .font(Typeface.ui(12.5))
                .foregroundStyle(id == cite || hot ? Ink.text1 : Ink.text2)
                .padding(.horizontal, 8).frame(height: 32)
                .background(hot ? Ink.ink3 : .clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .leading) { if hot { Ink.iris.frame(width: 2) } }
                .padding(.horizontal, -8)
                .contentShape(Rectangle())
                .onTapGesture { focus.opened = id }
                .onHover { inside in focus.hotCites = inside ? [id] : [] }
            }
        }
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) { Ink.line.frame(height: 1) }
        .padding(.bottom, 20)
    }

    private var passage: some View {
        let quote = citation?.quote ?? ""
        let text = snapshotText
        let passage = text.map { QuotePassage(text: $0, quote: quote, start: citation?.start, end: citation?.end) }
            ?? QuotePassage(before: "", quote: quote, after: "")
        let highlight = tier == .unsupported || tier == .unresolved ? Ink.amberWash : Ink.jadeWash
        var out = AttributedString(passage.before)
        out.foregroundColor = Ink.text3
        var lit = AttributedString(passage.quote)
        lit.foregroundColor = Ink.text1
        lit.backgroundColor = highlight
        var after = AttributedString(passage.after)
        after.foregroundColor = Ink.text3
        out += lit
        out += after
        return Text(out).font(Typeface.read(15.5)).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var snapshotText: String? {
        guard let directory = evidenceDirectory, let path = document?.snapshotPath else { return nil }
        return try? String(contentsOf: directory.appendingPathComponent(path), encoding: .utf8)
    }

    private var why: String? {
        switch tier {
        case .supported: return nil
        case .close: return "The quote matched the stored page closely, not character for character."
        case .unsupported: return "The run's claim sweep found this quote does not carry the claim it is cited for."
        case .unresolved: return "The quote was not found in the stored copy of the page."
        }
    }

    private var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            if let fetched = document?.fetchedAt { fact("Captured", String(fetched.prefix(16)).replacingOccurrences(of: "T", with: " ")) }
            if let page = citation?.page { fact("Page", "\(page)") }
            fact("Match", citation?.match.rawValue ?? "unresolved")
            fact("Citation", cite)
        }
        .font(Typeface.ui(12.5))
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(Ink.text3).frame(width: 100, alignment: .leading)
            Text(value).foregroundStyle(Ink.text2).monospacedDigit()
        }
    }
}
