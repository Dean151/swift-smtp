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

extension Email {
    /// Renders the message as RFC 5322 / MIME text with CRLF line endings.
    ///
    /// The output is what follows `DATA`, before SMTP dot-stuffing. It can
    /// also be handed to any API that accepts raw MIME messages.
    ///
    /// - Throws: ``MIMEError`` if a field is invalid.
    public func rendered() throws(MIMEError) -> String {
        try MessageRenderer().render(self)
    }
}

/// Builds the MIME text of an ``Email``. The clock and the random
/// identifiers are injectable so tests get a stable output.
struct MessageRenderer {
    var now: () -> Date = { Date() }
    var makeIdentifier: () -> String = MessageRenderer.randomIdentifier

    func render(_ email: Email) throws(MIMEError) -> String {
        try validate(email)

        var headers = ""
        headers += HeaderEncoding.field("Date", tokens: [HeaderEncoding.date(email.date ?? now())])
        headers += HeaderEncoding.field("From", tokens: mailboxList([email.from]))
        if !email.to.isEmpty {
            headers += HeaderEncoding.field("To", tokens: mailboxList(email.to))
        }
        if !email.cc.isEmpty {
            headers += HeaderEncoding.field("Cc", tokens: mailboxList(email.cc))
        }
        if !email.replyTo.isEmpty {
            headers += HeaderEncoding.field("Reply-To", tokens: mailboxList(email.replyTo))
        }
        headers += HeaderEncoding.field("Subject", tokens: HeaderEncoding.unstructured(email.subject))
        let messageID = email.messageID ?? "\(makeIdentifier())@\(domain(of: email.from.address))"
        headers += HeaderEncoding.field("Message-ID", tokens: ["<\(messageID)>"])
        headers += HeaderEncoding.field("MIME-Version", tokens: ["1.0"])
        for header in email.additionalHeaders {
            headers += HeaderEncoding.field(header.name, tokens: HeaderEncoding.unstructured(header.value))
        }

        return headers + render(part: rootPart(of: email)) + "\r\n"
    }

    // MARK: - MIME tree

    private indirect enum Part {
        case leaf(headers: [(String, [String])], body: String)
        case multipart(subtype: String, parts: [Part])
    }

    private func rootPart(of email: Email) -> Part {
        var content: Part = switch email.body {
        case let .text(text):
            textPart(text, subtype: "plain")
        case let .html(html):
            textPart(html, subtype: "html")
        case let .alternative(text, html):
            .multipart(subtype: "alternative", parts: [textPart(text, subtype: "plain"), textPart(html, subtype: "html")])
        }

        let inline = email.attachments.filter { $0.disposition != .attachment }
        if !inline.isEmpty {
            content = .multipart(subtype: "related", parts: [content] + inline.map(attachmentPart))
        }
        let attached = email.attachments.filter { $0.disposition == .attachment }
        if !attached.isEmpty {
            content = .multipart(subtype: "mixed", parts: [content] + attached.map(attachmentPart))
        }
        return content
    }

    private func textPart(_ text: String, subtype: String) -> Part {
        .leaf(
            headers: [
                ("Content-Type", ["text/\(subtype);", "charset=utf-8"]),
                ("Content-Transfer-Encoding", ["quoted-printable"]),
            ],
            body: QuotedPrintable.encode(text)
        )
    }

    private func attachmentPart(_ attachment: Email.Attachment) -> Part {
        var headers = [
            ("Content-Type", ["\(attachment.contentType);", HeaderEncoding.parameter("name", attachment.filename)]),
            ("Content-Transfer-Encoding", ["base64"]),
        ]
        switch attachment.disposition {
        case .attachment:
            headers.append(("Content-Disposition", ["attachment;", HeaderEncoding.parameter("filename", attachment.filename)]))
        case let .inline(contentID):
            headers.append(("Content-Disposition", ["inline;", HeaderEncoding.parameter("filename", attachment.filename)]))
            headers.append(("Content-ID", ["<\(contentID)>"]))
        }
        return .leaf(headers: headers, body: Base64.encode(attachment.data, lineLength: 76))
    }

