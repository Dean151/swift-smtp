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

import Logging
import MIME
import NIOConcurrencyHelpers
import NIOCore
import NIOSSL

/// One SMTP exchange over an established connection, written as a
/// straight sequence of awaits. Used by a single task, then discarded.
struct SMTPSession {
    let channel: any Channel
    let outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>
    var reader: LineReader
    let configuration: SMTPConfiguration
    let sslContext: NIOSSLContext?
    let logger: Logger

    /// Capabilities from the last `EHLO` reply, uppercased.
    private var capabilities: [String] = []

    init(
        channel: any Channel,
        inbound: NIOAsyncChannelInboundStream<ByteBuffer>,
        outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>,
        configuration: SMTPConfiguration,
        sslContext: NIOSSLContext?,
        logger: Logger
    ) {
        self.channel = channel
        self.outbound = outbound
        self.reader = LineReader(iterator: inbound.makeAsyncIterator())
        self.configuration = configuration
        self.sslContext = sslContext
        self.logger = logger
    }

    mutating func send(message: ByteBuffer, from sender: String, to recipients: [String]) async throws(SMTPError) {
        let timeouts = configuration.timeouts

        try await expect(220, after: nil, stage: .greeting, timeout: timeouts.command)
        try await hello()

        if configuration.security == .startTLS {
            try await startTLS()
            try await hello()
        }
        if let credentials = configuration.credentials {
            try await authenticate(with: credentials)
        }

        try await expect(250, after: "MAIL FROM:<\(sender)>", stage: .mailFrom, timeout: timeouts.command)
        for recipient in recipients {
            try await expect([250, 251], after: "RCPT TO:<\(recipient)>", stage: .recipient, timeout: timeouts.command)
        }
        try await expect(354, after: "DATA", stage: .data, timeout: timeouts.command)
        try await expect(250, sending: message, stage: .message, timeout: timeouts.messageAcceptance)

        // The message is accepted: a failing QUIT must not report an error,
        // or the caller would send the message twice.
        _ = try? await command("QUIT", stage: .quit, timeout: timeouts.command)
    }

    /// Best effort `QUIT` after a rejection, so the server can close cleanly.
    mutating func quit() async {
        _ = try? await command("QUIT", stage: .quit, timeout: .seconds(5))
    }

    // MARK: - Steps

    private mutating func hello() async throws(SMTPError) {
        let timeout = configuration.timeouts.command
        let reply = try await command("EHLO \(configuration.heloName)", stage: .hello, timeout: timeout)
        if reply.isPositiveCompletion {
            capabilities = reply.lines.dropFirst().map { $0.uppercased() }
            return
        }
        // RFC 5321 §3.2: fall back to HELO for servers predating ESMTP.
        guard reply.isPermanentFailure else {
            throw SMTPError(.rejected, stage: .hello, reply: reply)
        }
        try await expect(250, after: "HELO \(configuration.heloName)", stage: .hello, timeout: timeout)
        capabilities = []
    }

    private mutating func startTLS() async throws(SMTPError) {
        guard hasCapability("STARTTLS"), let sslContext else {
            throw SMTPError(.startTLSUnavailable, stage: .startTLS)
        }
        try await expect(220, after: "STARTTLS", stage: .startTLS, timeout: configuration.timeouts.command)

        // Anything received after the 220 was sent in clear text and could
        // have been injected by an attacker (CVE-2011-0411 and friends).
        guard reader.isEmpty else {
            throw SMTPError(.malformedReply, stage: .startTLS)
        }

        let hostname = configuration.hostname
        let channel = channel
        do {
            try await channel.eventLoop.submit {
                let handler = try NIOSSLClientHandler(context: sslContext, serverHostname: serverNameIndication(for: hostname))
                try channel.pipeline.syncOperations.addHandler(handler, position: .first)
            }.get()
        } catch {
            throw SMTPError(.connectionFailed, stage: .startTLS, underlyingError: error)
        }
        logger.debug("SMTP connection upgraded with STARTTLS")
    }

    private mutating func authenticate(with credentials: SMTPConfiguration.Credentials) async throws(SMTPError) {
        let mechanisms = capabilities
            .filter { $0.hasPrefix("AUTH ") || $0.hasPrefix("AUTH=") }
            .flatMap { $0.dropFirst(5).split(separator: " ") }
        let timeout = configuration.timeouts.command

        if mechanisms.contains("PLAIN") {
            let token = Base64.encode([0] + Array(credentials.username.utf8) + [0] + Array(credentials.password.utf8))
            try await expect(235, after: "AUTH PLAIN \(token)", stage: .authentication, timeout: timeout)
        } else if mechanisms.contains("LOGIN") {
            try await expect(334, after: "AUTH LOGIN", stage: .authentication, timeout: timeout)
            try await expect(334, after: Base64.encode(Array(credentials.username.utf8)), stage: .authentication, timeout: timeout)
            try await expect(235, after: Base64.encode(Array(credentials.password.utf8)), stage: .authentication, timeout: timeout)
        } else {
            throw SMTPError(.authenticationUnavailable, stage: .authentication)
        }
        logger.debug("SMTP authentication succeeded")
    }

