package com.functionhx.riji.core

import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

// 日迹同步协议 v1：HLC、密钥派生、日志段封装与校验、合并。
// 与 spec/reference/riji.mjs 及 Swift 的 RijiKit 逐字节一致，由 spec/test-vectors/ 检验。

/** 混合逻辑时钟：`1759889000000.0000.mac-1`。固定宽度，字符串字典序就是时钟顺序。 */
data class Hlc(val ms: Long, val counter: Int, val device: String) : Comparable<Hlc> {
    init {
        require(ms in 0..9_999_999_999_999L) { "hlc ms out of range" }
        require(counter in 0..0xFFFF) { "hlc counter out of range" }
        require(DEVICE.matches(device)) { "hlc device id must match [a-z0-9-]{1,36}" }
    }

    override fun toString(): String = ms.toString().padStart(13, '0') + "." + counter.toString(16).padStart(4, '0') + "." + device

    override fun compareTo(other: Hlc): Int = toString().compareTo(other.toString())

    companion object {
        private val DEVICE = Regex("^[a-z0-9-]{1,36}$")
        private val TEXT = Regex("^(\\d{13})\\.([0-9a-f]{4})\\.([a-z0-9-]{1,36})$")

        fun parse(text: String): Hlc {
            val match = TEXT.matchEntire(text) ?: throw IllegalArgumentException("invalid hlc $text")
            return Hlc(match.groupValues[1].toLong(), match.groupValues[2].toInt(16), match.groupValues[3])
        }

        /** 本地事件：max(墙钟, 上次)；同一毫秒计数 +1。 */
        fun tick(last: Hlc?, wallMs: Long, device: String): Hlc {
            val previousMs = last?.ms ?: 0
            return if (wallMs > previousMs) Hlc(wallMs, 0, device) else Hlc(previousMs, (last?.counter ?: 0) + 1, device)
        }

        /** 收到远端时钟：新时钟晚于本地上次与远端两者。 */
        fun receive(last: Hlc?, remote: Hlc, wallMs: Long, device: String): Hlc {
            val localMs = last?.ms ?: 0
            val localCounter = last?.counter ?: 0
            val ms = maxOf(wallMs, localMs, remote.ms)
            val counter = when {
                ms == localMs && ms == remote.ms -> maxOf(localCounter, remote.counter) + 1
                ms == localMs -> localCounter + 1
                ms == remote.ms -> remote.counter + 1
                else -> 0
            }
            return Hlc(ms, counter, device)
        }
    }
}

object RijiCrypto {
    val GENESIS_PREV: String = "0".repeat(64)
    private val random = SecureRandom()

    fun hkdf(ikm: ByteArray, salt: ByteArray, info: String, length: Int = 32): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(if (salt.isEmpty()) ByteArray(32) else salt, "HmacSHA256"))
        val prk = mac.doFinal(ikm)
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        val out = java.io.ByteArrayOutputStream()
        var block = ByteArray(0)
        var counter = 1
        while (out.size() < length) {
            mac.update(block)
            mac.update(info.toByteArray(Charsets.UTF_8))
            mac.update(counter.toByte())
            block = mac.doFinal()
            out.write(block)
            counter++
        }
        return out.toByteArray().copyOf(length)
    }

    /** 网站保险库根密钥 R → 日迹密钥 K_riji（每个 epoch 一把）。 */
    fun deriveRijiKey(root: ByteArray, rijiSalt: ByteArray, epoch: Int): ByteArray =
        hkdf(root, rijiSalt, "functionhx:riji:v1:epoch=$epoch")

    /** K_riji → 某台设备某一段的密钥（确定性派生，每段只加密一次）。 */
    fun deriveSegmentKey(rijiKey: ByteArray, device: String, seq: Int): ByteArray =
        hkdf(rijiKey, ByteArray(32), "functionhx:riji:segment:v1|$device|$seq")

    fun sha256Hex(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).toHex()

    fun randomNonce(): ByteArray = ByteArray(12).also(random::nextBytes)
}

fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
fun String.hexToBytes(): ByteArray = chunked(2).map { it.toInt(16).toByte() }.toByteArray()

