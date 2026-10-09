package com.functionhx.riji.core

import java.io.File
import java.nio.file.Files
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** 与 Swift 的 DailyBookTests 一一对应。 */
class DailyBookTest {
    private val monday = Instant.ofEpochSecond(1_759_889_000)
    private var wall = 1_759_889_000_000L
    private fun book(log: ChangeLog? = null) = DailyBook(RecordStore(log, "android-test") { ++wall })

    @Test fun dayClockUsesBeijingTime() {
        val clock = DayClock()
        assertEquals("2025-10-08", clock.key(Instant.ofEpochSecond(1_759_861_800)))
        assertEquals("10 月 8 日", clock.title("2026-10-08"))
        assertEquals("星期四", clock.weekday("2026-10-08"))
        assertEquals("2026-11-01", clock.adding(1, "2026-10-31"))
        assertEquals(3, clock.daysBetween("2026-10-05", "2026-10-08"))
    }

    @Test fun progressParser() {
        assertEquals(ProgressParser.Match("电路", 18, "讲"), ProgressParser.parse("电路 18 讲"))
        assertEquals(ProgressParser.Match("马原", 6, "章"), ProgressParser.parse("马原 第 6 章"))
        assertEquals(ProgressParser.Match("英语单词", 26, "天"), ProgressParser.parse("英语单词26天"))
        assertNull(ProgressParser.parse("徐涛马原"))
        assertNull(ProgressParser.parse("18 讲"))
    }

    @Test fun orderKeys() {
        val keys = generateSequence(OrderKey.after(null)) { OrderKey.after(it) }.take(60).toList()
        assertEquals(keys.sorted(), keys)
        assertEquals(keys.size, keys.toSet().size)
        val middle = OrderKey.between("a", "b")
        assertTrue("a" < middle && middle < "b")
        // 与 Swift 实现产生同样的键
        assertEquals("i", OrderKey.after(null))
        assertEquals("ai", OrderKey.between("a", "b"))
    }

    @Test fun dayEndsAtTheBoundaryNotMidnight() {
        val clock = DayClock(dayStart = 240)
        val night = Instant.ofEpochSecond(1_791_484_200)  // 2026-10-09 02:30 北京时间
        assertEquals("2026-10-09", DayClock().key(night))
        assertEquals("2026-10-08", clock.key(night))
        assertEquals("2026-10-09", clock.key(night.plusSeconds(90 * 60)))
        assertEquals(0, clock.minutesLeft(night))
        assertTrue(clock.isPastMidnight(night))
        assertEquals(1.0, clock.dayProgress(night))
        val evening = night.minusSeconds(4 * 3600)
        assertEquals(90, clock.minutesLeft(evening))
        assertTrue(!clock.isPastMidnight(evening))
        assertEquals(Instant.ofEpochSecond(1_791_477_000), clock.instant(30, "2026-10-08"))
        assertEquals(Instant.ofEpochSecond(1_791_469_800), clock.instant(22 * 60 + 30, "2026-10-08"))
        assertEquals(990.0 / 1080.0, clock.inkPosition(22 * 60 + 30), 1e-9)
        assertEquals(1.0, clock.inkPosition(30))
        assertEquals(990.0 / 1080.0, DayClock().inkPosition(22 * 60 + 30), 1e-9)
    }

    @Test fun carryOverHappensAtTheBoundary() {
        val book = book()
        book.clock = DayClock(dayStart = 240)
        val night = Instant.ofEpochSecond(1_791_484_200)
        book.add(BlockKind.CHECK, "写周报", SectionRole.TOMORROW, "2026-10-08", now = night)
        book.ensureDay(book.clock.key(night), night)
        assertNull(book.day("2026-10-09"))
        val morning = night.plusSeconds(5 * 3600)
        book.ensureDay(book.clock.key(morning), morning)
        assertEquals(listOf("写周报"), book.items(SectionRole.TODO, "2026-10-09").map { it.text })
    }

