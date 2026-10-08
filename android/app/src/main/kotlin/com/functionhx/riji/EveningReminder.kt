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
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId

/**
 * 每晚 22:30 的本地提醒。不依赖谷歌推送（荣耀国行机没有 GMS），用系统闹钟；
 * 允许在低电耗模式下触发、但不要求「精确闹钟」权限，所以可能有几分钟的偏差。
 * 触发后排下一天；开机后重新排。
 */
class EveningReminder : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == ACTION_FIRE) notify(context)
        schedule(context)
    }

    companion object {
        private const val ACTION_FIRE = "com.functionhx.riji.EVENING"
        private const val CHANNEL = "evening"
        private val TIME: LocalTime = LocalTime.of(22, 30)

        fun schedule(context: Context) {
            val zone = ZoneId.of("Asia/Shanghai")
            val now = java.time.ZonedDateTime.now(zone)
            var next = LocalDate.now(zone).atTime(TIME).atZone(zone)
            if (!next.isAfter(now)) next = next.plusDays(1)
            val pending = PendingIntent.getBroadcast(
                context, 0, Intent(context, EveningReminder::class.java).setAction(ACTION_FIRE),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            context.getSystemService(AlarmManager::class.java)
                .setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next.toInstant().toEpochMilli(), pending)
        }

        private fun notify(context: Context) {
            if (ContextCompat.checkSelfPermission(context, android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "晚间总结", NotificationManager.IMPORTANCE_DEFAULT))
            val open = PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
            val notification = NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_launcher_foreground)
                .setContentTitle("今晚总结")
                .setContentText("今天过得怎么样？花一分钟勾掉做完的事，写一句话。")
                .setContentIntent(open)
                .setAutoCancel(true)
                .build()
            manager.notify(1, notification)
        }
    }
}