object Base64Url {
    fun encode(bytes: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    fun decode(text: String): ByteArray = Base64.getUrlDecoder().decode(text)
}

/** 一条变更：某条记录在某个时刻的完整新值，或者删除。 */
data class Change(val type: String, val id: String, val hlc: Hlc, val deleted: Boolean = false, val value: JsonValue? = null) {
    val key: String get() = "$type:$id"

    fun json(): JsonValue {
        val fields = linkedMapOf<String, JsonValue>("type" to JsonValue.Str(type), "id" to JsonValue.Str(id), "hlc" to JsonValue.Str(hlc.toString()))
        if (deleted) fields["deleted"] = JsonValue.Bool(true) else if (value != null) fields["value"] = value
        return JsonValue.Obj(fields)
    }

    companion object {
        fun from(json: JsonValue): Change = Change(
            type = json["type"]?.string ?: error("malformed change"),
            id = json["id"]?.string ?: error("malformed change"),
            hlc = Hlc.parse(json["hlc"]?.string ?: error("malformed change")),
            deleted = json["deleted"]?.bool ?: false,
            value = if (json["deleted"]?.bool == true) null else json["value"],
        )

        fun sorted(changes: List<Change>): List<Change> =
            changes.sortedWith(compareBy<Change>({ it.type }, { it.id }, { it.hlc.toString() }))
    }
}

class SegmentAuthenticationException : Exception("segment failed authentication")

/** 一段加密日志。服务端只看得到这些头部字段与密文。 */
data class Segment(val v: Int, val device: String, val seq: Int, val prev: String, val epoch: Int, val hlcMax: String, val ct: String) {
    val name: String get() = "$device#$seq"

    private val aad: ByteArray get() = "riji-segment|v$v|$device|$seq|$prev|$epoch".toByteArray(Charsets.UTF_8)

    /** 下一段的 prev：本段完整密文字节（含 nonce）的 SHA-256。 */
    val chainHash: String get() = RijiCrypto.sha256Hex(Base64Url.decode(ct))

    fun open(rijiKey: ByteArray): List<Change> {
        val raw = Base64Url.decode(ct)
        if (raw.size <= 28) throw SegmentAuthenticationException()
        val plain = try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(RijiCrypto.deriveSegmentKey(rijiKey, device, seq), "AES"), GCMParameterSpec(128, raw, 0, 12))
            cipher.updateAAD(aad)
            cipher.doFinal(raw, 12, raw.size - 12)
        } catch (error: javax.crypto.AEADBadTagException) {
            throw SegmentAuthenticationException()
        }
        val changes = JsonValue.parse(plain)["changes"]?.array ?: error("segment body has no changes")
        return changes.map(Change::from)
    }

    fun json(): JsonValue = JsonValue.obj(
        "v" to JsonValue.num(v), "device" to JsonValue.str(device), "seq" to JsonValue.num(seq), "prev" to JsonValue.str(prev),
        "epoch" to JsonValue.num(epoch), "hlc_max" to JsonValue.str(hlcMax), "ct" to JsonValue.str(ct),
    )

    companion object {
        fun from(json: JsonValue) = Segment(
            v = json["v"]!!.int!!, device = json["device"]!!.string!!, seq = json["seq"]!!.int!!, prev = json["prev"]!!.string!!,
            epoch = json["epoch"]!!.int!!, hlcMax = json["hlc_max"]!!.string!!, ct = json["ct"]!!.string!!,
        )

        fun seal(rijiKey: ByteArray, device: String, seq: Int, prev: String, epoch: Int, changes: List<Change>, nonce: ByteArray = RijiCrypto.randomNonce()): Segment {
            require(seq >= 1) { "seq starts at 1" }
            require(Regex("^[0-9a-f]{64}$").matches(prev)) { "prev must be 64 hex chars" }
            require(seq != 1 || prev == RijiCrypto.GENESIS_PREV) { "the first segment must point at the genesis prev" }
            val sorted = Change.sorted(changes)
            val plaintext = JsonValue.obj("changes" to JsonValue.Arr(sorted.map { it.json() })).canonicalBytes()
            val header = Segment(1, device, seq, prev, epoch, "", "")
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(RijiCrypto.deriveSegmentKey(rijiKey, device, seq), "AES"), GCMParameterSpec(128, nonce))
            cipher.updateAAD(header.aad)
            val sealed = cipher.doFinal(plaintext)
            return header.copy(ct = Base64Url.encode(nonce + sealed), hlcMax = sorted.maxOfOrNull { it.hlc }?.toString() ?: "")
        }
    }
}

