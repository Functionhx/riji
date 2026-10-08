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
