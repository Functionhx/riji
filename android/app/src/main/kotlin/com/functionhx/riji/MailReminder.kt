package com.functionhx.riji

import android.content.Context
import com.functionhx.riji.core.Evening
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * 邮件提醒（兜底）：通知之后仍没写，由腾讯云上的 riji-reminder 发信（见仓库 server/reminder）。与 Mac 版 MailReminder 相同：
 * 只上报今天的几个数字和邮件设置，不上报笔记内容；设置以最近一次修改为准，服务器返回最新的一份，这里照着更新。
 */
object MailReminder {
    private const val ENDPOINT = "https://fanyuchen.com.cn/riji/api/"
    const val MAX_RECIPIENTS = 5
    val delays = listOf(30, 60, 90, 120)
    private val emailPattern = Regex("^[A-Za-z0-9._%+\\-]{1,64}@[A-Za-z0-9.\\-]{1,190}\\.[A-Za-z]{2,24}$")

    data class Settings(val email: Boolean, val recipients: String, val delay: Int, val token: String)

    private fun prefs(context: Context) = context.getSharedPreferences("riji", 0)

    fun load(context: Context) = prefs(context).let {
        Settings(it.getBoolean("mail_on", false), it.getString("mail_recipients", "") ?: "", it.getInt("mail_delay", 60), it.getString("mail_token", "") ?: "")
    }

    /** 用户改动设置：保存并记下修改时间（多设备以最新的一份为准）。连接码不算设置，不参与同步。 */
    fun save(context: Context, settings: Settings, touch: Boolean = true) {
        prefs(context).edit().putBoolean("mail_on", settings.email).putString("mail_recipients", settings.recipients)
            .putInt("mail_delay", settings.delay).putString("mail_token", settings.token.trim())
            .apply { if (touch) putLong("settings_updated", System.currentTimeMillis()) }.apply()
    }

    fun touch(context: Context) { prefs(context).edit().putLong("settings_updated", System.currentTimeMillis()).apply() }

    fun parse(text: String): Pair<List<String>, List<String>> {
        val parts = text.split(Regex("[,，;；、\\s]+")).map { it.trim() }.filter { it.isNotEmpty() }.distinctBy { it.lowercase() }
        return parts.partition { emailPattern.matches(it) }
    }

    private fun settingsJson(context: Context): JSONObject {
        val s = load(context)
        return JSONObject()
            .put("email", s.email)
            .put("reminder", EveningReminder.enabled(context))
            .put("recipients", JSONArray(parse(s.recipients).first.take(MAX_RECIPIENTS)))
            .put("minutes", EveningReminder.minutes(context))
            .put("delay", s.delay)
            .put("day_start", EveningReminder.dayStart(context))
            .put("carry", EveningReminder.carryByDefault(context))
            .put("updated_at", prefs(context).getLong("settings_updated", 0))
    }

    /** 随内容一起加密同步的全部设置（含连接码），格式与 Mac 相同。 */
    fun syncedSettings(context: Context): JSONObject = settingsJson(context).put("token", load(context).token)

    fun settingsUpdated(context: Context) = prefs(context).getLong("settings_updated", 0)

    /** 同步记录比本机新：照着改（提醒、分界线、邮件、连接码）。返回是否改了。 */
    fun adoptSynced(context: Context, shared: JSONObject): Boolean {
        if (shared.optLong("updated_at", 0) <= settingsUpdated(context)) return false
        adopt(context, shared)
        shared.optString("token").takeIf { it.isNotEmpty() }?.let { token -> save(context, load(context).copy(token = token), touch = false) }
        return true
    }

    /** 配对时从 Mac 带来的设置：直接采用（这台手机还没有自己的设置）。 */
    fun adoptFromPairing(context: Context, settings: JSONObject) {
        prefs(context).edit().putLong("settings_updated", 0).apply()
        adopt(context, settings.put("updated_at", maxOf(1L, settings.optLong("updated_at", 1))))
    }

