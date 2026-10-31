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

/// An e-mail message, ready to be rendered as RFC 5322 / MIME and sent.
///
/// The message is always rendered as 7-bit ASCII: text parts use
/// quoted-printable, attachments use base64 and non-ASCII header values
/// use RFC 2047 encoded-words. It therefore travels through any SMTP
/// server, with or without the `8BITMIME` extension.
///
/// ```swift
/// let email = Email(
///     from: Mailbox("contact@example.com", name: "Example"),
///     to: ["someone@example.org"],
///     subject: "Votre code de connexion",
///     body: .alternative(text: "Code : 123456", html: "<p>Code : <b>123456</b></p>")
/// )
/// ```
public struct Email: Sendable {
    /// The author of the message. Also used as the envelope sender
    /// (`MAIL FROM`) unless ``envelopeSender`` is set.
    public var from: Mailbox
    public var to: [Mailbox]
    public var cc: [Mailbox]
    /// Recipients that receive the message without appearing in its headers.
    public var bcc: [Mailbox]
    public var replyTo: [Mailbox]
    public var subject: String
    public var body: Body
    public var attachments: [Attachment]
    /// Extra headers, written after the standard ones. Names must be
    /// printable ASCII without colons; non-ASCII values are RFC 2047 encoded.
    public var additionalHeaders: [Header]
    /// The `Date` header. `nil` means "when the message is rendered".
    public var date: Date?
    /// The `Message-ID` header, without angle brackets. `nil` generates a
    /// random one on the domain of the ``from`` address.
    public var messageID: String?
    /// The address given to `MAIL FROM`, where bounces are sent.
    /// `nil` uses the ``from`` address.
    public var envelopeSender: String?

    public init(
        from: Mailbox,
        to: [Mailbox] = [],
        cc: [Mailbox] = [],
        bcc: [Mailbox] = [],
        replyTo: [Mailbox] = [],
        subject: String,
        body: Body,
        attachments: [Attachment] = [],
        additionalHeaders: [Header] = [],
        date: Date? = nil,
        messageID: String? = nil,
        envelopeSender: String? = nil
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.replyTo = replyTo
        self.subject = subject
        self.body = body
        self.attachments = attachments
        self.additionalHeaders = additionalHeaders
        self.date = date
        self.messageID = messageID
        self.envelopeSender = envelopeSender
    }

    /// The content of the message.
    public enum Body: Sendable, Equatable {
        /// A `text/plain` body.
        case text(String)
        /// A `text/html` body. Prefer ``alternative(text:html:)``: many
        /// spam filters penalise HTML-only messages.
        case html(String)
        /// A `multipart/alternative` body: clients display the HTML part
        /// and fall back to the text part.
        case alternative(text: String, html: String)
    }

    /// Every address the message is delivered to: `to`, `cc` and `bcc`.
    public var recipients: [Mailbox] {
        to + cc + bcc
    }
}

/// A mailbox: an address with an optional display name.
public struct Mailbox: Sendable, Hashable {
    /// The address, such as `someone@example.com`. Only ASCII addresses
    /// are supported (no `SMTPUTF8`).
    public var address: String
    /// The display name, such as `Zoé Martin`. Any Unicode is allowed.
    public var name: String?

    public init(_ address: String, name: String? = nil) {
        self.address = address
        self.name = name
    }
}

extension Mailbox: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.init(value)
    }
}

extension Email {
    /// A file attached to an ``Email``.
    public struct Attachment: Sendable, Equatable {
        public var filename: String
        /// A MIME type such as `application/pdf` or `image/png`.
        public var contentType: String
        public var data: [UInt8]
        public var disposition: Disposition

        public init(filename: String, contentType: String, data: [UInt8], disposition: Disposition = .attachment) {
            self.filename = filename
            self.contentType = contentType
            self.data = data
            self.disposition = disposition
        }

        public enum Disposition: Sendable, Equatable {
            /// Shown as a downloadable file.
            case attachment
            /// Embedded in the HTML body, referenced as `<img src="cid:…">`.
            /// The content ID is given without angle brackets.
            case inline(contentID: String)
        }
    }

    /// A raw header field.
    public struct Header: Sendable, Equatable {
        public var name: String
        public var value: String

        public init(_ name: String, _ value: String) {
            self.name = name
            self.value = value
        }
    }
}
