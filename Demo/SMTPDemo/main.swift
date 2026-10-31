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

import Foundation
import Logging
import SMTP

// Sends one test message through a real server, configured from the
// environment. Keep the password in a local, git-ignored `.env` file:
//
//     SMTP_HOST=ssl0.ovh.net
//     SMTP_SECURITY=tls            # tls, starttls or unencrypted
//     SMTP_USERNAME=contact@example.com
//     SMTP_PASSWORD=…
//     SMTP_FROM=contact@example.com
//     SMTP_TO=me@example.org
//
// then run `set -a; source .env; set +a; swift run SMTPDemo`.

let environment = ProcessInfo.processInfo.environment

func require(_ name: String) -> String {
    guard let value = environment[name], !value.isEmpty else {
        print("Missing environment variable \(name)")
        exit(1)
    }
    return value
}

let security: SMTPConfiguration.Security = switch environment["SMTP_SECURITY"]?.lowercased() {
case "starttls": .startTLS
case "unencrypted": .unencrypted
default: .tls
}

LoggingSystem.bootstrap { label in
    var handler = StreamLogHandler.standardOutput(label: label)
    handler.logLevel = .trace
    return handler
}

let client = try SMTPClient(
    configuration: SMTPConfiguration(
        hostname: require("SMTP_HOST"),
        port: environment["SMTP_PORT"].flatMap(Int.init),
        security: security,
        credentials: environment["SMTP_USERNAME"].map {
            .init(username: $0, password: require("SMTP_PASSWORD"))
        }
    ),
    logger: Logger(label: "smtp-demo")
)

let email = Email(
    from: Mailbox(require("SMTP_FROM"), name: "swift-smtp ☕️"),
    to: [Mailbox(require("SMTP_TO"))],
    subject: "Test d'envoi : accents, émoji ☕️ et pièce jointe",
    body: .alternative(
        text: """
        Bonjour,

        Ceci est un message de test envoyé par swift-smtp.
        .Cette ligne commence par un point.
        À bientôt ☕️
        """,
        html: """
        <p>Bonjour,</p>
        <p>Ceci est un message de test envoyé par <b>swift-smtp</b>.</p>
        <p>.Cette ligne commence par un point.</p>
        <p>À bientôt ☕️</p>
        """
    ),
    attachments: [
        Email.Attachment(filename: "données.txt", contentType: "text/plain", data: Array("Bonjour ☕️\n".utf8)),
    ]
)

do {
    try await client.send(email)
    print("Sent.")
} catch {
    print("Failed: \(error) (transient: \(error.isTransient))")
    exit(1)
}
