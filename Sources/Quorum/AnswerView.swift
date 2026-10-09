import SwiftUI
import AppKit
import QuorumCore

@MainActor
final class AnswerFocus: ObservableObject {
    @Published var hotCites: Set<String> = []
    @Published var hotRow: String?
    @Published var opened: String?
    @Published var peek: ChipPeekState?
    @Published var pendingPeek: String?
    let tables: Set<String>
    let charts: Set<String>

    init(hot: String? = nil, opened: String? = nil, tables: Set<String> = [], charts: Set<String> = [], peek: String? = nil) {
        if let hot { hotCites = [hot] }
        self.opened = opened
        self.tables = tables
        self.charts = charts
        pendingPeek = peek
        if let peek { hotCites.insert(peek) }
    }
}

struct AnswerContext {
    let page: AnswerPage
    let evidence: EvidenceIndex

    init(page: AnswerPage, evidence: EvidenceIndex) {
        self.page = page
        self.evidence = evidence
    }

    init?(run: StoredRun) {
        guard let page = AnswerPage(run: run) else { return nil }
        self.page = page
        evidence = run.evidence(forNode: page.answerNodeID ?? "synthesis")?.index ?? run.evidenceIndex
    }

    static func meta(_ run: StoredRun) -> String {
        let stats = run.record.stats
        let date = StoredRunDate.short(run.createdAt)
        return [Format.duration(stats.durationS), Format.money(stats.costUSD),
                "\(stats.tasks) angle\(stats.tasks == 1 ? "" : "s")", date].joined(separator: "   ")
    }

    func tier(_ id: String) -> CitationTier { evidence.tier(id) }
    func number(_ id: String) -> Int? { page.number(of: id) }
    func citation(_ id: String) -> Citation? { evidence.citation(id) }
    func document(_ id: String) -> SourceDocument? { evidence.citation(id).flatMap { evidence.document(for: $0) } }
}

enum ChipProse {
    static func attributed(_ text: String, context: AnswerContext, hot: Set<String>, opened: String?) -> AttributedString {
        var out = AttributedString()
        var cursor = text.startIndex
        let markers = CitationMarkers.markers(in: text)
        for (index, marker) in markers.enumerated() {
            var before = String(text[cursor..<marker.range.lowerBound])
            if index > 0, markers[index - 1].range.upperBound == marker.range.lowerBound { before = "" }
            out += AttributedString(before)
            out += AttributedString("\u{2009}")
            out += chip(marker.id, context: context, hot: hot.contains(marker.id), opened: opened == marker.id)
            cursor = marker.range.upperBound
        }
        out += AttributedString(String(text[cursor...]))
        return out
    }

    static func chip(_ id: String, context: AnswerContext, hot: Bool, opened: Bool) -> AttributedString {
        guard let number = context.number(id) else { return AttributedString() }
        let tier = context.tier(id)
        var run = AttributedString("\u{2009}\(number)\(tier.mark)\u{2009}")
        run.font = Typeface.chip.monospacedDigit()
        run.baselineOffset = 2
        run.foregroundColor = opened ? Ink.ink0 : tier.chipForeground
        run.backgroundColor = opened ? Ink.iris : hot ? tier.chipForeground.opacity(0.32) : tier.chipBackground
        if context.citation(id) != nil { run.link = CitationLink.url(id) }
        return run
    }
}

struct AnswerView: View {
    let context: AnswerContext
    @ObservedObject var focus: AnswerFocus
    var meta: String = ""
    var scrolls = true

    var body: some View {
        Group {
            if scrolls {
                ScrollView { column }
            } else {
                column
            }
        }
        .background(Ink.ink1)
        .environment(\.colorScheme, .dark)
        .environment(\.openURL, OpenURLAction { url in
            guard let id = CitationLink.citationID(in: url) else { return .systemAction }
            focus.opened = focus.opened == id ? nil : id
            return .handled
        })
    }

