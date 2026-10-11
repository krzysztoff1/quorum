import SwiftUI
import Charts
import QuorumCore

struct AnswerFigureCard: View {
    let figure: AnswerFigure
    let context: AnswerContext
    @ObservedObject var focus: AnswerFocus
    @State private var showsTable: Bool

    init(figure: AnswerFigure, context: AnswerContext, focus: AnswerFocus) {
        self.figure = figure
        self.context = context
        self.focus = focus
        _showsTable = State(initialValue: (figure.display == .table || focus.tables.contains(figure.id)) && !focus.charts.contains(figure.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
            content.padding(.top, 12)
            footer
        }
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
        .background(Ink.ink0, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.line))
        .padding(.top, 14).padding(.bottom, 6)
    }

    private var heading: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                if !isStat {
                    Text(figure.measure).font(Typeface.ui(13.5, .semibold)).foregroundStyle(Ink.text1)
                }
                if !figure.caption.isEmpty {
                    Text(ChipProse.attributed(figure.caption, context: context, hot: focus.hotCites, opened: focus.opened))
                        .font(Typeface.ui(12)).foregroundStyle(Ink.text3).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if figure.togglesTable {
                FigureToggle(showsTable: $showsTable)
            }
        }
    }

    private var isStat: Bool {
        if case .stat = figure.kind { return true }
        return false
    }

    @ViewBuilder private var content: some View {
        switch figure.kind {
        case .range(let range):
            if showsTable { FigureTable(rows: range.rows.map(FigureRow.init) + (range.reference.map { [FigureRow($0)] } ?? []), measure: figure.measure, context: context, focus: focus) }
            else { legend(range.rows.map(\.value.mark)); RangeChart(range: range, context: context, focus: focus) }
        case .bars(let bars):
            if showsTable { FigureTable(rows: bars.bars.map(FigureRow.init), measure: figure.measure, context: context, focus: focus) }
            else { legend(bars.bars.map(\.value.mark)); BarChart(bars: bars, context: context, focus: focus) }
        case .stat(let stat):
            StatView(stat: stat, context: context, focus: focus)
        case .conflict(let conflict):
            ConflictView(conflict: conflict, context: context, focus: focus)
        case .mix(let mix):
            SourceMixView(mix: mix)
        case .table(let table):
            EvidenceTableView(table: table, context: context, focus: focus)
        case .fallback:
            Text(figure.fallbackMarkdown).font(Typeface.ui(12.5)).foregroundStyle(Ink.text2)
        }
    }

    private func legend(_ marks: [DatumMark]) -> some View {
        let shown = [DatumMark.verified, .close, .estimate, .unverified].filter(marks.contains)
        return HStack(spacing: 18) {
            ForEach(shown, id: \.self) { mark in
                HStack(spacing: 7) { MarkSwatch(mark: mark); Text(mark.legend) }
            }
        }
        .font(Typeface.ui(12)).foregroundStyle(Ink.text2)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var footer: some View {
        let notes = figure.footnotes
        if let row = focus.hotRow.flatMap(figure.row), !showsTable {
            DatumPeek(label: row.label, value: row.value, context: context)
                .padding(.top, 10)
                .overlay(alignment: .top) { Ink.line.frame(height: 1) }
                .padding(.top, 8)
        } else if !notes.isEmpty || figure.togglesTable {
            HStack(alignment: .top, spacing: 10) {
                if !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(notes, id: \.self) { note in
                            HStack(spacing: 7) { WarningGlyph(); Text(note).foregroundStyle(Ink.text2) }
                        }
                    }
                }
                Spacer(minLength: 0)
                if figure.togglesTable && !showsTable { Text("Hover a row to see its quote") }
            }
            .font(Typeface.ui(12)).foregroundStyle(Ink.text3)
            .padding(.top, 10)
            .overlay(alignment: .top) { Ink.line.frame(height: 1) }
            .padding(.top, 8)
        }
    }
}

struct FigureToggle: View {
    @Binding var showsTable: Bool

    var body: some View {
        HStack(spacing: 0) {
            button("Chart", selected: !showsTable) { showsTable = false }
            button("Table", selected: showsTable) { showsTable = true }
        }
        .padding(2)
        .background(Ink.ink2, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Ink.line))
    }

    private func button(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Typeface.ui(11.5, .medium))
                .foregroundStyle(selected ? Ink.text1 : Ink.text3)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(selected ? Ink.ink3 : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}

