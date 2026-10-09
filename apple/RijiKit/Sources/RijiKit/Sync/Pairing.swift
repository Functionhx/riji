import CryptoKit
import Foundation

/// 设备配对（规格见 spec/reference/riji.mjs「设备配对」与 spec/test-vectors/pairing.json）。
///
/// 发起端（已开启同步的设备）与加入端各生成一对临时 P-256 密钥，经服务器交换公钥；两端由「配对码 + 双方公钥」
/// 派生同一把配对密钥与 6 位比对码。站长确认两边比对码一致后，发起端把日迹密钥封装进配对信封发给加入端。
public enum Pairing {
    public struct KeyPair: Sendable {
        public let privateKey: P256.KeyAgreement.PrivateKey
        /// 未压缩 X9.63 公钥（65 字节）的 base64url
        public var publicKey: String { Base64URL.encode(privateKey.publicKey.x963Representation) }

        public init(privateKey: P256.KeyAgreement.PrivateKey = .init()) { self.privateKey = privateKey }

        public init(privateScalar: Data) throws {
            privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: privateScalar)
        }
    }

    public enum PairingError: Error, Equatable {
        case badPublicKey
        case badEnvelope
    }

    /// ECDH 共享秘密：x 坐标，32 字节。
    public static func shared(_ own: KeyPair, peer: String) throws -> Data {
        guard let raw = Base64URL.decode(peer), let key = try? P256.KeyAgreement.PublicKey(x963Representation: raw) else {
            throw PairingError.badPublicKey
        }
        let secret = try own.privateKey.sharedSecretFromKeyAgreement(with: key)
        return secret.withUnsafeBytes { Data($0) }
    }

    public static func transcript(code: String, initiator: String, joiner: String) -> Data {
        Data(SHA256.hash(data: Data("riji-pair|v1|\(code)|\(initiator)|\(joiner)".utf8)))
    }

    /// → 配对密钥与 6 位比对码。
    public static func keys(shared: Data, transcript: Data) -> (key: SymmetricKey, sas: String) {
        let ikm = SymmetricKey(data: shared)
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: transcript, info: Data("functionhx:riji:pair:key:v1".utf8), outputByteCount: 32)
        let sasBytes = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: transcript, info: Data("functionhx:riji:pair:sas:v1".utf8), outputByteCount: 4)
            .withUnsafeBytes { Array($0) }
        let number = (UInt32(sasBytes[0]) << 24) | (UInt32(sasBytes[1]) << 16) | (UInt32(sasBytes[2]) << 8) | UInt32(sasBytes[3])
        return (key, String(format: "%06u", number % 1_000_000))
    }

    static func aad(_ code: String) -> Data { Data("riji-pair|v1|\(code)".utf8) }

    public static func seal(key: SymmetricKey, code: String, payload: JSONValue, nonce: Data? = nil) throws -> String {
        let gcmNonce = try nonce.map { try AES.GCM.Nonce(data: $0) } ?? AES.GCM.Nonce()
        let box = try AES.GCM.seal(try payload.canonicalData(), using: key, nonce: gcmNonce, authenticating: aad(code))
        return Base64URL.encode(box.combined!)
    }

    public static func open(key: SymmetricKey, code: String, sealed: String) throws -> JSONValue {
        guard let raw = Base64URL.decode(sealed), raw.count > 28,
              let box = try? AES.GCM.SealedBox(combined: raw),
              let plain = try? AES.GCM.open(box, using: key, authenticating: aad(code)) else { throw PairingError.badEnvelope }
        return try JSONValue(jsonData: plain)
    }
}
