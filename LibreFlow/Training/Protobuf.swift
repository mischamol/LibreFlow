import Foundation
import Compression

/// Minimal protobuf wire-format reader/writer (enough for Polar's .BPB/.GZB files and PSFTP messages).
enum PBValue {
    case varint(UInt64)
    case fixed64([UInt8])
    case bytes([UInt8])
    case fixed32([UInt8])

    var int: Int? { if case .varint(let v) = self { return Int(truncatingIfNeeded: v) }; return nil }
    var data: [UInt8]? { if case .bytes(let b) = self { return b }; return nil }
    var float: Float? {
        if case .fixed32(let b) = self, b.count == 4 { return Float(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24) }
        return nil
    }
}

enum PBError: Error { case truncated, badWireType(Int), fieldZero }

enum PB {
    static func varint(_ value: UInt64) -> [UInt8] {
        var n = value, out: [UInt8] = []
        repeat {
            var b = UInt8(n & 0x7F); n >>= 7
            if n != 0 { b |= 0x80 }
            out.append(b)
        } while n != 0
        return out
    }

    // MARK: writing (fields in the order given; used for the files LibreFlow writes to the watch)
    static func key(_ f: Int, _ wire: Int) -> [UInt8] { varint(UInt64(f << 3 | wire)) }
    static func vi(_ f: Int, _ v: UInt64) -> [UInt8] { key(f, 0) + varint(v) }
    static func vi(_ f: Int, _ v: Int) -> [UInt8] { vi(f, UInt64(max(0, v))) }
    /// sint32/sint64 (zigzag)
    static func zig(_ f: Int, _ v: Int) -> [UInt8] { vi(f, UInt64(bitPattern: Int64((v << 1) ^ (v >> 63)))) }
    static func ld(_ f: Int, _ b: [UInt8]) -> [UInt8] { key(f, 2) + varint(UInt64(b.count)) + b }
    /// a Polar text message {1 text} as field f
    static func text(_ f: Int, _ s: String) -> [UInt8] { ld(f, ld(1, Array(s.utf8))) }
    static func f32(_ f: Int, _ x: Double) -> [UInt8] { key(f, 5) + withUnsafeBytes(of: Float(x).bitPattern.littleEndian, Array.init) }
    static func f64(_ f: Int, _ x: Double) -> [UInt8] { key(f, 1) + withUnsafeBytes(of: x.bitPattern.littleEndian, Array.init) }

    /// PbSystemDateTime {1 date {y, m, d}, 2 time {h, m, s, ms}, 3 trusted}; ms only when trusted (as Polar writes it)
    static func dateTime(_ now: Date, trusted: Bool) -> [UInt8] {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: now)
        return ld(1, vi(1, c.year!) + vi(2, c.month!) + vi(3, c.day!))
            + ld(2, vi(1, c.hour!) + vi(2, c.minute!) + vi(3, c.second!) + vi(4, trusted ? c.nanosecond! / 1_000_000 : 0)) + vi(3, trusted ? 1 : 0)
    }

    /// ID.BPB of a favorite: {1 id, 2 last modified, 3 created}
    static func favoriteIdFile(_ id: UInt64, now: Date = Date()) -> [UInt8] {
        let dt = dateTime(now, trusted: false)
        return vi(1, id) + ld(2, dt) + ld(3, dt)
    }

    static func readVarint(_ buf: [UInt8], _ i: inout Int) throws -> UInt64 {
        var shift: UInt64 = 0, val: UInt64 = 0
        while true {
            guard i < buf.count, shift < 64 else { throw PBError.truncated }
            let b = buf[i]; i += 1
            val |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return val }
            shift += 7
        }
    }

    static func fields(_ buf: [UInt8]) throws -> [(Int, PBValue)] {
        var i = 0, out: [(Int, PBValue)] = []
        while i < buf.count {
            let key = try readVarint(buf, &i)
            let f = Int(key >> 3), wt = Int(key & 7)
            guard f != 0 else { throw PBError.fieldZero }
            switch wt {
            case 0: out.append((f, .varint(try readVarint(buf, &i))))
            case 1:
                guard i + 8 <= buf.count else { throw PBError.truncated }
                out.append((f, .fixed64(Array(buf[i..<i + 8])))); i += 8
            case 2:
                let ln = Int(try readVarint(buf, &i))
                guard ln >= 0, i + ln <= buf.count else { throw PBError.truncated }
                out.append((f, .bytes(Array(buf[i..<i + ln])))); i += ln
            case 5:
                guard i + 4 <= buf.count else { throw PBError.truncated }
                out.append((f, .fixed32(Array(buf[i..<i + 4])))); i += 4
            default: throw PBError.badWireType(wt)
            }
        }
        return out
    }
}