struct FigureRow: Identifiable {
    let id: String
    let label: String
    let sublabel: String?
    let group: String?
    let value: FigureValue

    init(_ row: RangeFigureRow) { id = row.id; label = row.label; sublabel = row.sublabel; group = row.group; value = row.value }
    init(_ row: BarFigureRow) { id = row.id; label = row.label; sublabel = row.sublabel; group = nil; value = row.value }
}

struct ChipRow: View {
    let cites: [String]
    let context: AnswerContext
    @ObservedObject var focus: AnswerFocus

    var body: some View {
        HStack(spacing: 2) {
            ForEach(distinctCites, id: \.self) { id in
                if let number = context.number(id) {
                    ChipLabel(number: number, tier: context.tier(id), hot: focus.hotCites.contains(id))
                        .onTapGesture { focus.opened = focus.opened == id ? nil : id }
                }
            }
        }
    }

    private var distinctCites: [String] {
        var seen = Set<String>()
        return cites.filter { seen.insert($0).inserted }
    }
}

struct RowLabel: View {
    let label: String
    let sublabel: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(Ink.text1).fontWeight(.medium)
            if let sublabel { Text(sublabel).foregroundStyle(Ink.text4) }
        }
        .font(Typeface.ui(12.5))
        .lineLimit(1)
        .truncationMode(.tail)
    }
}

private let labelWidth: CGFloat = 250
private let rowHeight: CGFloat = 32

struct RangeChart: View {
    let range: RangeFigure
    let context: AnswerContext
    @ObservedObject var focus: AnswerFocus

    private var groups: [(name: String?, rows: [RangeFigureRow])] {
        var out: [(name: String?, rows: [RangeFigureRow])] = []
        for row in range.rows {
            if let last = out.last, last.name == row.group { out[out.count - 1].rows.append(row) } else { out.append((row.group, [row])) }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                if let name = group.name {
                    Text(name).font(Typeface.ui(12, .medium)).foregroundStyle(Ink.text3)
                        .padding(.leading, 8).padding(.top, index == 0 ? 0 : 8).padding(.bottom, 2)
                }
                chart(group.rows, axis: index == groups.count - 1)
            }
        }
    }

    private func clamp(_ value: Double) -> Double { min(max(value, range.domain.lowerBound), range.domain.upperBound) }

    private func chart(_ rows: [RangeFigureRow], axis: Bool) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    RowLabel(label: row.label, sublabel: row.sublabel)
                        .padding(.leading, 8)
                        .frame(width: labelWidth, height: rowHeight, alignment: .leading)
                }
                if axis { Color.clear.frame(height: 22) }
            }
            Chart {
                ForEach(rows) { row in
                    if row.value.isRange && !row.offScale {
                        RuleMark(xStart: .value("low", clamp(row.value.low)), xEnd: .value("high", clamp(row.value.high)), y: .value("row", row.id))
                            .lineStyle(StrokeStyle(lineWidth: 10, lineCap: .round))
                            .foregroundStyle(row.value.mark.fill)
                            .accessibilityLabel(row.label)
                            .accessibilityValue(row.value.spoken)
                            .annotation(position: .trailing, alignment: .leading, spacing: 8) { valueLabel(row) }
                    } else {
                        PointMark(x: .value("value", clamp(row.value.high)), y: .value("row", row.id))
                            .symbol(row.offScale ? .triangle : .circle)
                            .symbolSize(row.offScale ? 90 : 110)
                            .foregroundStyle(row.value.mark.fill)
                            .accessibilityLabel(row.label)
                            .accessibilityValue(row.value.spoken + (row.offScale ? ", beyond the scale" : ""))
                            .annotation(position: row.offScale ? .leading : .trailing, alignment: row.offScale ? .trailing : .leading, spacing: 8) { valueLabel(row) }
                    }
                }
                if let reference = range.reference {
                    RuleMark(x: .value("reference", clamp(reference.value.high)))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .foregroundStyle(Ink.iris.opacity(0.6))
                }
            }
            .chartXScale(domain: range.domain)
            .chartYScale(domain: rows.map(\.id))
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: AxisTicks.values(range.domain)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Ink.line)
                    if axis {
                        AxisValueLabel {
                            if let number = value.as(Double.self) { Text(axisText(number)).font(Typeface.ui(11)).foregroundStyle(Ink.text3) }
                        }
                    }
                }
            }
            .chartPlotStyle { plot in plot.background(Color.clear) }
            .chartOverlay { proxy in hoverLayer(proxy: proxy, rows: rows) }
            .frame(height: CGFloat(rows.count) * rowHeight + (axis ? 22 : 0))
            .padding(.trailing, 56)
        }
        .background(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    RoundedRectangle(cornerRadius: 6)
                        .fill(focus.hotRow == row.id || !focus.hotCites.isDisjoint(with: row.value.cites) ? Color.white.opacity(0.035) : .clear)
                        .frame(height: rowHeight)
                }
            }
        }
    }

    private func valueLabel(_ row: RangeFigureRow) -> some View {
        HStack(spacing: 5) {
            if row.value.mark == .unverified { WarningGlyph() }
            Text(row.value.markedText + (row.offScale ? " →" : "")).font(Typeface.ui(12.5, .medium)).foregroundStyle(row.value.mark.valueColor).monospacedDigit()
            ChipRow(cites: row.value.cites, context: context, focus: focus)
        }
        .fixedSize()
    }

    private func axisText(_ number: Double) -> String {
        let unit = range.rows.first?.value.text.hasSuffix("%") == true ? "%" : ""
        return DatumFormat.number(number) + unit
    }

    private func hoverLayer(proxy: ChartProxy, rows: [RangeFigureRow]) -> some View {
        Rectangle().fill(.clear).contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let id: String? = proxy.value(atY: location.y)
                    let row = rows.first { $0.id == id }
                    focus.light(cites: context.lit(row?.value.cites ?? []), row: row?.id)
                case .ended:
                    focus.light(cites: [])
                }
            }
    }
}

