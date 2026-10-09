package com.functionhx.riji

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.functionhx.riji.core.ChangeLog
import com.functionhx.riji.core.DailyBook
import com.functionhx.riji.core.Evening
import com.functionhx.riji.core.RecordStore
import java.io.File
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZonedDateTime

/**
 * 晚间提醒：到点时读一眼今天的页面，只在今日总结或明日目标还空着时提醒，并且只提缺的那一样。
 * 不依赖谷歌推送（荣耀国行机没有 GMS），用系统精确闹钟（低电耗模式下也准点）；精确闹钟被系统收回时
 * 退回普通闹钟，可能晚到一小时以内。触发后排下一天；开机后、改设置后重新排。时间与开关在偏好设置里。
 */
class EveningReminder : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == ACTION_FIRE && enabled(context)) {
            val nudge = runCatching { todayEvening(context)?.nudge }.getOrElse { Evening.Nudge("今晚总结", "用一句话记下今天，再定下明天要做的事。") }
            if (nudge != null) notify(context, nudge)
        }
        schedule(context)
    }

    companion object {
        private const val ACTION_FIRE = "com.functionhx.riji.EVENING"
        private const val CHANNEL = "evening"
        private const val KEY_ON = "reminder_on"
        private const val KEY_MINUTES = "reminder_minutes"
        const val DEFAULT_MINUTES = 22 * 60 + 30
        private val zone: ZoneId = ZoneId.of("Asia/Shanghai")

        fun enabled(context: Context) = context.getSharedPreferences("riji", 0).getBoolean(KEY_ON, true)
        fun minutes(context: Context) = context.getSharedPreferences("riji", 0).getInt(KEY_MINUTES, DEFAULT_MINUTES)
        /** 一天的分界线（零点后的分钟数），默认凌晨 4 点。 */
        fun dayStart(context: Context) = context.getSharedPreferences("riji", 0).getInt("day_start", com.functionhx.riji.core.DayClock.SUGGESTED_DAY_START)
        fun saveDayStart(context: Context, minutes: Int) { context.getSharedPreferences("riji", 0).edit().putInt("day_start", minutes).apply() }

        fun save(context: Context, on: Boolean, minutes: Int) {
            context.getSharedPreferences("riji", 0).edit().putBoolean(KEY_ON, on).putInt(KEY_MINUTES, minutes).apply()
            schedule(context)
        }

        fun label(minutes: Int) = "%02d:%02d".format(minutes / 60, minutes % 60)

        fun schedule(context: Context) {
            val pending = PendingIntent.getBroadcast(
                context, 0, Intent(context, EveningReminder::class.java).setAction(ACTION_FIRE),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val alarms = context.getSystemService(AlarmManager::class.java)
            if (!enabled(context)) { alarms.cancel(pending); return }
            val minutes = minutes(context)
            val now = ZonedDateTime.now(zone)
            var next = LocalDate.now(zone).atStartOfDay(zone).plusMinutes(minutes.toLong())
            if (!next.isAfter(now)) next = next.plusDays(1)
            val at = next.toInstant().toEpochMilli()
            if (alarms.canScheduleExactAlarms()) alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
            else alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
        }

        /** 只读：打开本机日志看今天写了什么（不生成页面、不写入）。 */
        private fun todayEvening(context: Context): Evening? {
            val file = File(context.filesDir, "riji/changes.jsonl")
            if (!file.exists()) return null
            val device = context.getSharedPreferences("riji", 0).getString("device", null) ?: "android-reminder"
            val remote = ChangeLog(File(context.filesDir, "riji/remote-changes.jsonl"))
            val book = DailyBook(RecordStore(ChangeLog(file), device, remote), com.functionhx.riji.core.DayClock(dayStart = dayStart(context)))
            return book.evening(book.clock.key(Instant.now()))
        }

        private fun notify(context: Context, nudge: Evening.Nudge) {
            if (ContextCompat.checkSelfPermission(context, android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "晚间总结", NotificationManager.IMPORTANCE_DEFAULT))
            val open = PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
            val notification = NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_notify)
                .setContentTitle(nudge.title)
                .setContentText(nudge.body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(nudge.body))
                .setContentIntent(open)
                .setAutoCancel(true)
                .build()
            manager.notify(1, notification)
        }
    }
}
