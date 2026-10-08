package com.functionhx.riji.core

import java.io.File
import java.io.FileOutputStream
import java.security.SecureRandom
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.temporal.ChronoUnit

// 跨平台块格式 v1（docs/DESIGN.md §6）与本机存储。与 Swift 的 RijiKit/Model、Store 对应。

object RecordType {
    const val NOTE = "note"
    const val DAY = "day"
    const val BLOCK = "block"
    const val PROGRESS = "progress"
}

private fun JsonValue?.textRuns(): List<JsonValue> = this?.array ?: emptyList()
private fun plainOf(runs: List<JsonValue>): String = runs.joinToString("") { it["text"]?.string ?: "" }
private fun runsOf(plain: String): JsonValue = JsonValue.Arr(if (plain.isEmpty()) emptyList() else listOf(JsonValue.obj("text" to JsonValue.str(plain))))

data class Day(val date: String, val timeZone: String, val noteId: String, val summary: String = "") {
    fun json(): JsonValue = JsonValue.obj(
        "date" to JsonValue.str(date), "tz" to JsonValue.str(timeZone), "note_id" to JsonValue.str(noteId), "summary" to JsonValue.str(summary),
    )

    companion object {
        fun from(json: JsonValue): Day? {
            val date = json["date"]?.string ?: return null
            val noteId = json["note_id"]?.string ?: return null
            return Day(date, json["tz"]?.string ?: DayClock.DEFAULT_ZONE, noteId, json["summary"]?.string ?: "")
        }
    }
}

enum class BlockKind(val wire: String) { SECTION("section"), PARAGRAPH("paragraph"), LIST("list"), CHECK("check"), SPARK("spark"), DIVIDER("divider"), IMAGE("image");
    companion object { fun of(wire: String?) = entries.firstOrNull { it.wire == wire } }
}

enum class SectionRole(val wire: String) { TODO("todo"), SPARK("spark"), NOTES("notes");
    companion object { fun of(wire: String?) = entries.firstOrNull { it.wire == wire } }
}

data class Block(
    val id: String,
    val noteId: String,
    val parentId: String?,
    val order: String,
    val kind: BlockKind,
    val attrs: Map<String, JsonValue> = emptyMap(),
    val text: String = "",
    val textRuns: List<JsonValue> = emptyList(),
    val createdAt: String,
) {
    val checked: Boolean get() = attrs["checked"]?.bool ?: false
    val role: SectionRole? get() = SectionRole.of(attrs["role"]?.string)
    val carryFrom: String? get() = attrs["carry_from"]?.string
    val carriedTo: String? get() = attrs["carried_to"]?.string
    val carriedDays: Int get() = attrs["carried_days"]?.int ?: 0
    val progressId: String? get() = attrs["progress_id"]?.string
    val color: String get() = attrs["color"]?.string ?: "yellow"

    fun withText(plain: String) = copy(text = plain, textRuns = runsOf(plain).array!!)
    fun withAttr(key: String, value: JsonValue?) = copy(attrs = if (value == null) attrs - key else attrs + (key to value))

    fun json(): JsonValue {
        val fields = linkedMapOf<String, JsonValue>(
            "id" to JsonValue.str(id), "note_id" to JsonValue.str(noteId), "order" to JsonValue.str(order), "type" to JsonValue.str(kind.wire),
            "attrs" to JsonValue.Obj(attrs), "text" to JsonValue.Arr(textRuns), "created_at" to JsonValue.str(createdAt),
        )
        if (parentId != null) fields["parent_id"] = JsonValue.str(parentId)
        return JsonValue.Obj(fields)
    }

    companion object {
        fun create(id: String, noteId: String, parentId: String?, order: String, kind: BlockKind, attrs: Map<String, JsonValue>, text: String, createdAt: String) =
            Block(id, noteId, parentId, order, kind, attrs, text, runsOf(text).array!!, createdAt)

        fun from(json: JsonValue): Block? {
            val id = json["id"]?.string ?: return null
            val noteId = json["note_id"]?.string ?: return null
            val kind = BlockKind.of(json["type"]?.string) ?: return null
            val runs = json["text"].textRuns()
            return Block(id, noteId, json["parent_id"]?.string, json["order"]?.string ?: "a0", kind, json["attrs"]?.obj ?: emptyMap(),
                plainOf(runs), runs, json["created_at"]?.string ?: "")
        }
    }
}