    @Test fun unfinishedTasksCarryOverWithoutRewritingHistory() {
        val book = book()
        val english = book.add(BlockKind.CHECK, "英语单词", SectionRole.TODO, "2026-10-07", now = monday)!!
        val marx = book.add(BlockKind.CHECK, "徐涛马原", SectionRole.TODO, "2026-10-07", now = monday)!!
        book.setChecked(true, marx.id)
        book.ensureDay("2026-10-08", monday)
        val today = book.items(SectionRole.TODO, "2026-10-08")
        assertEquals(listOf("英语单词"), today.map { it.text })
        assertEquals(english.id, today[0].carryFrom)
        assertEquals(1, today[0].carriedDays)
        assertEquals(today[0].id, book.items(SectionRole.TODO, "2026-10-07").first { it.id == english.id }.carriedTo)
        book.ensureDay("2026-10-08", monday)
        assertEquals(1, book.items(SectionRole.TODO, "2026-10-08").size)
        book.ensureDay("2026-10-10", monday)
        assertEquals(3, book.items(SectionRole.TODO, "2026-10-10").single().carriedDays)
        assertEquals(DayStats(1, 1, 0, 0, true), book.stats("2026-10-07"))
    }

    @Test fun progressIsRecognisedAndAdvancedOnCheck() {
        val book = book()
        val task = book.add(BlockKind.CHECK, "电路 18 讲", SectionRole.TODO, "2026-10-08", now = monday)!!
        val progress = book.progresses.single()
        assertEquals(17, progress.current)
        book.setChecked(true, task.id)
        assertEquals(18, book.progress(progress.id)?.current)
        assertEquals(progress.id, book.add(BlockKind.CHECK, "电路 19 讲", SectionRole.TODO, "2026-10-09", now = monday)!!.progressId)
    }

    @Test fun sparksPromoteAndDeletesReleaseOriginals() {
        val book = book()
        val spark = book.add(BlockKind.SPARK, "每日日志提醒功能", SectionRole.SPARK, "2026-10-08", now = monday)!!
        val task = book.promote(spark.id, "2026-10-08", monday)!!
        assertEquals(task.id, book.block(spark.id)?.attrs?.get("promoted_to")?.string)
        val original = book.add(BlockKind.CHECK, "sony 继续", SectionRole.TODO, "2026-10-08", now = monday)!!
        book.ensureDay("2026-10-09", monday)
        val carried = book.items(SectionRole.TODO, "2026-10-09").first { it.carryFrom == original.id }
        book.delete(carried.id)
        assertNull(book.block(original.id)?.carriedTo)
        assertTrue(book.block(original.id)!!.dropped)
        // 再打开那天不会把它又带回来，也不算在原来那天的总数里
        book.ensureDay("2026-10-09", monday)
        assertTrue(book.items(SectionRole.TODO, "2026-10-09").none { it.text == "sony 继续" })
        assertEquals(0, book.stats("2026-10-08").total)  // 由 Spark 转来的那条延续走了，sony 放下了
    }

    @Test fun newDayHasFourSections() {
        val book = book()
        val day = book.ensureDay("2026-10-08", monday)
        assertEquals(SectionRole.entries.toSet(), book.blocks(day.noteId).mapNotNull { it.role }.toSet())
    }

