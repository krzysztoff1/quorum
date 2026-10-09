import XCTest
@testable import QuorumCore

final class EventLogTailTests: XCTestCase {

    private func logURL() throws -> URL {
        try makeTempProject().appendingPathComponent("events.ndjson")
    }

    private func append(_ text: String, to url: URL) throws {
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        } else {
            try Data(text.utf8).write(to: url)
        }
    }

    func testAFileThatDoesNotExistYetHasNothingToRead() throws {
        XCTAssertEqual(EventLogTail(url: try logURL()).newLines(), [])
    }

    func testReadsEveryCompleteLineOnceAndThenOnlyWhatWasAppended() throws {
        let url = try logURL()
        let tail = EventLogTail(url: url)
        try append("{\"a\":1}\n{\"a\":2}\n", to: url)

        XCTAssertEqual(tail.newLines(), ["{\"a\":1}", "{\"a\":2}"])
        XCTAssertEqual(tail.newLines(), [])
        try append("{\"a\":3}\n", to: url)
        XCTAssertEqual(tail.newLines(), ["{\"a\":3}"])
    }

    func testHoldsBackALineTheEngineHasNotFinishedWriting() throws {
        let url = try logURL()
        let tail = EventLogTail(url: url)
        try append("{\"a\":1}\n{\"a\":", to: url)

        XCTAssertEqual(tail.newLines(), ["{\"a\":1}"])
        try append("2}\n", to: url)
        XCTAssertEqual(tail.newLines(), ["{\"a\":2}"])
    }

    func testAMultibyteCharacterSplitAcrossTwoReadsStaysWhole() throws {
        let url = try logURL()
        let tail = EventLogTail(url: url)
        let bytes = Array("{\"t\":\"zażółć\"}\n".utf8)
        let cut = bytes.firstIndex(of: 0xC5)! + 1
        try Data(bytes[..<cut]).write(to: url)
        XCTAssertEqual(tail.newLines(), [])
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(bytes[cut...]))
        try handle.close()

        XCTAssertEqual(tail.newLines(), ["{\"t\":\"zażółć\"}"])
    }

    func testAnEmptyLineIsNotAnEvent() throws {
        let url = try logURL()
        try append("{\"a\":1}\n\n{\"a\":2}\n", to: url)

        XCTAssertEqual(EventLogTail(url: url).newLines(), ["{\"a\":1}", "{\"a\":2}"])
    }

    func testReadingFromTheStartReplaysAnEarlierRunForAReattach() throws {
        let url = try logURL()
        try append("{\"a\":1}\n{\"a\":2}\n", to: url)
        let tail = EventLogTail(url: url)

        XCTAssertEqual(tail.newLines().count, 2, "a fresh tail starts at the top, which is what a relaunched app needs")
    }
}