data class ProgressItem(
    val id: String, val name: String, val unit: String, val current: Int, val target: Int? = null,
    val isPublic: Boolean = false, val updatedDay: String? = null, val archived: Boolean = false,
) {
    val fraction: Double? get() = target?.takeIf { it > 0 }?.let { minOf(1.0, current.toDouble() / it) }

    fun json(): JsonValue {
        val fields = linkedMapOf<String, JsonValue>(
            "id" to JsonValue.str(id), "name" to JsonValue.str(name), "unit" to JsonValue.str(unit), "current" to JsonValue.num(current),
            "public" to JsonValue.Bool(isPublic), "archived" to JsonValue.Bool(archived),
        )
        if (target != null) fields["target"] = JsonValue.num(target)
        if (updatedDay != null) fields["updated_day"] = JsonValue.str(updatedDay)
        return JsonValue.Obj(fields)
    }

    companion object {
        fun from(json: JsonValue): ProgressItem? {
            val id = json["id"]?.string ?: return null
            val name = json["name"]?.string ?: return null
            return ProgressItem(id, name, json["unit"]?.string ?: "", json["current"]?.int ?: 0, json["target"]?.int,
                json["public"]?.bool ?: false, json["updated_day"]?.string, json["archived"]?.bool ?: false)
        }
    }
}

/** 记录 id：时间有序（UUIDv7 风格）。 */
object RecordId {
    private val random = SecureRandom()
    fun make(nowMs: Long = System.currentTimeMillis()): String {
        val bytes = ByteArray(16)
        random.nextBytes(bytes)
        for (i in 0 until 6) bytes[i] = ((nowMs shr (8 * (5 - i))) and 0xFF).toByte()
        bytes[6] = ((bytes[6].toInt() and 0x0F) or 0x70).toByte()
        bytes[8] = ((bytes[8].toInt() and 0x3F) or 0x80).toByte()
        val hex = bytes.toHex()
        return "${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}"
    }
}

/** 分数索引：在两个顺序键之间生成一个新键（base-36 小写，字典序即顺序）。与 Swift 的 OrderKey 相同。 */
object OrderKey {
    private const val DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"

    fun between(a: String?, b: String?): String {
        val low = a ?: ""
        val high = b ?: ""
        val result = StringBuilder()
        var i = 0
        while (true) {
            val lowDigit = if (i < low.length) DIGITS.indexOf(low[i]).coerceAtLeast(0) else 0
            val highDigit = if (i < high.length) DIGITS.indexOf(high[i]).coerceAtLeast(0) else DIGITS.length
            if (highDigit - lowDigit > 1) return result.append(DIGITS[(lowDigit + highDigit) / 2]).toString()
            result.append(DIGITS[lowDigit])
            i++
            if (i > 64) return result.append('i').toString()
        }
    }

    fun after(a: String?) = between(a, null)
}

/** 线程安全的本机时钟。 */
class HlcClock(val device: String, private var last: Hlc? = null, private val wall: () -> Long = System::currentTimeMillis) {
    @Synchronized fun now(): Hlc = Hlc.tick(last, wall(), device).also { last = it }
    @Synchronized fun observe(remote: Hlc) { last = Hlc.receive(last, remote, wall(), device) }
}

/** 本机变更日志：每次修改追加一行规范 JSON，启动时按 HLC 合并。 */
class ChangeLog(val file: File) {
    init { file.parentFile?.mkdirs(); if (!file.exists()) file.createNewFile() }

