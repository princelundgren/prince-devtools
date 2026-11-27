import Foundation
import XCTest
@testable import Containers

final class HTTPResponseTests: XCTestCase {
    func testContentLengthBody() throws {
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"

        XCTAssertEqual(try HTTPResponse.body(of: Data(response.utf8)), Data("{}".utf8))
    }

    func testChunkedBodyIsJoined() throws {
        let response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n[{\"a\r\n5\r\n\":1}]\r\n0\r\n\r\n"

        XCTAssertEqual(try HTTPResponse.body(of: Data(response.utf8)), Data(#"[{"a":1}]"#.utf8))
    }

    func testBodyToTheEnd() throws {
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nOK"

        XCTAssertEqual(try HTTPResponse.body(of: Data(response.utf8)), Data("OK".utf8))
    }

    func testOtherTransferCodingFails() {
        assertFails("HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n")
    }

    func testRepeatedTransferEncodingIsJoinedAndFails() {
        assertFails("HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n")
    }

    func testNon200Fails() {
        assertFails("HTTP/1.1 404 Not Found\r\nContent-Length: 2\r\n\r\n{}")
    }

    func testMalformedFails() {
        assertFails("{}\r\n\r\n")
    }

    func testOversizedChunkFails() {
        assertFails("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n7FFFFFFFFFFFFFFF\r\n{}\r\n0\r\n\r\n")
    }

    func testABodyShorterThanItsContentLengthFails() {
        assertFails("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n{}")
    }

    func testAChunkedBodyCutOffBeforeItsLastChunkFails() {
        assertFails("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n")
    }

    func testAChunkWithoutALineEndAfterItFails() {
        assertFails("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}XX0\r\n\r\n")
    }

    func testANegativeChunkSizeFails() {
        assertFails("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n-2\r\n{}\r\n0\r\n\r\n")
    }

    func testANonHexChunkSizeFails() {
        assertFails("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n{}\r\n0\r\n\r\n")
    }

    func testASignedChunkSizeFails() {
        assertFails("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n+2\r\n{}\r\n0\r\n\r\n")
    }

    func testASignedContentLengthFails() {
        assertFails("HTTP/1.1 200 OK\r\nContent-Length: +2\r\n\r\n{}")
    }

    func testDifferingContentLengthsFail() {
        assertFails("HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n{}")
    }

    func testWhitespaceBeforeAColonFails() {
        assertFails("HTTP/1.1 200 OK\r\nContent-Length : 1\r\n\r\n{}")
    }

    func testOversizedContentLengthFails() {
        assertFails("HTTP/1.1 200 OK\r\nContent-Length: \(Int.max)\r\n\r\n{}")
    }

    func testAHeaderOfManyRepeatedFieldsParsesQuickly() throws {
        let repeats = String(repeating: "A: b\r\n", count: 800_000)
        let response = Data("HTTP/1.1 200 OK\r\n\(repeats)Content-Length: 2\r\n\r\n{}".utf8)
        var body = Data()

        // Timing-dependent: appending each repeat to a joined string takes about 15 s here; joining once, under 1 s.
        let elapsed = try ContinuousClock().measure { body = try HTTPResponse.body(of: response) }

        XCTAssertEqual(body, Data("{}".utf8))
        XCTAssertLessThan(elapsed, .seconds(3))
    }

    private func assertFails(_ response: String, line: UInt = #line) {
        do {
            let body = try HTTPResponse.body(of: Data(response.utf8))
            XCTFail("expected .failed, got a body of \(body.count) bytes", line: line)
        } catch {
            guard case .failed = error else { return XCTFail("expected .failed, got \(error)", line: line) }
        }
    }
}
