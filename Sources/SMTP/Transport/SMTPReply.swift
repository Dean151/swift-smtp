//
//  MIT License
//
//  Copyright (c) 2026 Thomas Durand
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

/// A reply from an SMTP server: a three-digit code and one or more lines
/// of text (RFC 5321 §4.2).
public struct SMTPReply: Sendable, Equatable, CustomStringConvertible {
    public var code: Int
    /// The text of each line, without the code and separator.
    public var lines: [String]

    public init(code: Int, lines: [String]) {
        self.code = code
        self.lines = lines
    }

    /// 2xx: the command succeeded.
    public var isPositiveCompletion: Bool { (200..<300).contains(code) }
    /// 3xx: the server waits for more (`DATA`, `AUTH` challenges).
    public var isPositiveIntermediate: Bool { (300..<400).contains(code) }
    /// 4xx: a temporary failure, worth retrying later.
    public var isTransientFailure: Bool { (400..<500).contains(code) }
    /// 5xx: a permanent failure.
    public var isPermanentFailure: Bool { (500..<600).contains(code) }

    public var description: String {
        lines.isEmpty ? "\(code)" : "\(code) " + lines.joined(separator: " / ")
    }

    /// The same reply with every word containing `@` replaced by
    /// `<redacted>`, since servers often quote the address they reject.
    public func redacted() -> SMTPReply {
        SMTPReply(code: code, lines: lines.map { line in
            line.split(separator: " ", omittingEmptySubsequences: false)
                .map { $0.contains("@") ? "<redacted>" : String($0) }
                .joined(separator: " ")
        })
    }
}

/// Accumulates reply lines until a complete, possibly multi-line, reply.
///
/// ```
/// 250-smtp.example.com greets you
/// 250-PIPELINING
/// 250 AUTH PLAIN LOGIN
/// ```
struct SMTPReplyParser {
    private var code: Int?
    private var lines: [String] = []

    enum ParseError: Error {
        case malformed
    }

    /// Feeds one line, CRLF excluded. Returns the reply once its last line
    /// (code followed by a space, or by nothing) has been read.
    mutating func consume(_ line: String) throws(ParseError) -> SMTPReply? {
        let bytes = Array(line.utf8)
        guard bytes.count >= 3,
              bytes[0...2].allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
              let lineCode = Int(String(decoding: bytes[0...2], as: UTF8.self)),
              (200..<600).contains(lineCode)
        else {
            throw .malformed
        }
        if let code, code != lineCode {
            throw .malformed
        }
        code = lineCode

        let separator = bytes.count > 3 ? bytes[3] : UInt8(ascii: " ")
        guard separator == UInt8(ascii: " ") || separator == UInt8(ascii: "-") else {
            throw .malformed
        }
        lines.append(bytes.count > 4 ? String(decoding: bytes[4...], as: UTF8.self) : "")

        guard separator == UInt8(ascii: " ") else {
            return nil
        }
        defer { self = SMTPReplyParser() }
        return SMTPReply(code: lineCode, lines: lines)
    }
}
