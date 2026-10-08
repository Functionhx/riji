package com.functionhx.riji.core

import java.time.Instant

/** 识别「电路 18 讲」「马原 第 6 章」「英语单词 26 天」这类长期进度。与 Swift 的 ProgressParser 相同。 */
object ProgressParser {
    data class Match(val name: String, val value: Int, val unit: String)

    private val units = listOf("讲", "章", "节", "课", "集", "页", "题", "篇", "天", "周", "次", "单元", "小时", "关")
    // 名字必须以非数字结尾，否则「18 讲」会被拆成「1」和 8。
    private val pattern = Regex("^(.*?\\D)\\s*第?\\s*(\\d{1,5})\\s*(${units.joinToString("|")})$")

    fun parse(text: String): Match? {
        val match = pattern.matchEntire(text.trim()) ?: return null
        val name = match.groupValues[1].trim()
        if (name.isEmpty() || name.length > 24) return null
        return Match(name, match.groupValues[2].toInt(), match.groupValues[3])
    }
}

data class DayStats(val total: Int, val done: Int, val carried: Int, val sparks: Int, val hasContent: Boolean)

/** 每日层的全部规则。与 Swift 的 DailyBook 一一对应（同样的增量缓存）。 */
class DailyBook(val store: RecordStore, val clock: DayClock = DayClock()) {
    private val lock = Any()
    private var cachedRevision = -1
    private var cachedDays: List<Day> = emptyList()
    private var cachedDayByDate: MutableMap<String, Day> = mutableMapOf()
    private var cachedBlocksByNote: MutableMap<String, MutableList<Block>> = mutableMapOf()
    private var cachedBlockById: MutableMap<String, Block> = mutableMapOf()
    private var cachedProgresses: MutableList<ProgressItem> = mutableListOf()

    private fun <T> withCache(read: () -> T): T = synchronized(lock) {
        if (cachedRevision != store.revision) {
            cachedDays = store.values(RecordType.DAY).mapNotNull(Day::from).sortedByDescending { it.date }
            cachedDayByDate = cachedDays.associateBy { it.date }.toMutableMap()
            val blocks = store.values(RecordType.BLOCK).mapNotNull(Block::from)
            cachedBlockById = blocks.associateBy { it.id }.toMutableMap()
            cachedBlocksByNote = blocks.groupBy { it.noteId }.mapValues { it.value.toMutableList() }.toMutableMap()
            cachedProgresses = store.values(RecordType.PROGRESS).mapNotNull(ProgressItem::from).toMutableList()
            cachedRevision = store.revision
        }
        read()
    }

    private fun commit(edits: List<Triple<String, String, JsonValue?>>): List<Change> {
        val wasFresh = synchronized(lock) { cachedRevision == store.revision }
        val changes = store.write(edits)
        if (!wasFresh) return changes
        synchronized(lock) {
            var daysChanged = false
            for (change in changes) when (change.type) {
                RecordType.DAY -> {
                    val day = if (change.deleted) null else change.value?.let(Day::from)
                    if (day == null) cachedDayByDate.remove(change.id) else cachedDayByDate[change.id] = day
                    daysChanged = true
                }
                RecordType.BLOCK -> {
                    cachedBlockById[change.id]?.let { old -> cachedBlocksByNote[old.noteId]?.removeAll { it.id == change.id } }
                    val block = if (change.deleted) null else change.value?.let(Block::from)
                    if (block == null) cachedBlockById.remove(change.id) else {
                        cachedBlockById[change.id] = block
                        cachedBlocksByNote.getOrPut(block.noteId) { mutableListOf() }.add(block)
                    }
                }
                RecordType.PROGRESS -> {
                    cachedProgresses.removeAll { it.id == change.id }
                    if (!change.deleted) change.value?.let(ProgressItem::from)?.let(cachedProgresses::add)
                }
            }
            if (daysChanged) cachedDays = cachedDayByDate.values.sortedByDescending { it.date }
            cachedRevision = store.revision
        }
        return changes
    }

    // ---------------------------------------------------------------- 读取

    val days: List<Day> get() = withCache { cachedDays }
    fun day(date: String): Day? = withCache { cachedDayByDate[date] }
    fun blocks(noteId: String): List<Block> = withCache { cachedBlocksByNote[noteId]?.toList() ?: emptyList() }
    fun block(id: String): Block? = withCache { cachedBlockById[id] }
    fun section(role: SectionRole, day: Day): Block? = blocks(day.noteId).firstOrNull { it.kind == BlockKind.SECTION && it.role == role }
    fun children(section: Block): List<Block> =
        blocks(section.noteId).filter { it.parentId == section.id }.sortedWith(compareBy({ it.order }, { it.id }))

    fun items(role: SectionRole, date: String): List<Block> {
        val day = day(date) ?: return emptyList()
        val section = section(role, day) ?: return emptyList()
        return children(section)
    }

