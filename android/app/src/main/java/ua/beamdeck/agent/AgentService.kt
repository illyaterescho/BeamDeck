package ua.beamdeck.agent

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import org.json.JSONObject
import java.util.concurrent.Executors

class AgentService : Service() {
    internal lateinit var sessions: Sessions
        private set
    private lateinit var controls: ProjectorControls
    internal lateinit var geometryController: GeometryController
        private set
    private lateinit var projector: SystemProjectorController
    internal lateinit var shell: ShellBridge
        private set
    internal lateinit var router: CommandRouter
        private set
    internal var ble: BleLink? = null
        private set
    private var ticks = 0
    private val main = Handler(Looper.getMainLooper())
    private val networkCheck = Runnable { monitorNetwork() }
    private val sleepCheck = Runnable { expireSleep() }
    private val alarm by lazy { getSystemService(AlarmManager::class.java) }
    private val sleepIntent by lazy {
        PendingIntent.getBroadcast(this, 8, Intent(this, SleepAlarmReceiver::class.java), PendingIntent.FLAG_IMMUTABLE)
    }
    private var initialized = false
    private var generation = 0
    private var desiredLan: Lan? = null
    private var server: LocalServer? = null // Owned by serverThread.
    private var sleepDeadline: Long? = null
    private var sleepOutcome = "idle"
    internal var listeningOn: Lan? = null
        private set
    internal var message = "Під’єднайте проєктор до Wi-Fi або Ethernet."
        private set

    override fun onCreate() {
        super.onCreate()
        sessions = Sessions(this)
        geometryController = GeometryController(this)
        projector = SystemProjectorController(this)
        controls = ProjectorControls(this)
        shell = ShellBridge(this)
        router = CommandRouter(controls, projector, geometryController, InputEngine(this, shell)) {
            JSONObject().put("ble", ble?.state ?: "off").put("bleClients", ble?.connected ?: 0)
                .put("lan", listeningOn?.url ?: JSONObject.NULL)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (initialized) return START_NOT_STICKY
        try {
            val notification = notification()
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (_: RuntimeException) {
            lastProblem = "Android відхилив запуск сервера. Відкрийте Agent і спробуйте ще раз."
            stopSelf()
            return START_NOT_STICKY
        }
        initialized = true
        lastProblem = null
        sessions.rotate()
        current = this
        ble = BleLink(this, sessions) { router }.also { it.start() }
        shell.probe()
        monitorNetwork()
        return START_NOT_STICKY
    }

    private fun notification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "Локальний пульт", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 1, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 2, Intent(this, AgentService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.agent_icon)
            .setContentTitle("BeamDeck Agent")
            .setContentText("Сервер локального пульта ввімкнено")
            .setContentIntent(open)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, "Зупинити", stop).build())
            .build()
    }

    private fun monitorNetwork() {
        val lan = runCatching { Lan.find(this) }.getOrNull()
        if (lan != desiredLan) switchNetwork(lan)
        // Re-check loopback adb every ~10 s until the user has accepted the RSA prompt.
        if (++ticks % 5 == 0 && shell.state != ShellBridge.State.Ready) shell.probe()
        main.postDelayed(networkCheck, 2_000)
    }

    private fun switchNetwork(lan: Lan?) {
        val request = ++generation
        desiredLan = lan
        listeningOn = null
        message = if (lan == null) "Під’єднайте проєктор до Wi-Fi або Ethernet з локальною IPv4-адресою."
            else "Запускаємо сервер…"
        serverThread.execute {
            runCatching { server?.stop() }
            server = null
            val ready = lan != null && runCatching {
                val candidate = LocalServer(lan, assets, sessions, controls, geometryController, projector, router, shell)
                try {
                    candidate.start()
                    server = candidate
                } catch (problem: Exception) {
                    runCatching { candidate.stop() }
                    throw problem
                }
            }.isSuccess
            main.post {
                if (generation != request || current !== this) return@post
                if (ready) {
                    listeningOn = lan
                    message = "Сервер працює"
                } else if (lan != null) {
                    message = "Сервер не відкрив порт ${Lan.PORT}. Вимкніть його й спробуйте ще раз."
                }
            }
        }
    }

    internal fun scheduleSleep(minutes: Int) {
        if (minutes == 0) {
            alarm.cancel(sleepIntent)
            main.removeCallbacks(sleepCheck)
            sleepDeadline = null
            sleepOutcome = "idle"
            return
        }
        val duration = minutes * 60_000L
        val deadline = SystemClock.elapsedRealtime() + duration
        alarm.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, deadline, sleepIntent)
        main.removeCallbacks(sleepCheck)
        sleepDeadline = deadline
        sleepOutcome = "scheduled"
        main.postDelayed(sleepCheck, duration)
    }

    internal fun expireSleep() {
        val deadline = sleepDeadline ?: return
        if (SystemClock.elapsedRealtime() < deadline) return
        sleepDeadline = null
        main.removeCallbacks(sleepCheck)
        alarm.cancel(sleepIntent)
        sleepOutcome = controls.sleepEffects()
    }

    internal fun sleepStatus(): JSONObject {
        val remaining = sleepDeadline?.let { (it - SystemClock.elapsedRealtime()).coerceAtLeast(0) }
        return JSONObject().put("remainingMs", remaining ?: JSONObject.NULL).put("outcome", sleepOutcome)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        if (current === this) current = null
        if (initialized) {
            main.removeCallbacksAndMessages(null)
            scheduleSleep(0)
            switchNetwork(null)
            ble?.stop()
            ble = null
            shell.close()
        }
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    companion object {
        internal var current: AgentService? = null
            private set
        internal var lastProblem: String? = null
        private val serverThread = Executors.newSingleThreadExecutor()
        private const val ACTION_STOP = "ua.beamdeck.agent.STOP"
        private const val CHANNEL = "beamdeck_lan"
        private const val NOTIFICATION_ID = 27
    }
}
