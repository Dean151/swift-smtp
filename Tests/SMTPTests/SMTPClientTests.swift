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
import NIOPosix
import Testing
@testable import SMTP

private func client(port: Int, credentials: Bool = true, security: SMTPConfiguration.Security = .unencrypted, commandTimeout: Duration = .seconds(5)) throws -> SMTPClient {
    try SMTPClient(configuration: SMTPConfiguration(
        hostname: "127.0.0.1",
        port: port,
        security: security,
        credentials: credentials ? .init(username: "user@example.com", password: "secret") : nil,
        heloName: "client.example.com",
        timeouts: .init(connect: .seconds(5), command: commandTimeout, messageAcceptance: commandTimeout)
    ))
}

private let email = Email(
    from: Mailbox("contact@example.com", name: "Latte"),
    to: ["zoe@example.org"],
    bcc: ["hidden@example.org"],
    subject: "Code",
    body: .text("Votre code\n.123456\n..")
)

/// Checks that the error is of the given kind and stage, and does not
/// reveal any address.
private func expectError(
    _ kind: SMTPError.Kind,
    stage: SMTPError.Stage?,
    transient: Bool,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        Issue.record("Expected \(kind)", sourceLocation: sourceLocation)
    } catch let error as SMTPError {
        #expect(error.kind == kind, sourceLocation: sourceLocation)
        #expect(error.stage == stage, sourceLocation: sourceLocation)
        #expect(error.isTransient == transient, sourceLocation: sourceLocation)
        #expect(!"\(error)".contains("@"), sourceLocation: sourceLocation)
    } catch {
        Issue.record("Unexpected error \(error)", sourceLocation: sourceLocation)
    }
}

