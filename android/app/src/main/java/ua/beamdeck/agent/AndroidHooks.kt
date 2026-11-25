package ua.beamdeck.agent

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.accessibilityservice.GestureDescription
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.service.notification.NotificationListenerService
import android.util.DisplayMetrics
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit

class NavigationService : AccessibilityService() {
    private val main = Handler(Looper.getMainLooper())
    private var cursor: CursorView? = null
    private var learner: ((Int?) -> Unit)? = null
    private val hideCursor = Runnable { removeCursor() }
    private val stopLearning = Runnable { finishLearning(null) }
    @Volatile internal var foregroundPackage: String? = null
        private set

    override fun onServiceConnected() {
        super.onServiceConnected()
        current = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event?.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            event.packageName?.toString()?.takeIf { it != "com.android.systemui" }?.let { foregroundPackage = it }
        }
    }

    override fun onInterrupt() = Unit

    // ---- Focus navigation for Android < 13, where DPAD global actions do not exist ----

    internal fun moveFocus(direction: String): Boolean {
        val root = rootInActiveWindow ?: return false
        val focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
            ?: root.findFocus(AccessibilityNodeInfo.FOCUS_ACCESSIBILITY)
        val candidates = ArrayList<Pair<AccessibilityNodeInfo, Rect>>()
        collectFocusable(root, candidates, 0)
        if (focused == null) {
            val first = candidates.minByOrNull { (_, r) -> r.top * 4 + r.left } ?: return false
            return first.first.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
        }
        val view = when (direction) {
            "up" -> View.FOCUS_UP; "down" -> View.FOCUS_DOWN; "left" -> View.FOCUS_LEFT; else -> View.FOCUS_RIGHT
        }
        focused.focusSearch(view)?.let { if (it.performAction(AccessibilityNodeInfo.ACTION_FOCUS)) return true }
        // Geometric fallback: nearest focusable whose centre lies in the requested half-plane.
        val from = Rect().also(focused::getBoundsInScreen)
        val best = candidates.filter { (node, _) -> node != focused }.mapNotNull { (node, r) ->
            val dx = r.exactCenterX() - from.exactCenterX()
            val dy = r.exactCenterY() - from.exactCenterY()
            val (major, minor) = when (direction) {
                "up" -> -dy to dx; "down" -> dy to dx; "left" -> -dx to dy; else -> dx to dy
            }
            if (major <= 4f) null else node to (major + 2.5f * kotlin.math.abs(minor))
        }.minByOrNull { it.second }?.first ?: return scrollFrom(focused, direction)
        return best.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
    }

    private fun scrollFrom(node: AccessibilityNodeInfo, direction: String): Boolean {
        var item: AccessibilityNodeInfo? = node
        val action = if (direction == "up" || direction == "left") AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
            else AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
        repeat(8) {
            val current = item ?: return false
            if (current.isScrollable && current.performAction(action)) return true
            item = current.parent
        }
        return false
    }

    private fun collectFocusable(node: AccessibilityNodeInfo, out: MutableList<Pair<AccessibilityNodeInfo, Rect>>, depth: Int) {
        if (depth > 40 || out.size > 400) return
        if (node.isFocusable && node.isVisibleToUser && node.isEnabled) {
            out += node to Rect().also(node::getBoundsInScreen)
        }
        for (i in 0 until node.childCount) node.getChild(i)?.let { collectFocusable(it, out, depth + 1) }
    }

    internal fun clickFocused(): Boolean {
        val root = rootInActiveWindow ?: return false
        var node = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
            ?: root.findFocus(AccessibilityNodeInfo.FOCUS_ACCESSIBILITY) ?: return false
        repeat(6) {
            if (node.isClickable && node.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return true
            node = node.parent ?: return false
        }
        return false
    }

    // ---- Touchpad cursor drawn as an accessibility overlay (no overlay permission needed) ----

    private fun screen(): DisplayMetrics = DisplayMetrics().also {
        @Suppress("DEPRECATION")
        getSystemService(WindowManager::class.java).defaultDisplay.getRealMetrics(it)
    }

    private fun <T> onMain(block: () -> T): T {
        if (Looper.myLooper() == Looper.getMainLooper()) return block()
        val task = FutureTask(block)
        main.post(task)
        return task.get(2, TimeUnit.SECONDS)
    }

    /** Moves the cursor by a delta in projector pixels and returns its position. */
    internal fun pointer(dx: Float, dy: Float): Pair<Int, Int> = onMain {
        val metrics = screen()
        val view = cursor ?: CursorView(this).also { created ->
            cursor = created
            created.px = metrics.widthPixels / 2f
            created.py = metrics.heightPixels / 2f
            getSystemService(WindowManager::class.java).addView(created, WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                PixelFormat.TRANSLUCENT,
            ).apply { gravity = Gravity.TOP or Gravity.START })
        }
        view.px = (view.px + dx).coerceIn(0f, metrics.widthPixels - 1f)
        view.py = (view.py + dy).coerceIn(0f, metrics.heightPixels - 1f)
        view.postInvalidateOnAnimation()
        main.removeCallbacks(hideCursor)
        main.postDelayed(hideCursor, 6_000)
        view.px.toInt() to view.py.toInt()
    }

    internal fun cursorPosition(): Pair<Int, Int>? = onMain { cursor?.let { it.px.toInt() to it.py.toInt() } }

    internal fun screenSize(): Pair<Int, Int> = screen().let { it.widthPixels to it.heightPixels }

    private fun removeCursor() {
        cursor?.let { runCatching { getSystemService(WindowManager::class.java).removeView(it) } }
        cursor = null
    }

    internal fun tap(x: Int, y: Int): Boolean = gesture(Path().apply { moveTo(x.toFloat(), y.toFloat()) }, 60)

    internal fun swipe(x1: Int, y1: Int, x2: Int, y2: Int, ms: Long): Boolean =
        gesture(Path().apply { moveTo(x1.toFloat(), y1.toFloat()); lineTo(x2.toFloat(), y2.toFloat()) }, ms)

    private fun gesture(path: Path, ms: Long): Boolean = onMain {
        dispatchGesture(GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, ms.coerceIn(1, 2_000))).build(), null, null)
    }

    // ---- Learning vendor keys (focus, keystone…) from the physical remote ----

    internal fun learnNextKey(done: (Int?) -> Unit) = main.post {
        learner = done
        serviceInfo = serviceInfo.apply { flags = flags or AccessibilityServiceInfo.FLAG_REQUEST_FILTER_KEY_EVENTS }
        main.removeCallbacks(stopLearning)
        main.postDelayed(stopLearning, 20_000)
    }

    private fun finishLearning(code: Int?) {
        val callback = learner ?: return
        learner = null
        main.removeCallbacks(stopLearning)
        serviceInfo = serviceInfo.apply { flags = flags and AccessibilityServiceInfo.FLAG_REQUEST_FILTER_KEY_EVENTS.inv() }
        callback(code)
    }

    override fun onKeyEvent(event: KeyEvent): Boolean {
        if (learner == null) return false
        if (event.action == KeyEvent.ACTION_UP && event.keyCode != KeyEvent.KEYCODE_UNKNOWN) {
            val code = event.keyCode
            main.post { finishLearning(code) }
        }
        return true // swallow the key while learning so the menu under it does not react
    }

    override fun onUnbind(intent: Intent?): Boolean {
        if (current === this) current = null
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        if (current === this) current = null
        main.removeCallbacksAndMessages(null)
        removeCursor()
        super.onDestroy()
    }

    private class CursorView(context: Context) : View(context) {
        var px = 0f
        var py = 0f
        private val density = context.resources.displayMetrics.density
        private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }
        private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(150, 0, 0, 0); style = Paint.Style.STROKE; strokeWidth = 2.5f * density
        }

        override fun onDraw(canvas: Canvas) {
            val r = 11 * density
            canvas.drawCircle(px, py, r, fill)
            canvas.drawCircle(px, py, r, ring)
        }
    }

    companion object {
        @Volatile internal var current: NavigationService? = null
            private set
    }
}

class MediaAccessService : NotificationListenerService()

class SleepAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        AgentService.current?.expireSleep()
    }
}
