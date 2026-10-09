package com.functionhx.riji

import android.Manifest
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels

class MainActivity : ComponentActivity() {
    private val model: RijiViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        if (intent.getBooleanExtra("riji_demo", false)) model.seedDemoIfEmpty()
        // 晚间提醒：先要通知权限（Android 13+），然后排好每晚 22:30 的本地闹钟。
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { EveningReminder.schedule(this) }
            .launch(Manifest.permission.POST_NOTIFICATIONS)
        setContent {
            RijiTheme { RijiApp(model) }
        }
    }

    override fun onResume() {
        super.onResume()
        model.refreshDay()
        model.scheduleReport()
        model.syncNow()
    }
}
