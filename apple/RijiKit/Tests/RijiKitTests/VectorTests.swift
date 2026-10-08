import CryptoKit
import Foundation
import Testing
@testable import RijiKit

// 跨平台测试向量（spec/test-vectors/）：Swift 实现必须与参考实现逐字节一致。

private let vectorsURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("spec/test-vectors")

private func vector(_ name: String) throws -> JSONValue {
    try JSONValue(jsonData: Data(contentsOf: vectorsURL.appendingPathComponent(name)))
}

private func hexData(_ text: String) -> Data {
    var data = Data()
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        data.append(UInt8(text[index..<next], radix: 16)!)
        index = next
    }
    return data
}

private func keyHex(_ key: SymmetricKey) -> String {
    key.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
}

private func segment(_ json: JSONValue) -> Segment {
    Segment(
        v: json["v"]!.int!, device: json["device"]!.string!, seq: json["seq"]!.int!, prev: json["prev"]!.string!,
        epoch: json["epoch"]!.int!, hlcMax: json["hlc_max"]!.string!, ct: json["ct"]!.string!)
}

@Suite("spec test vectors")
struct VectorTests {
    @Test func canonicalJSON() throws {
        for item in try vector("canonical-json.json")["cases"]!.array! {
            #expect(try item["input"]!.canonicalJSON() == item["output"]!.string!)
        }
    }

    @Test func hlc() throws {
        let v = try vector("hlc.json")
        for item in v["format"]!.array! {
            let clock = try HLC(ms: Int64(item["ms"]!.int!), counter: item["counter"]!.int!, device: item["device"]!.string!)
            #expect(clock.description == item["text"]!.string!)
            #expect(try HLC(parsing: item["text"]!.string!) == clock)
        }
        for text in v["invalid"]!.array! {
            #expect(throws: (any Error).self) { try HLC(parsing: text.string!) }
        }
        for item in v["compare"]!.array! {
            let a = try HLC(parsing: item["a"]!.string!), b = try HLC(parsing: item["b"]!.string!)
            let result = a < b ? -1 : a > b ? 1 : 0
            #expect(result == item["result"]!.int!)
        }
        for item in v["tick"]!.array! {
            let last = try item["last"]!.string.map(HLC.init(parsing:))
            let next = try HLC.tick(last: last, wallMs: Int64(item["wall"]!.int!), device: item["device"]!.string!)
            #expect(next.description == item["result"]!.string!)
        }
        for item in v["receive"]!.array! {
            let last = try item["last"]!.string.map(HLC.init(parsing:))
            let next = try HLC.receive(
                last: last, remote: try HLC(parsing: item["remote"]!.string!), wallMs: Int64(item["wall"]!.int!),
                device: item["device"]!.string!)
            #expect(next.description == item["result"]!.string!)
        }
    }

    @Test func keyDerivation() throws {
        let v = try vector("kdf.json")
        let root = hexData(v["root"]!.string!), salt = hexData(v["riji_salt"]!.string!)
        var keys: [Int: SymmetricKey] = [:]
        for item in v["riji_keys"]!.array! {
            let epoch = item["epoch"]!.int!
            keys[epoch] = RijiCrypto.deriveRijiKey(root: root, rijiSalt: salt, epoch: epoch)
            #expect(keyHex(keys[epoch]!) == item["key"]!.string!)
        }
        for item in v["segment_keys"]!.array! {
            let key = RijiCrypto.deriveSegmentKey(rijiKey: keys[item["epoch"]!.int!]!, device: item["device"]!.string!, seq: item["seq"]!.int!)
            #expect(keyHex(key) == item["key"]!.string!)
        }
    }

    @Test func segmentsOpenSealAndDetectTampering() throws {
        let v = try vector("segments.json")
        let rijiKey = SymmetricKey(data: hexData(v["riji_key_epoch_1"]!.string!))
        for (_, json) in v["segments"]!.object! {
            let original = segment(json)
            let changes = try original.open(rijiKey: rijiKey)
            #expect(!changes.isEmpty)
            #expect(original.hlcMax == changes.map(\.hlc).max()!.description)
            // 用同一个 nonce 重新封装必须得到逐字节相同的密文。
            let nonce = Base64URL.decode(original.ct)!.prefix(12)
            let resealed = try Segment.seal(
                rijiKey: rijiKey, device: original.device, seq: original.seq, prev: original.prev,
                epoch: original.epoch, changes: changes, nonce: Data(nonce))
            #expect(resealed == original)
        }
        for (name, hash) in v["chain_hashes"]!.object! {
            #expect(segment(v["segments"]![name]!).chainHash == hash.string!)
        }
        for item in v["must_fail_to_open"]!.array! {
            #expect(throws: SegmentError.authenticationFailed) { try segment(item["segment"]!).open(rijiKey: rijiKey) }
        }
    }

    @Test func mergeScenarios() throws {
        let segments = try vector("segments.json")
        let merge = try vector("merge.json")
        let rijiKey = SymmetricKey(data: hexData(segments["riji_key_epoch_1"]!.string!))
        for scenario in merge["scenarios"]!.array! {
            let list = scenario["segments"]!.array!.map { name -> Segment in
                let text = name.string!
                return text.hasSuffix("(forged-prev)") ? segment(merge["forged_prev_segment"]!) : segment(segments["segments"]![text]!)
            }
            let result = try Merge.materialize(rijiKey: rijiKey, segments: list)
            let label = scenario["name"]!.string!
            #expect(.object(result.vector.mapValues { .number(Double($0)) }) == scenario["expected_vector"]!, "\(label)")
            #expect(.object(result.problems.mapValues { .array($0.map(\.json)) }) == scenario["expected_problems"]!, "\(label)")
            #expect(result.stateJSON == scenario["expected_state"]!, "\(label)")
            #expect(try result.digest() == scenario["expected_state_digest"]!.string!, "\(label)")
        }
    }
}