struct BarChart: View {
    let bars: BarFigure
    let context: AnswerContext
    @ObservedObject var focus: AnswerFocus

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(bars.bars) { bar in
                    RowLabel(label: bar.label, sublabel: bar.sublabel)
                        .padding(.leading, 8)
                        .frame(width: labelWidth, height: rowHeight, alignment: .leading)
                }
                Color.clear.frame(height: 22)
            }
            Chart(bars.bars) { bar in
                BarMark(xStart: .value("zero", 0), xEnd: .value("value", min(max(bar.value.high, bars.domain.lowerBound), bars.domain.upperBound)),
                        y: .value("bar", bar.id), height: .fixed(10))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(bar.value.mark.fill)
                    .accessibilityLabel(bar.label)
                    .accessibilityValue(bar.value.spoken + (bar.offScale ? ", beyond the scale" : ""))
                    .annotation(position: .trailing, alignment: .leading, spacing: 8) {
                        HStack(spacing: 5) {
                            if bar.value.mark == .unverified { WarningGlyph() }
                            Text(bar.value.markedText + (bar.offScale ? " →" : "")).font(Typeface.ui(12.5, .medium)).foregroundStyle(bar.value.mark.valueColor).monospacedDigit()
                            ChipRow(cites: bar.value.cites, context: context, focus: focus)
                        }
                        .fixedSize()
                    }
            }
            .chartXScale(domain: bars.domain)
            .chartYScale(domain: bars.bars.map(\.id))
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: AxisTicks.values(bars.domain)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Ink.line)
                    AxisValueLabel {
                        if let number = value.as(Double.self) { Text(compact(number)).font(Typeface.ui(11)).foregroundStyle(Ink.text3) }
                    }
                }
            }
            .chartOverlay { proxy in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let id: String? = proxy.value(atY: location.y)
                            let bar = bars.bars.first { $0.id == id }
                            focus.light(cites: context.lit(bar?.value.cites ?? []), row: bar?.id)
                        case .ended:
                            focus.light(cites: [])
                        }
                    }
            }
            .frame(height: CGFloat(bars.bars.count) * rowHeight + 22)
            .padding(.trailing, 84)
        }
        .background(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(bars.bars) { bar in
                    RoundedRectangle(cornerRadius: 6)
                        .fill(focus.hotRow == bar.id || !focus.hotCites.isDisjoint(with: bar.value.cites) ? Color.white.opacity(0.035) : .clear)
                        .frame(height: rowHeight)
                }
            }
        }
    }

    private func compact(_ number: Double) -> String {
        let prefix = bars.bars.first?.value.text.trimmingCharacters(in: CharacterSet(charactersIn: "<>~")).first.map(String.init) ?? ""
        let sign = ["$", "€", "£"].contains(prefix) ? prefix : ""
        let minus = number < 0 ? "-" : ""
        let size = abs(number)
        if size >= 1e9 { return minus + sign + DatumFormat.number(size / 1e9) + "B" }
        if size >= 1e6 { return minus + sign + DatumFormat.number(size / 1e6) + "M" }
        if size >= 1e3 { return minus + sign + DatumFormat.number(size / 1e3) + "k" }
        return minus + sign + DatumFormat.number(size) + (bars.bars.first?.value.text.hasSuffix("%") == true ? "%" : "")
    }
}