    val progresses: List<ProgressItem>
        get() = withCache { cachedProgresses.toList() }.filter { !it.archived }
            .sortedWith(compareByDescending<ProgressItem> { it.updatedDay ?: "" }.thenByDescending { it.name })

    fun progress(id: String): ProgressItem? = withCache { cachedProgresses.firstOrNull { it.id == id } }

    fun stats(date: String): DayStats {
        val written = items(SectionRole.TODO, date)
        // 没做完、已被带到后面某天的任务不算在这一天的总数里；但这一天仍然「写过东西」。
        val todos = written.filter { it.carriedTo == null || it.checked }
        val sparks = items(SectionRole.SPARK, date)
        val notes = items(SectionRole.NOTES, date)
        return DayStats(todos.size, todos.count { it.checked }, todos.count { it.carryFrom != null }, sparks.size,
            written.isNotEmpty() || sparks.isNotEmpty() || notes.any { it.text.isNotEmpty() })
    }

    fun heatmap(): Map<String, Int> = days.mapNotNull { day ->
        val stats = stats(day.date)
        if (!stats.hasContent) null else day.date to when {
            stats.done == 0 -> 1; stats.done <= 2 -> 2; stats.done <= 4 -> 3; else -> 4
        }
    }.toMap()

    fun streak(today: String): Int {
        val active = heatmap().keys
        var cursor = if (today in active) today else clock.adding(-1, today)
        var count = 0
        while (cursor in active) { count++; cursor = clock.adding(-1, cursor) }
        return count
    }

    // ---------------------------------------------------------------- 今天页

    fun ensureDay(date: String, now: Instant = Instant.now()): Day {
        day(date)?.let { carryOver(it, now); return it }
        val noteId = RecordId.make(now.toEpochMilli())
        val stamp = now.toString()
        val day = Day(date, clock.zone.id, noteId)
        val edits = mutableListOf<Triple<String, String, JsonValue?>>(
            Triple(RecordType.NOTE, noteId, JsonValue.obj("id" to JsonValue.str(noteId), "kind" to JsonValue.str("day"),
                "title" to JsonValue.str(clock.title(date)), "created_at" to JsonValue.str(stamp), "updated_at" to JsonValue.str(stamp))),
            Triple(RecordType.DAY, date, day.json()),
        )
        var order: String? = null
        for ((role, title) in listOf(SectionRole.TODO to "TODO", SectionRole.SPARK to "SPARK", SectionRole.NOTES to "随记")) {
            order = OrderKey.after(order)
            val section = Block.create(RecordId.make(now.toEpochMilli()), noteId, null, order, BlockKind.SECTION,
                mapOf("role" to JsonValue.str(role.wire), "title" to JsonValue.str(title)), "", stamp)
            edits += Triple(RecordType.BLOCK, section.id, section.json())
        }
        commit(edits)
        carryOver(day, now)
        return day
    }

    fun carryOver(day: Day, now: Instant = Instant.now()) {
        val previous = days.firstOrNull { it.date < day.date } ?: return
        val target = section(SectionRole.TODO, day) ?: return
        val source = section(SectionRole.TODO, previous) ?: return
        val pending = children(source).filter { it.kind == BlockKind.CHECK && !it.checked && it.carriedTo == null }
        if (pending.isEmpty()) return
        val gap = maxOf(1, clock.daysBetween(previous.date, day.date))
        val existing = children(target)
        var lastOrder: String? = null
        val edits = mutableListOf<Triple<String, String, JsonValue?>>()
        for (original in pending) {
            val order = lastOrder?.let { OrderKey.between(it, existing.firstOrNull()?.order) }
                ?: existing.firstOrNull()?.let { OrderKey.between(null, it.order) } ?: "a"
            lastOrder = order
            val attrs = original.attrs - "carried_to" + mapOf(
                "carry_from" to JsonValue.str(original.id), "carried_days" to JsonValue.num(original.carriedDays + gap))
            val copy = original.copy(id = RecordId.make(now.toEpochMilli()), noteId = day.noteId, parentId = target.id, order = order,
                attrs = attrs, createdAt = now.toString())
            edits += Triple(RecordType.BLOCK, copy.id, copy.json())
            edits += Triple(RecordType.BLOCK, original.id, original.withAttr("carried_to", JsonValue.str(copy.id)).json())
        }
        commit(edits)
    }

    // ---------------------------------------------------------------- 编辑

