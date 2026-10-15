package com.yuchuan.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/**
 * 后台传输保活前台服务。
 *
 * 为什么需要它：MainActivity 持有的 WifiLock / MulticastLock 只在 Activity 存活期间有效，
 * 且 onDestroy（配置变更、系统回收）会无条件放锁——进程一被降级，聊天连接与文件传输就断。
 * 前台服务把进程抬到「用户可见」优先级，锁也挂在服务上而不是 Activity 上，切后台、转屏、
 * Activity 被回收都不再断传输。
 *
 * 只在真有传输任务（或发件箱有待发）时启动，空闲时由 Dart 侧 stopKeepAlive() 停掉，
 * 避免通知栏常驻。
 */
class TransferService : Service() {
    private var wifiLock: WifiManager.WifiLock? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        running = true
        acquireLocks()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "雨传正在后台传输"
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: "保持连接，避免传输中断"
        ensureChannel()
        val notification = buildNotification(title, text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        // 被系统杀掉后自动重建，传输不因进程回收而永久中断
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        releaseLocks()
        super.onDestroy()
    }

    /**
     * 三把锁一起拿：
     * - WifiLock(高功耗模式)：切后台不降级 Wi-Fi，TCP 连接不断
     * - MulticastLock：省电策略不丢组播包，设备发现不断
     * - WakeLock(PARTIAL)：屏幕熄灭后 CPU 不被挂起，传输继续推进
     * 全部吞异常：拿不到锁只意味着省电优化会介入，不该让服务启动失败。
     */
    private fun acquireLocks() {
        try {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            if (wifi != null) {
                if (wifiLock?.isHeld != true) {
                    @Suppress("DEPRECATION")
                    val lock = wifi.createWifiLock(
                        WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                        "yuchuan-svc-wifi",
                    )
                    lock.setReferenceCounted(false)
                    lock.acquire()
                    wifiLock = lock
                }
                if (multicastLock?.isHeld != true) {
                    val lock = wifi.createMulticastLock("yuchuan-svc-multicast")
                    lock.setReferenceCounted(true)
                    lock.acquire()
                    multicastLock = lock
                }
            }
        } catch (e: Exception) {
            // 忽略：拿不到锁不影响服务本身
        }
        try {
            if (wakeLock?.isHeld != true) {
                val power = applicationContext
                    .getSystemService(Context.POWER_SERVICE) as? PowerManager
                if (power != null) {
                    val lock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "yuchuan-svc:cpu")
                    lock.setReferenceCounted(false)
                    lock.acquire()
                    wakeLock = lock
                }
            }
        } catch (e: Exception) {
            // 忽略
        }
    }

    private fun releaseLocks() {
        try {
            if (wifiLock?.isHeld == true) wifiLock?.release()
        } catch (e: Exception) {
        }
        wifiLock = null
        try {
            if (multicastLock?.isHeld == true) multicastLock?.release()
        } catch (e: Exception) {
        }
        multicastLock = null
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (e: Exception) {
        }
        wakeLock = null
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "后台传输",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "传输文件时保持后台连接"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(title: String, text: String): Notification {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val pending = PendingIntent.getActivity(this, 0, intent, flags)
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(pending)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "yuchuan-transfer"
        private const val NOTIFICATION_ID = 0x7C01
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_TEXT = "text"

        /** 服务是否存活。MainActivity.onDestroy 据此决定要不要放锁。 */
        @Volatile
        private var running = false

        fun isRunning(): Boolean = running

        /** 启动保活（O+ 必须走 startForegroundService，否则会抛 IllegalStateException）。 */
        fun start(context: Context, title: String, text: String) {
            val intent = Intent(context, TransferService::class.java).apply {
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_TEXT, text)
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                // 后台启动前台服务受限（Android 12+）时静默失败：
                // 宁可没有保活，也不能让调用方崩。
            }
        }

        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, TransferService::class.java))
            } catch (e: Exception) {
            }
        }
    }
}
