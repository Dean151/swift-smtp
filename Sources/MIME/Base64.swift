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

/// Base64 (RFC 4648), written here to avoid depending on Foundation's
/// line-wrapping options, which differ across platforms.
package enum Base64 {
    /// Encodes bytes as base64. With `lineLength`, the output is wrapped
    /// with CRLF every `lineLength` characters (76 for MIME bodies).
    package static func encode<Bytes: Collection<UInt8>>(_ bytes: Bytes, lineLength: Int? = nil) -> String {
        var output: [UInt8] = []
        output.reserveCapacity((bytes.count + 2) / 3 * 4 + (bytes.count / 57 + 1) * 2)
        var lineCount = 0

        func append(_ character: UInt8) {
            if let lineLength, lineCount == lineLength {
                output.append(.carriageReturn)
                output.append(.lineFeed)
                lineCount = 0
            }
            output.append(character)
            lineCount += 1
        }

        var iterator = bytes.makeIterator()
        while let first = iterator.next() {
            let second = iterator.next()
            let third = iterator.next()
            let value = UInt32(first) << 16 | UInt32(second ?? 0) << 8 | UInt32(third ?? 0)
            append(alphabet[Int(value >> 18 & 0x3F)])
            append(alphabet[Int(value >> 12 & 0x3F)])
            append(second == nil ? .equals : alphabet[Int(value >> 6 & 0x3F)])
            append(third == nil ? .equals : alphabet[Int(value & 0x3F)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
}
