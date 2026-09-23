import Foundation
import Compression

/// Minimal ZIP writer (deflate, no ZIP64) — enough for Office documents such as .pptx.
struct ZipWriter {
    private var body = Data()
    private var central = Data()
    private var count = 0

    mutating func add(_ name: String, _ content: Data) {
        let nameData = Data(name.utf8)
        let crc = CRC32.checksum(content)
        let deflated = Deflate.raw(content)
        // Keep tiny or incompressible parts stored.
        let (method, stored): (UInt16, Data) = deflated.map { $0.count < content.count ? (8, $0) : (0, content) } ?? (0, content)
        let offset = body.count
        // DOS date/time: 1 Jan 2000 00:00, so output is reproducible.
        let dosTime: UInt16 = 0, dosDate: UInt16 = (20 << 9) | (1 << 5) | 1

        body.append(le32(0x0403_4B50))
        body.append(le16(20)); body.append(le16(0x0800)); body.append(le16(method))
        body.append(le16(dosTime)); body.append(le16(dosDate))
        body.append(le32(crc)); body.append(le32(UInt32(stored.count))); body.append(le32(UInt32(content.count)))
        body.append(le16(UInt16(nameData.count))); body.append(le16(0))
        body.append(nameData); body.append(stored)

        central.append(le32(0x0201_4B50))
        central.append(le16(20)); central.append(le16(20)); central.append(le16(0x0800)); central.append(le16(method))
        central.append(le16(dosTime)); central.append(le16(dosDate))
        central.append(le32(crc)); central.append(le32(UInt32(stored.count))); central.append(le32(UInt32(content.count)))
        central.append(le16(UInt16(nameData.count))); central.append(le16(0)); central.append(le16(0))
        central.append(le16(0)); central.append(le16(0)); central.append(le32(0)); central.append(le32(UInt32(offset)))
        central.append(nameData)
        count += 1
    }

    mutating func add(_ name: String, _ text: String) { add(name, Data(text.utf8)) }

    func finish() -> Data {
        var out = body
        out.append(central)
        out.append(le32(0x0605_4B50))
        out.append(le16(0)); out.append(le16(0))
        out.append(le16(UInt16(count))); out.append(le16(UInt16(count)))
        out.append(le32(UInt32(central.count))); out.append(le32(UInt32(body.count)))
        out.append(le16(0))
        return out
    }

    private func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

enum Deflate {
    /// Raw DEFLATE (what ZIP stores); nil if compression fails.
    static func raw(_ input: Data) -> Data? {
        if input.isEmpty { return nil }
        let capacity = input.count + input.count / 10 + 1024
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        out.count = written
        return out
    }
}
