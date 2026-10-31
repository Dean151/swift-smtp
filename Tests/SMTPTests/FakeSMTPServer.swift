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

import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
@testable import SMTP

/// A scripted SMTP server on localhost, without TLS.
///
/// Each command gets the reply of the first matching rule in `replies`,
/// then the default reply of a well-behaved server. A `nil` reply means
/// "never answer". Everything received is recorded.
final class FakeSMTPServer: Sendable {
    struct Rule: Sendable {
        var prefix: String
        var reply: String?
    }

    let port: Int
    private let serverChannel: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>
    private let recorded = NIOLockedValueBox<(commands: [String], messages: [String])>(([], []))

    var commands: [String] { recorded.withLockedValue { $0.commands } }
    var messages: [String] { recorded.withLockedValue { $0.messages } }

    static let defaultEHLO = "250-fake.example.com\r\n250-PIPELINING\r\n250-AUTH PLAIN LOGIN\r\n250 SIZE 10240000"

    /// Starts the server. Use ``run(greeting:replies:body:)`` instead,
    /// which also stops it.
    private init(greeting: String?, rules: [Rule]) async throws {
        serverChannel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                }
            }
        port = serverChannel.channel.localAddress!.port!

        let serverChannel = serverChannel
        let recorded = recorded
        Task {
            try? await serverChannel.executeThenClose { connections in
                try await withThrowingDiscardingTaskGroup { group in
                    for try await connection in connections {
                        group.addTask {
                            try? await Self.serve(connection, greeting: greeting, rules: rules, recorded: recorded)
                        }
                    }
                }
            }
        }
    }

    static func run<Result>(
        greeting: String? = "220 fake.example.com ESMTP",
        replies: [(String, String?)] = [],
        body: (FakeSMTPServer) async throws -> Result
    ) async throws -> Result {
        let server = try await FakeSMTPServer(greeting: greeting, rules: replies.map { Rule(prefix: $0.0, reply: $0.1) })
        defer { server.serverChannel.channel.close(promise: nil) }
        return try await body(server)
    }

    private static func serve(
        _ connection: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
        greeting: String?,
        rules: [Rule],
        recorded: NIOLockedValueBox<(commands: [String], messages: [String])>
    ) async throws {
        try await connection.executeThenClose { inbound, outbound in
            var reader = LineReader(iterator: inbound.makeAsyncIterator())

            func send(_ reply: String?) async throws -> Bool {
                guard let reply else {
                    // Never answer: wait until the client gives up.
                    while (try? await reader.readLine()) != nil {}
                    return false
                }
                try await outbound.write(ByteBuffer(string: reply + "\r\n"))
                return true
            }

            guard try await send(greeting) else { return }
            var message: [String]?
            var loginStep = 0

            while let line = try? await reader.readLine() {
                if var lines = message {
                    guard line == "." else {
                        lines.append(line)
                        message = lines
                        continue
                    }
                    recorded.withLockedValue { $0.messages.append(lines.joined(separator: "\r\n")) }
                    message = nil
                    guard try await send(Self.reply(to: ".", rules: rules)) else { return }
                    continue
                }

                recorded.withLockedValue { $0.commands.append(line) }
                let reply: String?
                switch loginStep {
                case 1:
                    reply = "334 UGFzc3dvcmQ6"
                    loginStep = 2
                case 2:
                    reply = "235 2.7.0 Authentication successful"
                    loginStep = 0
                default:
                    reply = Self.reply(to: line, rules: rules)
                    if line == "AUTH LOGIN", reply?.hasPrefix("334") == true {
                        loginStep = 1
                    }
                }
                guard try await send(reply) else { return }
                if line == "DATA", reply?.hasPrefix("354") == true {
                    message = []
                }
                if line == "QUIT" {
                    return
                }
            }
        }
    }

    private static func reply(to line: String, rules: [Rule]) -> String? {
        if let rule = rules.first(where: { line.hasPrefix($0.prefix) }) {
            return rule.reply
        }
        let verb = line.split(separator: " ").first.map(String.init) ?? line
        return switch verb {
        case "EHLO": defaultEHLO
        case "HELO": "250 fake.example.com"
        case "AUTH": line.hasPrefix("AUTH LOGIN") ? "334 VXNlcm5hbWU6" : "235 2.7.0 Authentication successful"
        case "MAIL", "RCPT": "250 2.1.0 OK"
        case "DATA": "354 End data with <CR><LF>.<CR><LF>"
        case ".": "250 2.0.0 Ok: queued as 12345"
        case "QUIT": "221 2.0.0 Bye"
        case "RSET", "NOOP": "250 OK"
        default: "500 5.5.2 Unknown command"
        }
    }
}