    /// Renders the headers of a part, a blank line, then its body. The
    /// body has no trailing line break: in a multipart, the CRLF before a
    /// boundary belongs to the boundary.
    private func render(part: Part) -> String {
        switch part {
        case let .leaf(headers, body):
            return headers.map(HeaderEncoding.field).joined() + "\r\n" + body

        case let .multipart(subtype, parts):
            // "=_" never appears in quoted-printable or base64 output, so
            // the boundary cannot collide with the content.
            let boundary = "=_" + makeIdentifier()
            var output = HeaderEncoding.field("Content-Type", tokens: ["multipart/\(subtype);", "boundary=\"\(boundary)\""])
            output += "\r\n"
            for part in parts {
                output += "--\(boundary)\r\n" + render(part: part) + "\r\n"
            }
            return output + "--\(boundary)--"
        }
    }

    // MARK: - Addresses

    private func mailboxList(_ mailboxes: [Mailbox]) -> [String] {
        var tokens: [String] = []
        for (index, mailbox) in mailboxes.enumerated() {
            let separator = index < mailboxes.count - 1 ? "," : ""
            if let name = mailbox.name, !name.isEmpty {
                tokens += HeaderEncoding.phrase(name)
                tokens.append("<\(mailbox.address)>" + separator)
            } else {
                tokens.append(mailbox.address + separator)
            }
        }
        return tokens
    }

    private func domain(of address: String) -> Substring {
        address.split(separator: "@").last ?? "localhost"
    }

    // MARK: - Validation

    private func validate(_ email: Email) throws(MIMEError) {
        guard Self.isValidAddress(email.from.address) else {
            throw MIMEError("The sender address is invalid.")
        }
        if let envelopeSender = email.envelopeSender, !Self.isValidAddress(envelopeSender) {
            throw MIMEError("The envelope sender address is invalid.")
        }
        let lists: [(String, [Mailbox])] = [("To", email.to), ("Cc", email.cc), ("Bcc", email.bcc), ("Reply-To", email.replyTo)]
        for (field, mailboxes) in lists {
            if let index = mailboxes.firstIndex(where: { !Self.isValidAddress($0.address) }) {
                throw MIMEError("\(field) address #\(index + 1) is invalid.")
            }
        }
        if let messageID = email.messageID, !Self.isValidIdentifier(messageID) {
            throw MIMEError("The Message-ID is invalid.")
        }
        for header in email.additionalHeaders {
            guard !header.name.isEmpty, header.name.utf8.allSatisfy({ $0 > 32 && $0 < 127 && $0 != UInt8(ascii: ":") }) else {
                throw MIMEError("A header name is invalid.")
            }
            guard !Self.reservedHeaders.contains(header.name.lowercased()) else {
                throw MIMEError("The \(header.name) header is set by the library and cannot be added.")
            }
        }
        for (index, attachment) in email.attachments.enumerated() {
            guard Self.isValidContentType(attachment.contentType) else {
                throw MIMEError("Attachment #\(index + 1) has an invalid content type.")
            }
            if case let .inline(contentID) = attachment.disposition, !Self.isValidIdentifier(contentID) {
                throw MIMEError("Attachment #\(index + 1) has an invalid content ID.")
            }
        }
    }

    private static let reservedHeaders: Set<String> = [
        "date", "from", "to", "cc", "bcc", "reply-to", "subject", "message-id",
        "mime-version", "content-type", "content-transfer-encoding", "content-disposition",
    ]

    /// A pragmatic check: ASCII, no whitespace, control characters or angle
    /// brackets, and a non-empty local part and domain around the last `@`.
    /// Its main job is to keep CR, LF and `>` out of headers and commands.
    static func isValidAddress(_ address: String) -> Bool {
        guard address.utf8.allSatisfy({ $0 > 32 && $0 < 127 && $0 != UInt8(ascii: "<") && $0 != UInt8(ascii: ">") }),
              let at = address.lastIndex(of: "@")
        else {
            return false
        }
        return at != address.startIndex && address.index(after: at) != address.endIndex
    }

    /// A Message-ID or Content-ID, without its angle brackets.
    private static func isValidIdentifier(_ identifier: String) -> Bool {
        !identifier.isEmpty
            && identifier.utf8.allSatisfy { $0 > 32 && $0 < 127 && $0 != UInt8(ascii: "<") && $0 != UInt8(ascii: ">") }
    }

    /// `type/subtype`, made of RFC 2045 token characters.
    private static func isValidContentType(_ contentType: String) -> Bool {
        let parts = contentType.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy { $0 > 32 && $0 < 127 && !"()<>@,;:\\\"/[]?=".utf8.contains($0) }
        }
    }

    static func randomIdentifier() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<2).map { _ in String(generator.next() as UInt64, radix: 16).leftPadded(to: 16) }.joined()
    }
}