    private var page: AnswerPage { context.page }

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            AnswerTrustStrip(strip: page.strip)
                .padding(.top, 22).padding(.bottom, 28)
            ReadingText(paragraph: "lead", text: page.lead, style: .lead, context: context, focus: focus)
                .padding(.bottom, 8)
                .zIndex(focus.peek?.paragraph == "lead" ? 10 : 0)
            ForEach(page.sections) { section in
                if !section.title.isEmpty {
                    Text(section.title).font(Typeface.meta.weight(.medium)).foregroundStyle(Ink.text3)
                        .padding(.top, 22).padding(.bottom, 6)
                }
                ForEach(section.items) { item in
                    switch item {
                    case .claim(let claim):
                        AnswerClaimView(claim: claim, context: context, focus: focus)
                            .zIndex(focus.peek?.paragraph == claim.id ? 10 : 0)
                    case .figure(let figure): AnswerFigureCard(figure: figure, context: context, focus: focus)
                    }
                }
            }
            if page.openItems.count > 0 { AnswerOpenItemsView(items: page.openItems).padding(.top, 36) }
        }
        .textSelection(.enabled)
        .frame(width: 688, alignment: .leading)
        .padding(.top, 34).padding(.bottom, 64)
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !meta.isEmpty {
                Text(meta).font(Typeface.meta).foregroundStyle(Ink.text3).monospacedDigit()
            }
            Text(page.title).font(Typeface.title).tracking(-0.4).foregroundStyle(Ink.text1)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12).padding(.bottom, 8)
            if page.question != page.title {
                Text(page.question).font(Typeface.ui(15)).foregroundStyle(Ink.text2).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 620, alignment: .leading)
            }
        }
    }
}


struct AnswerTrustStrip: View {
    let strip: AnswerStrip

    var body: some View {
        HStack(spacing: 0) {
            cell(first: true) {
                HStack(spacing: 3) {
                    ForEach(Array(strip.claimMarks.enumerated()), id: \.offset) { _, mark in
                        GutterRule(strength: mark).frame(height: 13)
                    }
                }
                Text(strip.trustLevel.rawValue.capitalized).fontWeight(.semibold).foregroundStyle(Ink.text1)
                Text("\(strip.claimMarks.filter { $0 == .solid }.count) of \(strip.claimMarks.count) solid").foregroundStyle(Ink.text3)
            }
            if strip.conflictsOpen > 0 {
                cell { ConflictGlyph(); Text("\(strip.conflictsOpen)").fontWeight(.semibold).foregroundStyle(Ink.text1); Text("open conflict\(strip.conflictsOpen == 1 ? "" : "s")") }
            }
            cell {
                Text("\(strip.sourcesCited)").fontWeight(.semibold).foregroundStyle(Ink.text1)
                Text("sources")
                Text("of \(strip.sourcesRead) read").foregroundStyle(Ink.text3)
            }
            if strip.objectionsOpen > 0 {
                cell { ObjectionGlyph(); Text("\(strip.objectionsOpen) open").foregroundStyle(Ink.text2) }
            }
            if strip.unverifiedNumbers > 0 {
                cell { WarningGlyph(); Text("\(strip.unverifiedNumbers) number\(strip.unverifiedNumbers == 1 ? "" : "s") not in quote") }
            }
            if !strip.checkProblems.isEmpty {
                cell { WarningGlyph(color: .red); Text("\(strip.checkProblems.count) check failed").foregroundStyle(.red) }
                    .help(strip.checkProblems.joined(separator: "\n"))
            }
            Spacer(minLength: 0)
        }
        .font(Typeface.meta)
        .foregroundStyle(Ink.text2)
        .monospacedDigit()
        .frame(height: 38)
        .overlay(alignment: .top) { Ink.line.frame(height: 1) }
        .overlay(alignment: .bottom) { Ink.line.frame(height: 1) }
    }

    private func cell<Content: View>(first: Bool = false, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 7) { content() }
            .padding(.leading, first ? 0 : 13).padding(.trailing, 13)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .leading) { if !first { Ink.line.frame(width: 1) } }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