    @Test fun tomorrowGoalsBecomeNextDaysGoals() {
        val book = book()
        val d = "2026-10-07"
        book.add(BlockKind.CHECK, "sony 继续", SectionRole.TODO, d, now = monday)
        val circuit = book.add(BlockKind.CHECK, "电路 20 讲", SectionRole.TOMORROW, d, now = monday)!!
        val report = book.add(BlockKind.CHECK, "写周报", SectionRole.TOMORROW, d, now = monday)!!
        val same = book.add(BlockKind.CHECK, "Sony 继续 ", SectionRole.TOMORROW, d, now = monday)!!
        book.add(BlockKind.CHECK, "  ", SectionRole.TOMORROW, d, now = monday)
        assertNull(book.day("2026-10-08"))

        book.ensureDay("2026-10-08", monday)
        val today = book.items(SectionRole.TODO, "2026-10-08")
        assertEquals(listOf("电路 20 讲", "写周报", "sony 继续"), today.map { it.text })
        assertEquals(circuit.id, today[0].plannedFrom)
        assertEquals(circuit.progressId, today[0].progressId)
        assertNull(today[2].plannedFrom)
        assertEquals(today[0].id, book.block(circuit.id)?.plannedTo)
        assertEquals(today[1].id, book.block(report.id)?.plannedTo)
        assertEquals(today[2].id, book.block(same.id)?.plannedTo)
        book.ensureDay("2026-10-08", monday)
        assertEquals(3, book.items(SectionRole.TODO, "2026-10-08").size)

        book.ensureDay("2026-10-09", monday)
        val third = book.items(SectionRole.TODO, "2026-10-09")
        assertEquals(listOf("电路 20 讲", "写周报", "sony 继续"), third.map { it.text })
        assertTrue(third.all { it.plannedFrom == null && it.carryFrom != null })
    }

    @Test fun goalsAfterMidnightLandAndPastDaysStayUntouched() {
        val book = book()
        book.add(BlockKind.CHECK, "背单词", SectionRole.TODO, "2026-10-07", now = monday)
        book.ensureDay("2026-10-08", monday)
        val goal = book.add(BlockKind.CHECK, "整理笔记", SectionRole.TOMORROW, "2026-10-07", now = monday)!!
        book.add(BlockKind.CHECK, "跑步", SectionRole.TOMORROW, "2026-10-07", now = monday)
        assertEquals(listOf("整理笔记", "跑步", "背单词"), book.items(SectionRole.TODO, "2026-10-08").map { it.text })
        book.add(BlockKind.CHECK, "背单词", SectionRole.TOMORROW, "2026-10-07", now = monday)
        assertEquals(3, book.items(SectionRole.TODO, "2026-10-08").size)
        assertNotNull(book.block(goal.id)?.plannedTo)

        val later = Instant.ofEpochSecond(1_791_857_000)  // 2026-10-13
        val late = book.add(BlockKind.CHECK, "补的目标", SectionRole.TOMORROW, "2026-10-07", now = later)!!
        assertNull(book.block(late.id)?.plannedTo)
        assertEquals(3, book.items(SectionRole.TODO, "2026-10-08").size)
    }

    @Test fun editingAGoalFollowsItUntilTouched() {
        val book = book()
        val goal = book.add(BlockKind.CHECK, "电路 20 讲", SectionRole.TOMORROW, "2026-10-07", now = monday)!!
        book.ensureDay("2026-10-08", monday)
        val copyId = book.block(goal.id)!!.plannedTo!!
        book.setText("电路 21 讲", goal.id)
        assertEquals("电路 21 讲", book.block(copyId)?.text)
        book.setChecked(true, copyId)
        book.setText("电路 22 讲", goal.id)
        assertEquals("电路 21 讲", book.block(copyId)?.text)
    }

    @Test fun oldPagesGetTheTomorrowSectionOnFirstWrite() {
        val book = book()
        val day = book.ensureDay("2026-10-07", monday)
        book.store.write(listOf(Triple(RecordType.BLOCK, book.section(SectionRole.TOMORROW, day)!!.id, null)))
        assertNull(book.section(SectionRole.TOMORROW, day))
        book.add(BlockKind.CHECK, "写周报", SectionRole.TOMORROW, "2026-10-07", now = monday)
        assertEquals(listOf("写周报"), book.items(SectionRole.TOMORROW, "2026-10-07").map { it.text })
        val roles = book.blocks(day.noteId).filter { it.kind == BlockKind.SECTION }.sortedBy { it.order }.mapNotNull { it.role }
        assertEquals(listOf(SectionRole.TODO, SectionRole.SPARK, SectionRole.NOTES, SectionRole.TOMORROW), roles)
    }