    /** 服务器上的设置比本机新：照着更新（含通知时间）。返回是否改了本机设置。 */
    private fun adopt(context: Context, server: JSONObject): Boolean {
        val updated = server.optLong("updated_at", 0)
        if (updated <= prefs(context).getLong("settings_updated", 0)) return false
        val recipients = server.optJSONArray("recipients")?.let { array -> (0 until array.length()).joinToString(", ") { array.getString(it) } } ?: ""
        prefs(context).edit()
            .putBoolean("mail_on", server.optBoolean("email"))
            .putString("mail_recipients", recipients)
            .putInt("mail_delay", server.optInt("delay", 60))
            .putLong("settings_updated", updated)
            .apply()
        if (server.has("day_start")) EveningReminder.saveDayStart(context, server.optInt("day_start"))
        if (server.has("carry")) EveningReminder.saveCarryByDefault(context, server.optBoolean("carry"))
        EveningReminder.save(context, server.optBoolean("reminder", true), server.optInt("minutes", EveningReminder.DEFAULT_MINUTES))
        return true
    }

    sealed interface Result {
        data class Ok(val message: String, val adopted: Boolean = false) : Result
        data class Failed(val message: String) : Result
    }

    /** 上报今天（在后台线程调用）。没填连接码返回 null。 */
    fun report(context: Context, device: String, date: String, evening: Evening): Result? {
        val token = load(context).token.ifEmpty { return null }
        val body = JSONObject().put("device", device).put("date", date).put("settings", settingsJson(context))
            .put("evening", JSONObject().put("has_summary", evening.hasSummary).put("plans", evening.plans)
                .put("done", evening.stats.done).put("total", evening.stats.total).put("pending", evening.pending))
        return when (val reply = post("status", token, body)) {
            is Reply.Ok -> {
                val adopted = reply.json.optJSONObject("settings")?.let { adopt(context, it) } ?: false
                Result.Ok(if (reply.json.optBoolean("smtp")) "已连接" else "已连接，但服务器上还没设置发信邮箱", adopted)
            }
            is Reply.Error -> Result.Failed(reply.message)
        }
    }

    fun sendTest(context: Context): Result {
        val token = load(context).token.ifEmpty { return Result.Failed("先填连接码") }
        return when (val reply = post("test", token, JSONObject().put("settings", settingsJson(context)))) {
            is Reply.Ok -> Result.Ok("已发出，去 ${reply.json.optInt("sent_to")} 个邮箱里看看（也看看垃圾箱）")
            is Reply.Error -> Result.Failed(reply.message)
        }
    }

    private sealed interface Reply {
        data class Ok(val json: JSONObject) : Reply
        data class Error(val message: String) : Reply
    }

    private fun post(path: String, token: String, body: JSONObject): Reply = try {
        val connection = (URL(ENDPOINT + path).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            connectTimeout = 15_000
            readTimeout = 20_000
            doOutput = true
            setRequestProperty("Content-Type", "application/json")
            setRequestProperty("Authorization", "Bearer $token")
        }
        connection.outputStream.use { it.write(body.toString().toByteArray()) }
        val code = connection.responseCode
        val text = (if (code in 200..299) connection.inputStream else connection.errorStream)?.bufferedReader()?.use { it.readText() } ?: "{}"
        val json = runCatching { JSONObject(text) }.getOrDefault(JSONObject())
        if (code == 200) Reply.Ok(json) else Reply.Error(message(json.optString("error"), code))
    } catch (e: Exception) {
        Reply.Error("连不上服务器：${e.message ?: e.javaClass.simpleName}")
    }

    private fun message(error: String, code: Int) = when (error) {
        "unauthorized" -> "连接码不对"
        "invalid" -> "有邮箱地址格式不对"
        "rate_limited" -> "今天的测试邮件发得太多了，明天再试"
        "smtp_not_configured" -> "服务器上还没设置发信邮箱"
        "no_recipients" -> "先填收件邮箱"
        "send_failed" -> "发信失败：检查服务器上的发信邮箱授权码"
        else -> "服务器返回 $code"
    }
}