struct AnswerClaimView: View {
    let claim: AnswerClaimRow
    let context: AnswerContext
    @ObservedObject var focus: AnswerFocus

    private var lit: Bool { !focus.hotCites.isDisjoint(with: claim.cites) || claim.cites.contains(focus.opened ?? "") }

    var body: some View {
        ReadingText(paragraph: claim.id, text: claim.text, style: lit ? .claimLit : .claim, context: context, focus: focus,
                    columnWidth: 670)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 18)
            .overlay(alignment: .leading) {
                GutterRule(strength: claim.strength, focused: lit).padding(.vertical, 6)
            }
        .padding(.vertical, 7).padding(.leading, 0).padding(.trailing, 18)
        .background(lit ? Color.white.opacity(0.028) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .padding(.leading, -18)
        .overlay(alignment: .topLeading) {
            if lit, let reason = claim.reason {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(claim.strength == .solid ? "Solid" : claim.strength == .shaky ? "Shaky" : "Unchecked")
                        .font(Typeface.small).foregroundStyle(Ink.text3)
                    Text(reason).font(Typeface.ui(11.5)).foregroundStyle(Ink.text4).multilineTextAlignment(.trailing)
                }
                .frame(width: 108, alignment: .trailing)
                .offset(x: -150, y: 11)
            }
        }
        .padding(.top, 2)
    }
}

enum StoredRunDate {
    static func short(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMM, HH:mm"
        return formatter.string(from: date)
    }
}

struct AnswerScreen: View {
    let context: AnswerContext
    @ObservedObject var focus: AnswerFocus
    var meta = ""
    var evidenceDirectory: URL?
    var scrolls = true

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            AnswerView(context: context, focus: focus, meta: meta, scrolls: scrolls)
            if let opened = focus.opened, context.citation(opened) != nil {
                AnswerSourceRail(cite: opened, context: context, evidenceDirectory: evidenceDirectory, focus: focus)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.timingCurve(0.65, 0, 0.35, 1, duration: 0.22), value: focus.opened)
        .background(Ink.ink1)
    }
}

struct AnswerOpenItemsView: View {
    let items: AnswerOpenItems

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Open items").font(Typeface.ui(13.5, .semibold)).foregroundStyle(Ink.text1)
                Text("what this answer could not settle").font(Typeface.meta).foregroundStyle(Ink.text3)
            }
            .padding(.bottom, 16)
            ForEach(items.conflicts) { conflict in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        ConflictGlyph()
                        Text(conflict.statement).font(Typeface.ui(13, .medium)).foregroundStyle(Ink.text1)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    Ink.line.frame(height: 1)
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(conflict.positions.enumerated()), id: \.offset) { index, position in
                            Text(position).font(Typeface.bodyUI).foregroundStyle(Ink.text2)
                                .padding(.horizontal, 14).padding(.vertical, 12)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .overlay(alignment: .leading) { if index > 0 { Ink.line.frame(width: 1) } }
                        }
                    }
                }
                .background(Ink.ink0, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.line))
                .padding(.bottom, 12)
            }
            ForEach(items.objections) { objection in
                row(glyph: AnyView(ObjectionGlyph()), text: objection.statement, detail: objection.followup, tag: objection.lens)
            }
            ForEach(Array(items.gaps.enumerated()), id: \.offset) { _, gap in
                row(glyph: AnyView(Circle().strokeBorder(Ink.text3, lineWidth: 1.5).frame(width: 9, height: 9)), text: gap, detail: nil, tag: "gap")
            }
        }
        .padding(.top, 22)
        .overlay(alignment: .top) { Ink.line.frame(height: 1) }
    }

    private func row(glyph: AnyView, text: String, detail: String?, tag: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            glyph.frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).foregroundStyle(Ink.text2)
                if let detail { Text("→ \(detail)").foregroundStyle(Ink.text3) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(tag).font(Typeface.ui(12)).foregroundStyle(Ink.text3)
        }
        .font(Typeface.bodyUI)
        .padding(.vertical, 9)
        .overlay(alignment: .top) { Ink.line.frame(height: 1) }
    }
}
