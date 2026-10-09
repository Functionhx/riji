package com.functionhx.riji.core

import java.io.File
import java.nio.file.Files
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** 与 Swift 的 SyncTests 一一对应：内存副本只接受「接在最后一段后面、prev 吻合」的段。 */
class SyncTest {
    private class FakeReplica : SyncTransport {
        val logs = mutableMapOf<String, MutableList<Segment>>()
        var rejected = 0
        override fun heads() = logs.mapValues { SegmentHead(it.value.last().seq, it.value.last().chainHash) }
        override fun fetch(device: String, from: Int, limit: Int) = (logs[device] ?: emptyList()).filter { it.seq >= from }.take(limit)
        override fun push(segments: List<Segment>) {
            for (segment in segments) {
                val log = logs.getOrPut(segment.device) { mutableListOf() }
                val head = log.lastOrNull()?.let { SegmentHead(it.seq, it.chainHash) } ?: SegmentHead.EMPTY
                if (segment.seq <= head.seq && log.firstOrNull { it.seq == segment.seq }?.ct == segment.ct) continue
                if (segment.seq != head.seq + 1 || segment.prev != head.hash) { rejected++; continue }
                log += segment
            }
        }
    }

    private class Device(val folder: File, val name: String, var wall: Long, key: SyncKey, replica: FakeReplica) {
        val store = RecordStore(ChangeLog(File(folder, "changes.jsonl")), name, ChangeLog(File(folder, "remote-changes.jsonl"))) { ++wall }
        val book = DailyBook(store)
        val engine = SyncEngine(store, key, replica, File(folder, "sync"))
    }

    private fun temp() = Files.createTempDirectory("riji-sync").toFile()
    private val morning = Instant.ofEpochSecond(1_791_425_000)

    @Test fun twoDevicesConverge() {
        val key = SyncKey.generate(); val replica = FakeReplica()
        val mac = Device(temp(), "mac-1", 1_791_425_000_000, key, replica)
        val phone = Device(temp(), "android-1", 1_791_425_100_000, key, replica)
        val task = mac.book.add(BlockKind.CHECK, "高数 18 讲", SectionRole.TODO, "2026-10-08", now = morning)!!
        mac.book.add(BlockKind.SPARK, "同桌理论", SectionRole.SPARK, "2026-10-08", now = morning)
        val first = mac.engine.sync()
        assertEquals(1, first.sealed); assertEquals(1, first.pushed)
        val pulled = phone.engine.sync()
        assertEquals(1, pulled.pulled)
        assertEquals(listOf("高数 18 讲"), phone.book.items(SectionRole.TODO, "2026-10-08").map { it.text })
        phone.book.setChecked(true, task.id)
        phone.book.setSummary("高数过完 18 讲", "2026-10-08")
        phone.engine.sync(); mac.engine.sync()
        assertTrue(mac.book.items(SectionRole.TODO, "2026-10-08").first().checked)
        assertEquals("高数过完 18 讲", mac.book.day("2026-10-08")?.summary)
        assertEquals(mac.store.snapshot(), phone.store.snapshot())
        assertEquals(0, replica.rejected)
    }

    @Test fun nothingIsSentTwiceAndRestartsResume() {
        val key = SyncKey.generate(); val replica = FakeReplica()
        val folder = temp()
        var mac = Device(folder, "mac-1", 1_791_425_000_000, key, replica)
        val phone = Device(temp(), "android-1", 1_791_425_100_000, key, replica)
        mac.book.add(BlockKind.CHECK, "英语单词", SectionRole.TODO, "2026-10-08", now = morning)
        mac.engine.sync()
        val again = mac.engine.sync()
        assertEquals(0, again.sealed); assertEquals(0, again.pushed)
        phone.book.add(BlockKind.SPARK, "参考文献必填", SectionRole.SPARK, "2026-10-08", now = morning)
        phone.engine.sync(); mac.engine.sync()
        mac = Device(folder, "mac-1", mac.wall, key, replica)
        assertEquals(listOf("参考文献必填"), mac.book.items(SectionRole.SPARK, "2026-10-08").map { it.text })
        val resumed = mac.engine.sync()
        assertEquals(listOf(0, 0, 0), listOf(resumed.sealed, resumed.pushed, resumed.pulled))
        mac.book.add(BlockKind.CHECK, "背 50 个单词", SectionRole.TODO, "2026-10-08", now = morning)
        assertEquals(1, mac.engine.sync().pushed)
        assertEquals(listOf(1, 2), replica.logs["mac-1"]!!.map { it.seq })
    }