    @Synchronized fun readAll(): List<Change> = file.readLines(Charsets.UTF_8).mapNotNull { line ->
        if (line.isBlank()) return@mapNotNull null
        runCatching { Change.from(JsonValue.parse(line)) }.getOrElse { if (!line.endsWith("}")) null else throw IllegalStateException("corrupt change log") }
    }

    @Synchronized fun append(changes: List<Change>) {
        if (changes.isEmpty()) return
        FileOutputStream(file, true).use { out ->
            for (change in changes) { out.write(change.json().canonicalBytes()); out.write('\n'.code) }
            out.fd.sync()
        }
    }
}

/** 合并后的全部记录 + 写入接口。 */
class RecordStore(private val log: ChangeLog?, device: String, wall: () -> Long = System::currentTimeMillis) {
    private val state = mutableMapOf<String, RecordState>()
    private val byType = mutableMapOf<String, MutableMap<String, RecordState>>()
    val clock: HlcClock
    var revision = 0
        private set

    init {
        val changes = log?.readAll() ?: emptyList()
        Merge.apply(changes, state)
        for ((key, record) in state) byType.getOrPut(key.substringBefore(':')) { mutableMapOf() }[key.substringAfter(':')] = record
        clock = HlcClock(device, changes.maxOfOrNull { it.hlc }, wall)
    }

    val size: Int @Synchronized get() = state.size

    @Synchronized fun value(type: String, id: String): JsonValue? = state["$type:$id"]?.takeIf { !it.deleted }?.value
    @Synchronized fun values(type: String): List<JsonValue> = byType[type]?.values?.mapNotNull { if (it.deleted) null else it.value } ?: emptyList()

    @Synchronized fun write(edits: List<Triple<String, String, JsonValue?>>): List<Change> {
        val changes = edits.map { (type, id, value) -> Change(type, id, clock.now(), value == null, value) }
        log?.append(changes)
        Merge.apply(changes, state)
        index(changes)
        return changes
    }

    @Synchronized fun absorb(changes: List<Change>) {
        Merge.apply(changes, state)
        index(changes)
        changes.maxOfOrNull { it.hlc }?.let(clock::observe)
    }

    private fun index(changes: List<Change>) {
        for (change in changes) state[change.key]?.let { byType.getOrPut(change.type) { mutableMapOf() }[change.id] = it }
        revision++
    }
}

/** 按发布时区（默认北京时间）计算「今天」。 */
class DayClock(zoneId: String = DEFAULT_ZONE) {
    val zone: ZoneId = runCatching { ZoneId.of(zoneId) }.getOrDefault(ZoneId.of("UTC+8"))

    fun key(instant: Instant): String = instant.atZone(zone).toLocalDate().toString()
    fun daysBetween(from: String, to: String): Int = ChronoUnit.DAYS.between(LocalDate.parse(from), LocalDate.parse(to)).toInt()
    fun adding(days: Int, key: String): String = LocalDate.parse(key).plusDays(days.toLong()).toString()
    fun title(key: String): String = LocalDate.parse(key).let { "${it.monthValue} 月 ${it.dayOfMonth} 日" }
    fun weekday(key: String): String = WEEKDAYS[LocalDate.parse(key).dayOfWeek.value % 7]

    fun dayProgress(now: Instant): Double {
        val zoned = now.atZone(zone)
        val start = zoned.toLocalDate().atStartOfDay(zone).plusHours(6)
        return ((now.epochSecond - start.toEpochSecond()) / (18.0 * 3600)).coerceIn(0.0, 1.0)
    }

    fun minutesLeft(now: Instant): Int {
        val end: ZonedDateTime = now.atZone(zone).toLocalDate().plusDays(1).atStartOfDay(zone)
        return maxOf(0, ((end.toEpochSecond() - now.epochSecond) / 60).toInt())
    }

    companion object {
        const val DEFAULT_ZONE = "Asia/Shanghai"
        private val WEEKDAYS = listOf("星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六")
    }
}
