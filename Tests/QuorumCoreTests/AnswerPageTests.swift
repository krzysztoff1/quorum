import XCTest
@testable import QuorumCore

final class AnswerPageTests: XCTestCase {

    private func run(_ name: String) throws -> StoredRun {
        let url = EngineFixtures.url("record/\(name).run.json")
        let record = try JSONDecoder().decode(RunRecord.self, from: Data(contentsOf: url))
        return StoredRun(runDir: url.deletingLastPathComponent(), record: record)
    }

    private func page(_ name: String) throws -> AnswerPage {
        try XCTUnwrap(AnswerPage(run: run(name)))
    }

    private func figure(_ page: AnswerPage, _ id: String) throws -> AnswerFigure {
        try XCTUnwrap(page.sections.flatMap(\.items).compactMap { item -> AnswerFigure? in
            if case .figure(let figure) = item, figure.id == id { return figure }
            return nil
        }.first)
    }

    func testTheAnswerReadsAsALeadThenSectionsOfClaimsAndFigures() throws {
        let page = try page("personalization")
        XCTAssertTrue(page.lead.hasPrefix("Personalization pays in food tech"))
        XCTAssertEqual(page.verdict, .leaning)
        XCTAssertEqual(page.sections.map(\.title), [
            "The lift is real, and small in grocery", "Vendor figures do not survive a filing",
            "The money is retail media, not data sales", "Diet data is policed by enforcement, not HIPAA",
        ])
        guard case .claim(let lift) = page.sections[0].items[0] else { return XCTFail("the first item is not a claim") }
        XCTAssertEqual(lift.id, "c_lift")
        XCTAssertEqual(lift.strength, .solid)
        XCTAssertEqual(lift.reason, "primary benchmark, re-verified")
        guard case .claim(let vendor) = page.sections[1].items[0] else { return XCTFail("no vendor claim") }
        XCTAssertEqual(vendor.strength, .shaky)
    }

    func testChipsAreNumberedInReadingOrderAcrossProseCaptionsAndData() throws {
        let page = try page("personalization")
        XCTAssertEqual(Array(page.citationOrder.prefix(5)), ["a2c6", "a2c17", "a2c11", "a2c4", "a2c9"])
        XCTAssertEqual(page.number(of: "a2c4"), 4)
    }

    func testARangeChartKeepsItsGroupsAndShowsAnOffScaleValueAtTheEdge() throws {
        let figure = try figure(page("personalization"), "roi")
        guard case .range(let range) = figure.kind else { return XCTFail("roi is not a range") }
        XCTAssertEqual(range.rows.map(\.group), ["Benchmark", "Benchmark", "Vendor case studies", "Vendor case studies"])
        XCTAssertEqual(range.domain, 0...20)
        XCTAssertEqual(range.rows[0].value.text, "5–15%")
        XCTAssertEqual(range.rows[0].value.low, 5)
        XCTAssertEqual(range.rows[0].value.high, 15)
        XCTAssertEqual(range.rows[2].value.mark, .close)
        XCTAssertEqual(range.rows[3].value.mark, .verified)
        XCTAssertTrue(range.rows[3].offScale)
        XCTAssertEqual(figure.display, .chart)
        XCTAssertEqual(figure.measure, "Revenue lift from personalization")
    }

    func testANumberItsQuoteDoesNotHoldIsShownHatchedAndSaysWhy() throws {
        let figure = try figure(page("personalization"), "ads")
        guard case .bars(let bars) = figure.kind else { return XCTFail("ads is not a bar chart") }
        XCTAssertEqual(bars.bars.map(\.label), ["Uber", "Instacart", "DoorDash"])
        let doordash = try XCTUnwrap(bars.bars.last)
        XCTAssertEqual(doordash.value.mark, .unverified)
        XCTAssertEqual(doordash.value.text, ">$1B")
        XCTAssertEqual(doordash.value.why, "The number is not in the quoted passage.")
        XCTAssertEqual(doordash.value.low, 1_000_000_000)
        XCTAssertEqual(bars.notLikeForLike, "Not like-for-like: the bars differ in period and in scope.")
        XCTAssertEqual(doordash.sublabel, "ads, full year · 2024")
    }

    func testAConflictShowsBothSidesAndWhereTheRunLeans() throws {
        let figure = try figure(page("personalization"), "split")
        guard case .conflict(let split) = figure.kind else { return XCTFail("split is not a conflict") }
        XCTAssertEqual(split.sides.map(\.headline), ["1–2%", "$2.1B"])
        XCTAssertEqual(split.sides.map(\.sourceType), ["primary", "seo"])
        XCTAssertEqual(split.leaning, 0)
        XCTAssertEqual(split.settle, "A Starbucks 10-K or earnings call that attributes revenue to Deep Brew.")
    }