struct FigureTable: View {
    let rows: [FigureRow]
    let measure: String
    let context: AnswerContext
    @ObservedObject var focus: AnswerFocus

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                Text(measure).gridColumnAlignment(.trailing)
                Text("Sources")
            }
            .font(Typeface.ui(12.5, .medium)).foregroundStyle(Ink.text3)
            .padding(.bottom, 8)
            Ink.line.frame(height: 1).gridCellUnsizedAxes(.horizontal)
            ForEach(rows) { row in
                GridRow {
                    RowLabel(label: row.label, sublabel: row.sublabel)
                    HStack(spacing: 6) {
                        MarkSwatch(mark: row.value.mark, width: 10)
                        if row.value.mark == .unverified { WarningGlyph() }
                        Text(row.value.markedText).foregroundStyle(row.value.mark.valueColor).fontWeight(.medium).monospacedDigit()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(row.label)
                    .accessibilityValue(row.value.spoken)
                    ChipRow(cites: row.value.cites, context: context, focus: focus)
                }
                .font(Typeface.ui(12.5))
                .frame(height: 34)
                .opacity(focus.hotCites.isEmpty || !focus.hotCites.isDisjoint(with: row.value.cites) ? 1 : 0.55)
                .help(row.value.why ?? "")
                Ink.line.frame(height: 1).gridCellUnsizedAxes(.horizontal)
            }
        }
    }
}

struct EvidenceTableView: View {
    let table: TableFigure
    let context: AnswerContext
    @ObservedObject var focus: AnswerFocus

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
            GridRow {
                ForEach(table.columns, id: \.key) { column in
                    Text(column.label).gridColumnAlignment(column.align == "end" ? .trailing : .leading)
                }
                Text("Sources")
            }
            .font(Typeface.ui(12.5, .medium)).foregroundStyle(Ink.text3)
            .padding(.bottom, 8)
            Ink.line.frame(height: 1).gridCellUnsizedAxes(.horizontal)
            ForEach(table.rows) { row in
                GridRow {
                    ForEach(Array(row.cells.enumerated()), id: \.offset) { index, cell in
                        HStack(spacing: 6) {
                            if let value = cell.value {
                                MarkSwatch(mark: value.mark, width: 10)
                                if value.mark == .unverified { WarningGlyph() }
                            }
                            Text(cell.value.map(\.markedText) ?? CitationMarkers.stripping(cell.text))
                                .foregroundStyle(cell.value?.mark.valueColor ?? (index == 0 ? Ink.text1 : Ink.text2))
                                .fontWeight(index == 0 || cell.value != nil ? .medium : .regular)
                                .monospacedDigit()
                        }
                    }
                    ChipRow(cites: row.cells.flatMap(\.cites), context: context, focus: focus)
                }
                .font(Typeface.ui(12.5))
                .frame(height: 34)
                .opacity(focus.hotCites.isEmpty || !focus.hotCites.isDisjoint(with: row.cells.flatMap(\.cites)) ? 1 : 0.55)
                Ink.line.frame(height: 1).gridCellUnsizedAxes(.horizontal)
            }
        }
    }
}

