import CryptoKit
import Foundation

// 日迹同步协议 v1：密钥派生、日志段封装与校验、合并。与 spec/reference/riji.mjs 逐字节一致，
// 由 spec/test-vectors/ 检验（Tests/RijiKitTests/VectorTests.swift）。

public enum RijiCrypto {
    public static let genesisPrev = String(repeating: "0", count: 64)

    /// 网站保险库根密钥 R → 日迹密钥 K_riji（每个 epoch 一把）。
    public static func deriveRijiKey(root: Data, rijiSalt: Data, epoch: Int) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: root), salt: rijiSalt,
            info: Data("functionhx:riji:v1:epoch=\(epoch)".utf8), outputByteCount: 32)
    }

    /// K_riji → 某台设备某一段的密钥（确定性派生，每段只加密一次）。
    public static func deriveSegmentKey(rijiKey: SymmetricKey, device: String, seq: Int) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: rijiKey, salt: Data(count: 32),
            info: Data("functionhx:riji:segment:v1|\(device)|\(seq)".utf8), outputByteCount: 32)
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// 一条变更：某条记录在某个时刻的完整新值，或者删除。
public struct Change: Hashable, Sendable {
    public var type: String
    public var id: String
    public var hlc: HLC
    public var deleted: Bool
    public var value: JSONValue?

    public init(type: String, id: String, hlc: HLC, deleted: Bool = false, value: JSONValue? = nil) {
        self.type = type
        self.id = id
        self.hlc = hlc
        self.deleted = deleted
        self.value = deleted ? nil : value
    }

    public var key: String { "\(type):\(id)" }

    public var json: JSONValue {
        var fields: [String: JSONValue] = ["type": .string(type), "id": .string(id), "hlc": .string(hlc.description)]
        if deleted { fields["deleted"] = true } else if let value { fields["value"] = value }
        return .object(fields)
    }

    public init(json: JSONValue) throws {
        guard let type = json["type"]?.string, let id = json["id"]?.string, let hlcText = json["hlc"]?.string else {
            throw SegmentError.malformedChange
        }
        self.init(type: type, id: id, hlc: try HLC(parsing: hlcText), deleted: json["deleted"]?.bool ?? false, value: json["value"])
    }

    static func sorted(_ changes: [Change]) -> [Change] {
        changes.sorted { a, b in
            if a.type != b.type { return a.type < b.type }
            if a.id != b.id { return a.id < b.id }
            return a.hlc < b.hlc
        }
    }
}

public enum SegmentError: Error, Equatable {
    case invalidSeq
    case invalidPrev
    case malformedChange
    case malformedSegment
    case authenticationFailed
}

/// 一段加密日志。服务端只看得到这些头部字段与密文。
public struct Segment: Hashable, Sendable, Codable {
    public var v: Int
    public var device: String
    public var seq: Int
    public var prev: String
    public var epoch: Int
    public var hlcMax: String
    public var ct: String

    enum CodingKeys: String, CodingKey {
        case v, device, seq, prev, epoch, ct
        case hlcMax = "hlc_max"
    }

    public var name: String { "\(device)#\(seq)" }

    var aad: Data { Data("riji-segment|v\(v)|\(device)|\(seq)|\(prev)|\(epoch)".utf8) }

    /// 下一段的 prev：本段完整密文字节（含 nonce）的 SHA-256。
    public var chainHash: String { RijiCrypto.sha256Hex(Base64URL.decode(ct) ?? Data()) }

    public static func seal(
        rijiKey: SymmetricKey, device: String, seq: Int, prev: String, epoch: Int,
        changes: [Change], nonce: Data? = nil
    ) throws -> Segment {
        guard seq >= 1 else { throw SegmentError.invalidSeq }
        guard prev.count == 64, prev.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw SegmentError.invalidPrev }
        guard seq != 1 || prev == RijiCrypto.genesisPrev else { throw SegmentError.invalidPrev }
        let sorted = Change.sorted(changes)
        let plaintext = try JSONValue.object(["changes": .array(sorted.map(\.json))]).canonicalData()
        let key = RijiCrypto.deriveSegmentKey(rijiKey: rijiKey, device: device, seq: seq)
        var header = Segment(v: 1, device: device, seq: seq, prev: prev, epoch: epoch, hlcMax: "", ct: "")
        let gcmNonce = try nonce.map { try AES.GCM.Nonce(data: $0) } ?? AES.GCM.Nonce()
        let box = try AES.GCM.seal(plaintext, using: key, nonce: gcmNonce, authenticating: header.aad)
        header.ct = Base64URL.encode(box.combined!)
        header.hlcMax = sorted.map(\.hlc).max()?.description ?? ""
        return header
    }

    public func open(rijiKey: SymmetricKey) throws -> [Change] {
        guard let raw = Base64URL.decode(ct), raw.count > 28 else { throw SegmentError.malformedSegment }
        let key = RijiCrypto.deriveSegmentKey(rijiKey: rijiKey, device: device, seq: seq)
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(try AES.GCM.SealedBox(combined: raw), using: key, authenticating: aad)
        } catch {
            throw SegmentError.authenticationFailed
        }
        guard let changes = try JSONValue(jsonData: plaintext)["changes"]?.array else { throw SegmentError.malformedSegment }
        return try changes.map(Change.init(json:))
    }
}