/// Convenience accessors on a decoded message.
struct PBMessage {
    let fields: [(Int, PBValue)]
    init(_ buf: [UInt8]?) { fields = (try? PB.fields(buf ?? [])) ?? [] }

    func all(_ f: Int) -> [PBValue] { fields.filter { $0.0 == f }.map { $0.1 } }
    func first(_ f: Int) -> PBValue? { fields.first { $0.0 == f }?.1 }
    func int(_ f: Int, _ def: Int = 0) -> Int { first(f)?.int ?? def }
    func optInt(_ f: Int) -> Int? { first(f)?.int }
    func float(_ f: Int) -> Float? { first(f)?.float }
    func msg(_ f: Int) -> PBMessage? { first(f)?.data.map { PBMessage($0) } }

    /// packed or repeated varints
    func varints(_ f: Int) -> [Int] {
        var out: [Int] = []
        for v in all(f) {
            switch v {
            case .varint(let x): out.append(Int(truncatingIfNeeded: x))
            case .bytes(let b):
                var i = 0
                while i < b.count, let x = try? PB.readVarint(b, &i) { out.append(Int(truncatingIfNeeded: x)) }
            default: break
            }
        }
        return out
    }
    /// packed little-endian floats
    func floats(_ f: Int) -> [Float] {
        var out: [Float] = []
        for v in all(f) {
            switch v {
            case .bytes(let b):
                var i = 0
                while i + 4 <= b.count { out.append(Float(bitPattern: le32(b, i))); i += 4 }
            case .fixed32(let b): out.append(Float(bitPattern: le32(b, 0)))
            default: break
            }
        }
        return out
    }
    /// packed little-endian doubles
    func doubles(_ f: Int) -> [Double] {
        var out: [Double] = []
        for v in all(f) {
            switch v {
            case .bytes(let b):
                var i = 0
                while i + 8 <= b.count { out.append(Double(bitPattern: le64(b, i))); i += 8 }
            case .fixed64(let b): out.append(Double(bitPattern: le64(b, 0)))
            default: break
            }
        }
        return out
    }
}

@inline(__always) func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
    UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
}
@inline(__always) func le64(_ b: [UInt8], _ i: Int) -> UInt64 {
    UInt64(le32(b, i)) | UInt64(le32(b, i + 4)) << 32
}

enum Gzip {
    /// Decompress a gzip member (RFC 1952). Returns the input unchanged when it is not gzip.
    static func decompressIfNeeded(_ data: [UInt8]) -> [UInt8]? {
        guard data.count >= 18, data[0] == 0x1F, data[1] == 0x8B else { return data }
        guard data[2] == 8 else { return nil }   // deflate only
        let flg = data[3]
        var i = 10
        if flg & 4 != 0 { guard i + 2 <= data.count else { return nil }; i += 2 + Int(data[i]) + Int(data[i + 1]) << 8 }
        if flg & 8 != 0 { while i < data.count, data[i] != 0 { i += 1 }; i += 1 }
        if flg & 16 != 0 { while i < data.count, data[i] != 0 { i += 1 }; i += 1 }
        if flg & 2 != 0 { i += 2 }
        guard i < data.count - 8 else { return nil }
        let isize = Int(le32(data, data.count - 4))
        let deflate = Array(data[i..<(data.count - 8)])
        var capacity = max(isize, 1024)
        for _ in 0..<4 {
            var out = [UInt8](repeating: 0, count: capacity)
            let n = deflate.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    compression_decode_buffer(dst.baseAddress!, capacity, src.baseAddress!, deflate.count, nil, COMPRESSION_ZLIB)
                }
            }
            if n > 0 && n < capacity { return Array(out[0..<n]) }
            if n == capacity && n == isize { return out }
            capacity *= 4   // ISIZE is mod 2^32 or decode filled the buffer: try bigger
        }
        return nil
    }
}
