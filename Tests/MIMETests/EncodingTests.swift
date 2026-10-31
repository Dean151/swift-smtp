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

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Testing
@testable import MIME

@Suite("Quoted-printable")
struct QuotedPrintableTests {
    @Test("ASCII text is unchanged")
    func ascii() {
        #expect(QuotedPrintable.encode("Hello, world!") == "Hello, world!")
    }

    @Test("Equals signs, control characters and non-ASCII bytes are escaped")
    func escapes() {
        #expect(QuotedPrintable.encode("a=b\u{1}é") == "a=3Db=01=C3=A9")
    }

    @Test("Trailing whitespace is escaped, inner whitespace is kept")
    func trailingWhitespace() {
        #expect(QuotedPrintable.encode("a b \nc\t") == "a b=20\r\nc=09")
    }

    @Test("All line break conventions become CRLF")
    func lineBreaks() {
        #expect(QuotedPrintable.encode("a\nb\r\nc\rd") == "a\r\nb\r\nc\r\nd")
    }

    @Test("Long lines get soft breaks and stay within 76 characters")
    func longLine() {
        let encoded = QuotedPrintable.encode(String(repeating: "é", count: 60) + String(repeating: "x", count: 100))
        let lines = encoded.components(separatedBy: "\r\n")
        #expect(lines.count > 1)
        #expect(lines.allSatisfy { $0.utf8.count <= 76 })
        #expect(lines.dropLast().allSatisfy { $0.hasSuffix("=") })
        // No escape is cut in half by a soft break.
        #expect(lines.dropLast().allSatisfy { !$0.dropLast().hasSuffix("=") && !$0.dropLast(2).hasSuffix("=") })
        // Decoding gives back the input.
        let joined = lines.map { $0.hasSuffix("=") ? String($0.dropLast()) : $0 }.joined()
        #expect(decode(joined) == String(repeating: "é", count: 60) + String(repeating: "x", count: 100))
    }

    @Test("A line of exactly 76 characters is not wrapped")
    func exactLine() {
        let line = String(repeating: "x", count: 76)
        #expect(QuotedPrintable.encode(line) == line)
        #expect(QuotedPrintable.encode(line + "x") == String(repeating: "x", count: 75) + "=\r\nxx")
    }

    @Test("A line starting with a period is left to SMTP dot-stuffing")
    func leadingPeriod() {
        #expect(QuotedPrintable.encode("a\n.b") == "a\r\n.b")
    }

    private func decode(_ text: String) -> String {
        var bytes: [UInt8] = []
        var iterator = Array(text.utf8).makeIterator()
        while let byte = iterator.next() {
            if byte == .equals, let high = iterator.next(), let low = iterator.next() {
                bytes.append(UInt8(String(decoding: [high, low], as: UTF8.self), radix: 16)!)
            } else {
                bytes.append(byte)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

@Suite("Base64")
struct Base64Tests {
    @Test("RFC 4648 test vectors", arguments: [
        ("", ""), ("f", "Zg=="), ("fo", "Zm8="), ("foo", "Zm9v"),
        ("foob", "Zm9vYg=="), ("fooba", "Zm9vYmE="), ("foobar", "Zm9vYmFy"),
    ])
    func vectors(input: String, expected: String) {
        #expect(Base64.encode(Array(input.utf8)) == expected)
    }

    @Test("Wrapped output matches Foundation and has 76-character lines")
    func wrapped() {
        let bytes = (0..<1_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let encoded = Base64.encode(bytes, lineLength: 76)
        let lines = encoded.components(separatedBy: "\r\n")
        #expect(lines.dropLast().allSatisfy { $0.utf8.count == 76 })
        #expect(lines.joined() == Data(bytes).base64EncodedString())
    }
}

@Suite("Header encoding")
struct HeaderEncodingTests {
    @Test("Dates are formatted in UTC, independent of the locale", arguments: [
        (0.0, "Thu, 1 Jan 1970 00:00:00 +0000"),
        (1_000_000_000, "Sun, 9 Sep 2001 01:46:40 +0000"),
        (951_782_400, "Tue, 29 Feb 2000 00:00:00 +0000"),
        (1_793_478_180.9, "Sat, 31 Oct 2026 20:23:00 +0000"),
        (-86_400, "Wed, 31 Dec 1969 00:00:00 +0000"),
    ])
    func dates(timestamp: Double, expected: String) {
        #expect(HeaderEncoding.date(Date(timeIntervalSince1970: timestamp)) == expected)
    }

    @Test("Text that looks like an encoded-word is encoded")
    func encodedWordLookalike() {
        #expect(HeaderEncoding.unstructured("=?utf-8?B?x?=").first?.hasPrefix("=?utf-8?B?") == true)
    }

    @Test("Phrases with specials are quoted and escaped")
    func quotedPhrase() {
        #expect(HeaderEncoding.phrase("Dr. \"Who\"") == ["\"Dr. \\\"Who\\\"\""])
        #expect(HeaderEncoding.phrase("Plain Name") == ["Plain", "Name"])
    }

    @Test("Long headers fold at whitespace")
    func folding() {
        let field = HeaderEncoding.field("Subject", tokens: Array(repeating: "word", count: 30))
        let lines = field.components(separatedBy: "\r\n").dropLast()
        #expect(lines.count == 3)
        #expect(lines.allSatisfy { $0.utf8.count <= 78 })
        #expect(lines.dropFirst().allSatisfy { $0.hasPrefix(" ") })
    }
}