public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }
}

// ---------------------------------------------------------------- 链校验与合并

public enum ChainProblem: Hashable, Sendable {
    case gap(missing: Int)
    case brokenChain(seq: Int)
    case fork(seq: Int)

    public var json: JSONValue {
        switch self {
        case let .gap(missing): ["code": "gap", "missing": .number(Double(missing))]
        case let .brokenChain(seq): ["code": "broken_chain", "seq": .number(Double(seq))]
        case let .fork(seq): ["code": "fork", "seq": .number(Double(seq))]
        }
    }
}

public enum Chain {
    /// 一台设备的段：序号从 1 连续、prev 吻合；重复段忽略。返回可接受的最长前缀与问题。
    public static func verify(_ segments: [Segment]) -> (accepted: [Segment], problems: [ChainProblem]) {
        let ordered = segments.enumerated().sorted { ($0.element.seq, $0.offset) < ($1.element.seq, $1.offset) }.map(\.element)
        var accepted: [Segment] = []
        var problems: [ChainProblem] = []
        var expectedSeq = 1
        var expectedPrev = RijiCrypto.genesisPrev
        for segment in ordered {
            if segment.seq < expectedSeq {
                if accepted.contains(where: { $0.seq == segment.seq && $0.ct == segment.ct }) { continue }
                problems.append(.fork(seq: segment.seq))
                break
            }
            if segment.seq > expectedSeq {
                problems.append(.gap(missing: expectedSeq))
                break
            }
            if segment.prev != expectedPrev {
                problems.append(.brokenChain(seq: segment.seq))
                break
            }
            accepted.append(segment)
            expectedSeq += 1
            expectedPrev = segment.chainHash
        }
        return (accepted, problems)
    }
}

/// 合并后的状态中的一项：最新值或墓碑。
public struct RecordState: Hashable, Sendable {
    public var hlc: HLC
    public var deleted: Bool
    public var value: JSONValue?

    public var json: JSONValue {
        deleted ? ["hlc": .string(hlc.description), "deleted": true] : ["hlc": .string(hlc.description), "value": value ?? .null]
    }
}

public struct Materialized: Sendable {
    public var state: [String: RecordState]
    public var vector: [String: Int]
    public var problems: [String: [ChainProblem]]

    public var stateJSON: JSONValue { .object(state.mapValues(\.json)) }

    public func digest() throws -> String {
        RijiCrypto.sha256Hex(try stateJSON.canonicalData())
    }
}

public enum Merge {
    /// 同一 (type, id) 取 HLC 最大者；与到达顺序无关。
    public static func apply(_ changes: [Change], to state: inout [String: RecordState]) {
        for change in changes {
            if let current = state[change.key], change.hlc <= current.hlc { continue }
            state[change.key] = RecordState(hlc: change.hlc, deleted: change.deleted, value: change.deleted ? nil : change.value)
        }
    }

    /// 一组段（可能来自多个副本、乱序、重复）→ 状态。
    public static func materialize(rijiKey: SymmetricKey, segments: [Segment]) throws -> Materialized {
        let byDevice = Dictionary(grouping: segments, by: \.device)
        var state: [String: RecordState] = [:]
        var vector: [String: Int] = [:]
        var problems: [String: [ChainProblem]] = [:]
        for device in byDevice.keys.sorted() {
            let (accepted, found) = Chain.verify(byDevice[device]!)
            if !found.isEmpty { problems[device] = found }
            vector[device] = accepted.count
            for segment in accepted { apply(try segment.open(rijiKey: rijiKey), to: &state) }
        }
        return Materialized(state: state, vector: vector, problems: problems)
    }
}