    @Test fun sameDayOnBothDevicesIsDeterministic() {
        val key = SyncKey.generate(); val replica = FakeReplica()
        val mac = Device(temp(), "mac-1", 1_791_425_000_000, key, replica)
        val phone = Device(temp(), "android-1", 1_791_425_100_000, key, replica)
        mac.book.add(BlockKind.CHECK, "Mac 上的事", SectionRole.TODO, "2026-10-09", now = morning)
        phone.book.add(BlockKind.CHECK, "手机上的事", SectionRole.TODO, "2026-10-09", now = morning)
        mac.engine.sync(); phone.engine.sync(); mac.engine.sync()
        for (device in listOf(mac, phone)) {
            assertEquals(setOf("Mac 上的事", "手机上的事"), device.book.items(SectionRole.TODO, "2026-10-09").map { it.text }.toSet())
            assertTrue(!device.book.reconcileDays())
        }
        assertEquals(mac.store.snapshot(), phone.store.snapshot())
    }

    @Test fun legacyDuplicateDaysAreMerged() {
        val key = SyncKey.generate(); val replica = FakeReplica()
        val mac = Device(temp(), "mac-1", 1_791_425_000_000, key, replica)
        val phone = Device(temp(), "android-1", 1_791_425_100_000, key, replica)
        for ((device, text) in listOf(mac to "sony 继续", phone to "背单词")) {
            val noteId = RecordId.make(morning.toEpochMilli()); val sectionId = RecordId.make(morning.toEpochMilli())
            val stamp = morning.toString()
            val note = JsonValue.obj("id" to JsonValue.str(noteId), "kind" to JsonValue.str("day"), "title" to JsonValue.str("10 月 9 日"),
                "created_at" to JsonValue.str(stamp), "updated_at" to JsonValue.str(stamp))
            val section = Block.create(sectionId, noteId, null, "a", BlockKind.SECTION, mapOf("role" to JsonValue.str("todo")), "", stamp)
            val task = Block.create(RecordId.make(morning.toEpochMilli()), noteId, sectionId, "a", BlockKind.CHECK, mapOf("checked" to JsonValue.Bool(false)), text, stamp)
            device.store.write(listOf(Triple(RecordType.NOTE, noteId, note), Triple(RecordType.DAY, "2026-10-09", Day("2026-10-09", "Asia/Shanghai", noteId).json()),
                Triple(RecordType.BLOCK, sectionId, section.json()), Triple(RecordType.BLOCK, task.id, task.json())))
        }
        mac.engine.sync(); phone.engine.sync(); mac.engine.sync()
        assertEquals(1, mac.book.items(SectionRole.TODO, "2026-10-09").size)
        assertTrue(mac.book.reconcileDays()); assertTrue(phone.book.reconcileDays())
        mac.engine.sync(); phone.engine.sync(); mac.engine.sync()
        for (device in listOf(mac, phone)) {
            assertEquals(setOf("sony 继续", "背单词"), device.book.items(SectionRole.TODO, "2026-10-09").map { it.text }.toSet())
            assertEquals(1, device.store.values(RecordType.NOTE).size)
        }
        assertEquals(mac.store.snapshot(), phone.store.snapshot())
    }

    @Test fun wrongKeyIsDetected() {
        val replica = FakeReplica()
        val mac = Device(temp(), "mac-1", 1_791_425_000_000, SyncKey.generate(), replica)
        val stranger = Device(temp(), "android-9", 1_791_425_100_000, SyncKey.generate(), replica)
        mac.book.add(BlockKind.CHECK, "秘密", SectionRole.TODO, "2026-10-08", now = morning)
        mac.engine.sync()
        val report = stranger.engine.sync()
        assertEquals(0, report.absorbed); assertEquals(1, report.problems.size)
        assertTrue(stranger.book.items(SectionRole.TODO, "2026-10-08").isEmpty())
    }
}
