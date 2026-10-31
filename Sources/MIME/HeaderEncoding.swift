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

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Header field encoding: RFC 2047 encoded-words, RFC 5322 phrases and
/// folding, RFC 2231 parameter values and the RFC 5322 date format.
enum HeaderEncoding {
    /// The recommended maximum line length, CRLF excluded (RFC 5322 §2.1.1).
    static let lineLimit = 78

    /// Writes `Name: token token…` folded at whitespace so lines stay within
    /// ``lineLimit`` whenever a single token allows it.
    static func field(_ name: String, tokens: [String]) -> String {
        var output = name + ":"
        var lineLength = output.utf8.count
        for token in tokens {
            let width = token.utf8.count
            if lineLength + 1 + width > lineLimit, lineLength > name.utf8.count + 1 {
                output += "\r\n " + token
                lineLength = 1 + width
            } else {
                output += " " + token
                lineLength += 1 + width
            }
        }
        return output + "\r\n"
    }

    /// Tokens for an unstructured value such as `Subject`. Plain ASCII text
    /// is kept readable; anything else becomes encoded-words.
    static func unstructured(_ value: String) -> [String] {
        if isPlainText(value) {
            return value.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        }
        return encodedWords(value)
    }

    /// Tokens for a display name inside an address (an RFC 5322 phrase).
    static func phrase(_ value: String) -> [String] {
        guard isPlainText(value) else {
            return encodedWords(value)
        }
        if value.utf8.allSatisfy({ $0 == .space || isAtext($0) }) {
            return value.split(separator: " ").map(String.init)
        }
        var quoted = "\""
        for character in value {
            if character == "\"" || character == "\\" {
                quoted.append("\\")
            }
            quoted.append(character)
        }
        return [quoted + "\""]
    }

    /// Splits a value into `=?utf-8?B?…?=` words. Each word holds at most
    /// 39 bytes of UTF-8, cut on Unicode scalar boundaries, which keeps a
    /// word at 64 characters so `Subject:` plus one word fits on a line.
    static func encodedWords(_ value: String) -> [String] {
        var words: [String] = []
        var chunk: [UInt8] = []
        for scalar in value.unicodeScalars {
            let bytes = Array(String(scalar).utf8)
            if chunk.count + bytes.count > 39 {
                words.append(encodedWord(chunk))
                chunk.removeAll(keepingCapacity: true)
            }
            chunk.append(contentsOf: bytes)
        }
        if !chunk.isEmpty || words.isEmpty {
            words.append(encodedWord(chunk))
        }
        return words
    }

    private static func encodedWord(_ bytes: [UInt8]) -> String {
        "=?utf-8?B?" + Base64.encode(bytes) + "?="
    }

    /// A MIME parameter (`name="value"`), switching to the RFC 2231
    /// extended form (`name*=utf-8''…`) when the value is not plain ASCII.
    static func parameter(_ name: String, _ value: String) -> String {
        if isPlainText(value), !value.contains("\""), !value.contains("\\") {
            return "\(name)=\"\(value)\""
        }
        var encoded = ""
        for byte in value.utf8 {
            if isAttributeChar(byte) {
                encoded.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                encoded += "%" + String(byte, radix: 16, uppercase: true).leftPadded(to: 2)
            }
        }
        return "\(name)*=utf-8''\(encoded)"
    }

    /// Printable ASCII with no encoded-word lookalike: safe to write as is.
    static func isPlainText(_ value: String) -> Bool {
        value.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7F } && !value.contains("=?")
    }

    /// RFC 5322 `atext`.
    private static func isAtext(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"):
            true
        default:
            "!#$%&'*+-/=?^_`{|}~".utf8.contains(byte)
        }
    }

    /// RFC 2231 `attribute-char`.
    private static func isAttributeChar(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"):
            true
        default:
            "!#$&+-.^_`|~".utf8.contains(byte)
        }
    }

    /// Formats a date as RFC 5322 `date-time` in UTC, such as
    /// `Sat, 31 Oct 2026 20:43:00 +0000`. Computed by hand so the result
    /// does not depend on the locale or on Foundation's formatters.
    static func date(_ date: Date) -> String {
        let seconds = Int64(date.timeIntervalSince1970.rounded(.down))
        let days = seconds >= 0 ? seconds / 86_400 : (seconds - 86_399) / 86_400
        let secondOfDay = seconds - days * 86_400

        // Days since 1970-01-01 to a civil date (Howard Hinnant's algorithm).
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)

        // 1970-01-01 was a Thursday.
        let weekday = Int(((days % 7) + 7 + 4) % 7)
        let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

        let hour = String(secondOfDay / 3_600).leftPadded(to: 2)
        let minute = String(secondOfDay % 3_600 / 60).leftPadded(to: 2)
        let second = String(secondOfDay % 60).leftPadded(to: 2)
        return "\(weekdays[weekday]), \(day) \(months[Int(month) - 1]) \(year) \(hour):\(minute):\(second) +0000"
    }
}

extension String {
    func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}
