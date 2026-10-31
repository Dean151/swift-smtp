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

import NIOSSL

/// How to reach and authenticate with an SMTP server.
public struct SMTPConfiguration: Sendable {
    public var hostname: String
    public var port: Int
    public var security: Security
    public var credentials: Credentials?
    /// The name announced with `EHLO`. Some servers expect the fully
    /// qualified domain name of the sending host.
    public var heloName: String
    public var timeouts: Timeouts
    /// The TLS settings for ``Security-swift.enum/tls`` and
    /// ``Security-swift.enum/startTLS``. The default verifies the
    /// certificate chain and the hostname against the system trust store.
    public var tlsConfiguration: TLSConfiguration

    /// - Parameter port: Defaults to 465 for ``Security-swift.enum/tls``,
    ///   587 for ``Security-swift.enum/startTLS`` and 25 for
    ///   ``Security-swift.enum/unencrypted``.
    public init(
        hostname: String,
        port: Int? = nil,
        security: Security = .tls,
        credentials: Credentials? = nil,
        heloName: String = "localhost",
        timeouts: Timeouts = Timeouts(),
        tlsConfiguration: TLSConfiguration = .makeClientConfiguration()
    ) {
        self.hostname = hostname
        self.port = port ?? security.defaultPort
        self.security = security
        self.credentials = credentials
        self.heloName = heloName
        self.timeouts = timeouts
        self.tlsConfiguration = tlsConfiguration
    }

    public enum Security: Sendable, Equatable {
        /// TLS from the first byte ("implicit TLS", RFC 8314), usually on
        /// port 465. The recommended mode.
        case tls
        /// A plain connection upgraded with `STARTTLS` before anything else
        /// is sent, usually on port 587. Fails if the server does not
        /// offer `STARTTLS`: there is no silent fallback to plain text.
        case startTLS
        /// No encryption at all, credentials included. Only for tests and
        /// trusted local relays.
        case unencrypted

        var defaultPort: Int {
            switch self {
            case .tls: 465
            case .startTLS: 587
            case .unencrypted: 25
            }
        }
    }

    /// The account used with `AUTH`. `PLAIN` is preferred, `LOGIN` is used
    /// when it is the only mechanism offered.
    public struct Credentials: Sendable, CustomStringConvertible {
        public var username: String
        public var password: String

        public init(username: String, password: String) {
            self.username = username
            self.password = password
        }

        /// Never reveals the username or the password.
        public var description: String {
            "Credentials(<redacted>)"
        }
    }

    /// How long to wait at each step before giving up with
    /// ``SMTPError/Kind/timeout``.
    public struct Timeouts: Sendable {
        /// Establishing the TCP connection.
        public var connect: Duration
        /// Each command's reply, the greeting and the TLS handshake included.
        public var command: Duration
        /// The reply after the message has been sent: the server may scan
        /// it before accepting it.
        public var messageAcceptance: Duration

        public init(
            connect: Duration = .seconds(10),
            command: Duration = .seconds(60),
            messageAcceptance: Duration = .seconds(120)
        ) {
            self.connect = connect
            self.command = command
            self.messageAcceptance = messageAcceptance
        }
    }
}
