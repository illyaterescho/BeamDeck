package ua.beamdeck.agent

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.StateListDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.google.zxing.BarcodeFormat
import com.google.zxing.MultiFormatWriter
import java.lang.ref.WeakReference

class MainActivity : Activity() {
    private val main = Handler(Looper.getMainLooper())
    private val refresh = Runnable { renderStatus(); queueRefresh() }
    private val lilac = Color.rgb(209, 180, 255)
    private val muted = Color.rgb(194, 184, 209)
    private lateinit var serverButton: Button
    private lateinit var pinButton: Button
    private lateinit var revokeButton: Button
    private lateinit var networkText: TextView
    private lateinit var statusText: TextView
    private lateinit var navigationText: TextView
    private lateinit var pinText: TextView
    private lateinit var qr: ImageView
    private var qrUrl: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val root = column(10).apply { setPadding(dp(27), dp(20), dp(27), dp(24)) }
        root.addView(text("BeamDeck Agent", 30, Color.WHITE, bold = true))
        root.addView(text("${Build.MANUFACTURER} ${Build.MODEL}  ·  Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})", 14))

        val wide = resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
        val body = column(0).apply { orientation = if (wide) LinearLayout.HORIZONTAL else LinearLayout.VERTICAL }
        val connection = column(7).apply {
            background = panel(Color.rgb(33, 28, 48), 18)
            setPadding(dp(16), dp(12), dp(16), dp(14))
        }
        statusText = text("", 16, lilac, bold = true)
        networkText = text("", 15)
        pinText = text("", 24, Color.WHITE, bold = true).apply { typeface = Typeface.MONOSPACE }
        qr = ImageView(this).apply {
            contentDescription = "QR-код адреси вебпульта"
            visibility = View.GONE
            scaleType = ImageView.ScaleType.FIT_CENTER
            setBackgroundColor(Color.WHITE)
        }
        navigationText = text("", 14, lilac, bold = true)
        connection.addView(statusText)
        connection.addView(navigationText)
        connection.addView(networkText)
        connection.addView(pinText)
        val qrSize = if (wide) 116 else 164
        connection.addView(qr, LinearLayout.LayoutParams(dp(qrSize), dp(qrSize)).apply { topMargin = dp(4) })
        connection.addView(text(getString(R.string.leave_with_home), 13))
        val controls = column(6)
        serverButton = button("Увімкнути сервер") { toggleServer() }
        pinButton = button("Новий PIN") {
            AgentService.current?.sessions?.rotate()
            renderStatus()
        }
        revokeButton = button("Завершити всі сеанси") {
            runCatching { AgentService.current?.sessions?.clear() }.onFailure {
                android.widget.Toast.makeText(this, "Не вдалося завершити сеанси.", android.widget.Toast.LENGTH_SHORT).show()
            }
            renderStatus()
        }
        controls.addView(serverButton)
        controls.addView(pinButton)
        controls.addView(revokeButton)
        controls.addView(button(getString(R.string.open_grid)) { showCinema("grid") })
        controls.addView(button(getString(R.string.open_player)) { showCinema("player") })
        controls.addView(button(getString(R.string.accessibility_settings)) { openSettings(Settings.ACTION_ACCESSIBILITY_SETTINGS) })
        controls.addView(button(getString(R.string.agent_app_info)) {
            openSettings(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null))
        })
        controls.addView(button("Увімкнути клавіатуру BeamDeck") { openSettings(Settings.ACTION_INPUT_METHOD_SETTINGS) })
        controls.addView(button("Вибрати клавіатуру") {
            getSystemService(android.view.inputmethod.InputMethodManager::class.java).showInputMethodPicker()
        })
        controls.addView(button("Доступ до сповіщень для медіа") { openSettings(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS) })
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            controls.addView(button("Показувати сповіщення Agent") { requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1) })
        }

        if (wide) {
            body.addView(connection, LinearLayout.LayoutParams(0, -2, 1f).apply { marginEnd = dp(16) })
            body.addView(controls, LinearLayout.LayoutParams(0, -2, 1f))
        } else {
            body.addView(connection)
            body.addView(controls, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(11) })
        }
        root.addView(body)
        setContentView(ScrollView(this).apply { isFillViewport = true; addView(root) })
        renderStatus()
        serverButton.requestFocus()
    }

    override fun onResume() {
        super.onResume()
        foregroundActivity = WeakReference(this)
        renderStatus()
        queueRefresh()
    }

    override fun onPause() {
        if (foreground === this) foregroundActivity.clear()
        main.removeCallbacks(refresh)
        super.onPause()
    }

    private fun queueRefresh() { main.postDelayed(refresh, 800) }
    private fun dp(value: Int) = (value * resources.displayMetrics.density + .5f).toInt()

    private fun text(value: String, size: Int, color: Int = muted, bold: Boolean = false) =
        TextView(this).apply {
            text = value
            textSize = size.toFloat()
            setTextColor(color)
            if (bold) typeface = Typeface.DEFAULT_BOLD
        }

    private fun panel(color: Int, radius: Int, stroke: Int? = null) = GradientDrawable().apply {
        setColor(color)
        cornerRadius = dp(radius).toFloat()
        if (stroke != null) setStroke(dp(2), stroke)
    }

    private fun column(spacing: Int) = object : LinearLayout(this) {
        override fun addView(child: View, index: Int, params: android.view.ViewGroup.LayoutParams?) {
            if (childCount > 0 && spacing > 0 && params is LayoutParams && params.topMargin == 0) {
                params.topMargin = dp(spacing)
            }
            super.addView(child, index, params)
        }
    }.apply { orientation = LinearLayout.VERTICAL; gravity = Gravity.TOP }

    private fun button(label: String, action: () -> Unit) = Button(this).apply {
        text = label
        isAllCaps = false
        minHeight = dp(42)
        setPadding(dp(12), dp(4), dp(12), dp(4))
        gravity = Gravity.START or Gravity.CENTER_VERTICAL
        setTextColor(ColorStateList(
            arrayOf(intArrayOf(-android.R.attr.state_enabled), intArrayOf()),
            intArrayOf(Color.rgb(135, 126, 150), Color.WHITE),
        ))
        background = StateListDrawable().apply {
            addState(intArrayOf(android.R.attr.state_pressed), panel(Color.rgb(91, 62, 128), 11, lilac))
            addState(intArrayOf(android.R.attr.state_focused), panel(Color.rgb(67, 49, 94), 11, lilac))
            addState(intArrayOf(), panel(Color.rgb(43, 35, 61), 11))
        }
        setOnClickListener { action() }
    }

    private fun toggleServer() {
        val intent = Intent(this, AgentService::class.java)
        if (AgentService.current != null) {
            stopService(intent)
            main.postDelayed({ renderStatus() }, 170)
        } else {
            try {
                startForegroundService(intent)
                statusText.text = "Запускаємо сервер…"
            } catch (_: Exception) {
                statusText.text = "Android відхилив запуск сервера."
            }
        }
    }

    private fun renderStatus() {
        val service = AgentService.current
        val network = service?.listeningOn ?: runCatching { Lan.find(this) }.getOrNull()
        val link = service?.listeningOn?.url
        val pin = if (link != null) service.sessions.displayedPin() else null
        serverButton.setText(if (service == null) R.string.start_server else R.string.stop_server)
        pinButton.isEnabled = service != null
        revokeButton.isEnabled = service != null
        statusText.text = service?.message ?: AgentService.lastProblem ?: "Сервер вимкнено"
        navigationText.setText(when {
            NavigationService.current != null -> R.string.navigation_connected
            navigationSelected() -> R.string.navigation_waiting
            else -> R.string.navigation_disabled
        })
        networkText.text = link ?: "IP ${network?.ipv4 ?: "відсутня"}  ·  Порт ${Lan.PORT}"
        pinText.text = when {
            pin != null -> "PIN $pin"
            link != null -> "Створіть новий PIN"
            else -> "PIN —"
        }
        if (link != qrUrl) {
            qrUrl = link
            qr.visibility = if (link == null) View.GONE else View.VISIBLE
            qr.setImageBitmap(link?.let(::qrBitmap))
        }
    }

    private fun qrBitmap(url: String): Bitmap {
        val size = 256
        val matrix = MultiFormatWriter().encode(url, BarcodeFormat.QR_CODE, size, size)
        val pixels = IntArray(size * size) { offset -> if (matrix[offset % size, offset / size]) Color.BLACK else Color.WHITE }
        return Bitmap.createBitmap(pixels, size, size, Bitmap.Config.ARGB_8888)
    }

    private fun showCinema(mode: String) {
        startActivity(Intent(this, CinemaActivity::class.java).putExtra("mode", mode))
    }

    private fun navigationSelected(): Boolean {
        val service = ComponentName(this, NavigationService::class.java)
        val enabled = runCatching {
            Settings.Secure.getString(contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)
        }.getOrNull()
        return enabled.orEmpty().split(':').any { ComponentName.unflattenFromString(it) == service }
    }

    private fun openSettings(action: String, uri: Uri? = null) {
        try {
            startActivity(Intent(action, uri))
        } catch (error: RuntimeException) {
            if (error !is ActivityNotFoundException && error !is SecurityException) throw error
            android.widget.Toast.makeText(this, "Відкрийте цей розділ через налаштування Android.", android.widget.Toast.LENGTH_LONG).show()
        }
    }

    companion object {
        private var foregroundActivity = WeakReference<MainActivity>(null)
        internal val foreground: MainActivity? get() = foregroundActivity.get()
    }
}
