import Foundation

struct ServerSentEvents {
    private var line = Data()
    private var payload = Data()

    mutating func append(_ byte: UInt8) -> Data? {
        guard byte == 10 else {
            line.append(byte)
            return nil
        }

        if line.last == 13 { line.removeLast() }
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            guard !payload.isEmpty else { return nil }
            defer { payload.removeAll(keepingCapacity: true) }
            return payload
        }

        let field = "data:".utf8
        guard line.starts(with: field) else { return nil }
        var value = line.dropFirst(field.count)
        if value.first == 32 { value = value.dropFirst() }
        if !payload.isEmpty { payload.append(10) }
        payload.append(contentsOf: value)
        return nil
    }
}

enum PartialMarkdown {
    static func read(from output: String) -> String? {
        // The recognition schema has one markdown property, even when it arrives after other fields.
        guard let field = output.range(of: #""markdown"\s*:\s*""#, options: .regularExpression) else { return nil }
        let bytes = Array(output[field.upperBound...].utf8)
        var end = 0
        while end < bytes.count {
            if bytes[end] == 34 { break }
            guard bytes[end] == 92 else {
                end += 1
                continue
            }
            guard end + 1 < bytes.count else { break }
            if bytes[end + 1] == 117 {
                guard end + 6 <= bytes.count else { break }
                let digits = String(decoding: bytes[(end + 2)..<(end + 6)], as: UTF8.self)
                let highSurrogate = UInt16(digits, radix: 16).map { (0xD800...0xDBFF).contains($0) } ?? false
                let length = highSurrogate ? 12 : 6
                guard end + length <= bytes.count else { break }
                end += length
            } else {
                end += 2
            }
        }

        var json = Data([34])
        json.append(contentsOf: bytes.prefix(end))
        json.append(34)
        return try? JSONDecoder().decode(String.self, from: json)
    }
}