struct StatView: View {
    let stat: StatFigure
    let context: AnswerContext
    @ObservedObject var focus: AnswerFocus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if stat.value.mark == .unverified { WarningGlyph() }
                Text(stat.value.text).font(Typeface.ui(34, .semibold)).tracking(-0.6)
                    .foregroundStyle(stat.value.mark.valueColor).monospacedDigit()
                VStack(alignment: .leading, spacing: 2) {
                    Text(stat.label).font(Typeface.ui(13.5)).foregroundStyle(Ink.text2)
                    if let of = stat.of { part("of", of) }
                    if let context = stat.context { part("compared with", context) }
                }
                Spacer(minLength: 0)
                ChipRow(cites: stat.value.cites, context: context, focus: focus)
            }
            if let share = stat.share {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Ink.ink3)
                        Capsule().fill(stat.value.mark.fill).frame(width: geometry.size.width * min(max(share, 0), 1))
                    }
                }
                .frame(height: 8)
            }
        }
    }

    private func part(_ lead: String, _ part: StatPart) -> some View {
        HStack(spacing: 5) {
            Text(lead).foregroundStyle(Ink.text3)
            if part.value.mark == .unverified { WarningGlyph() }
            Text(part.text).foregroundStyle(part.value.mark == .unverified ? Ink.amber : Ink.text2).monospacedDigit()
            if let label = part.label { Text(label).foregroundStyle(Ink.text3) }
            ChipRow(cites: part.value.cites, context: context, focus: focus)
        }
        .font(Typeface.ui(12.5))
    }
}

struct ConflictView: View {
    let conflict: ConflictFigure
    let context: AnswerContext
    @ObservedObject var focus: AnswerFocus

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(conflict.sides) { side in
                    sideView(side)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .overlay(alignment: .leading) { if side.id > 0 { Ink.line.frame(width: 1) } }
                }
            }
            .background(Ink.ink1.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.line))
            if let why = conflict.why, let leaning = conflict.leaning, conflict.sides.indices.contains(leaning) {
                Text(ChipProse.attributed("The run leans to \(conflict.sides[leaning].label): \(why)", context: context, hot: focus.hotCites, opened: focus.opened))
                    .font(Typeface.ui(12.5)).foregroundStyle(Ink.text2).padding(.top, 10)
            }
            if let settle = conflict.settle {
                HStack(spacing: 7) {
                    ConflictGlyph()
                    Text("Would settle it: ").foregroundStyle(Ink.text3) + Text(settle).foregroundStyle(Ink.text2)
                }
                .font(Typeface.ui(12)).padding(.top, 8)
            }
        }
    }

    private func sideView(_ side: ConflictFigureSide) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(side.label).font(Typeface.ui(12.5, .semibold)).foregroundStyle(Ink.text1)
                if conflict.leaning == side.id {
                    Text("leaning").font(Typeface.ui(11, .semibold)).foregroundStyle(Ink.iris)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Ink.irisWash, in: Capsule())
                        .overlay(Capsule().strokeBorder(Ink.iris.opacity(0.18)))
                }
                Spacer(minLength: 0)
                Text(side.sourceType).font(Typeface.ui(11)).foregroundStyle(Ink.text3)
            }
            HStack(spacing: 6) {
                if side.headlineValue?.mark == .unverified { WarningGlyph() }
                Text(side.headline).font(Typeface.ui(20, .medium)).tracking(-0.2)
                    .foregroundStyle(side.headlineValue.map { $0.mark == .unverified ? Ink.amber : (conflict.leaning == side.id ? Ink.text1 : Ink.text2) } ?? Ink.text1)
                    .monospacedDigit()
                if let value = side.headlineValue { ChipRow(cites: value.cites, context: context, focus: focus) }
            }
            Text(ChipProse.attributed(side.summary, context: context, hot: focus.hotCites, opened: focus.opened))
                .font(Typeface.ui(13.5)).foregroundStyle(Ink.text2).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if let mix = side.tierMix { TierMixBar(mix: mix).padding(.top, 4) }
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 14)
    }
}

struct TierMixBar: View {
    let mix: TierMix

