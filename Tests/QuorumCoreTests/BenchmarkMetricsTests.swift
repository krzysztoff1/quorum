import XCTest
@testable import QuorumCore

final class BenchmarkMetricsTests: XCTestCase {

    func testExtractsHttpAndHttpsUrls() {
        let text = "See https://arxiv.org/abs/2506 and http://example.com/x?y=1."
        XCTAssertEqual(BenchmarkMetrics.urlDomains(in: text).sorted(), ["arxiv.org", "example.com"])
    }

    func testStripsWwwAndLowercases() {
        let text = "https://www.Arxiv.org/a https://ARXIV.org/b https://arxiv.org/c"
        XCTAssertEqual(BenchmarkMetrics.urlDomains(in: text), ["arxiv.org", "arxiv.org", "arxiv.org"])
    }

    func testTrimsTrailingPunctuationAndParens() {
        let text = "See (https://x.com/a) and https://y.com/b, and https://z.com/c."
        XCTAssertEqual(Set(BenchmarkMetrics.urlDomains(in: text)), ["x.com", "y.com", "z.com"])
    }

    func testSimpsonEmpty() {
        XCTAssertEqual(BenchmarkMetrics.simpsonDiversity([]), 0, accuracy: 1e-9)
    }

    func testSimpsonOneDomain() {
        XCTAssertEqual(BenchmarkMetrics.simpsonDiversity(["a", "a", "a"]), 0, accuracy: 1e-9)
    }

    func testSimpsonAllDistinctFourSources() {
        XCTAssertEqual(BenchmarkMetrics.simpsonDiversity(["a", "b", "c", "d"]), 0.75, accuracy: 1e-9)
    }

    func testSimpsonSkewedThreeToOne() {
        XCTAssertEqual(BenchmarkMetrics.simpsonDiversity(["a", "a", "a", "b"]), 0.375, accuracy: 1e-9)
    }

    func testAllAgreeRequiresIdenticalNonEmpty() {
        XCTAssertTrue(BenchmarkMetrics.allAgree(["quorum", "quorum"]))
        XCTAssertTrue(BenchmarkMetrics.allAgree(["quorum", "quorum", "quorum", "quorum"]))
        XCTAssertTrue(BenchmarkMetrics.allAgree(["tie", "tie"]))
        XCTAssertFalse(BenchmarkMetrics.allAgree(["quorum", "traditional"]))
        XCTAssertFalse(BenchmarkMetrics.allAgree(["quorum", "tie"]))
        XCTAssertFalse(BenchmarkMetrics.allAgree([]))
    }

    func testMeanPassRateAveragesTruthiness() {
        XCTAssertEqual(BenchmarkMetrics.meanPassRate([[true, false, true], [true, true, false]]), 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(BenchmarkMetrics.meanPassRate([]), 0, accuracy: 1e-9)
        XCTAssertEqual(BenchmarkMetrics.meanPassRate([[]]), 0, accuracy: 1e-9)
        XCTAssertEqual(BenchmarkMetrics.meanPassRate([[true, true, true]]), 1.0, accuracy: 1e-9)
    }
}
