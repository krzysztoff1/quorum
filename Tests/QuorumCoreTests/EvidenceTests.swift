import XCTest
@testable import QuorumCore

/// Per-sentence provenance (PRD 03), the pure half: `[^c3]` markers parsed out of a writeup, the writeup
/// split into citable blocks, and the portable markdown footnote definitions a note carries so the citation
/// survives outside the app. Plus the evidence index those markers resolve through.
final class EvidenceTests: XCTestCase {

    private func sampleIndex() -> EvidenceIndex {
        EvidenceIndex(
            documents: [
                SourceDocument(sourceID: "s1", url: "https://www.nature.com/articles/x", title: "Cold starts",
                               contentType: .pdf, snapshotPath: "sources/s1.md", originalPath: "sources/s1.pdf",
                               textLength: 4821, pageOffsets: [0, 100, 250]),
                SourceDocument(sourceID: "s2", url: "https://blog.example/post", title: "", contentType: .html),
            ],
            citations: [
                Citation(id: "c1", sourceID: "s1", quote: "latency fell 40%\nyear over year",
                         start: 120, end: 152, match: .exact, page: 4),
                Citation(id: "c2", sourceID: "s2", quote: "adoption is uneven", match: .unresolved),
                Citation(id: "c9", sourceID: "s1", quote: "never referenced", match: .exact),
            ])
    }

    // MARK: markers

    func testMarkersCarryTheirIDsAndPositions() {
        let text = "Cold starts fell [^c1] and adoption is uneven [^a2c3]."
        let markers = CitationMarkers.markers(in: text)
        XCTAssertEqual(markers.map(\.id), ["c1", "a2c3"])
        XCTAssertEqual(markers.map { String(text[$0.range]) }, ["[^c1]", "[^a2c3]"],
                       "the range spans the whole marker, so the reader can swap in a chip")
        XCTAssertLessThan(markers[0].range.lowerBound, markers[1].range.lowerBound)
    }

    func testIDsPreserveDuplicatesInReadingOrder() {
        XCTAssertEqual(CitationMarkers.ids(in: "a [^c2] b [^c1] c [^c2]"), ["c2", "c1", "c2"],
                       "a sentence may cite the same source twice")
    }

    func testOnlyFootnoteSyntaxCounts() {
        XCTAssertEqual(CitationMarkers.ids(in: "a [link](https://x) and [c1] and [^ ] and [^]"), [])
        XCTAssertFalse(CitationMarkers.hasMarkers(in: "a legacy writeup with no provenance"))
        XCTAssertTrue(CitationMarkers.hasMarkers(in: "a cited claim [^c1]"))
    }

    // MARK: stripping

    func testStrippingTidiesTheSpaceAMarkerLeavesBehind() {
        XCTAssertEqual(CitationMarkers.stripping("fact [^c1]."), "fact.")
        XCTAssertEqual(CitationMarkers.stripping("fact [^c1], and more [^c2]!"), "fact, and more!")
        XCTAssertEqual(CitationMarkers.stripping("mid [^c1] sentence"), "mid sentence")
        XCTAssertEqual(CitationMarkers.stripping("trailing [^c1]"), "trailing")
        XCTAssertEqual(CitationMarkers.stripping("no markers here."), "no markers here.")
    }

    func testBlockExposesItsProseWithoutMarkers() {
        let block = CitationMarkers.blocks(in: "The claim holds [^c1].").first
        XCTAssertEqual(block?.strippedText, "The claim holds.")
        XCTAssertEqual(block?.citationIDs, ["c1"])
    }

    // MARK: blocks

    func testHeadingsListItemsAndQuotesStandAlone() {
        let writeup = """
        ## Findings [^c1]
        - first item [^c2]
        - second item
        > quoted line [^c3]
        A paragraph line
        that continues.
        """
        let blocks = CitationMarkers.blocks(in: writeup)
        XCTAssertEqual(blocks.map(\.kind), [.heading, .listItem, .listItem, .quote, .paragraph])
        XCTAssertEqual(blocks.map(\.id), [0, 1, 2, 3, 4], "ids are the reading order")
        XCTAssertEqual(blocks[0].citationIDs, ["c1"])
        XCTAssertEqual(blocks[3].citationIDs, ["c3"])
        XCTAssertEqual(blocks[4].text, "A paragraph line\nthat continues.",
                       "consecutive prose lines are one paragraph")
    }

    func testConsecutiveTableRowsGroupIntoOneBlock() {
        let writeup = """
        | option | latency [^c1] |
        | --- | --- |
        | k8s | down 40% [^c2] |

        After the table.
        """
        let blocks = CitationMarkers.blocks(in: writeup)
        XCTAssertEqual(blocks.map(\.kind), [.table, .paragraph])
        XCTAssertEqual(blocks[0].text.components(separatedBy: "\n").count, 3, "the rows stay one block")
        XCTAssertEqual(blocks[0].citationIDs, ["c1", "c2"])
    }

