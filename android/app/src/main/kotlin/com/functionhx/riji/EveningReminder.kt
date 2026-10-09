package com.functionhx.riji

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.functionhx.riji.core.DailyBook
import java.time.Instant

/**
 * 晚间通知：只在日迹开着时弹（不用系统闹钟，不需要自启动或后台运行）。到了提醒时间、今日总结或明日目标还空着，
 * 就弹一次，只提缺的那一样；一天最多一次。日迹没开着时由服务器按兜底时间发邮件（MailReminder）。
 */
object EveningReminder {
    private const val CHANNEL = "evening"
    private const val KEY_ON = "reminder_on"
    private const val KEY_MINUTES = "reminder_minutes"
    const val DEFAULT_MINUTES = 22 * 60 + 30

    fun enabled(context: Context) = context.getSharedPreferences("riji", 0).getBoolean(KEY_ON, true)
    fun minutes(context: Context) = context.getSharedPreferences("riji", 0).getInt(KEY_MINUTES, DEFAULT_MINUTES)
    /** 一天的分界线（零点后的分钟数），默认凌晨 4 点。 */
    fun dayStart(context: Context) = context.getSharedPreferences("riji", 0).getInt("day_start", com.functionhx.riji.core.DayClock.SUGGESTED_DAY_START)
    fun saveDayStart(context: Context, minutes: Int) { context.getSharedPreferences("riji", 0).edit().putInt("day_start", minutes).apply() }
    /** 没做完的事默认是否带到明天（每件事可以单独选），默认不带。 */
    fun carryByDefault(context: Context) = context.getSharedPreferences("riji", 0).getBoolean("carry_default", false)
    fun saveCarryByDefault(context: Context, carry: Boolean) { context.getSharedPreferences("riji", 0).edit().putBoolean("carry_default", carry).apply() }

    fun save(context: Context, on: Boolean, minutes: Int) {
        context.getSharedPreferences("riji", 0).edit().putBoolean(KEY_ON, on).putInt(KEY_MINUTES, minutes).apply()
    }

    fun label(minutes: Int) = "%02d:%02d".format(minutes / 60, minutes % 60)

    /** 旧版用系统闹钟排过提醒：取消掉（接收器已经删了，留着只会空转）。 */
    fun cancelLegacyAlarm(context: Context) {
        val intent = Intent("com.functionhx.riji.EVENING").setComponent(ComponentName(context, "com.functionhx.riji.EveningReminder"))
        PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE)?.let {
            context.getSystemService(AlarmManager::class.java).cancel(it)
            it.cancel()
        }
    }

    /** 应用开着时每分钟、以及内容变化后调用。 */
    fun notifyIfDue(context: Context, book: DailyBook, today: String, now: Instant = Instant.now()) {
        val prefs = context.getSharedPreferences("riji", 0)
        if (!enabled(context) || prefs.getString("notified", null) == today) return
        if (now.isBefore(book.clock.instant(minutes(context), today))) return
        val nudge = book.evening(today).nudge ?: return
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
        prefs.edit().putString("notified", today).apply()
    }
}