    var body: some View {
        let parts: [(Int, AnyShapeStyle, String)] = [
            (mix.supported, AnyShapeStyle(Ink.vizConfirmed), "verified"), (mix.close, AnyShapeStyle(Ink.vizConfirmed.opacity(0.42)), "close"),
            (mix.unsupported, AnyShapeStyle(Hatch.unverified), "unsupported"), (mix.unresolved, AnyShapeStyle(Ink.text4), "unresolved"),
        ].filter { $0.0 > 0 }
        return HStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    RoundedRectangle(cornerRadius: 1).fill(part.1).frame(width: CGFloat(part.0) * 10, height: 4)
                }
            }
            Text(parts.map { "\($0.0) \($0.2)" }.joined(separator: " · ")).font(Typeface.ui(11)).foregroundStyle(Ink.text3)
        }
    }
}

struct SourceMixView: View {
    let mix: MixFigure

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(mix.summary).font(Typeface.ui(13.5, .medium)).foregroundStyle(Ink.text1)
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(mix.segments) { segment in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(style(segment.key))
                            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(outline(segment.key), lineWidth: 1))
                            .frame(width: max(4, (geometry.size.width - CGFloat(mix.segments.count - 1) * 2) * segment.fraction))
                    }
                }
            }
            .frame(height: 8)
            HStack(spacing: 14) {
                ForEach(mix.segments) { segment in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(style(segment.key))
                            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(outline(segment.key), lineWidth: 1))
                            .frame(width: 10, height: 8)
                        Text("\(segment.key) ").foregroundStyle(Ink.text2) + Text("\(segment.n)").foregroundStyle(Ink.text1).fontWeight(.semibold)
                    }
                }
                Spacer(minLength: 0)
                Text("engine-counted").foregroundStyle(Ink.text4)
            }
            .font(Typeface.ui(12)).monospacedDigit()
        }
    }

    private func style(_ key: String) -> AnyShapeStyle {
        switch key {
        case "primary", "supported": return AnyShapeStyle(Ink.vizConfirmed)
        case "academic", "close": return AnyShapeStyle(Ink.vizConfirmed.opacity(0.6))
        case "news": return AnyShapeStyle(Ink.text3)
        case "vendor": return AnyShapeStyle(Ink.vizUnconfirmed.opacity(0.55))
        case "seo", "unsupported": return AnyShapeStyle(Hatch.unverified)
        default: return AnyShapeStyle(Ink.text4)
        }
    }

    private func outline(_ key: String) -> Color {
        key == "seo" || key == "unsupported" ? Ink.vizUnconfirmed : .clear
    }
}

enum AxisTicks {
    static func values(_ domain: ClosedRange<Double>) -> [Double] {
        let span = domain.upperBound - domain.lowerBound
        guard span > 0 else { return [domain.lowerBound] }
        let step = DatumFormat.niceCeiling(span / 4)
        return Array(stride(from: domain.lowerBound, through: domain.upperBound + step * 0.001, by: step))
    }
}

struct DatumPeek: View {
    let label: String
    let value: FigureValue
    let context: AnswerContext

    var body: some View {
        let cite = value.cites.first ?? ""
        let document = context.document(cite)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(label).font(Typeface.ui(12.5, .semibold)).foregroundStyle(Ink.text1)
                if value.mark == .unverified { WarningGlyph() }
                Text(value.text).font(Typeface.ui(12.5, .medium)).foregroundStyle(value.mark.valueColor).monospacedDigit()
                MarkSwatch(mark: value.mark, width: 12)
                Text(value.mark.legend).font(Typeface.ui(11.5)).foregroundStyle(Ink.text3)
                Spacer(minLength: 0)
                if let document {
                    SourceFavicon(host: document.host, size: 14)
                    Text(document.host).font(Typeface.ui(11.5)).foregroundStyle(Ink.text3)
                }
            }
            if let quote = context.citation(cite)?.quote {
                Text("„\(quote.trimmingCharacters(in: .whitespacesAndNewlines))”")
                    .font(Typeface.read(13.5)).foregroundStyle(Ink.text2).lineSpacing(3)
                    .lineLimit(4).fixedSize(horizontal: false, vertical: true)
            }
            if let why = value.why {
                Text(why).font(Typeface.ui(12)).foregroundStyle(value.mark == .unverified ? Ink.amber : Ink.text3)
            }
        }
    }
}
