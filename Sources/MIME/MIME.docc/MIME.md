# ``MIME``

Build e-mail messages as standards-compliant MIME, with no dependency.

## Overview

``Email`` describes a message: plain text, HTML or both, attachments and inline images. ``Email/rendered()`` turns it into RFC 5322 / MIME text with CRLF line endings, always 7-bit:

- text parts in quoted-printable, attachments in base64;
- non-ASCII subjects, display names and headers as RFC 2047 encoded-words;
- non-ASCII file names in the RFC 2231 form;
- long header lines folded at 78 characters.

The result travels through any SMTP server. Send it with the `SMTP` module of this package, or hand it to any API that accepts raw messages, such as Amazon SES `SendRawEmail` or the Gmail API.

```swift
import MIME

let email = Email(
    from: Mailbox("contact@example.com", name: "Example"),
    to: ["someone@example.org"],
    subject: "Votre export est prêt",
    body: .alternative(text: "Bonjour", html: "<p>Bonjour</p>")
)
let raw = try email.rendered()
```

Invalid input, such as an address containing a line break, throws a ``MIMEError`` whose reason never quotes an address.

## Topics

### Messages

- ``Email``
- ``Mailbox``
- ``Email/Body``
- ``Email/Attachment``
- ``Email/Header``

### Errors

- ``MIMEError``