    func testFencedCodeIsOpaqueSoASampleMarkerIsNotACitation() {
        let writeup = """
        Prose [^c1].

        ```swift
        let footnote = "[^c1]"
        ```

        More prose.
        """
        let blocks = CitationMarkers.blocks(in: writeup)
        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .code, .paragraph])
        XCTAssertEqual(blocks[1].citationIDs, [], "a marker inside a code sample is part of the sample")
        XCTAssertTrue(blocks[1].text.hasPrefix("```swift"))
        XCTAssertTrue(blocks[1].text.hasSuffix("```"))
    }

    func testUnterminatedFenceStillEmitsItsBlock() {
        let blocks = CitationMarkers.blocks(in: "Intro.\n\n```\nnever closed\n")
        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .code], "a truncated writeup still renders")
        XCTAssertTrue(blocks[1].text.contains("never closed"))
    }

    func testBlankLinesAndWhitespaceEmitNoBlocks() {
        XCTAssertTrue(CitationMarkers.blocks(in: "\n\n   \n").isEmpty)
    }

    // MARK: the index the markers resolve through

    func testResolveKeepsMarkerOrderAndDropsUnknownIDs() {
        let cites = sampleIndex().resolve(["c2", "nope", "c1"])
        XCTAssertEqual(cites.map(\.id), ["c2", "c1"])
        XCTAssertEqual(cites.first?.isVerified, false)
        XCTAssertEqual(cites.last?.snapshotRange, 120..<152)
    }

    func testMergingPrefersTheAlreadyResolvedEntry() {
        let resolved = EvidenceIndex(documents: [SourceDocument(sourceID: "s1", url: "https://a", title: "A", contentType: .html)],
                                     citations: [Citation(id: "c1", sourceID: "s1", quote: "q", start: 1, end: 5, match: .exact)])
        let duplicate = EvidenceIndex(documents: [SourceDocument(sourceID: "s1", url: "https://a", title: "A", contentType: .html),
                                                 SourceDocument(sourceID: "s2", url: "https://b", title: "B", contentType: .html)],
                                      citations: [Citation(id: "c1", sourceID: "s1", quote: "q", match: .unresolved),
                                                  Citation(id: "c2", sourceID: "s2", quote: "q2", match: .fuzzy)])
        let merged = resolved.merging(duplicate)
        XCTAssertEqual(merged.documents.map(\.sourceID), ["s1", "s2"], "sources dedupe by id")
        XCTAssertEqual(merged.citation("c1")?.match, .exact, "a resolved citation is never overwritten by an unresolved twin")
        XCTAssertEqual(merged.citation("c2")?.match, .fuzzy)
        XCTAssertFalse(merged.isEmpty)
    }

    func testDocumentPagesAndDisplayLabels() {
        let doc = sampleIndex().document("s1")
        XCTAssertEqual(doc?.page(containing: 0), 1)
        XCTAssertEqual(doc?.page(containing: 150), 2)
        XCTAssertEqual(doc?.page(containing: 9_000), 3)
        XCTAssertEqual(doc?.host, "nature.com", "www. is dropped for a compact label")
        XCTAssertTrue(doc?.hasSnapshot == true)
        XCTAssertEqual(sampleIndex().document("s2")?.displayTitle, "blog.example")
        XCTAssertFalse(sampleIndex().document("s2")?.hasSnapshot == true, "search-only URLs register without a snapshot")
    }

    // MARK: PRD 07 R1 — an unvalidated run says so, everywhere it is read

    func testAnUnvalidatedRunShowsNoVerifiedMatchHoweverWellItsQuotesLineUp() {
        let unvalidated = EvidenceIndex(documents: sampleIndex().documents,
                                        citations: sampleIndex().citations, grounding: .none)
        XCTAssertEqual(unvalidated.citation("c1")?.match, .exact, "the recorded data stays honest")
        XCTAssertEqual(unvalidated.displayMatch("c1"), .unresolved, "what the reader is shown does not")
        XCTAssertEqual(unvalidated.displayMatch("c2"), .unresolved)
        XCTAssertFalse(unvalidated.isValidated)
        XCTAssertEqual(unvalidated.unvalidatedNotice, "unvalidated — no evidence was captured")
    }

    func testACapturedRunKeepsItsRecordedMatchTiers() {
        let captured = sampleIndex()
        XCTAssertEqual(captured.grounding, .captured, "a run that never declared a tier reads as it always did")
        XCTAssertEqual(captured.displayMatch("c1"), .exact)
        XCTAssertEqual(captured.displayMatch("c2"), .unresolved)
        XCTAssertEqual(captured.displayMatch("nope"), .unresolved)
        XCTAssertTrue(captured.isValidated)
        XCTAssertNil(captured.unvalidatedNotice)
    }

    func testMergingLetsAnUnvalidatedRunPoisonTheRegistryItIsFoldedInto() {
        XCTAssertEqual(sampleIndex().merging(EvidenceIndex(grounding: .none)).grounding, .none)
        XCTAssertEqual(EvidenceIndex(grounding: .none).merging(sampleIndex()).grounding, .none)
        XCTAssertEqual(sampleIndex().merging(EvidenceIndex()).grounding, .captured)
    }

    func testAReportWrittenBeforeGroundingTiersExistedStillDecodes() throws {
        let json = #"{"documents":[],"citations":[]}"#
        let index = try JSONDecoder().decode(EvidenceIndex.self, from: Data(json.utf8))
        XCTAssertEqual(index.grounding, .captured)
        let roundTripped = try JSONDecoder().decode(EvidenceIndex.self,
                                                    from: JSONEncoder().encode(EvidenceIndex(grounding: .none)))
        XCTAssertEqual(roundTripped.grounding, .none)
    }

    func testUnknownContentTypeAndMatchDecodeToTheHonestFallback() throws {
        let json = #"{"source_id":"s3","url":"https://x","title":"T","content_type":"epub"}"#
        let doc = try JSONDecoder().decode(SourceDocument.self, from: Data(json.utf8))
        XCTAssertEqual(doc.contentType, .text, "one odd content type never costs a run its evidence")

        let cite = try JSONDecoder().decode(Citation.self, from: Data(#"{"id":"c1","match":"guessed"}"#.utf8))
        XCTAssertEqual(cite.match, .unresolved)
        XCTAssertNil(cite.snapshotRange)
    }
}
