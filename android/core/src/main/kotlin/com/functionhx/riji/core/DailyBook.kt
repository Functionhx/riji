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
class DailyBook(val store: RecordStore, var clock: DayClock = DayClock()) {
    companion object { fun dayNoteId(date: String) = "day-$date" }

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
        // 没做完、已被带到后面某天（或放下了）的任务不算在这一天的总数里；但这一天仍然「写过东西」。
        val todos = written.filter { (it.carriedTo == null && !it.dropped) || it.checked }
        val sparks = items(SectionRole.SPARK, date)
        val notes = items(SectionRole.NOTES, date)
        val wroteEvening = !day(date)?.summary.isNullOrEmpty() || items(SectionRole.TOMORROW, date).isNotEmpty()
        return DayStats(todos.size, todos.count { it.checked }, todos.count { it.carryFrom != null }, sparks.size,
            written.isNotEmpty() || sparks.isNotEmpty() || notes.any { it.text.isNotEmpty() } || wroteEvening)
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

    // ---------------------------------------------------------------- 晚间

    /** 一天收尾的情况：今日总结写了没有、明日目标定了几条、还有几件没做完（会自动延续）。 */
    fun evening(date: String): Evening {
        val plans = items(SectionRole.TOMORROW, date).count { normalized(it.text).isNotEmpty() }
        val pending = items(SectionRole.TODO, date).count { !it.checked && it.carriedTo == null && !it.dropped }
        return Evening(date, stats(date), !day(date)?.summary.isNullOrBlank(), plans, pending)
    }

    /** 早上补写：昨天写过东西、却没写总结时返回昨天的日期。 */
    fun missedEvening(today: String): String? {
        val yesterday = clock.adding(-1, today)
        val evening = evening(yesterday)
        return if (day(yesterday) != null && evening.stats.hasContent && !evening.hasSummary) yesterday else null
    }

    // ---------------------------------------------------------------- 今天页

    fun ensureDay(date: String, now: Instant = Instant.now()): Day {
        day(date)?.let { carryOver(it, now); return it }
        // 确定的 id：两台设备各自生成同一天时写的是同一组记录，同步后不会出现两页
        val noteId = dayNoteId(date)
        val stamp = now.toString()
        val day = Day(date, clock.zone.id, noteId)
        val edits = mutableListOf<Triple<String, String, JsonValue?>>(
            Triple(RecordType.NOTE, noteId, JsonValue.obj("id" to JsonValue.str(noteId), "kind" to JsonValue.str("day"),
                "title" to JsonValue.str(clock.title(date)), "created_at" to JsonValue.str(stamp), "updated_at" to JsonValue.str(stamp))),
            Triple(RecordType.DAY, date, day.json()),
        )
        var order: String? = null
        for ((role, title) in listOf(SectionRole.TODO to "TODO", SectionRole.SPARK to "SPARK", SectionRole.NOTES to "随记", SectionRole.TOMORROW to "明日目标")) {
            order = OrderKey.after(order)
            val section = Block.create("$noteId-${role.wire}", noteId, null, order, BlockKind.SECTION,
                mapOf("role" to JsonValue.str(role.wire), "title" to JsonValue.str(title)), "", stamp)
            edits += Triple(RecordType.BLOCK, section.id, section.json())
        }
        commit(edits)
        carryOver(day, now)
        return day
    }

