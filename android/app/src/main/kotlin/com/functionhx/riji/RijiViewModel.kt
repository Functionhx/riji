package com.functionhx.riji

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import com.functionhx.riji.core.BlockKind
import com.functionhx.riji.core.ChangeLog
import com.functionhx.riji.core.DailyBook
import com.functionhx.riji.core.DayClock
import com.functionhx.riji.core.JsonValue
import com.functionhx.riji.core.ProgressItem
import com.functionhx.riji.core.RecordStore
import com.functionhx.riji.core.SectionRole
import java.io.File
import java.time.Instant
import java.util.UUID

enum class Tab(val title: String) { TODAY("今天"), TIMELINE("时间线"), PROGRESS("进度"), ME("我") }

/**
 * 界面唯一的状态源。所有修改经过 DailyBook（→ RecordStore → 本机变更日志），然后 revision 加一，
 * 读取 revision 的 Composable 重新组合。数据在应用私有目录 files/riji/changes.jsonl。
 */
class RijiViewModel(application: Application) : AndroidViewModel(application) {
    val book: DailyBook
    var revision by mutableIntStateOf(0)
        private set
    var today by mutableStateOf("")
        private set
    var selectedDate by mutableStateOf("")
    var tab by mutableStateOf(Tab.TODAY)
    var error by mutableStateOf<String?>(null)
        private set
    private var device = ""

    // 邮件提醒（兜底）的设置与最近一次上报的结果
    var mail by mutableStateOf(MailReminder.load(application))
        private set
    var mailStatus by mutableStateOf("")
        private set
    private var reportJob: Job? = null

    init {
        val prefs = application.getSharedPreferences("riji", 0)
        val device = prefs.getString("device", null) ?: "android-${UUID.randomUUID().toString().take(8)}".also {
            prefs.edit().putString("device", it).apply()
        }
        this.device = device
        val log = ChangeLog(File(application.filesDir, "riji/changes.jsonl"))
        book = DailyBook(RecordStore(log, device), DayClock(dayStart = EveningReminder.dayStart(application)))
        today = book.clock.key(Instant.now())
        selectedDate = today
        perform { book.ensureDay(today) }
    }

    /** 调试版：本机为空时写入示例内容（只用于截图与演示）。 */
    fun seedDemoIfEmpty() {
        val debuggable = (getApplication<Application>().applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
        if (!debuggable || book.days.any { book.stats(it.date).hasContent }) return
        perform { DemoData.seed(book, today) }
    }

    /** 跨过零点时生成新的一天（界面每分钟调用一次）。 */
    fun refreshDay() {
        val key = book.clock.key(Instant.now())
        if (key == today) return
        val wasOnToday = selectedDate == today
        today = key
        if (wasOnToday) selectedDate = key
        perform { book.ensureDay(key) }
    }

    fun open(date: String) {
        selectedDate = date
        tab = Tab.TODAY
        perform { book.ensureDay(date) }
    }

    fun perform(action: () -> Unit) {
        error = try {
            action(); null
        } catch (e: Exception) {
            "没能保存：${e.message}"
        }
        revision++
        scheduleReport()
    }

    /** 内容变了：一秒后上报今天的数字（连续修改只报最后一次）。 */
    fun scheduleReport() {
        reportJob?.cancel()
        reportJob = viewModelScope.launch {
            delay(1_000)
            val app = getApplication<Application>()
            val result = withContext(Dispatchers.IO) { MailReminder.report(app, device, today, book.evening(today)) } ?: return@launch
            when (result) {
                is MailReminder.Result.Ok -> {
                    mailStatus = result.message
                    if (result.adopted) {
                        mail = MailReminder.load(app)
                        reminderOn = EveningReminder.enabled(app)
                        reminderMinutes = EveningReminder.minutes(app)
                        applyDayStart(EveningReminder.dayStart(app))
                    }
                }
                is MailReminder.Result.Failed -> mailStatus = result.message
            }
        }
    }

    fun updateMail(settings: MailReminder.Settings) {
        val tokenOnly = settings.copy(token = mail.token) == mail
        mail = settings
        MailReminder.save(getApplication(), settings, touch = !tokenOnly)
        scheduleReport()
    }

    fun sendTestMail() {
        mailStatus = "正在发送…"
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { MailReminder.sendTest(getApplication()) }
            mailStatus = when (result) { is MailReminder.Result.Ok -> result.message; is MailReminder.Result.Failed -> result.message }
        }
    }

    // 读取前先读 revision，建立重组依赖
    fun items(role: SectionRole, date: String) = revision.let { book.items(role, date) }
    fun stats(date: String) = revision.let { book.stats(date) }
    fun days() = revision.let { book.days }
    fun progresses() = revision.let { book.progresses }
    fun progress(id: String?) = revision.let { id?.let(book::progress) }
    fun heatmap() = revision.let { book.heatmap() }
    fun streak() = revision.let { book.streak(today) }
    fun notes(date: String) = revision.let { book.notes(date) }
    fun summary(date: String) = revision.let { book.day(date)?.summary ?: "" }
    fun evening(date: String) = revision.let { book.evening(date) }
    fun missedEvening() = revision.let { book.missedEvening(today) }

    // 晚间提醒的设置（与接收器读同一份偏好）
    var reminderOn by mutableStateOf(EveningReminder.enabled(application))
        private set
    var reminderMinutes by mutableIntStateOf(EveningReminder.minutes(application))
        private set
    var dayStart by mutableIntStateOf(EveningReminder.dayStart(application))
        private set

    /** 改了一天的分界线：「今天」可能变成前一天。 */
    fun changeDayStart(minutes: Int) {
        EveningReminder.saveDayStart(getApplication(), minutes)
        MailReminder.touch(getApplication())
        applyDayStart(minutes)
        scheduleReport()
    }

    private fun applyDayStart(minutes: Int) {
        dayStart = minutes
        if (book.clock.dayStart == minutes) return
        book.clock = DayClock(dayStart = minutes)
        refreshDay()
        revision++
    }

    fun setReminder(on: Boolean, minutes: Int) {
        reminderOn = on
        reminderMinutes = minutes
        EveningReminder.save(getApplication(), on, minutes)
        MailReminder.touch(getApplication())
        scheduleReport()
    }

    // 写入
    fun addTask(text: String, date: String) = perform { book.add(BlockKind.CHECK, text, SectionRole.TODO, date) }
    fun addPlan(text: String, date: String) = perform { book.add(BlockKind.CHECK, text, SectionRole.TOMORROW, date) }
    fun addSpark(text: String, date: String) = perform { book.add(BlockKind.SPARK, text, SectionRole.SPARK, date) }
    fun toggle(id: String, checked: Boolean) = perform { book.setChecked(checked, id) }
    fun rename(id: String, text: String) = perform { if (text.isBlank()) book.delete(id) else book.setText(text.trim(), id) }
    fun delete(id: String) = perform { book.delete(id) }
    fun promote(sparkId: String) = perform { book.promote(sparkId, today) }
    fun recolor(sparkId: String, color: String) = perform { book.setAttr("color", JsonValue.str(color), sparkId) }
    fun setNotes(text: String, date: String) = perform { book.setNotes(text, date) }
    fun setSummary(text: String, date: String) = perform { book.setSummary(text, date) }
    fun updateProgress(progress: ProgressItem) = perform { book.updateProgress(progress) }
}
