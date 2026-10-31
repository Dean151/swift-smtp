# ``SMTP``

Send e-mail messages through an SMTP server, with async/await on SwiftNIO.

## Overview

Messages are built with the `MIME` module of this package (`Email`, `Mailbox`, attachments), which `SMTP` re-exports: `import SMTP` is all you need.

``SMTPClient`` connects with implicit TLS or `STARTTLS`, authenticates with `AUTH PLAIN` or `AUTH LOGIN`, and delivers the message. Each step has its own timeout.

Every failure is an ``SMTPError``. Its ``SMTPError/isTransient`` property tells whether retrying later can help, and it never contains e-mail addresses, so it can be logged safely.

```swift
import SMTP

let client = try SMTPClient(configuration: SMTPConfiguration(
    hostname: "smtp.example.com",
    credentials: .init(username: "contact@example.com", password: password)
))

try await client.send(Email(
    from: Mailbox("contact@example.com", name: "Example"),
    to: ["someone@example.org"],
    subject: "Bienvenue !",
    body: .alternative(text: "Bonjour", html: "<p>Bonjour</p>")
))
```

## Topics

### Delivery

- ``SMTPClient``
- ``SMTPConfiguration``

### Errors

- ``SMTPError``
- ``SMTPReply``