    /**
     * 从最近的前一天，把两样东西带到这一天「今日目标」的顶部：先是那天定下的明日目标，再是没勾、也还没被带走的 TODO。
     * 原块记下去向（planned_to / carried_to），历史不改写。明日目标只落到今天及以后的页面上；
     * 和延续过来的事、这一天已有的事重名的目标不重复添加。与 Swift 的 carryOver 相同。
     */
    fun carryOver(day: Day, now: Instant = Instant.now()) {
        val previous = days.firstOrNull { it.date < day.date } ?: return
        val target = section(SectionRole.TODO, day) ?: return
        val pending = section(SectionRole.TODO, previous)?.let(::children).orEmpty()
            .filter { it.kind == BlockKind.CHECK && !it.checked && it.carriedTo == null && !it.dropped }
        val plans = if (day.date < clock.key(now)) emptyList() else section(SectionRole.TOMORROW, previous)?.let(::children).orEmpty()
            .filter { it.kind == BlockKind.CHECK && it.plannedTo == null && normalized(it.text).isNotEmpty() }
        if (pending.isEmpty() && plans.isEmpty()) return

        val gap = maxOf(1, clock.daysBetween(previous.date, day.date))
        val existing = children(target)
        // 插在顶部；这一天已经有排进来的目标（过了零点逐条补写）时，接在它们后面，保持书写顺序。
        val anchor = existing.indexOfLast { it.plannedFrom != null && it.carryFrom == null }.takeIf { it >= 0 }
        var lastOrder: String? = anchor?.let { existing[it].order }
        val upper = if (anchor != null) existing.getOrNull(anchor + 1)?.order else existing.firstOrNull()?.order
        fun nextOrder(): String = (if (lastOrder == null && upper == null) "a" else OrderKey.between(lastOrder, upper)).also { lastOrder = it }
        val edits = mutableListOf<Triple<String, String, JsonValue?>>()
        val landed = mutableMapOf<String, String>()
        for (block in existing) landed.putIfAbsent(normalized(block.text), block.id)
        val carried = pending.map { original ->
            val attrs = original.attrs - "carried_to" - "planned_from" + mapOf(
                "carry_from" to JsonValue.str(original.id), "carried_days" to JsonValue.num(original.carriedDays + gap))
            original to original.copy(id = "carry-${original.id}-${day.date}", noteId = day.noteId, parentId = target.id, order = "",
                attrs = attrs, createdAt = now.toString())
        }
        for ((original, copy) in carried) landed.putIfAbsent(normalized(original.text), copy.id)

        val planCopies = mutableListOf<Block>()
        for (plan in plans) {
            val key = normalized(plan.text)
            val landedId = landed[key] ?: run {
                val attrs = mutableMapOf<String, JsonValue>("checked" to JsonValue.Bool(false), "planned_from" to JsonValue.str(plan.id))
                plan.attrs["progress_id"]?.let { attrs["progress_id"] = it }
                val copy = Block.create("plan-${plan.id}", day.noteId, target.id, nextOrder(), BlockKind.CHECK, attrs, plan.text, now.toString())
                planCopies += copy
                landed[key] = copy.id
                copy.id
            }
            edits += Triple(RecordType.BLOCK, plan.id, plan.withAttr("planned_to", JsonValue.str(landedId)).json())
        }
        for (copy in planCopies) edits += Triple(RecordType.BLOCK, copy.id, copy.json())
        for ((original, unordered) in carried) {
            val copy = unordered.copy(order = nextOrder())
            edits += Triple(RecordType.BLOCK, copy.id, copy.json())
            edits += Triple(RecordType.BLOCK, original.id, original.withAttr("carried_to", JsonValue.str(copy.id)).json())
        }
        commit(edits)
    }

    // ---------------------------------------------------------------- 编辑

    fun add(kind: BlockKind, text: String, role: SectionRole, date: String, after: String? = null,
            attrs: Map<String, JsonValue> = emptyMap(), now: Instant = Instant.now()): Block? {
        val day = ensureDay(date, now)
        val section = section(role, day) ?: createSection(role, day, now)
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
        // 第二天的页面已经在了（过了零点才写明日目标）：直接排进去。
        if (role == SectionRole.TOMORROW) days.lastOrNull { it.date > date }?.let { carryOver(it, now) }
        return block
    }

    /** 老页面没有的区块（比如「明日目标」是后来加的）在第一次写入时补上，排在最后。 */
    private fun createSection(role: SectionRole, day: Day, now: Instant): Block {
        val titles = mapOf(SectionRole.TODO to "TODO", SectionRole.SPARK to "SPARK", SectionRole.NOTES to "随记", SectionRole.TOMORROW to "明日目标")
        val last = blocks(day.noteId).filter { it.parentId == null }.maxOfOrNull { it.order }
        val section = Block.create("${day.noteId}-${role.wire}", day.noteId, null, OrderKey.after(last), BlockKind.SECTION,
            mapOf("role" to JsonValue.str(role.wire), "title" to JsonValue.str(titles.getValue(role))), "", now.toString())
        commit(listOf(Triple(RecordType.BLOCK, section.id, section.json())))
        return section
    }

