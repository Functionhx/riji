package com.functionhx.riji

import com.functionhx.riji.core.BlockKind
import com.functionhx.riji.core.DailyBook
import com.functionhx.riji.core.JsonValue
import com.functionhx.riji.core.ProgressItem
import com.functionhx.riji.core.SectionRole
import java.time.Instant

/** 调试版的示例内容（与 Mac 版 DemoData 相同），只在本机为空时、用 `--ez riji_demo true` 启动才写入。 */
object DemoData {
    fun seed(book: DailyBook, today: String, now: Instant = Instant.now()) {
        val clock = book.clock
        val yesterday = clock.adding(-1, today)
        for (offset in 120 downTo 2) {
            if (offset % 3 == 0 && offset % 7 != 1) continue
            val date = clock.adding(-offset, today)
            val count = (offset * 7) % 5
            for (i in 0..count) {
                val task = book.add(BlockKind.CHECK, "第 ${i + 1} 件事", SectionRole.TODO, date, now = now)
                if (task != null) book.setChecked(true, task.id)
            }
        }
        book.add(BlockKind.CHECK, "英语单词", SectionRole.TODO, yesterday, now = now)
        for (text in listOf("徐涛马原", "电路 18 讲")) book.add(BlockKind.CHECK, text, SectionRole.TODO, yesterday, now = now)?.let { book.setChecked(true, it.id) }
        for (text in listOf("sony 继续", "文章便利贴功能", "参考文献必填")) book.add(BlockKind.SPARK, text, SectionRole.SPARK, yesterday, now = now)
        book.setNotes("感觉黑夜模式下更好看？", yesterday, now)
        book.setSummary("马原过完一轮，电路推进到 18 讲。", yesterday)
        for (text in listOf("电路 19 讲", "sony 继续")) book.add(BlockKind.CHECK, text, SectionRole.TOMORROW, yesterday, now = now)
        book.ensureDay(today, now)
        book.items(SectionRole.TODO, today).firstOrNull { it.carryFrom != null }?.let { book.setAttr("carried_days", JsonValue.num(2), it.id) }
        book.add(BlockKind.CHECK, "徐涛马原", SectionRole.TODO, today, now = now)?.let { book.setChecked(true, it.id) }
        book.items(SectionRole.TODO, today).firstOrNull { it.text == "电路 19 讲" }?.let { book.setChecked(true, it.id) }
        book.add(BlockKind.SPARK, "每日日志提醒功能", SectionRole.SPARK, today, now = now)?.let { book.promote(it.id, today, now) }
        book.add(BlockKind.CHECK, "电路 20 讲", SectionRole.TOMORROW, today, now = now)
        for (text in listOf("微信文件传输助手分析历史", "参考文献必填", "继续浏览·全部文章？")) book.add(BlockKind.SPARK, text, SectionRole.SPARK, today, now = now)
        book.progresses.firstOrNull { it.name == "电路" }?.let { book.updateProgress(it.copy(target = 40)) }
        book.updateProgress(ProgressItem("demo-english", "英语单词", "天", 26, 60, updatedDay = today))
        book.updateProgress(ProgressItem("demo-marx", "马原", "章", 6, 8, updatedDay = yesterday))
    }
}
