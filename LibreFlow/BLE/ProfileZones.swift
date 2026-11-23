import Foundation

/// The heart-rate and speed zones in a Polar sport profile (/U/0/SPROF/<n>/PROFILE.BPB, `PbSportProfile`):
/// field 3 settings › 6 zone_limits › 1 heart_rate_zone {1 lower, 2 upper} (bpm) / 2 speed_zone {1, 2} (float km/h).
/// `replacing` swaps only those zone entries; every other field is copied byte for byte, in its original order.
struct ProfileZones: Equatable {
    var hr: [ClosedRange<Int>]          // 5 zones
    var speed: [ClosedRange<Float>]     // 5 zones, km/h

    /// One field as it appears in the file: number, the raw bytes of the whole field, and its payload (length-delimited).
    private struct Field { let number: Int; let raw: [UInt8]; let payload: [UInt8]?; let value: UInt64? }

    private static func split(_ b: [UInt8]) throws -> [Field] {
        var i = 0, out: [Field] = []
        while i < b.count {
            let start = i
            let key = try PB.readVarint(b, &i)
            let f = Int(key >> 3), wt = Int(key & 7)
            switch wt {
            case 0: let v = try PB.readVarint(b, &i); out.append(Field(number: f, raw: Array(b[start..<i]), payload: nil, value: v))
            case 2:
                let n = Int(try PB.readVarint(b, &i))
                guard n >= 0, i + n <= b.count else { throw PBError.truncated }
                let pl = Array(b[i..<i + n]); i += n
                out.append(Field(number: f, raw: Array(b[start..<i]), payload: pl, value: nil))
            case 5: guard i + 4 <= b.count else { throw PBError.truncated }; i += 4; out.append(Field(number: f, raw: Array(b[start..<i]), payload: nil, value: nil))
            case 1: guard i + 8 <= b.count else { throw PBError.truncated }; i += 8; out.append(Field(number: f, raw: Array(b[start..<i]), payload: nil, value: nil))
            default: throw PBError.badWireType(wt)
            }
        }
        return out
    }
    private static func ld(_ f: Int, _ payload: [UInt8]) -> [UInt8] { PB.varint(UInt64(f << 3 | 2)) + PB.varint(UInt64(payload.count)) + payload }
    private static func f32(_ x: Float) -> [UInt8] { withUnsafeBytes(of: x.bitPattern.littleEndian, Array.init) }

    /// Sport id of the profile (1 = running).
    static func sport(_ b: [UInt8]) -> Int? { PBMessage(b).msg(2)?.int(1) }

    /// Read the zones; nil when the file has no zone limits.
    static func read(_ b: [UInt8]) -> ProfileZones? {
        guard let zl = PBMessage(b).msg(3)?.msg(6) else { return nil }
        let hr = zl.all(1).compactMap { $0.data.map { PBMessage($0) } }.map { $0.int(1)...max($0.int(1), $0.int(2)) }
        let sp = zl.all(2).compactMap { $0.data.map { PBMessage($0) } }.compactMap { m -> ClosedRange<Float>? in
            guard let lo = m.float(1), let hi = m.float(2), lo <= hi else { return nil }; return lo...hi }
        guard hr.count == 5, sp.count == 5 else { return nil }
        return ProfileZones(hr: hr, speed: sp)
    }

    /// The same profile with these zones. Throws when the file is not as expected.
    func replacing(in b: [UInt8]) throws -> [UInt8] {
        func zoneLimits(_ zl: [UInt8]) throws -> [UInt8] {
            var out: [UInt8] = [], putHr = false, putSp = false
            for f in try Self.split(zl) {
                if f.number == 1 {
                    if !putHr { for z in hr { out += Self.ld(1, [0x08] + PB.varint(UInt64(z.lowerBound)) + [0x10] + PB.varint(UInt64(z.upperBound))) }; putHr = true }
                } else if f.number == 2 {
                    if !putSp { for z in speed { out += Self.ld(2, [0x0D] + Self.f32(z.lowerBound) + [0x15] + Self.f32(z.upperBound)) }; putSp = true }
                } else { out += f.raw }
            }
            guard putHr, putSp else { throw PBError.truncated }
            return out
        }
        func settings(_ st: [UInt8]) throws -> [UInt8] {
            var found = false
            let out = try Self.split(st).flatMap { f -> [UInt8] in
                guard f.number == 6, let pl = f.payload else { return f.raw }
                found = true; return Self.ld(6, try zoneLimits(pl))
            }
            guard found else { throw PBError.truncated }
            return out
        }
        var found = false
        let out = try Self.split(b).flatMap { f -> [UInt8] in
            guard f.number == 3, let pl = f.payload else { return f.raw }
            found = true; return Self.ld(3, try settings(pl))
        }
        guard found else { throw PBError.truncated }
        return out
    }
}
