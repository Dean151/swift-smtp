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

/// Quoted-printable content transfer encoding (RFC 2045 §6.7).
enum QuotedPrintable {
    /// Encodes text as quoted-printable.
    ///
    /// Line breaks (`\r\n`, `\n` or `\r`) become hard CRLF breaks. Lines
    /// longer than 76 characters are wrapped with soft breaks (`=` CRLF),
    /// never in the middle of an `=XX` escape. The result has no trailing
    /// line break.
    static func encode(_ text: String) -> String {
        var output: [UInt8] = []
        output.reserveCapacity(text.utf8.count + text.utf8.count / 8)
        for (index, line) in lines(of: text).enumerated() {
            if index > 0 {
                output.append(contentsOf: crlf)
            }
            encode(line: line, into: &output)
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func encode(line: ArraySlice<UInt8>, into output: inout [UInt8]) {
        var length = 0
        for index in line.indices {
            let byte = line[index]
            let isLast = index == line.index(before: line.endIndex)
            let isWhitespace = byte == .space || byte == .tab
            let mustEscape = byte == .equals
                || byte > 126
                || (byte < 32 && byte != .tab)
                // Trailing whitespace is stripped by some relays.
                || (isWhitespace && isLast)

            let width = mustEscape ? 3 : 1
            // A line ending in a soft break holds 75 characters plus `=`.
            // The very last token of a line may use the full 76.
            if length + width > (isLast ? 76 : 75) {
                output.append(.equals)
                output.append(contentsOf: crlf)
                length = 0
            }
            if mustEscape {
                output.append(.equals)
                output.append(hexDigits[Int(byte >> 4)])
                output.append(hexDigits[Int(byte & 0x0F)])
            } else {
                output.append(byte)
            }
            length += width
        }
    }

    /// Splits text on any line break convention.
    private static func lines(of text: String) -> [ArraySlice<UInt8>] {
        let bytes = Array(text.utf8)
        var lines: [ArraySlice<UInt8>] = []
        var start = 0
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case .carriageReturn:
                lines.append(bytes[start..<index])
                if index + 1 < bytes.count, bytes[index + 1] == .lineFeed {
                    index += 1
                }
                start = index + 1
            case .lineFeed:
                lines.append(bytes[start..<index])
                start = index + 1
            default:
                break
            }
            index += 1
        }
        lines.append(bytes[start..<bytes.count])
        return lines
    }

    private static let crlf: [UInt8] = [.carriageReturn, .lineFeed]
    private static let hexDigits = Array("0123456789ABCDEF".utf8)
}

extension UInt8 {
    package static let tab: UInt8 = 0x09
    package static let lineFeed: UInt8 = 0x0A
    package static let carriageReturn: UInt8 = 0x0D
    package static let space: UInt8 = 0x20
    package static let period: UInt8 = 0x2E
    package static let equals: UInt8 = 0x3D
}