    private func hasCapability(_ name: String) -> Bool {
        capabilities.contains { $0 == name || $0.hasPrefix(name + " ") }
    }

    // MARK: - Commands

    private mutating func expect(_ code: Int, after line: String?, stage: SMTPError.Stage, timeout: Duration) async throws(SMTPError) {
        try await expect([code], after: line, stage: stage, timeout: timeout)
    }

    private mutating func expect(_ codes: Set<Int>, after line: String?, stage: SMTPError.Stage, timeout: Duration) async throws(SMTPError) {
        let reply = try await command(line, stage: stage, timeout: timeout)
        guard codes.contains(reply.code) else {
            throw SMTPError(reply.isPositiveCompletion || reply.isPositiveIntermediate ? .malformedReply : .rejected, stage: stage, reply: reply)
        }
    }

    private mutating func expect(_ code: Int, sending message: ByteBuffer, stage: SMTPError.Stage, timeout: Duration) async throws(SMTPError) {
        let reply = try await exchange(message, stage: stage, timeout: timeout)
        guard reply.code == code else {
            throw SMTPError(reply.isPositiveCompletion ? .malformedReply : .rejected, stage: stage, reply: reply)
        }
    }

    /// Sends a command line (or nothing, for the greeting) and reads the reply.
    private mutating func command(_ line: String?, stage: SMTPError.Stage, timeout: Duration) async throws(SMTPError) -> SMTPReply {
        try await exchange(line.map { ByteBuffer(string: $0 + "\r\n") }, stage: stage, timeout: timeout)
    }

    private mutating func exchange(_ bytes: ByteBuffer?, stage: SMTPError.Stage, timeout: Duration) async throws(SMTPError) -> SMTPReply {
        // On expiry the connection is closed, which ends any pending read
        // or write; the resulting error is then reported as a timeout.
        let deadline = Deadline(channel: channel, after: timeout)
        defer { deadline.cancel() }

        do {
            if let bytes {
                try await outbound.write(bytes)
            }
            let reply = try await reader.readReply()
            logger.trace("SMTP reply", metadata: ["stage": "\(stage.rawValue)", "code": "\(reply.code)"])
            return reply
        } catch {
            if deadline.hasFired {
                throw SMTPError(.timeout, stage: stage)
            }
            switch error {
            case let error as SMTPError:
                var error = error
                error.stage = stage
                throw error
            case SMTPReplyParser.ParseError.malformed:
                throw SMTPError(.malformedReply, stage: stage)
            default:
                throw SMTPError(.connectionClosed, stage: stage, underlyingError: error)
            }
        }
    }
}

/// Closes the channel if not cancelled in time.
private struct Deadline {
    private let task: Scheduled<Void>
    private let fired: NIOLockedValueBox<Bool>

    init(channel: any Channel, after duration: Duration) {
        let fired = NIOLockedValueBox(false)
        self.fired = fired
        self.task = channel.eventLoop.scheduleTask(in: TimeAmount(duration)) {
            fired.withLockedValue { $0 = true }
            channel.close(promise: nil)
        }
    }

    var hasFired: Bool {
        fired.withLockedValue { $0 }
    }

    func cancel() {
        task.cancel()
    }
}

/// Splits the inbound byte stream into lines and SMTP replies.
struct LineReader {
    var iterator: NIOAsyncChannelInboundStream<ByteBuffer>.AsyncIterator
    private var buffer = ByteBuffer()

    /// Longest accepted line. RFC 5321 allows 512 bytes for a reply line;
    /// the margin tolerates chatty servers without buffering forever.
    private static let maximumLineLength = 4_096

    init(iterator: NIOAsyncChannelInboundStream<ByteBuffer>.AsyncIterator) {
        self.iterator = iterator
    }

    var isEmpty: Bool {
        buffer.readableBytes == 0
    }

    mutating func readReply() async throws -> SMTPReply {
        var parser = SMTPReplyParser()
        while true {
            if let reply = try parser.consume(try await readLine()) {
                return reply
            }
        }
    }

    /// Reads one line, accepting CRLF or a bare LF as terminator.
    mutating func readLine() async throws -> String {
        while true {
            if let index = buffer.readableBytesView.firstIndex(of: .lineFeed) {
                let length = index - buffer.readerIndex
                var line = buffer.readString(length: length) ?? ""
                buffer.moveReaderIndex(forwardBy: 1)
                if line.utf8.last == .carriageReturn {
                    line.removeLast()
                }
                buffer.discardReadBytes()
                return line
            }
            guard buffer.readableBytes <= Self.maximumLineLength else {
                throw SMTPReplyParser.ParseError.malformed
            }
            guard var chunk = try await iterator.next() else {
                throw SMTPError(.connectionClosed)
            }
            buffer.writeBuffer(&chunk)
        }
    }
}

/// SNI and hostname verification need a name: IP literals are not allowed.
func serverNameIndication(for hostname: String) -> String? {
    (try? SocketAddress(ipAddress: hostname, port: 0)) == nil ? hostname : nil
}