    @Test fun eveningNudgeOnlyAsksForWhatIsMissing() {
        val book = book()
        val date = "2026-10-08"
        book.setChecked(true, book.add(BlockKind.CHECK, "徐涛马原", SectionRole.TODO, date, now = monday)!!.id)
        book.add(BlockKind.CHECK, "sony 继续", SectionRole.TODO, date, now = monday)
        var evening = book.evening(date)
        assertEquals(listOf("今日总结", "明日目标"), evening.missing)
        assertEquals("今晚总结", evening.nudge?.title)
        assertTrue(evening.nudge!!.body.contains("今天完成 1/2") && evening.nudge!!.body.contains("没做完的 1 件会自动延续"))
        book.add(BlockKind.CHECK, "写周报", SectionRole.TOMORROW, date, now = monday)
        assertEquals("今日总结还没写", book.evening(date).nudge?.title)
        book.setSummary("马原过完一轮。", date)
        evening = book.evening(date)
        assertTrue(evening.isComplete)
        assertNull(evening.nudge)
        book.ensureDay("2026-10-09", monday)
        book.setSummary("休息日", "2026-10-09")
        assertEquals("明天做什么？", book.evening("2026-10-09").nudge?.title)
    }

    @Test fun morningAsksToBackfillYesterday() {
        val book = book()
        assertNull(book.missedEvening("2026-10-08"))
        book.ensureDay("2026-10-07", monday)
        assertNull(book.missedEvening("2026-10-08"))
        book.add(BlockKind.SPARK, "参考文献必填", SectionRole.SPARK, "2026-10-07", now = monday)
        assertEquals("2026-10-07", book.missedEvening("2026-10-08"))
        book.setSummary("写了一点", "2026-10-07")
        assertNull(book.missedEvening("2026-10-08"))
    }

    @Test fun heatmapAndStreak() {
        val book = book()
        for ((date, done) in listOf("2026-10-05" to 1, "2026-10-06" to 3, "2026-10-07" to 0, "2026-10-08" to 5)) {
            repeat(maxOf(done, 1)) { i ->
                val task = book.add(BlockKind.CHECK, "任务 $i", SectionRole.TODO, date, now = monday)!!
                if (i < done) book.setChecked(true, task.id)
            }
        }
        val levels = book.heatmap()
        assertEquals(4, levels["2026-10-08"]); assertEquals(3, levels["2026-10-06"]); assertEquals(2, levels["2026-10-05"])
        assertEquals(4, book.streak("2026-10-08"))
        assertEquals(4, book.streak("2026-10-09"))
        assertEquals(0, book.streak("2026-10-11"))
    }

    @Test fun everythingSurvivesARestart() {
        val file = File(Files.createTempDirectory("riji").toFile(), "changes.jsonl")
        book(ChangeLog(file)).apply {
            val task = add(BlockKind.CHECK, "电路 18 讲", SectionRole.TODO, "2026-10-08", now = monday)!!
            setChecked(true, task.id)
            add(BlockKind.SPARK, "参考文献必填", SectionRole.SPARK, "2026-10-08", now = monday)
            setNotes("感觉黑夜模式下更好看？", "2026-10-08", monday)
        }
        val reopened = book(ChangeLog(file))
        assertEquals(listOf(true), reopened.items(SectionRole.TODO, "2026-10-08").map { it.checked })
        assertEquals("感觉黑夜模式下更好看？", reopened.notes("2026-10-08"))
        assertNotNull(reopened.progresses.firstOrNull { it.current == 18 })
    }

    @Test fun manyWritesStayFast() {
        val book = book()
        val start = System.nanoTime()
        var date = "2026-06-01"
        repeat(120) { day ->
            repeat(3) { i -> book.add(BlockKind.CHECK, "第 $i 件事", SectionRole.TODO, date, now = monday)?.let { if (i < 2) book.setChecked(true, it.id) } }
            date = book.clock.adding(1, date)
            if (day % 10 == 0) book.heatmap()
        }
        val seconds = (System.nanoTime() - start) / 1e9
        assertTrue(seconds < 3.0, "120 天的写入用了 $seconds 秒")
    }
}