    fun setText(text: String, blockId: String) {
        var block = block(blockId)?.takeIf { it.text != text } ?: return
        val before = block.text
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
        // 改写已排进第二天的明日目标：那边还没动过的话一起改。
        block.plannedTo?.let(::block)?.takeIf { it.plannedFrom == block.id && !it.checked && it.text == before }?.let { copy ->
            edits += Triple(RecordType.BLOCK, copy.id, copy.withText(text).withAttr("progress_id", block.attrs["progress_id"]).json())
        }
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
        // 删掉一个被带过来的任务 = 不做了：原来那天的记录标成「放下了」，以后不会再被带回来。
        block.carryFrom?.let(::block)?.takeIf { it.carriedTo == blockId }?.let { original ->
            edits += Triple(RecordType.BLOCK, original.id, original.withAttr("carried_to", null).withAttr("dropped", JsonValue.Bool(true)).json())
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

    // ---------------------------------------------------------------- 同步后的同日合并（与 Swift 的 reconcileDays 相同）

    /** 旧版两台设备各自生成过同一天：把孤儿笔记的内容按区块角色挪进胜出的那一页，再删掉孤儿。结果是确定的。 */
    fun reconcileDays(now: Instant = Instant.now()): Boolean {
        val referenced = days.map { it.noteId }.toSet()
        val orphans = store.values(RecordType.NOTE).filter { it["kind"]?.string == "day" && it["id"]?.string !in referenced }
        var changed = false
        for (note in orphans) {
            val noteId = note["id"]?.string ?: continue
            val target = dateOf(note)?.let(::day) ?: continue
            val blocks = blocks(noteId)
            val sections = blocks.filter { it.kind == BlockKind.SECTION }.associateBy { it.id }
            val edits = mutableListOf<Triple<String, String, JsonValue?>>()
            for (block in blocks) {
                if (block.kind == BlockKind.SECTION) continue
                val role = block.parentId?.let(sections::get)?.role ?: SectionRole.NOTES
                val section = section(role, target) ?: createSection(role, target, now)
                edits += Triple(RecordType.BLOCK, block.id, block.copy(noteId = target.noteId, parentId = section.id).json())
            }
            for (section in sections.values) edits += Triple(RecordType.BLOCK, section.id, null)
            edits += Triple(RecordType.NOTE, noteId, null)
            commit(edits)
            changed = true
        }
        return changed
    }

    /** 孤儿笔记是哪一天的：新版 id 里就有日期；旧版从标题「10 月 9 日」和创建时间推出年份。 */
    private fun dateOf(note: JsonValue): String? {
        val id = note["id"]?.string ?: return null
        if (id.startsWith("day-")) return id.removePrefix("day-")
        val numbers = Regex("\\d+").findAll(note["title"]?.string ?: "").map { it.value.toInt() }.toList()
        if (numbers.size != 2) return null
        val created = note["created_at"]?.string?.let { runCatching { Instant.parse(it) }.getOrNull() } ?: return null
        val year = created.atZone(clock.zone).year
        return listOf(year - 1, year, year + 1).map { "%04d-%02d-%02d".format(it, numbers[0], numbers[1]) }
            .filter { runCatching { java.time.LocalDate.parse(it) }.isSuccess }
            .minByOrNull { kotlin.math.abs(java.time.LocalDate.parse(it).atStartOfDay(clock.zone).toInstant().epochSecond - created.epochSecond) }
    }

    private fun normalized(text: String) = text.trim().lowercase()

    private fun dayDate(block: Block): String? = days.firstOrNull { it.noteId == block.noteId }?.date

    private fun progressFor(match: ProgressParser.Match, date: String): ProgressItem =
        progresses.firstOrNull { it.name == match.name }?.let { if (it.unit.isEmpty()) it.copy(unit = match.unit) else it }
            ?: ProgressItem(RecordId.make(), match.name, match.unit, maxOf(0, match.value - 1), updatedDay = date)
}

/** 一天的收尾：晚间提醒据此决定提不提醒、提醒什么。与 Swift 的 Evening 相同（文字也相同）。 */
data class Evening(val date: String, val stats: DayStats, val hasSummary: Boolean, val plans: Int, val pending: Int) {
    data class Nudge(val title: String, val body: String)

    val isComplete: Boolean get() = hasSummary && plans > 0

    /** 还差什么（界面上的「还差：…」）。 */
    val missing: List<String> get() = (if (hasSummary) emptyList() else listOf("今日总结")) + (if (plans > 0) emptyList() else listOf("明日目标"))

    /** 晚间通知的文字；都写好了就是 null（不提醒）。 */
    val nudge: Nudge?
        get() {
            val done = if (stats.total > 0) "今天完成 ${stats.done}/${stats.total}。" else ""
            val carry = if (pending > 0) "没做完的 $pending 件会自动延续，不用再抄一遍。" else ""
            return when {
                hasSummary && plans > 0 -> null
                !hasSummary && plans == 0 -> Nudge("今晚总结", done + "用一句话记下今天，再定下明天要做的事。" + carry)
                !hasSummary -> Nudge("今日总结还没写", done + "明天的目标定好了，再用一句话记下今天。")
                else -> Nudge("明天做什么？", "总结写好了。定一两件明天的事，明早会出现在今日目标里。" + carry)
            }
        }
}
