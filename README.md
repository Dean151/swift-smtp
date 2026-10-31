# swift-smtp

[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FDean151%2Fswift-smtp%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/Dean151/swift-smtp)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FDean151%2Fswift-smtp%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/Dean151/swift-smtp)

A small SMTP client for Swift servers, built on SwiftNIO with async/await.
No web framework, no Dispatch: just `swift-nio`, `swift-nio-ssl` and
`swift-log`, which most server apps already depend on.

## What's in the box

| Product | Purpose | Dependencies |
| --- | --- | --- |
| `MIME` | Builds messages as standards-compliant MIME text. | None |
| `SMTP` | Sends them through an SMTP server. Re-exports `MIME`. | `swift-nio`, `swift-nio-ssl`, `swift-log` |

- **Message building**: plain text, HTML, or both (`multipart/alternative`),
  attachments (`multipart/mixed`) and inline images (`multipart/related`).
  Always rendered as 7-bit MIME: quoted-printable text, base64 attachments,
  RFC 2047 encoded headers and RFC 2231 file names, so accents and emoji go
  through any server.
- **Delivery**: implicit TLS (port 465) or mandatory `STARTTLS` (port 587),
  `AUTH PLAIN` and `AUTH LOGIN`, multi-line replies, `HELO` fallback, and a
  timeout for every step.
- **Errors made for retry queues**: every failure is an `SMTPError` that says
  whether it is transient (network, timeout, 4xx) or permanent (5xx, invalid
  message).
- **Privacy**: errors and logs never contain addresses, credentials or
  message content. Server replies are kept, with addresses redacted.

## Requirements

- Swift **6.1** or later (Swift 6 language mode)
- Linux, macOS 13+, iOS 16+, tvOS 16+, visionOS 1+

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/Dean151/swift-smtp.git", from: "0.1.0"),
],
targets: [
    .target(
        name: "MyServer",
        dependencies: [
            .product(name: "SMTP", package: "swift-smtp"),
        ]
    ),
]
```

Only need to build messages, for instance to hand them to an HTTP API?
Depend on the `MIME` product instead: it compiles without SwiftNIO.

## Usage

```swift
import SMTP

let client = try SMTPClient(configuration: SMTPConfiguration(
    hostname: "smtp.example.com",          // port 465, implicit TLS by default
    credentials: .init(username: "contact@example.com", password: password)
))

let email = Email(
    from: Mailbox("contact@example.com", name: "Example"),
    to: [Mailbox("zoe@example.org", name: "Zoé")],
    subject: "Votre export est prêt ☕️",
    body: .alternative(
        text: "Bonjour,\n\nVotre export est disponible pendant 24 h.",
        html: "<p>Bonjour,</p><p>Votre export est disponible pendant 24 h.</p>"
    )
)

do {
    try await client.send(email)
} catch let error where error.isTransient {
    // Network failure, timeout or 4xx: try again later.
} catch {
    // 5xx or invalid message: retrying will not help.
}
```

### Attachments and inline images

```swift
var email = Email(
    from: "contact@example.com",
    to: ["zoe@example.org"],
    subject: "Facture",
    body: .alternative(text: "Voir la pièce jointe.", html: #"<img src="cid:logo"><p>Voir la pièce jointe.</p>"#)
)
email.attachments = [
    Email.Attachment(filename: "facture.pdf", contentType: "application/pdf", data: pdfBytes),
    Email.Attachment(filename: "logo.png", contentType: "image/png", data: logoBytes, disposition: .inline(contentID: "logo")),
]
```

### Configuration

| Option | Default |
| --- | --- |
| `security` | `.tls` (implicit TLS). Also `.startTLS`, which fails rather than falling back to plain text, and `.unencrypted` for tests and local relays. |
| `port` | 465 for `.tls`, 587 for `.startTLS`, 25 for `.unencrypted` |
| `heloName` | `localhost`. Some servers expect the sender's fully qualified domain name. |
| `timeouts` | 10 s to connect, 60 s per command, 120 s for the server to accept the message |
| `tlsConfiguration` | Certificate chain and hostname verified against the system trust store |

Pass a `Logger` to `SMTPClient` to see steps and reply codes. It logs nothing
by default.

### Raw MIME

`Email.rendered()` returns the MIME text without sending it, for APIs that
accept raw messages (Amazon SES `SendRawEmail`, the Gmail API…):

```swift
import MIME

let raw = try email.rendered()   // throws MIMEError on invalid input
```

## Design notes

- **One connection per message.** Nothing is kept open between calls, so
  `SMTPClient` is a `Sendable` value you can share across tasks.
- **All or nothing.** If any recipient is rejected, the message is not sent.
- **No 8-bit.** Everything is encoded to 7-bit ASCII, so `8BITMIME` and
  `SMTPUTF8` are not needed. Addresses must be ASCII.

## Trying it against a real server

The `SMTPDemo` target sends a test message with accents, an emoji and an
attachment. Put the settings in a git-ignored `.env` file (see
`Demo/SMTPDemo/main.swift`), then:

```sh
set -a; source .env; set +a; swift run SMTPDemo
```

## Contributions

Issues and PRs welcome.

## License

[MIT](LICENSE) © Thomas Durand.