sealed interface ChainProblem {
    data class Gap(val missing: Int) : ChainProblem
    data class BrokenChain(val seq: Int) : ChainProblem
    data class Fork(val seq: Int) : ChainProblem

    fun json(): JsonValue = when (this) {
        is Gap -> JsonValue.obj("code" to JsonValue.str("gap"), "missing" to JsonValue.num(missing))
        is BrokenChain -> JsonValue.obj("code" to JsonValue.str("broken_chain"), "seq" to JsonValue.num(seq))
        is Fork -> JsonValue.obj("code" to JsonValue.str("fork"), "seq" to JsonValue.num(seq))
    }
}

object Chain {
    /** 一台设备的段：序号从 1 连续、prev 吻合；重复段忽略。返回可接受的最长前缀与问题。 */
    fun verify(segments: List<Segment>): Pair<List<Segment>, List<ChainProblem>> {
        val ordered = segments.withIndex().sortedWith(compareBy({ it.value.seq }, { it.index })).map { it.value }
        val accepted = mutableListOf<Segment>()
        val problems = mutableListOf<ChainProblem>()
        var expectedSeq = 1
        var expectedPrev = RijiCrypto.GENESIS_PREV
        for (segment in ordered) {
            if (segment.seq < expectedSeq) {
                if (accepted.any { it.seq == segment.seq && it.ct == segment.ct }) continue
                problems += ChainProblem.Fork(segment.seq); break
            }
            if (segment.seq > expectedSeq) { problems += ChainProblem.Gap(expectedSeq); break }
            if (segment.prev != expectedPrev) { problems += ChainProblem.BrokenChain(segment.seq); break }
            accepted += segment
            expectedSeq++
            expectedPrev = segment.chainHash
        }
        return accepted to problems
    }
}

data class RecordState(val hlc: Hlc, val deleted: Boolean, val value: JsonValue?) {
    fun json(): JsonValue = if (deleted) {
        JsonValue.obj("hlc" to JsonValue.str(hlc.toString()), "deleted" to JsonValue.Bool(true))
    } else {
        JsonValue.obj("hlc" to JsonValue.str(hlc.toString()), "value" to (value ?: JsonValue.Null))
    }
}

data class Materialized(val state: Map<String, RecordState>, val vector: Map<String, Int>, val problems: Map<String, List<ChainProblem>>) {
    fun stateJson(): JsonValue = JsonValue.Obj(state.mapValues { it.value.json() })
    fun digest(): String = RijiCrypto.sha256Hex(stateJson().canonicalBytes())
}

object Merge {
    /** 同一 (type, id) 取 HLC 最大者；与到达顺序无关。 */
    fun apply(changes: List<Change>, state: MutableMap<String, RecordState>) {
        for (change in changes) {
            val current = state[change.key]
            if (current != null && change.hlc <= current.hlc) continue
            state[change.key] = RecordState(change.hlc, change.deleted, if (change.deleted) null else change.value)
        }
    }

    /** 一组段（可能来自多个副本、乱序、重复）→ 状态。 */
    fun materialize(rijiKey: ByteArray, segments: List<Segment>): Materialized {
        val byDevice = segments.groupBy { it.device }
        val state = mutableMapOf<String, RecordState>()
        val vector = mutableMapOf<String, Int>()
        val problems = mutableMapOf<String, List<ChainProblem>>()
        for (device in byDevice.keys.sorted()) {
            val (accepted, found) = Chain.verify(byDevice.getValue(device))
            if (found.isNotEmpty()) problems[device] = found
            vector[device] = accepted.size
            for (segment in accepted) apply(segment.open(rijiKey), state)
        }
        return Materialized(state, vector, problems)
    }
}