    func testTheSourceMixSaysHowMuchOfTheEvidenceIsVendorOrSEO() throws {
        let figure = try figure(page("personalization"), "mix")
        guard case .mix(let mix) = figure.kind else { return XCTFail("mix is not a source mix") }
        XCTAssertEqual(mix.segments.map(\.key), ["primary", "news", "vendor", "seo"])
        XCTAssertEqual(mix.total, 9)
        XCTAssertEqual(mix.summary, "4 of 9 sources are vendor or SEO")
    }

    func testAStatWithAShareTurnsOnTheMeter() throws {
        let figure = try figure(page("allergy"), "allergy")
        guard case .stat(let stat) = figure.kind else { return XCTFail("allergy is not a stat") }
        XCTAssertEqual(stat.value.text, "80%")
        XCTAssertEqual(stat.share, 0.8)
        XCTAssertEqual(stat.of?.text, "50")
        XCTAssertEqual(stat.of?.label, "restaurants checked")
    }

    func testATableShowsItsCellsAsCitedValues() throws {
        let figure = try figure(page("allergy"), "share")
        guard case .table(let table) = figure.kind else { return XCTFail("share is not a table") }
        XCTAssertEqual(figure.display, .table)
        XCTAssertEqual(table.columns.map(\.label), ["", "Share of US online grocery shoppers"])
        XCTAssertEqual(table.rows.map { $0.cells.map(\.text) }, [["Walmart+", "25%"], ["Instacart+", "9%"]])
        XCTAssertEqual(table.rows[0].cells[1].value?.cites, ["a2c15"])
    }

    func testTheTrustStripReadsTheEnginesStats() throws {
        let page = try page("personalization")
        XCTAssertEqual(page.strip.claimMarks, [.solid, .solid, .shaky, .shaky, .shaky, .shaky, .solid, .solid, .solid, .shaky])
        XCTAssertEqual(page.strip.sourcesCited, 9)
        XCTAssertEqual(page.strip.sourcesRead, 28)
        XCTAssertEqual(page.strip.unverifiedNumbers, 1)
    }

    func testAnAnswerBuiltFromProseStillReadsAsSectionsOfClaims() throws {
        let page = try page("mock-run")
        XCTAssertEqual(page.sections.first?.title, "The arithmetic")
        XCTAssertTrue(page.sections.allSatisfy { $0.items.allSatisfy { if case .claim = $0 { return true } else { return false } } })
    }

    func testOpenItemsListWhatTheAnswerLeftUnsettled() throws {
        let items = try page("personalization").openItems
        XCTAssertEqual(items.conflicts.map(\.statement), ["How big is the revenue lift?"])
        XCTAssertEqual(items.conflicts.first?.positions, ["benchmarks: 1–2% in grocery", "vendors: $2.1B at Starbucks"])
        XCTAssertEqual(items.gaps, ["Does any filing attribute revenue to Starbucks Deep Brew?"])
        XCTAssertEqual(items.count, 2)
    }

    func testDatumsReadAsTheEngineWritesThem() {
        func text(_ datum: Datum) -> String { DatumFormat.text(datum) }
        XCTAssertEqual(text(Datum(lo: 1, hi: 2, unit: .pct, basis: .reported, cite: [])), "1–2%")
        XCTAssertEqual(text(Datum(v: 2.1, unit: .usd, scale: .billion, basis: .reported, cite: [])), "$2.1B")
        XCTAssertEqual(text(Datum(v: 20, unit: .pct, cmp: .approx, basis: .reported, cite: [])), "~20%")
        XCTAssertEqual(text(Datum(v: 3, unit: .pp, basis: .reported, cite: [])), "3 pp")
        XCTAssertEqual(text(Datum(v: 4, unit: .ratio, basis: .reported, cite: [])), "4×")
        XCTAssertEqual(text(Datum(v: 1500, unit: .count, basis: .reported, cite: [])), "1,500")
        XCTAssertEqual(text(Datum(v: 3.15, unit: .other, suffix: "MJ", basis: .reported, cite: [])), "3.15 MJ")
        XCTAssertEqual(text(Datum(lo: 10, hi: 20, unit: .eur, scale: .million, basis: .reported, cite: [])), "€10M–€20M")
    }
}
