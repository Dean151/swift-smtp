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

/// A renderer with a fixed clock and sequential identifiers.
private func render(_ email: Email) throws -> String {
    var counter = 0
    let renderer = MessageRenderer(
        now: { Date(timeIntervalSince1970: 1_000_000_000) },
        makeIdentifier: {
            counter += 1
            return "id\(counter)"
        }
    )
    return try renderer.render(email)
}

private func email(
    subject: String = "Bonjour",
    body: Email.Body = .text("Bonjour"),
    attachments: [Email.Attachment] = []
) -> Email {
    Email(
        from: Mailbox("contact@example.com", name: "Latte"),
        to: ["zoe@example.org"],
        subject: subject,
        body: body,
        attachments: attachments
    )
}

@Suite("Message rendering")
struct MessageRendererTests {
    @Test("A text message renders headers and a quoted-printable body")
    func plainText() throws {
        let output = try render(email(body: .text("Café\nÀ bientôt")))
        #expect(output == """
        Date: Sun, 9 Sep 2001 01:46:40 +0000\r
        From: Latte <contact@example.com>\r
        To: zoe@example.org\r
        Subject: Bonjour\r
        Message-ID: <id1@example.com>\r
        MIME-Version: 1.0\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        Caf=C3=A9\r
        =C3=80 bient=C3=B4t\r

        """)
    }

    @Test("Every line ends with CRLF and stays within 78 characters")
    func lineEndings() throws {
        let output = try render(email(
            subject: String(repeating: "Très long sujet ", count: 10),
            body: .alternative(text: String(repeating: "texte ", count: 100), html: String(repeating: "<p>html</p>", count: 50))
        ))
        let bytes = Array(output.utf8)
        for (index, byte) in bytes.enumerated() where byte == .lineFeed {
            #expect(index > 0 && bytes[index - 1] == .carriageReturn)
        }
        for line in output.components(separatedBy: "\r\n") {
            #expect(line.utf8.count <= 78, "\(line)")
            #expect(line.utf8.allSatisfy { $0 < 0x80 })
        }
    }

    @Test("An accented subject is RFC 2047 encoded")
    func accentedSubject() throws {
        let output = try render(email(subject: "Votre contribution a été publiée"))
        #expect(output.contains("Subject: =?utf-8?B?Vm90cmUgY29udHJpYnV0aW9uIGEgw6l0w6kgcHVibGnDqWU=?=\r\n"))
    }

    @Test("An emoji subject is split on scalar boundaries")
    func emojiSubject() throws {
        let subject = String(repeating: "☕️ Latte ", count: 6)
        let words = HeaderEncoding.encodedWords(subject)
        #expect(words.count > 1)
        let decoded = words.map { word in
            let base64 = word.dropFirst("=?utf-8?B?".count).dropLast(2)
            return String(decoding: Data(base64Encoded: String(base64))!, as: UTF8.self)
        }.joined()
        #expect(decoded == subject)
        #expect(words.allSatisfy { $0.utf8.count <= 75 })
    }

    @Test("An emoji body is quoted-printable encoded")
    func emojiBody() throws {
        let output = try render(email(body: .text("Merci ☕️")))
        #expect(output.contains("\r\n\r\nMerci =E2=98=95=EF=B8=8F\r\n"))
    }

    @Test("A subject containing CRLF cannot inject headers")
    func headerInjection() throws {
        let output = try render(email(subject: "Hi\r\nBcc: attacker@example.net"))
        #expect(!output.contains("\r\nBcc:"))
        #expect(output.contains("Subject: =?utf-8?B?"))
    }

    @Test("Display names are kept, quoted or encoded as needed")
    func displayNames() throws {
        var message = email()
        message.to = [
            Mailbox("a@example.org", name: "Alice Martin"),
            Mailbox("b@example.org", name: "Martin, Bob"),
            Mailbox("c@example.org", name: "Zoé"),
            "d@example.org",
        ]
        let output = try render(message)
        #expect(output.contains("""
        To: Alice Martin <a@example.org>, "Martin, Bob" <b@example.org>,\r
         =?utf-8?B?Wm/DqQ==?= <c@example.org>, d@example.org\r

        """))
    }

    @Test("Bcc recipients are delivered but not written")
    func bcc() throws {
        var message = email()
        message.bcc = ["hidden@example.org"]
        let output = try render(message)
        #expect(!output.contains("hidden@example.org"))
        #expect(message.recipients.map(\.address) == ["zoe@example.org", "hidden@example.org"])
    }

    @Test("Text and HTML render as multipart/alternative")
    func alternative() throws {
        let output = try render(email(body: .alternative(text: "Bonjour", html: "<p>Bonjour</p>")))
        #expect(output.hasSuffix("""
        MIME-Version: 1.0\r
        Content-Type: multipart/alternative; boundary="=_id2"\r
        \r
        --=_id2\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        Bonjour\r
        --=_id2\r
        Content-Type: text/html; charset=utf-8\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        <p>Bonjour</p>\r
        --=_id2--\r

        """))
    }

    @Test("Attachments and inline images nest mixed, related and alternative")
    func attachments() throws {
        let output = try render(email(
            body: .alternative(text: "Logo", html: "<img src=\"cid:logo\">"),
            attachments: [
                Email.Attachment(filename: "export.json", contentType: "application/json", data: Array("{}".utf8)),
                Email.Attachment(filename: "logo.png", contentType: "image/png", data: [0x89, 0x50, 0x4E, 0x47], disposition: .inline(contentID: "logo")),
            ]
        ))
        // Boundaries are generated outermost first.
        #expect(output.contains("Content-Type: multipart/mixed; boundary=\"=_id2\"\r\n"))
        #expect(output.contains("--=_id2\r\nContent-Type: multipart/related; boundary=\"=_id3\"\r\n"))
        #expect(output.contains("--=_id3\r\nContent-Type: multipart/alternative; boundary=\"=_id4\"\r\n"))
        #expect(output.contains("""
        --=_id3\r
        Content-Type: image/png; name="logo.png"\r
        Content-Transfer-Encoding: base64\r
        Content-Disposition: inline; filename="logo.png"\r
        Content-ID: <logo>\r
        \r
        iVBORw==\r
        --=_id3--\r

        """))
        #expect(output.contains("""
        --=_id2\r
        Content-Type: application/json; name="export.json"\r
        Content-Transfer-Encoding: base64\r
        Content-Disposition: attachment; filename="export.json"\r
        \r
        e30=\r
        --=_id2--\r

        """))
    }

    @Test("A non-ASCII filename uses the RFC 2231 form")
    func unicodeFilename() throws {
        let output = try render(email(attachments: [
            Email.Attachment(filename: "données été.txt", contentType: "text/plain", data: []),
        ]))
        #expect(output.contains("filename*=utf-8''donn%C3%A9es%20%C3%A9t%C3%A9.txt"))
    }

    @Test("Invalid input is rejected without quoting addresses", arguments: [
        { (email: inout Email) in email.to = ["zoe@example.org\r\nRCPT TO:<x@y.z>"] },
        { (email: inout Email) in email.from = "not-an-address" },
        { (email: inout Email) in email.bcc = ["<a@b.c>"] },
        { (email: inout Email) in email.additionalHeaders = [Email.Header("Bcc", "x@y.z")] },
        { (email: inout Email) in email.additionalHeaders = [Email.Header("X-Bad:Name", "v")] },
        { (email: inout Email) in email.messageID = "a b@c" },
        { (email: inout Email) in
            email.attachments = [Email.Attachment(filename: "a", contentType: "text/plain\r\nX: y", data: [])]
        },
    ] as [@Sendable (inout Email) -> Void])
    func invalid(mutate: @Sendable (inout Email) -> Void) {
        var message = email()
        mutate(&message)
        #expect {
            try render(message)
        } throws: { error in
            guard let error = error as? MIMEError else { return false }
            return !error.description.contains("@")
        }
    }

    @Test("Additional headers are written after the standard ones")
    func additionalHeaders() throws {
        var message = email()
        message.additionalHeaders = [Email.Header("List-Unsubscribe", "<mailto:unsubscribe@example.com>")]
        let output = try render(message)
        #expect(output.contains("MIME-Version: 1.0\r\nList-Unsubscribe: <mailto:unsubscribe@example.com>\r\nContent-Type:"))
    }
}
