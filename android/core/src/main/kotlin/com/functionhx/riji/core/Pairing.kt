package com.functionhx.riji.core

import java.math.BigInteger
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.interfaces.ECPrivateKey
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPrivateKeySpec
import java.security.spec.ECPublicKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * 设备配对（规格见 spec/reference/riji.mjs「设备配对」与 spec/test-vectors/pairing.json）。与 Swift 的 Pairing 相同：
 * 两端各一对临时 P-256 密钥，由「配对码 + 双方公钥」派生配对密钥与 6 位比对码；确认一致后发起端把日迹密钥封进信封。
 */
object Pairing {
    class KeyPair(val privateKey: ECPrivateKey, val publicKeyObj: ECPublicKey) {
        /** 未压缩 X9.63 公钥（65 字节）的 base64url */
        val publicKey: String get() = Base64Url.encode(x963(publicKeyObj))
    }

    class BadEnvelope : Exception("pairing envelope failed authentication")

    private val params: ECParameterSpec by lazy {
        AlgorithmParameters.getInstance("EC").apply { init(ECGenParameterSpec("secp256r1")) }.getParameterSpec(ECParameterSpec::class.java)
    }

    fun generate(): KeyPair {
        val pair = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
        return KeyPair(pair.private as ECPrivateKey, pair.public as ECPublicKey)
    }

    /** 由私钥标量得到密钥对（测试向量用）：公钥 = d·G。 */
    fun fromScalar(d: ByteArray): KeyPair {
        val factory = KeyFactory.getInstance("EC")
        val privateKey = factory.generatePrivate(ECPrivateKeySpec(BigInteger(1, d), params)) as ECPrivateKey
        val point = multiply(params.generator, BigInteger(1, d))
        val publicKey = factory.generatePublic(ECPublicKeySpec(point, params)) as ECPublicKey
        return KeyPair(privateKey, publicKey)
    }

    fun shared(own: KeyPair, peer: String): ByteArray {
        val raw = Base64Url.decode(peer)
        require(raw.size == 65 && raw[0] == 4.toByte()) { "bad public key" }
        val point = ECPoint(BigInteger(1, raw.copyOfRange(1, 33)), BigInteger(1, raw.copyOfRange(33, 65)))
        val publicKey = KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(point, params))
        return KeyAgreement.getInstance("ECDH").run { init(own.privateKey); doPhase(publicKey, true); generateSecret() }
    }

    fun transcript(code: String, initiator: String, joiner: String): ByteArray =
        MessageDigest.getInstance("SHA-256").digest("riji-pair|v1|$code|$initiator|$joiner".toByteArray(Charsets.UTF_8))

    /** → 配对密钥与 6 位比对码 */
    fun keys(shared: ByteArray, transcript: ByteArray): Pair<ByteArray, String> {
        val key = RijiCrypto.hkdf(shared, transcript, "functionhx:riji:pair:key:v1")
        val sas = RijiCrypto.hkdf(shared, transcript, "functionhx:riji:pair:sas:v1", 4)
        val number = ((sas[0].toLong() and 0xFF) shl 24) or ((sas[1].toLong() and 0xFF) shl 16) or
            ((sas[2].toLong() and 0xFF) shl 8) or (sas[3].toLong() and 0xFF)
        return key to (number % 1_000_000).toString().padStart(6, '0')
    }

    private fun aad(code: String) = "riji-pair|v1|$code".toByteArray(Charsets.UTF_8)

    fun seal(key: ByteArray, code: String, payload: JsonValue, nonce: ByteArray = RijiCrypto.randomNonce()): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        cipher.updateAAD(aad(code))
        return Base64Url.encode(nonce + cipher.doFinal(payload.canonicalBytes()))
    }

    fun open(key: ByteArray, code: String, sealed: String): JsonValue {
        val raw = runCatching { Base64Url.decode(sealed) }.getOrNull()?.takeIf { it.size > 28 } ?: throw BadEnvelope()
        val plain = try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, raw, 0, 12))
            cipher.updateAAD(aad(code))
            cipher.doFinal(raw, 12, raw.size - 12)
        } catch (e: javax.crypto.AEADBadTagException) {
            throw BadEnvelope()
        }
        return JsonValue.parse(plain)
    }

    private fun x963(key: ECPublicKey): ByteArray {
        fun fixed(n: BigInteger) = n.toByteArray().let { if (it.size > 32) it.copyOfRange(it.size - 32, it.size) else ByteArray(32 - it.size) + it }
        return byteArrayOf(4) + fixed(key.w.affineX) + fixed(key.w.affineY)
    }

    // 只在测试向量里用到的标量乘法（仿射坐标，双倍加）
    private fun multiply(point: ECPoint, k: BigInteger): ECPoint {
        var result: ECPoint = ECPoint.POINT_INFINITY
        var addend = point
        var n = k
        while (n.signum() > 0) {
            if (n.testBit(0)) result = add(result, addend)
            addend = add(addend, addend)
            n = n.shiftRight(1)
        }
        return result
    }

    private fun add(p: ECPoint, q: ECPoint): ECPoint {
        if (p == ECPoint.POINT_INFINITY) return q
        if (q == ECPoint.POINT_INFINITY) return p
        val field = (params.curve.field as java.security.spec.ECFieldFp).p
        val a = params.curve.a
        val lambda = if (p == q) {
            p.affineX.pow(2).multiply(BigInteger.valueOf(3)).add(a).multiply(p.affineY.shiftLeft(1).modInverse(field))
        } else {
            if (p.affineX == q.affineX) return ECPoint.POINT_INFINITY
            q.affineY.subtract(p.affineY).multiply(q.affineX.subtract(p.affineX).modInverse(field))
        }.mod(field)
        val x = lambda.pow(2).subtract(p.affineX).subtract(q.affineX).mod(field)
        val y = lambda.multiply(p.affineX.subtract(x)).subtract(p.affineY).mod(field)
        return ECPoint(x, y)
    }
}
