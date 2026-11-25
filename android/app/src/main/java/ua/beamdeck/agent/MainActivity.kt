package ua.beamdeck.agent

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.google.zxing.BarcodeFormat
import com.google.zxing.MultiFormatWriter
import java.lang.ref.WeakReference

/** Receiver home screen on the projector, laid out like a tvOS settings pane. */
class MainActivity : Activity() {
    private val main = Handler(Looper.getMainLooper())
    private val refresh = object : Runnable {
        override fun run() { render(); main.postDelayed(this, 1000) }
    }
    private lateinit var pinText: TextView
    private lateinit var pinHint: TextView
    private lateinit var linkText: TextView
    private lateinit var qr: ImageView
    private lateinit var serverRow: Row
    private val status = LinkedHashMap<String, Row>()
    private var qrUrl: String? = null

    private class Row(val view: LinearLayout, val title: TextView, val detail: TextView, val dot: View)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.decorView.setBackgroundColor(BACKGROUND)
        // Show the previous crash before building anything that might crash again.
        val crash = BeamDeckApplication.crashFile(this)
        if (crash.isFile) { showCrash(crash.readText()); return }
        try {
            buildScreen()
        } catch (error: Throwable) {
            showCrash("Помилка під час відкриття екрана\n\n" + android.util.Log.getStackTraceString(error))
        }
    }

    private fun buildScreen() {
        val wide = resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
        val root = LinearLayout(this).apply {
            orientation = if (wide) LinearLayout.HORIZONTAL else LinearLayout.VERTICAL
            setPadding(dp(48), dp(36), dp(48), dp(36))
        }

        val left = column()
        left.addView(text("BeamDeck", 34, LABEL, Typeface.BOLD))
        left.addView(text("${Build.MANUFACTURER} ${Build.MODEL} · Android ${Build.VERSION.RELEASE}", 15, SECONDARY), gap(4))
        val card = column().apply {
            background = rounded(GROUPED, 22)
            setPadding(dp(24), dp(20), dp(24), dp(22))
        }
        card.addView(text("Код підключення", 13, SECONDARY, Typeface.BOLD))
        pinText = text("— — —", 54, LABEL, Typeface.BOLD).apply {
            typeface = Typeface.create("sans-serif", Typeface.BOLD)
            letterSpacing = 0.12f
        }
        card.addView(pinText, gap(2))
        pinHint = text("", 14, SECONDARY)
        card.addView(pinHint)
        qr = ImageView(this).apply {
            contentDescription = "QR-код вебпульта"
            scaleType = ImageView.ScaleType.FIT_CENTER
            background = rounded(Color.WHITE, 14)
            setPadding(dp(8), dp(8), dp(8), dp(8))
            visibility = View.GONE
        }
        card.addView(qr, LinearLayout.LayoutParams(dp(148), dp(148)).apply { topMargin = dp(18) })
        linkText = text("", 15, SECONDARY)
        card.addView(linkText, gap(10))
        left.addView(card, gap(22))
        left.addView(text("iPhone: відкрийте BeamDeck і виберіть цей проєктор. Браузер: відскануйте QR-код.", 14, SECONDARY), gap(14))

        val right = column()
        right.addView(header("Стан"))
        val stateGroup = group()
        for ((key, title) in listOf(
            "ble" to "Bluetooth", "lan" to "Wi-Fi", "adb" to "Системні кнопки (ADB)",
            "nav" to "Навігація", "keyboard" to "Клавіатура", "media" to "Медіа",
        )) status[key] = row(stateGroup, title, true) { open(key) }
        right.addView(stateGroup)
        right.addView(header("Дії"), gap(22))
        val actions = group()
        serverRow = row(actions, "Вимкнути приймач", false) { toggleServer() }
        row(actions, "Новий код", false) { AgentService.current?.sessions?.rotate(); render() }
        row(actions, "Завершити всі сеанси", false) {
            runCatching { AgentService.current?.sessions?.clear() }
            render()
        }
        row(actions, getString(R.string.open_grid), false) { cinema("grid") }
        row(actions, getString(R.string.open_player), false) { cinema("player") }
        row(actions, "Екран iPhone", false) { MirrorActivity.open(this) }
        row(actions, autostartTitle(), false) {
            val enabled = !BootReceiver.enabled(this)
            BootReceiver.setEnabled(this, enabled)
            (it.getChildAt(1) as? LinearLayout)?.let { body -> (body.getChildAt(0) as TextView).text = autostartTitle() }
        }
        right.addView(actions)

        if (wide) {
            root.addView(left, LinearLayout.LayoutParams(0, -2, 0.95f).apply { marginEnd = dp(40) })
            root.addView(right, LinearLayout.LayoutParams(0, -2, 1.05f))
        } else {
            root.addView(left)
            root.addView(right, gap(28))
        }
        setContentView(ScrollView(this).apply { isFillViewport = true; addView(root) })
        // Permissions are asked only from the Bluetooth row: some TV firmwares open an invisible
        // permission window on launch that swallows the remote, which looks like the app never opened.
        ensureServer()
        render()
        status.getValue("ble").view.requestFocus()
    }

    override fun onResume() {
        super.onResume()
        foregroundActivity = WeakReference(this)
        if (::pinText.isInitialized) main.post(refresh)
    }

    override fun onPause() {
        if (foreground === this) foregroundActivity.clear()
        main.removeCallbacksAndMessages(null)
        super.onPause()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        ensureServer() // BleLink re-checks permissions on its own tick.
    }

    private fun requestRuntimePermissions() {
        val wanted = buildList {
            if (Build.VERSION.SDK_INT >= 31) { add(Manifest.permission.BLUETOOTH_ADVERTISE); add(Manifest.permission.BLUETOOTH_CONNECT) }
            if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
        }.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (wanted.isNotEmpty()) requestPermissions(wanted.toTypedArray(), 1)
    }

    private fun ensureServer() {
        if (AgentService.current != null) return
        runCatching { startForegroundService(Intent(this, AgentService::class.java)) }
    }

    private fun toggleServer() {
        if (AgentService.current != null) stopService(Intent(this, AgentService::class.java)) else ensureServer()
        main.postDelayed({ render() }, 200)
    }

    private fun render() {
        val service = AgentService.current
        val link = service?.listeningOn?.url
        val pin = service?.sessions?.displayedPin()
        pinText.text = pin?.chunked(3)?.joinToString(" ") ?: "— — —"
        pinHint.text = when {
            service == null -> AgentService.lastProblem ?: "Приймач вимкнено"
            pin == null -> "Код сплив. Виберіть «Новий код»."
            else -> "Діє 10 хвилин. Потрібен один раз для кожного телефона."
        }
        linkText.text = link ?: "Wi-Fi не під’єднано"
        if (link != qrUrl) {
            qrUrl = link
            qr.visibility = if (link == null) View.GONE else View.VISIBLE
            qr.setImageBitmap(link?.let(::qrBitmap))
        }
        serverRow.title.text = if (service == null) "Увімкнути приймач" else "Вимкнути приймач"

        val ble = service?.ble
        set("ble", when (ble?.state) {
            "advertising" -> (if (ble.connected > 0) "Під’єднано пристроїв: ${ble.connected}" else "Видимий для iPhone") to GREEN
            "permission_required" -> "Натисніть, щоб дозволити «Пристрої поблизу»" to ORANGE
            "bluetooth_off" -> "Bluetooth вимкнено" to ORANGE
            "unsupported", "advertise_failed" -> "Прошивка не підтримує BLE-рекламу" to RED
            else -> "Запускається…" to SECONDARY
        })
        set("lan", if (link != null) link.removePrefix("http://") to GREEN else (service?.message ?: "Вимкнено") to ORANGE)
        set("adb", when (service?.shell?.state) {
            ShellBridge.State.Ready -> "Працює: фокус, живлення, меню" to GREEN
            ShellBridge.State.Authorizing -> "Підтвердьте запит «Дозволити налагодження»" to ORANGE
            else -> "Увімкніть налагодження по мережі" to SECONDARY
        })
        set("nav", when {
            NavigationService.current != null -> "Служба підключена" to GREEN
            else -> "Увімкніть «BeamDeck · Навігація»" to ORANGE
        })
        set("keyboard", when {
            keyboardSelected() -> "Вибрана" to GREEN
            keyboardEnabled() -> "Увімкнена, виберіть її" to SECONDARY
            else -> "Увімкніть клавіатуру BeamDeck" to SECONDARY
        })
        set("media", if (mediaAllowed()) "Доступ надано" to GREEN else "Надайте доступ до сповіщень" to SECONDARY)
    }

    private fun set(key: String, value: Pair<String, Int>) {
        val row = status.getValue(key)
        row.detail.text = value.first
        (row.dot.background as GradientDrawable).setColor(value.second)
    }

    private fun open(key: String) {
        when (key) {
            "ble" -> if (Build.VERSION.SDK_INT >= 31 && checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) != PackageManager.PERMISSION_GRANTED) {
                requestRuntimePermissions()
            } else settings(Settings.ACTION_BLUETOOTH_SETTINGS)
            "lan" -> settings(Settings.ACTION_WIFI_SETTINGS)
            "adb" -> {
                AgentService.current?.shell?.probe()
                if (AgentService.current?.shell?.state == ShellBridge.State.Off) settings(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)
            }
            "nav" -> settings(Settings.ACTION_ACCESSIBILITY_SETTINGS)
            "keyboard" -> if (keyboardEnabled()) {
                getSystemService(android.view.inputmethod.InputMethodManager::class.java).showInputMethodPicker()
            } else settings(Settings.ACTION_INPUT_METHOD_SETTINGS)
            "media" -> settings(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
        }
    }

    // Android 14 blocks reading most Settings.Secure keys for targetSdk 34: use the public APIs.
    private fun keyboardSelected() = runCatching {
        Settings.Secure.getString(contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)?.substringBefore('/') == packageName
    }.getOrDefault(false)

    private fun keyboardEnabled() = runCatching {
        getSystemService(android.view.inputmethod.InputMethodManager::class.java)
            .enabledInputMethodList.any { it.packageName == packageName }
    }.getOrDefault(false)

    private fun mediaAllowed(): Boolean = runCatching {
        val component = ComponentName(this, MediaAccessService::class.java)
        if (Build.VERSION.SDK_INT >= 27) {
            getSystemService(android.app.NotificationManager::class.java).isNotificationListenerAccessGranted(component)
        } else {
            Settings.Secure.getString(contentResolver, "enabled_notification_listeners").orEmpty()
                .split(':').any { ComponentName.unflattenFromString(it) == component }
        }
    }.getOrDefault(false)

    private fun autostartTitle() = if (BootReceiver.enabled(this)) "Автозапуск: увімкнено" else "Автозапуск: вимкнено"

    private fun cinema(mode: String) = startActivity(Intent(this, CinemaActivity::class.java).putExtra("mode", mode))

    private fun settings(action: String, uri: Uri? = null) {
        try {
            startActivity(Intent(action, uri))
        } catch (error: RuntimeException) {
            if (error !is ActivityNotFoundException && error !is SecurityException) throw error
            android.widget.Toast.makeText(this, "Відкрийте цей розділ у налаштуваннях Android.", android.widget.Toast.LENGTH_LONG).show()
        }
    }

    private fun showCrash(report: String) {
        val box = column().apply { setPadding(dp(48), dp(36), dp(48), dp(36)) }
        box.addView(text("BeamDeck зупинився минулого разу", 26, LABEL, Typeface.BOLD))
        box.addView(text("Сфотографуйте цей екран і надішліть розробнику. Потім натисніть «Продовжити».", 15, SECONDARY), gap(8))
        box.addView(text(report.lines().take(28).joinToString("\n"), 12, LABEL).apply {
            typeface = Typeface.MONOSPACE
            background = rounded(GROUPED, 14)
            setPadding(dp(16), dp(14), dp(16), dp(14))
        }, gap(16))
        val group = group()
        row(group, "Продовжити", false) {
            BeamDeckApplication.crashFile(this).delete()
            recreate()
        }.view.requestFocus()
        box.addView(group, gap(16))
        setContentView(ScrollView(this).apply { addView(box) })
    }

    // ---- view helpers ----

    private fun dp(value: Int) = (value * resources.displayMetrics.density + .5f).toInt()
    private fun gap(top: Int) = LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(top) }
    private fun column() = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
    private fun rounded(color: Int, radius: Int) = GradientDrawable().apply { setColor(color); cornerRadius = dp(radius).toFloat() }

    private fun text(value: String, size: Int, color: Int, style: Int = Typeface.NORMAL) = TextView(this).apply {
        text = value
        textSize = size.toFloat()
        setTextColor(color)
        typeface = Typeface.create("sans-serif", style)
    }

    private fun header(value: String) = text(value.uppercase(), 13, SECONDARY, Typeface.BOLD).apply {
        letterSpacing = 0.04f
        setPadding(dp(16), 0, 0, dp(8))
    }

    private fun group() = column().apply {
        background = rounded(GROUPED, 16)
        clipToOutline = true
    }

    private fun row(parent: LinearLayout, title: String, withDot: Boolean, action: (LinearLayout) -> Unit): Row {
        val view = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = dp(54)
            setPadding(dp(16), dp(8), dp(16), dp(8))
            isFocusable = true
            isClickable = true
        }
        val dot = View(this).apply { background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(SECONDARY) } }
        view.addView(dot, LinearLayout.LayoutParams(dp(10), dp(10)).apply { marginEnd = dp(14) })
        dot.visibility = if (withDot) View.VISIBLE else View.GONE
        val body = column()
        val titleView = text(title, 17, LABEL)
        val detail = text("", 14, SECONDARY)
        body.addView(titleView)
        if (withDot) body.addView(detail)
        view.addView(body, LinearLayout.LayoutParams(0, -2, 1f))
        view.addView(text("›", 22, TERTIARY))
        // tvOS-style focus: the focused row lifts and turns light.
        view.setOnFocusChangeListener { v, focused ->
            v.background = if (focused) rounded(Color.WHITE, 12) else null
            titleView.setTextColor(if (focused) Color.BLACK else LABEL)
            detail.setTextColor(if (focused) Color.rgb(60, 60, 67) else SECONDARY)
            v.animate().scaleX(if (focused) 1.02f else 1f).scaleY(if (focused) 1.02f else 1f).setDuration(120).start()
        }
        view.setOnClickListener { action(view) }
        if (parent.childCount > 0) {
            parent.addView(View(this).apply { setBackgroundColor(SEPARATOR) },
                LinearLayout.LayoutParams(-1, 1).apply { marginStart = dp(if (withDot) 40 else 16) })
        }
        parent.addView(view, LinearLayout.LayoutParams(-1, -2))
        return Row(view, titleView, detail, dot)
    }

    private fun qrBitmap(url: String): Bitmap {
        val size = 256
        val matrix = MultiFormatWriter().encode(url, BarcodeFormat.QR_CODE, size, size)
        val pixels = IntArray(size * size) { offset -> if (matrix[offset % size, offset / size]) Color.BLACK else Color.WHITE }
        return Bitmap.createBitmap(pixels, size, size, Bitmap.Config.ARGB_8888)
    }

    companion object {
        // Apple dark-mode system colours.
        private val BACKGROUND = Color.rgb(0, 0, 0)
        private val GROUPED = Color.rgb(28, 28, 30)
        private val LABEL = Color.WHITE
        private val SECONDARY = Color.argb(153, 235, 235, 245)
        private val TERTIARY = Color.argb(76, 235, 235, 245)
        private val SEPARATOR = Color.argb(90, 84, 84, 88)
        private val GREEN = Color.rgb(48, 209, 88)
        private val ORANGE = Color.rgb(255, 159, 10)
        private val RED = Color.rgb(255, 69, 58)

        private var foregroundActivity = WeakReference<MainActivity>(null)
        internal val foreground: MainActivity? get() = foregroundActivity.get()
    }
}

/** Starts the receiver after the projector boots, like a stock remote receiver. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED || !enabled(context)) return
        runCatching { context.startForegroundService(Intent(context, AgentService::class.java)) }
    }

    companion object {
        fun enabled(context: Context) = context.getSharedPreferences("agent", Context.MODE_PRIVATE).getBoolean("autostart", true)
        fun setEnabled(context: Context, value: Boolean) =
            context.getSharedPreferences("agent", Context.MODE_PRIVATE).edit().putBoolean("autostart", value).apply()
    }
}
