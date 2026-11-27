package org.localsend.localsend_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Foreground service that keeps the app process (and thus the LocalSend receive server
 * running in the Dart engine) alive while the activity is in the background.
 *
 * This is mainly for Android TV, where the App should receive files without being opened
 * explicitly: after boot, [BootReceiver] relaunches the activity as a background task and
 * this service pins the process so OEM task killers leave it alone.
 *
 * While the service runs it also holds three network locks (TV only):
 * - a multicast lock, so the WiFi driver keeps delivering the UDP discovery packets
 *   even in power-save mode (without it, devices "vanish" from the sender once the
 *   app is not visible),
 * - a high-perf WiFi lock, keeping the radio responsive,
 * - a partial wake lock, keeping the CPU up when the screen turns off / standby kicks in,
 *   so the HTTP server still answers.
 *
 * When the activity is visible the service keeps running as well: stopping it on
 * [MainActivity.onStart] left gaps where discovery packets were dropped again, so it
 * now stays resident from app start until keep-alive is disabled in the settings
 * (or the activity is destroyed).
 */
class KeepAliveService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        isRunning = true
        startInForeground()
        ensureNetworkLocks(this)
        log(this, "onStartCommand src=${describeIntent(intent)} fgs=true")

        // BOOT_COMPLETED may arrive before the system is ready to start activities,
        // and some TV ROMs silently drop the attempt made by [BootReceiver]. Retry
        // once from here, but never steal the foreground from an already visible app.
        val fromBoot = intent?.getBooleanExtra(EXTRA_FROM_BOOT, false) == true
        // A null intent means the process was killed and the sticky service was
        // restarted: the Dart engine (and with it the receive server) is gone, so
        // the activity has to be relaunched to bring the server back up.
        if (isTv(this) && !bootRetryScheduled && (fromBoot || intent == null)) {
            bootRetryScheduled = true
            Handler(Looper.getMainLooper()).postDelayed({
                bootRetryScheduled = false
                if (isRunning && !MainActivity.activityInForeground) {
                    try {
                        val launch = Intent(this, MainActivity::class.java)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(launch)
                    } catch (e: Exception) {
                        // Background activity start blocked; the user can open the app manually.
                    }
                }
            }, if (fromBoot) BOOT_ACTIVITY_RETRY_MS else PROCESS_RESTART_RETRY_MS)
        }
        return START_STICKY
    }

    override fun onDestroy() {
        isRunning = false
        bootRetryScheduled = false
        log(this, "onDestroy")
        releaseNetworkLocks()
        super.onDestroy()
    }

    private fun startInForeground() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_MIN)
            manager.createNotificationChannel(channel)
        }

        val notification: Notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle(NOTIFICATION_TITLE)
                .setContentText("LocalSend")
                .setOngoing(true)
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle(NOTIFICATION_TITLE)
                .setContentText("LocalSend")
                .setOngoing(true)
                .build()
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            // dataSync cannot be started from BOOT_COMPLETED on Android 15+; specialUse can.
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    companion object {
        const val CHANNEL_ID = "localsend_keep_alive"
        const val CHANNEL_NAME = "LocalSend 常驻服务"
        const val NOTIFICATION_TITLE = "LocalSend 常驻服务"
        const val NOTIFICATION_ID = 4712
        const val EXTRA_FROM_BOOT = "from_boot"
        const val BOOT_ACTIVITY_RETRY_MS = 8000L
        const val PROCESS_RESTART_RETRY_MS = 5000L

        /**
         * Called by the TV IME when its panel becomes available. The receiver
         * service owns the process/network locks, so the IME must only ensure
         * that it is started and must never stop it when the panel disappears.
         */
        fun startForIme(context: Context) {
            if (isRunning) {
                return
            }
            start(context)
        }
        private const val PREF_NAME = "FlutterSharedPreferences"
        private const val PREF_KEY = "flutter.ls_keep_alive"

        /// Whether the TV-specific network locks are relevant (leanback devices only,
        /// so phones keep the upstream behavior and battery profile).
        fun isTv(context: Context): Boolean {
            return context.packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
        }

        // ---- diagnostics state (read via the "keepAliveStatus" method channel) ----
        @Volatile
        var isRunning: Boolean = false
            private set

        @Volatile
        var multicastHeld: Boolean = false
            private set

        @Volatile
        var wakeHeld: Boolean = false
            private set

        @Volatile
        var wifiHeld: Boolean = false
            private set

        @Volatile
        private var bootRetryScheduled: Boolean = false

        @Volatile
        private var multicastLock: WifiManager.MulticastLock? = null

        @Volatile
        private var wakeLock: PowerManager.WakeLock? = null

        @Volatile
        private var wifiLock: WifiManager.WifiLock? = null

        /// Acquires the multicast / wake / wifi locks (TV only, idempotent).
        /// They keep discovery and transfers working while the app is in the
        /// background, screen off or in standby. A failing lock is never fatal:
        /// receiving still works with the remaining locks (and on the foreground
        /// screen without any of them).
        fun ensureNetworkLocks(context: Context) {
            if (!isTv(context)) {
                return
            }
            val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            if (multicastLock == null && wifi != null) {
                runCatching {
                    val lock = wifi.createMulticastLock("localsend_multicast")
                    lock.setReferenceCounted(false)
                    lock.acquire()
                    multicastLock = lock
                }
                multicastHeld = multicastLock?.isHeld == true
                log(context, "multicastLock held=$multicastHeld")
            }
            val pm = context.applicationContext.getSystemService(Context.POWER_SERVICE) as? PowerManager
            if (wakeLock == null && pm != null) {
                runCatching {
                    val lock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "localsend:keep_alive")
                    lock.setReferenceCounted(false)
                    lock.acquire()
                    wakeLock = lock
                }
                wakeHeld = wakeLock?.isHeld == true
                log(context, "wakeLock held=$wakeHeld")
            }
            if (wifiLock == null && wifi != null) {
                runCatching {
                    val lock = wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "localsend_wifi")
                    lock.setReferenceCounted(false)
                    lock.acquire()
                    wifiLock = lock
                }
                wifiHeld = wifiLock?.isHeld == true
                log(context, "wifiLock held=$wifiHeld")
            }
        }

        /// Releases all network locks; called when the service stops (app foreground).
        fun releaseNetworkLocks() {
            runCatching { multicastLock?.release() }
            runCatching { wakeLock?.release() }
            runCatching { wifiLock?.release() }
            multicastLock = null
            wakeLock = null
            wifiLock = null
            multicastHeld = false
            wakeHeld = false
            wifiHeld = false
        }

        /// Appends a timestamped line to keepalive.log in the app's external files
        /// directory (USB-visible on many TVs). Used to diagnose why background
        /// receiving failed: a gap in timestamps means the process was killed, a
        /// continuous log with failed transfers means the process lived but the
        /// network path was broken. Never throws; logging failures are ignored.
        fun log(context: Context, message: String) {
            try {
                val dir = context.getExternalFilesDir(null) ?: return
                logDir = dir
                val file = File(dir, LOG_FILE_NAME)
                val stamp = SimpleDateFormat("MM-dd HH:mm:ss", Locale.US).format(Date())
                file.appendText("[$stamp] $message\n")
                // Keep the file small: rewrite with only the newest lines once it grows.
                val lines = file.readLines()
                if (lines.size > LOG_MAX_LINES) {
                    file.writeText(lines.takeLast(LOG_MAX_LINES / 2).joinToString(separator = "", postfix = "\n"))
                }
            } catch (e: Exception) {
                // Diagnostic logging only; ignore any failure.
            }
        }

        /// Last lines of the log, surfaced through the keepAliveStatus channel and
        /// shown on the TV debug line so the user can screenshot the state.
        fun logTail(): String {
            return try {
                val dir = logDir ?: return ""
                val file = File(dir, LOG_FILE_NAME)
                if (!file.exists()) "" else file.readLines().takeLast(LOG_TAIL_LINES).joinToString("\n")
            } catch (e: Exception) {
                ""
            }
        }

        @Volatile
        private var logDir: File? = null

        private const val LOG_FILE_NAME = "keepalive.log"
        private const val LOG_MAX_LINES = 200
        private const val LOG_TAIL_LINES = 8

        fun describeIntent(intent: Intent?): String = when {
            intent == null -> "restart(sticky)"
            intent.getBooleanExtra(EXTRA_FROM_BOOT, false) -> "boot"
            else -> "start"
        }

        /// Starts the service only when the user did not disable keep-alive in the app settings.
        /// The preference is stored by the shared_preferences plugin; reading it natively keeps
        /// the native lifecycle hooks in sync with the Dart-side toggle.
        fun maybeStart(context: Context, fromBoot: Boolean = false) {
            val prefs = context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            val enabled = prefs.getBoolean(PREF_KEY, true)
            if (!enabled) {
                return
            }
            start(context, fromBoot)
        }

        fun start(context: Context, fromBoot: Boolean = false) {
            val intent = Intent(context, KeepAliveService::class.java)
            if (fromBoot) {
                intent.putExtra(EXTRA_FROM_BOOT, true)
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                // Starting from the background is restricted; if this fails the app can still
                // run while the user keeps it open.
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, KeepAliveService::class.java))
        }
    }
}