    fun add(kind: BlockKind, text: String, role: SectionRole, date: String, after: String? = null,
            attrs: Map<String, JsonValue> = emptyMap(), now: Instant = Instant.now()): Block? {
        val day = ensureDay(date, now)
        val section = section(role, day) ?: return null
        val siblings = children(section)
        val index = after?.let { id -> siblings.indexOfFirst { it.id == id } } ?: -1
        val order = if (index >= 0) OrderKey.between(siblings[index].order, siblings.getOrNull(index + 1)?.order) else OrderKey.after(siblings.lastOrNull()?.order)
        val finalAttrs = attrs.toMutableMap()
        if (kind == BlockKind.CHECK) finalAttrs.putIfAbsent("checked", JsonValue.Bool(false))
        if (kind == BlockKind.SPARK) finalAttrs.putIfAbsent("color", JsonValue.str(listOf("yellow", "pink", "mint", "blue")[items(SectionRole.SPARK, date).size % 4]))
        val edits = mutableListOf<Triple<String, String, JsonValue?>>()
        if (kind == BlockKind.CHECK) ProgressParser.parse(text)?.let { match ->
            val progress = progressFor(match, date)
            finalAttrs["progress_id"] = JsonValue.str(progress.id)
            edits += Triple(RecordType.PROGRESS, progress.id, progress.json())
        }
        val block = Block.create(RecordId.make(now.toEpochMilli()), day.noteId, section.id, order, kind, finalAttrs, text, now.toString())
        edits += Triple(RecordType.BLOCK, block.id, block.json())
        commit(edits)
        return block
    }

    fun setText(text: String, blockId: String) {
        var block = block(blockId)?.takeIf { it.text != text } ?: return
        block = block.withText(text)
        val edits = mutableListOf<Triple<String, String, JsonValue?>>()
        if (block.kind == BlockKind.CHECK) {
            val match = ProgressParser.parse(text)
            block = if (match != null) {
                val progress = progressFor(match, dayDate(block) ?: clock.key(Instant.now()))
                edits += Triple(RecordType.PROGRESS, progress.id, progress.json())
                block.withAttr("progress_id", JsonValue.str(progress.id))
            } else block.withAttr("progress_id", null)
        }
        edits += Triple(RecordType.BLOCK, block.id, block.json())
        commit(edits)
    }

    fun setChecked(checked: Boolean, blockId: String) {
        val block = block(blockId)?.takeIf { it.checked != checked } ?: return
        val edits = mutableListOf<Triple<String, String, JsonValue?>>(Triple(RecordType.BLOCK, block.id, block.withAttr("checked", JsonValue.Bool(checked)).json()))
        val progress = block.progressId?.let(::progress)
        val match = ProgressParser.parse(block.text)
        if (checked && progress != null && match != null && match.value > progress.current) {
            val updated = progress.copy(current = match.value, updatedDay = dayDate(block))
            edits += Triple(RecordType.PROGRESS, updated.id, updated.json())
        }
        commit(edits)
    }

    fun setAttr(key: String, value: JsonValue?, blockId: String) {
        val block = block(blockId) ?: return
        commit(listOf(Triple(RecordType.BLOCK, block.id, block.withAttr(key, value).json())))
    }

    fun delete(blockId: String) {
        val block = block(blockId) ?: return
        val edits = mutableListOf<Triple<String, String, JsonValue?>>(Triple(RecordType.BLOCK, blockId, null))
        // 删掉一个被带过来的任务：原来那天的记录恢复成「未延续」。
        block.carryFrom?.let(::block)?.takeIf { it.carriedTo == blockId }?.let { original ->
            edits += Triple(RecordType.BLOCK, original.id, original.withAttr("carried_to", null).json())
        }
        commit(edits)
    }

    fun promote(sparkId: String, date: String, now: Instant = Instant.now()): Block? {
        val spark = block(sparkId)?.takeIf { it.kind == BlockKind.SPARK } ?: return null
        val task = add(BlockKind.CHECK, spark.text, SectionRole.TODO, date, attrs = mapOf("from_spark" to JsonValue.str(spark.id)), now = now)
        if (task != null) setAttr("promoted_to", JsonValue.str(task.id), spark.id)
        return task
    }

    fun setNotes(text: String, date: String, now: Instant = Instant.now()) {
        val day = ensureDay(date, now)
        val section = section(SectionRole.NOTES, day) ?: return
        val paragraph = children(section).firstOrNull { it.kind == BlockKind.PARAGRAPH }
        if (paragraph != null) setText(text, paragraph.id) else if (text.isNotEmpty()) add(BlockKind.PARAGRAPH, text, SectionRole.NOTES, date, now = now)
    }

    fun notes(date: String): String = items(SectionRole.NOTES, date).firstOrNull { it.kind == BlockKind.PARAGRAPH }?.text ?: ""

    fun setSummary(summary: String, date: String) {
        val day = day(date) ?: return
        commit(listOf(Triple(RecordType.DAY, date, day.copy(summary = summary).json())))
    }

    fun updateProgress(progress: ProgressItem) { commit(listOf(Triple(RecordType.PROGRESS, progress.id, progress.json()))) }

    private fun dayDate(block: Block): String? = days.firstOrNull { it.noteId == block.noteId }?.date

    private fun progressFor(match: ProgressParser.Match, date: String): ProgressItem =
        progresses.firstOrNull { it.name == match.name }?.let { if (it.unit.isEmpty()) it.copy(unit = match.unit) else it }
            ?: ProgressItem(RecordId.make(), match.name, match.unit, maxOf(0, match.value - 1), updatedDay = date)
}
