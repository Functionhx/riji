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

    @Test func pairing() throws {
        let v = try vector("pairing.json")
        let code = v["code"]!.string!
        let a = try Pairing.KeyPair(privateScalar: hexData(v["a"]!["private_d_hex"]!.string!))
        let b = try Pairing.KeyPair(privateScalar: hexData(v["b"]!["private_d_hex"]!.string!))
        #expect(a.publicKey == v["a"]!["public"]!.string!)
        #expect(b.publicKey == v["b"]!["public"]!.string!)
        let sharedA = try Pairing.shared(a, peer: b.publicKey)
        let sharedB = try Pairing.shared(b, peer: a.publicKey)
        #expect(sharedA == sharedB)
        #expect(sharedA.map { String(format: "%02x", $0) }.joined() == v["shared_hex"]!.string!)
        let transcript = Pairing.transcript(code: code, initiator: a.publicKey, joiner: b.publicKey)
        #expect(transcript.map { String(format: "%02x", $0) }.joined() == v["transcript_hex"]!.string!)
        let (key, sas) = Pairing.keys(shared: sharedB, transcript: transcript)
        #expect(keyHex(key) == v["pair_key_hex"]!.string!)
        #expect(sas == v["sas"]!.string!)
        // 同样的 nonce 封装出同样的信封；也能解开参考实现的信封
        #expect(try Pairing.seal(key: key, code: code, payload: v["payload"]!, nonce: hexData(v["nonce_hex"]!.string!)) == v["sealed"]!.string!)
        #expect(try Pairing.open(key: key, code: code, sealed: v["sealed"]!.string!) == v["payload"]!)
        #expect(throws: Pairing.PairingError.badEnvelope) { try Pairing.open(key: key, code: "00000000", sealed: v["sealed"]!.string!) }
        // 中间人看到的比对码不同
        let m = try Pairing.KeyPair(privateScalar: hexData(v["mitm"]!["m_private_d_hex"]!.string!))
        let sasAM = Pairing.keys(shared: try Pairing.shared(a, peer: m.publicKey),
                                 transcript: Pairing.transcript(code: code, initiator: a.publicKey, joiner: m.publicKey)).sas
        #expect(sasAM == v["mitm"]!["sas_seen_by_a"]!.string!)
    }
}
