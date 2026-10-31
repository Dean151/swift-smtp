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

import NIOCore
import Testing
@testable import SMTP

@Suite("Dot-stuffing")
struct DotStuffingTests {
    @Test("Every line starting with a period gets another one")
    func stuffing() {
        let stuffed = SMTPClient.dotStuffed("a\r\n.b\r\n..c\r\n.\r\n")
        #expect(String(buffer: stuffed) == "a\r\n..b\r\n...c\r\n..\r\n.\r\n")
    }

    @Test("A message without a final line break still ends properly")
    func missingFinalLineBreak() {
        #expect(String(buffer: SMTPClient.dotStuffed(".start")) == "..start\r\n.\r\n")
    }
}

@Suite("Reply parsing")
struct ReplyParserTests {
    @Test("A single-line reply")
    func singleLine() throws {
        var parser = SMTPReplyParser()
        #expect(try parser.consume("250 OK") == SMTPReply(code: 250, lines: ["OK"]))
    }

    @Test("A multi-line reply is accumulated until the last line")
    func multiLine() throws {
        var parser = SMTPReplyParser()
        #expect(try parser.consume("250-smtp.example.com") == nil)
        #expect(try parser.consume("250-AUTH PLAIN LOGIN") == nil)
        #expect(try parser.consume("250 SIZE 1000") == SMTPReply(code: 250, lines: ["smtp.example.com", "AUTH PLAIN LOGIN", "SIZE 1000"]))
        // The parser is reset for the next reply.
        #expect(try parser.consume("221") == SMTPReply(code: 221, lines: [""]))
    }

    @Test("Malformed lines are rejected", arguments: ["", "25", "abc OK", "250_OK", "999 no", "250-a"])
    func malformed(line: String) {
        var parser = SMTPReplyParser()
        if line == "250-a" {
            // A continuation followed by a different code.
            _ = try? parser.consume(line)
            #expect(throws: SMTPReplyParser.ParseError.self) { try parser.consume("354 go") }
        } else {
            #expect(throws: SMTPReplyParser.ParseError.self) { try parser.consume(line) }
        }
    }

    @Test("Redaction removes every word containing @")
    func redaction() {
        let reply = SMTPReply(code: 550, lines: ["5.1.1 <zoe@example.org>: Recipient address rejected", "see admin@example.com"])
        #expect(reply.redacted().lines == ["5.1.1 <redacted> Recipient address rejected", "see <redacted>"])
    }
}