@Suite("SMTP exchange against a fake server")
struct SMTPClientTests {
    @Test("A message is delivered with the expected command sequence")
    func delivery() async throws {
        try await FakeSMTPServer.run { server in
            try await client(port: server.port).send(email)

            #expect(server.commands == [
                "EHLO client.example.com",
                "AUTH PLAIN AHVzZXJAZXhhbXBsZS5jb20Ac2VjcmV0",
                "MAIL FROM:<contact@example.com>",
                "RCPT TO:<zoe@example.org>",
                "RCPT TO:<hidden@example.org>",
                "DATA",
                "QUIT",
            ])
            let message = try #require(server.messages.first)
            // Lines starting with a period are dot-stuffed on the wire.
            #expect(message.hasSuffix("\r\n\r\nVotre code\r\n..123456\r\n..."))
            #expect(!message.contains("hidden@example.org"))
        }
    }

    @Test("Multi-line greeting and EHLO replies are parsed")
    func multiLineReplies() async throws {
        try await FakeSMTPServer.run(greeting: "220-fake.example.com ESMTP\r\n220-Welcome\r\n220 Ready") { server in
            try await client(port: server.port).send(email)
            #expect(server.messages.count == 1)
        }
    }

    @Test("AUTH LOGIN is used when PLAIN is not offered")
    func authLogin() async throws {
        try await FakeSMTPServer.run(replies: [("EHLO", "250-fake.example.com\r\n250 AUTH LOGIN")]) { server in
            try await client(port: server.port).send(email)
            #expect(server.commands.prefix(4) == ["EHLO client.example.com", "AUTH LOGIN", "dXNlckBleGFtcGxlLmNvbQ==", "c2VjcmV0"])
        }
    }

    @Test("HELO is used when the server does not know EHLO")
    func heloFallback() async throws {
        try await FakeSMTPServer.run(replies: [("EHLO", "502 5.5.2 Command not recognized")]) { server in
            try await client(port: server.port, credentials: false).send(email)
            #expect(server.commands.prefix(2) == ["EHLO client.example.com", "HELO client.example.com"])
        }
    }

    @Test("A 4xx reply to RCPT is a transient failure, followed by QUIT")
    func transientRecipient() async throws {
        try await FakeSMTPServer.run(replies: [("RCPT TO:<hidden", "450 4.2.1 <hidden@example.org>: Mailbox busy")]) { server in
            await expectError(.rejected, stage: .recipient, transient: true) {
                try await client(port: server.port).send(email)
            }
            #expect(server.messages.isEmpty)
            #expect(server.commands.last == "QUIT")
        }
    }

    @Test("The rejected reply is kept with addresses redacted")
    func redactedReply() async throws {
        try await FakeSMTPServer.run(replies: [("RCPT", "550 5.1.1 <zoe@example.org>: Recipient address rejected")]) { server in
            let client = try client(port: server.port)
            do throws(SMTPError) {
                try await client.send(email)
                Issue.record("Expected an error")
            } catch {
                #expect(error.reply == SMTPReply(code: 550, lines: ["5.1.1 <redacted> Recipient address rejected"]))
                #expect(!error.isTransient)
            }
        }
    }

    @Test("A 5xx reply to AUTH is a permanent failure")
    func permanentAuthentication() async throws {
        try await FakeSMTPServer.run(replies: [("AUTH", "535 5.7.8 Authentication credentials invalid")]) { server in
            await expectError(.rejected, stage: .authentication, transient: false) {
                try await client(port: server.port).send(email)
            }
            #expect(!server.commands.contains { $0.hasPrefix("MAIL") })
        }
    }

    @Test("A rejected message after DATA is reported at the message stage")
    func rejectedMessage() async throws {
        try await FakeSMTPServer.run(replies: [(".", "554 5.7.1 Spam detected")]) { server in
            await expectError(.rejected, stage: .message, transient: false) {
                try await client(port: server.port).send(email)
            }
        }
    }

    @Test("A server that never greets times out")
    func silentGreeting() async throws {
        try await FakeSMTPServer.run(greeting: nil) { server in
            await expectError(.timeout, stage: .greeting, transient: true) {
                try await client(port: server.port, commandTimeout: .milliseconds(200)).send(email)
            }
        }
    }

    @Test("A server that stops answering mid-exchange times out")
    func silentRecipient() async throws {
        try await FakeSMTPServer.run(replies: [("RCPT", nil)]) { server in
            let start = ContinuousClock.now
            await expectError(.timeout, stage: .recipient, transient: true) {
                try await client(port: server.port, commandTimeout: .milliseconds(200)).send(email)
            }
            #expect(ContinuousClock.now - start < .seconds(3))
        }
    }

    @Test("A server that hangs up is a transient failure")
    func hangUp() async throws {
        try await FakeSMTPServer.run(replies: [("MAIL", "421 4.3.2 Shutting down")]) { server in
            await expectError(.rejected, stage: .mailFrom, transient: true) {
                try await client(port: server.port).send(email)
            }
        }
    }

    @Test("Garbage instead of a reply is reported as malformed")
    func garbage() async throws {
        try await FakeSMTPServer.run(greeting: "Hello there") { server in
            await expectError(.malformedReply, stage: .greeting, transient: true) {
                try await client(port: server.port).send(email)
            }
        }
    }

    @Test("STARTTLS is required when configured, with no fallback")
    func startTLSUnavailable() async throws {
        try await FakeSMTPServer.run { server in
            await expectError(.startTLSUnavailable, stage: .startTLS, transient: false) {
                try await client(port: server.port, security: .startTLS).send(email)
            }
            #expect(!server.commands.contains { $0.hasPrefix("AUTH") || $0.hasPrefix("MAIL") })
        }
    }

    @Test("Credentials without a supported AUTH mechanism fail before MAIL")
    func authenticationUnavailable() async throws {
        try await FakeSMTPServer.run(replies: [("EHLO", "250-fake.example.com\r\n250 AUTH CRAM-MD5")]) { server in
            await expectError(.authenticationUnavailable, stage: .authentication, transient: false) {
                try await client(port: server.port).send(email)
            }
        }
    }

    @Test("A refused connection is a transient failure")
    func connectionRefused() async throws {
        // Bind a port, then free it, so nothing listens there.
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0).get()
        let port = channel.localAddress!.port!
        try await channel.close()

        await expectError(.connectionFailed, stage: .connection, transient: true) {
            try await client(port: port).send(email)
        }
    }

    @Test("A message without recipients fails before connecting")
    func noRecipient() async throws {
        let message = Email(from: "contact@example.com", subject: "Nobody", body: .text("Hi"))
        await expectError(.invalidEmail("The message has no recipient."), stage: nil, transient: false) {
            try await client(port: 9).send(message)
        }
    }

    @Test("Credentials never appear in their description")
    func credentialsDescription() {
        let credentials = SMTPConfiguration.Credentials(username: "user@example.com", password: "secret")
        #expect("\(credentials)" == "Credentials(<redacted>)")
    }
}
