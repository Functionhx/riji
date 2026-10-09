package com.functionhx.riji.core

import java.io.File
import java.io.FileOutputStream
import java.security.SecureRandom
import java.time.Instant

// 同步一轮（docs/DESIGN.md §8.3），与 Swift 的 SyncEngine 相同：封装本机新变更 → 推给副本 → 拉回其他设备的新段，
// 校验序号与哈希链、解密、按 HLC 合并。副本（腾讯云 riji-server）只存密文段。

data class SegmentHead(val seq: Int, val hash: String) {
    fun json(): JsonValue = JsonValue.obj("seq" to JsonValue.num(seq), "hash" to JsonValue.str(hash))

    companion object {
        val EMPTY = SegmentHead(0, RijiCrypto.GENESIS_PREV)
        fun from(json: JsonValue?) = json?.let { SegmentHead(it["seq"]?.int ?: 0, it["hash"]?.string ?: RijiCrypto.GENESIS_PREV) } ?: EMPTY
    }
}

/** 副本的访问方式（阻塞调用；应用里在 IO 线程上跑）。 */
interface SyncTransport {
    fun heads(): Map<String, SegmentHead>
    fun fetch(device: String, from: Int, limit: Int): List<Segment>
    fun push(segments: List<Segment>)
}

/** 同步用的密钥：第一台设备随机生成，配对时封装给新设备；服务器永远看不到。 */
data class SyncKey(val key: ByteArray, val epoch: Int = 0) {
    fun json(): JsonValue = JsonValue.obj("key" to JsonValue.str(Base64Url.encode(key)), "epoch" to JsonValue.num(epoch))

    companion object {
        fun generate() = SyncKey(ByteArray(32).also(SecureRandom()::nextBytes))
        fun from(json: JsonValue?): SyncKey? {
            val text = json?.get("key")?.string ?: return null
            val key = runCatching { Base64Url.decode(text) }.getOrNull()?.takeIf { it.size == 32 } ?: return null
            return SyncKey(key, json["epoch"]?.int ?: 0)
        }
    }

    override fun equals(other: Any?) = other is SyncKey && key.contentEquals(other.key) && epoch == other.epoch
    override fun hashCode() = key.contentHashCode() * 31 + epoch
}

data class SyncReport(
    val sealed: Int = 0, val pushed: Int = 0, val pulled: Int = 0, val absorbed: Int = 0,
    val problems: List<String> = emptyList(), val devices: Int = 0,
)

class OwnLogAheadException(server: Int, local: Int) : Exception("server has $server own segments, local has $local")

/** 同步引擎。文件都在 folder 里：sync-state.json（进度）、own-segments.jsonl（本设备的段）。 */
class SyncEngine(private val store: RecordStore, private val key: SyncKey, private val transport: SyncTransport, folder: File) {
    val device: String = store.clock.device
    private val stateFile = File(folder, "sync-state.json")
    private val ownFile = File(folder, "own-segments.jsonl")
    var sealed = 0; private set
    var own = SegmentHead.EMPTY; private set
    val vector = mutableMapOf<String, SegmentHead>()
    var lastSync: Instant? = null; private set

    init {
        folder.mkdirs()
        if (stateFile.exists()) {
            val json = JsonValue.parse(stateFile.readText())
            sealed = json["sealed"]?.int ?: 0
            own = SegmentHead.from(json["own"])
            json["vector"]?.obj?.forEach { (device, head) -> vector[device] = SegmentHead.from(head) }
            lastSync = json["last_sync"]?.string?.let(Instant::parse)
        }
    }

    @Synchronized
    fun sync(): SyncReport {
        val sealedCount = sealPending()
        val heads = transport.heads()
        val pushed = pushOwn(heads[device] ?: SegmentHead.EMPTY)
        var pulled = 0
        var absorbed = 0
        val problems = mutableListOf<String>()
        for ((other, head) in heads.toSortedMap()) {
            if (other == device) continue
            val (segments, changes, problem) = pull(other, head)
            pulled += segments
            absorbed += changes
            problem?.let(problems::add)
        }
        lastSync = Instant.now()
        saveState()
        return SyncReport(sealedCount, pushed, pulled, absorbed, problems, (heads.keys + device).size)
    }

    // ---------------------------------------------------------------- 封装

    fun sealPending(): Int {
        val log = store.log ?: return 0
        val all = log.readAll()
        if (all.size <= sealed) return 0
        var count = 0
        for (chunk in all.drop(sealed).chunked(CHANGES_PER_SEGMENT)) {
            val segment = Segment.seal(key.key, device, own.seq + 1, own.hash, key.epoch, chunk)
            FileOutputStream(ownFile, true).use { out -> out.write(segment.json().canonicalBytes()); out.write('\n'.code); out.fd.sync() }
            own = SegmentHead(segment.seq, segment.chainHash)
            sealed += chunk.size
            saveState()
            count++
        }
        return count
    }

    fun ownSegments(after: Int): List<Segment> =
        if (!ownFile.exists()) emptyList()
        else ownFile.readLines().filter { it.isNotBlank() }.map { Segment.from(JsonValue.parse(it)) }.filter { it.seq > after }.sortedBy { it.seq }

    // ---------------------------------------------------------------- 推送 / 拉取

    private fun pushOwn(serverHead: SegmentHead): Int {
        if (serverHead.seq > own.seq) throw OwnLogAheadException(serverHead.seq, own.seq)
        val missing = ownSegments(serverHead.seq)
        missing.chunked(50).forEach(transport::push)
        return missing.size
    }

    private fun pull(other: String, head: SegmentHead): Triple<Int, Int, String?> {
        var known = vector[other] ?: SegmentHead.EMPTY
        if (head.seq <= known.seq) return Triple(0, 0, null)
        var segments = 0
        var absorbed = 0
        while (known.seq < head.seq) {
            val page = transport.fetch(other, known.seq + 1, 200)
            if (page.isEmpty()) break
            val changes = mutableListOf<Change>()
            var problem: String? = null
            for (segment in page.sortedBy { it.seq }) {
                if (segment.device != other || segment.seq != known.seq + 1) { problem = "$other：缺第 ${known.seq + 1} 段"; break }
                if (segment.prev != known.hash) { problem = "$other：第 ${segment.seq} 段的哈希链对不上"; break }
                val opened = runCatching { segment.open(key.key) }.getOrNull()
                if (opened == null) { problem = "$other：第 ${segment.seq} 段解不开（密钥不对或被篡改）"; break }
                changes += opened
                known = SegmentHead(segment.seq, segment.chainHash)
                segments++
            }
            if (changes.isNotEmpty()) { store.absorb(changes); absorbed += changes.size }
            vector[other] = known
            saveState()
            if (problem != null) return Triple(segments, absorbed, problem)
        }
        return Triple(segments, absorbed, null)
    }

    private fun saveState() {
        val json = JsonValue.obj(
            "sealed" to JsonValue.num(sealed), "own" to own.json(),
            "vector" to JsonValue.Obj(vector.mapValues { it.value.json() }),
            "last_sync" to (lastSync?.let { JsonValue.str(it.toString()) } ?: JsonValue.Null),
        )
        val tmp = File(stateFile.path + ".tmp")
        tmp.writeBytes(json.canonicalBytes())
        tmp.renameTo(stateFile)
    }

    companion object { const val CHANGES_PER_SEGMENT = 400 }
}
