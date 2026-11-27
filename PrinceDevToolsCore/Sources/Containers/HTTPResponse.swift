import Foundation

enum HTTPResponse {
    private static let lineEnd = Data("\r\n".utf8)
    private static let headEnd = Data("\r\n\r\n".utf8)

    /// The body of a complete response read to the connection's close: `Content-Length`,
    /// `Transfer-Encoding: chunked`, or neither (to the end). Throws `.failed` on a status other
    /// than 200, any other transfer coding, or a malformed response.
    static func body(of response: Data) throws(SocketReadError) -> Data {
        guard let head = response.firstRange(of: headEnd) else {
            throw .failed("malformed response: no end of the header")
        }
        let lines = String(decoding: response[..<head.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let status = lines[0].split(separator: " ", maxSplits: 2)
        guard status.count >= 2, status[0].hasPrefix("HTTP/1."), let code = Int(status[1]) else {
            throw .failed("malformed response: no status line")
        }
        guard code == 200 else { throw .failed("HTTP status \(code)") }

        let fields = try headerFields(lines.dropFirst())
        let content = response[head.upperBound...]
        if let encoding = fields["transfer-encoding"] {
            guard encoding.lowercased() == "chunked" else { throw .failed("Transfer-Encoding \(encoding)") }
            return try joinedChunks(content)
        }
        if let declared = fields["content-length"] {
            guard let length = number(declared, radix: 10), content.count >= length else {
                throw .failed("malformed response: Content-Length \(declared) with \(content.count) bytes")
            }
            return Data(content.prefix(length))
        }
        return Data(content)
    }

    /// Lowercased field names to their trimmed values, a repeated field's values joined by ", "
    /// as RFC 9110 combines them, so two differing `Content-Length` lines are no number. Throws on
    /// whitespace between a name and its colon, which RFC 9112 doesn't allow.
    private static func headerFields(_ lines: ArraySlice<String>) throws(SocketReadError) -> [String: String] {
        var values: [String: [String]] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon]
            guard name.last?.isWhitespace != true else {
                throw .failed("malformed response: whitespace before the colon of \(name.debugDescription)")
            }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            values[name.lowercased(), default: []].append(value)
        }
        // Joined once: appending to a joined string would copy it for every repeat a peer sends.
        return values.mapValues { $0.joined(separator: ", ") }
    }

    private static func joinedChunks(_ encoded: Data) throws(SocketReadError) -> Data {
        var body = Data()
        var rest = encoded
        while true {
            guard let sizeLine = rest.firstRange(of: lineEnd),
                let size = number(
                    String(decoding: rest[..<sizeLine.lowerBound], as: UTF8.self)
                        .prefix { $0 != ";" }
                        .trimmingCharacters(in: .whitespaces),
                    radix: 16)
            else { throw .failed("malformed chunked body: no chunk size") }
            if size == 0 { return body }
            let start = sizeLine.upperBound
            // The size is the peer's: compare it with what arrived before adding to it.
            guard size <= rest.endIndex - start - lineEnd.count else {
                throw .failed("malformed chunked body: a chunk shorter than its size")
            }
            let end = start + size
            guard rest[end..<(end + lineEnd.count)] == lineEnd else {
                throw .failed("malformed chunked body: no line end after a chunk")
            }
            body.append(rest[start..<end])
            rest = rest[(end + lineEnd.count)...]
        }
    }

    /// `digits` as a number when it is only ASCII digits of `radix`, as RFC 9112 writes a length,
    /// else `nil`: `Int(_:radix:)` alone also takes a leading `+` or `-`.
    private static func number(_ digits: String, radix: Int) -> Int? {
        guard digits.allSatisfy({ $0.isASCII && ($0.hexDigitValue ?? radix) < radix }) else { return nil }
        return Int(digits, radix: radix)
    }
}
