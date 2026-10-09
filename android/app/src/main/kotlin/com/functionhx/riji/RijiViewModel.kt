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

    // 同步（这台手机是配对的加入端）
    sealed interface PairState {
        data object Idle : PairState
        data object Joining : PairState
        data class Confirm(val sas: String) : PairState
        data object Done : PairState
        data class Failed(val message: String) : PairState
    }
    var syncEnabled by mutableStateOf(false)
        private set
    var syncing by mutableStateOf(false)
        private set
    var syncStatus by mutableStateOf("")
        private set
    var syncDevices by mutableIntStateOf(0)
        private set
    var lastSync by mutableStateOf<java.time.Instant?>(null)
        private set
    var pairState by mutableStateOf<PairState>(PairState.Idle)
        private set
    private var engine: com.functionhx.riji.core.SyncEngine? = null
    private var pairJob: Job? = null

    // 发起配对（这台设备已开启同步时添加另一台）
    sealed interface StartState {
        data object Idle : StartState
        data class Waiting(val code: String) : StartState
        data class Confirm(val sas: String) : StartState
        data object Done : StartState
        data class Failed(val message: String) : StartState
    }
    var startState by mutableStateOf<StartState>(StartState.Idle)
        private set
    private var starter: PairingStart? = null
    private var startJob: Job? = null
    var space by mutableStateOf<Spaces.Info?>(null)
        private set
    var invite by mutableStateOf<String?>(null)
        private set
    var notice by mutableStateOf<String?>(null)
        private set

    init {
        val prefs = application.getSharedPreferences("riji", 0)
        val device = prefs.getString("device", null) ?: "android-${UUID.randomUUID().toString().take(8)}".also {
            prefs.edit().putString("device", it).apply()
        }
        this.device = device
        val log = ChangeLog(File(application.filesDir, "riji/changes.jsonl"))
        val remote = ChangeLog(File(application.filesDir, "riji/remote-changes.jsonl"))
        book = DailyBook(RecordStore(log, device, remote), DayClock(dayStart = EveningReminder.dayStart(application)))
        book.carryByDefault = EveningReminder.carryByDefault(application)
        today = book.clock.key(Instant.now())
        selectedDate = today
        perform { book.ensureDay(today) }
        SyncKeyStore.load(application)?.let(::startSync)
        viewModelScope.launch { while (true) { delay(60_000); refreshDay(); syncNow(); checkReminder() } }
    }

    private fun startSync(key: com.functionhx.riji.core.SyncKey) {
        val token = MailReminder.load(getApplication()).token.ifEmpty { syncStatus = "缺连接码"; return }
        engine = com.functionhx.riji.core.SyncEngine(book.store, key, HttpSyncTransport(token), File(getApplication<Application>().filesDir, "riji/sync"))
        syncEnabled = true
        publishSettings()
        lastSync = engine?.lastSync
        syncStatus = if (lastSync == null) "已开启" else "已同步"
        viewModelScope.launch { space = withContext(Dispatchers.IO) { runCatching { Spaces.info(token) }.getOrNull() } }
    }

    /** 同步一轮（IO 线程）；拉回了东西就合并同一天的重复页、刷新界面。 */
    fun syncNow() {
        val engine = engine ?: return
        if (syncing) return
        syncing = true
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { runCatching { engine.sync() } }
            syncing = false
            result.onSuccess { report ->
                syncDevices = report.devices
                lastSync = engine.lastSync
                syncStatus = report.problems.firstOrNull() ?: "已同步"
                if (report.absorbed > 0) {
                    adoptSettings()
                    revision++
                    perform { book.reconcileDays() }
                    refreshDay()
                }
            }.onFailure { syncStatus = "同步失败：${it.message ?: it.javaClass.simpleName}" }
        }
    }

    // ---------------------------------------------------------------- 设置也同步（与 Mac 相同：settings:shared，最后一次修改为准）

    private fun sharedSettings(): org.json.JSONObject? =
        book.store.value(com.functionhx.riji.core.RecordType.SETTINGS, "shared")?.let { org.json.JSONObject(String(it.canonicalBytes())) }

    /** 本机设置比同步记录新（或还没有记录）：写进记录，下一轮同步带给其他设备。 */
    private fun publishSettings() {
        if (engine == null) return
        val app = getApplication<Application>()
        val local = MailReminder.syncedSettings(app)
        val shared = sharedSettings()
        if (shared != null && shared.optLong("updated_at") >= local.optLong("updated_at")) return
        perform { book.store.write(listOf(Triple(com.functionhx.riji.core.RecordType.SETTINGS, "shared", com.functionhx.riji.core.JsonValue.parse(local.toString())))) }
    }

    /** 同步记录比本机新：照着改本机设置与界面状态。 */
    private fun adoptSettings() {
        val app = getApplication<Application>()
        val shared = sharedSettings() ?: return
        if (!MailReminder.adoptSynced(app, shared)) return
        mail = MailReminder.load(app)
        reminderOn = EveningReminder.enabled(app)
        reminderMinutes = EveningReminder.minutes(app)
        applyDayStart(EveningReminder.dayStart(app))
        applyCarryByDefault(EveningReminder.carryByDefault(app))
    }

    // ---------------------------------------------------------------- 第一台设备 / 邀请 / 删除空间

    /** 这台设备是空间里的第一台：生成日迹密钥、开启同步（需要连接码）。 */
    fun enableAsFirst() {
        val app = getApplication<Application>()
        if (MailReminder.load(app).token.isEmpty()) { notice = "先填连接码，或用邀请码加入"; return }
        val key = com.functionhx.riji.core.SyncKey.generate()
        SyncKeyStore.save(app, key)
        startSync(key)
        syncNow()
    }

    /** 朋友：用邀请码建自己的空间，拿到连接码，这台设备生成自己的密钥。 */
    fun joinWithInvite(code: String) {
        notice = null
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { runCatching { Spaces.redeem(code) } }
            result.onSuccess { token ->
                val app = getApplication<Application>()
                MailReminder.save(app, MailReminder.load(app).copy(token = token), touch = false)
                mail = MailReminder.load(app)
                enableAsFirst()
                notice = "已加入：这是你自己的空间，内容只有你的设备解得开"
            }.onFailure { notice = it.message }
        }
    }

    fun createInvite() {
        notice = null
        viewModelScope.launch {
            withContext(Dispatchers.IO) { runCatching { Spaces.invite(mail.token) } }
                .onSuccess { invite = it }.onFailure { notice = it.message }
        }
    }

    /** 删除服务器上的这个空间；本机的笔记保留。 */
    fun deleteSpace() {
        notice = null
        viewModelScope.launch {
            val app = getApplication<Application>()
            withContext(Dispatchers.IO) { runCatching { Spaces.delete(mail.token) } }
                .onSuccess {
                    engine = null
                    syncEnabled = false
                    space = null
                    File(app.filesDir, "riji/sync-key.json").delete()
                    File(app.filesDir, "riji/sync").deleteRecursively()
                    MailReminder.save(app, MailReminder.load(app).copy(token = ""), touch = false)
                    mail = MailReminder.load(app)
                    notice = "服务器上的空间已删除；这台手机上的笔记还在"
                }.onFailure { notice = it.message }
        }
    }

    // ---------------------------------------------------------------- 配对（发起端）

    fun startPairing() {
        startJob?.cancel()
        val token = mail.token
        startJob = viewModelScope.launch {
            val pairing = PairingStart(token)
            starter = pairing
            val code = withContext(Dispatchers.IO) { runCatching { pairing.start() } }.getOrElse { startState = StartState.Failed(it.message ?: "配对失败"); return@launch }
            startState = StartState.Waiting(code)
            val deadline = System.currentTimeMillis() + 600_000
            while (System.currentTimeMillis() < deadline) {
                delay(1_500)
                val sas = withContext(Dispatchers.IO) { runCatching { pairing.poll() } }.getOrElse { startState = StartState.Failed(it.message ?: "配对失败"); return@launch }
                    ?: continue
                startState = StartState.Confirm(sas)
                return@launch
            }
            startState = StartState.Failed("配对码已过期")
        }
    }

    /** 站长确认两边比对码一致：把日迹密钥、连接码与全部设置封进信封。 */
    fun confirmPairing() {
        val pairing = starter ?: return
        val app = getApplication<Application>()
        val key = SyncKeyStore.load(app) ?: return
        val payload = com.functionhx.riji.core.JsonValue.obj(
            "key" to com.functionhx.riji.core.JsonValue.str(com.functionhx.riji.core.Base64Url.encode(key.key)),
            "epoch" to com.functionhx.riji.core.JsonValue.num(key.epoch),
            "token" to com.functionhx.riji.core.JsonValue.str(mail.token),
            "settings" to com.functionhx.riji.core.JsonValue.parse(MailReminder.syncedSettings(app).toString()),
        )
        viewModelScope.launch {
            withContext(Dispatchers.IO) { runCatching { pairing.seal(payload) } }
                .onSuccess { startState = StartState.Done }.onFailure { startState = StartState.Failed(it.message ?: "发送失败") }
        }
    }

    fun cancelStart() { startJob?.cancel(); starter = null; startState = StartState.Idle }

    fun joinPairing(code: String) {
        val digits = code.filter(Char::isDigit)
        if (digits.length != 8) { pairState = PairState.Failed("配对码是 8 位数字"); return }
        pairJob?.cancel()
        pairState = PairState.Joining
        pairJob = viewModelScope.launch {
            val join = PairingJoin(digits)
            val sas = withContext(Dispatchers.IO) { runCatching { join.join() } }.getOrElse { pairState = PairState.Failed(it.message ?: "配对失败"); return@launch }
            pairState = PairState.Confirm(sas)
            val deadline = System.currentTimeMillis() + 600_000
            while (System.currentTimeMillis() < deadline) {
                delay(1_500)
                val payload = withContext(Dispatchers.IO) { runCatching { join.fetch() } }.getOrElse { pairState = PairState.Failed(it.message ?: "配对失败"); return@launch }
                    ?: continue
                adoptPairing(payload)
                return@launch
            }
            pairState = PairState.Failed("等太久了，配对码已过期")
        }
    }

    fun cancelPairing() { pairJob?.cancel(); pairState = PairState.Idle }

    /** 信封里的日迹密钥、连接码与提醒设置。 */
    private fun adoptPairing(payload: com.functionhx.riji.core.JsonValue) {
        val app = getApplication<Application>()
        val key = PairingJoin.keyFrom(payload) ?: run { pairState = PairState.Failed("信封里没有密钥"); return }
        payload["token"]?.string?.let { token -> MailReminder.save(app, MailReminder.load(app).copy(token = token), touch = false) }
        payload["settings"]?.let { settings ->
            runCatching { MailReminder.adoptFromPairing(app, org.json.JSONObject(String(settings.canonicalBytes()))) }
        }
        mail = MailReminder.load(app)
        reminderOn = EveningReminder.enabled(app)
        reminderMinutes = EveningReminder.minutes(app)
        applyDayStart(EveningReminder.dayStart(app))
        applyCarryByDefault(EveningReminder.carryByDefault(app))
        SyncKeyStore.save(app, key)
        startSync(key)
        pairState = PairState.Done
        syncNow()
        scheduleReport()
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
        scheduleSync()
    }

    private var syncJob: Job? = null

    /** 内容变了：几秒后同步一轮（连续修改只同步最后一次）。 */
    private fun scheduleSync() {
        if (engine == null) return
        syncJob?.cancel()
        syncJob = viewModelScope.launch { delay(3_000); syncNow() }
    }

    /** 日迹开着时：到了提醒时间还缺东西就弹一次通知。 */
    fun checkReminder() = EveningReminder.notifyIfDue(getApplication(), book, today)

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
        publishSettings()
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
    var carryByDefault by mutableStateOf(EveningReminder.carryByDefault(application))
        private set

    fun changeCarryByDefault(carry: Boolean) {
        EveningReminder.saveCarryByDefault(getApplication(), carry)
        MailReminder.touch(getApplication())
        applyCarryByDefault(carry)
        publishSettings()
        scheduleReport()
    }

    private fun applyCarryByDefault(carry: Boolean) {
        carryByDefault = carry
        if (book.carryByDefault == carry) return
        book.carryByDefault = carry
        perform { book.ensureDay(today) }
    }

    fun setCarry(id: String, carry: Boolean) = perform { book.setCarry(carry, id) }
    fun willCarry(item: com.functionhx.riji.core.Block) = revision.let { book.willCarry(item) }

    /** 改了一天的分界线：「今天」可能变成前一天。 */
    fun changeDayStart(minutes: Int) {
        EveningReminder.saveDayStart(getApplication(), minutes)
        MailReminder.touch(getApplication())
        applyDayStart(minutes)
        publishSettings()
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
        publishSettings()
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
