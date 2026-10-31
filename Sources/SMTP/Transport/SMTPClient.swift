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

@_exported import MIME
import Logging
import NIOCore
import NIOPosix
import NIOSSL

/// Sends `Email` messages through an SMTP server.
///
/// Each call to ``send(_:)`` opens a connection, delivers one message and
/// closes the connection. The client holds no connection between calls,
/// so it can be shared freely across tasks.
///
/// ```swift
/// let client = try SMTPClient(configuration: SMTPConfiguration(
///     hostname: "smtp.example.com",
///     credentials: .init(username: "contact@example.com", password: password)
/// ))
/// try await client.send(email)
/// ```
///
/// The client logs steps and reply codes only: never addresses, message
/// content, credentials or reply text.
public struct SMTPClient: Sendable {
    public let configuration: SMTPConfiguration
    private let eventLoopGroup: any EventLoopGroup
    private let sslContext: NIOSSLContext?
    private let logger: Logger

    /// - Throws: An `NIOSSLError` if the TLS configuration is invalid.
    public init(
        configuration: SMTPConfiguration,
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        logger: Logger = Logger(label: "swift-smtp", factory: { _ in SwiftLogNoOpLogHandler() })
    ) throws {
        self.configuration = configuration
        self.eventLoopGroup = eventLoopGroup
        self.logger = logger
        self.sslContext = switch configuration.security {
        case .tls, .startTLS:
            try NIOSSLContext(configuration: configuration.tlsConfiguration)
        case .unencrypted:
            nil
        }
    }

    /// Delivers a message.
    ///
    /// The message is rendered first, so an invalid message fails before
    /// any connection is opened. Delivery is all or nothing: if the server
    /// rejects any recipient, nothing is sent.
    ///
    /// - Throws: ``SMTPError``. Check ``SMTPError/isTransient`` to decide
    ///   whether to try again later.
    public func send(_ email: Email) async throws(SMTPError) {
        let recipients = email.recipients.map(\.address)
        guard !recipients.isEmpty else {
            throw SMTPError(.invalidEmail("The message has no recipient."))
        }
        let message: ByteBuffer
        do {
            message = Self.dotStuffed(try email.rendered())
        } catch {
            throw SMTPError(.invalidEmail(error.reason))
        }
        let sender = email.envelopeSender ?? email.from.address

        let channel = try await connect()
        do {
            try await channel.executeThenClose { inbound, outbound in
                var session = SMTPSession(
                    channel: channel.channel,
                    inbound: inbound,
                    outbound: outbound,
                    configuration: configuration,
                    sslContext: sslContext,
                    logger: logger
                )
                do {
                    try await session.send(message: message, from: sender, to: recipients)
                } catch let error as SMTPError {
                    if error.kind == .rejected {
                        await session.quit()
                    }
                    throw error
                }
            }
        } catch let error as SMTPError {
            logger.warning("SMTP delivery failed", metadata: [
                "error.kind": "\(error.kind)",
                "error.stage": "\(error.stage?.rawValue ?? "-")",
                "error.code": "\(error.reply?.code ?? 0)",
            ])
            throw error
        } catch {
            // executeThenClose itself failed (closing an already closed channel).
            throw SMTPError(.connectionClosed, underlyingError: error)
        }
        logger.debug("SMTP delivery succeeded", metadata: ["recipients": "\(recipients.count)"])
    }

    private func connect() async throws(SMTPError) -> NIOAsyncChannel<ByteBuffer, ByteBuffer> {
        let implicitTLSContext = configuration.security == .tls ? sslContext : nil
        let hostname = configuration.hostname
        do {
            return try await ClientBootstrap(group: eventLoopGroup)
                .connectTimeout(TimeAmount(configuration.timeouts.connect))
                .connect(host: hostname, port: configuration.port) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        if let implicitTLSContext {
                            let handler = try NIOSSLClientHandler(
                                context: implicitTLSContext,
                                serverHostname: serverNameIndication(for: hostname)
                            )
                            try channel.pipeline.syncOperations.addHandler(handler)
                        }
                        return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                    }
                }
        } catch {
            logger.warning("SMTP connection failed", metadata: ["error": "\(error)"])
            throw SMTPError(.connectionFailed, stage: .connection, underlyingError: error)
        }
    }

    /// Prepares a rendered message for `DATA`: doubles every period that
    /// starts a line (RFC 5321 §4.5.2) and appends the `.` terminator.
    static func dotStuffed(_ message: String) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.reserveCapacity(message.utf8.count + 64)
        var atLineStart = true
        for byte in message.utf8 {
            if atLineStart, byte == .period {
                buffer.writeInteger(UInt8.period)
            }
            buffer.writeInteger(byte)
            atLineStart = byte == .lineFeed
        }
        if !atLineStart {
            buffer.writeString("\r\n")
        }
        buffer.writeString(".\r\n")
        return buffer
    }
}
