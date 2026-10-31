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

import MIME

/// An error raised while sending an `Email`.
///
/// Errors never contain e-mail addresses: server replies are kept, but any
/// word that looks like an address is replaced by `<redacted>`, so the
/// error can be logged as is.
public struct SMTPError: Error, Sendable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        /// The message cannot be rendered or sent as given (see
        /// `MIMEError`). The associated value explains why, without
        /// quoting any address.
        case invalidEmail(String)
        /// The TCP connection or the TLS handshake failed.
        case connectionFailed
        /// The server closed the connection unexpectedly.
        case connectionClosed
        /// The server did not answer within the configured timeout.
        case timeout
        /// ``SMTPConfiguration/Security-swift.enum/startTLS`` was required
        /// but the server does not offer `STARTTLS`.
        case startTLSUnavailable
        /// Credentials were given but the server offers neither `AUTH PLAIN`
        /// nor `AUTH LOGIN`.
        case authenticationUnavailable
        /// The server sent something that is not a valid SMTP reply.
        case malformedReply
        /// The server answered with a 4xx or 5xx reply. See ``SMTPError/reply``.
        case rejected
    }

    /// The step of the SMTP exchange during which the error happened.
    public enum Stage: String, Sendable, Equatable {
        case connection
        case greeting
        case hello
        case startTLS
        case authentication
        case mailFrom
        case recipient
        case data
        case message
        case quit
    }

    public var kind: Kind
    /// `nil` for errors raised before any connection.
    public var stage: Stage?
    /// The server's reply, with addresses redacted, when there is one.
    public var reply: SMTPReply?
    /// The lower-level error (NIO, TLS), when there is one.
    public var underlyingError: (any Error & Sendable)?

    public init(
        _ kind: Kind,
        stage: Stage? = nil,
        reply: SMTPReply? = nil,
        underlyingError: (any Error & Sendable)? = nil
    ) {
        self.kind = kind
        self.stage = stage
        self.reply = reply?.redacted()
        self.underlyingError = underlyingError
    }

    /// Whether trying again later may succeed.
    ///
    /// Network failures, timeouts and 4xx replies are transient. 5xx
    /// replies and invalid messages are permanent: retrying will fail the
    /// same way.
    public var isTransient: Bool {
        switch kind {
        case .connectionFailed, .connectionClosed, .timeout, .malformedReply:
            true
        case .rejected:
            reply?.isTransientFailure ?? false
        case .invalidEmail, .startTLSUnavailable, .authenticationUnavailable:
            false
        }
    }

    public var description: String {
        var description = "SMTPError.\(kind)"
        if let stage {
            description += " during \(stage.rawValue)"
        }
        if let reply {
            description += ": \(reply)"
        } else if let underlyingError {
            description += ": \(underlyingError)"
        }
        return description
    }
}
