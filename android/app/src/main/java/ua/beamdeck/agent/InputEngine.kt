package ua.beamdeck.agent

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.os.Build
import android.os.SystemClock
import org.json.JSONObject

/**
 * Executes remote keys on the projector itself, picking the strongest path available:
 * 1. adb shell over loopback (any key on any Android version, incl. learned vendor keys such as focus),
 * 2. BeamDeck accessibility service (global actions, focus traversal, gestures).
 * Thread-agnostic: never call it on the main thread, shell calls block for up to a few seconds.
 */
internal class InputEngine(context: Context, val shell: ShellBridge) {
    private val prefs = context.getSharedPreferences("keymap", Context.MODE_PRIVATE)
    @Volatile var learning: Learning? = null
        private set

    data class Learning(val key: String, val state: String, val code: Int?, val at: Long = SystemClock.elapsedRealtime()) {
        fun json(): JSONObject = JSONObject().put("key", key).put("state", state).put("code", code ?: JSONObject.NULL)
    }

    fun code(key: String): Int? = prefs.getInt(key, 0).takeIf { it > 0 } ?: DEFAULT_CODES[key]

    fun keymap(): JSONObject = JSONObject().apply {
        for (key in KEYS) put(key, JSONObject().put("code", code(key) ?: JSONObject.NULL).put("learned", prefs.contains(key)))
    }

    fun forget(key: String) {
        require(key in KEYS)
        prefs.edit().remove(key).apply()
    }

    /** null = available; otherwise the reason code shown on the remote. */
    fun reason(key: String): String? {
        val shellReady = shell.state == ShellBridge.State.Ready
        val nav = NavigationService.current
        return when {
            key !in KEYS -> "unsupported"
            shellReady && code(key) != null -> null
            key in LEARN_ONLY && code(key) == null -> "learn_required"
            key in ACCESSIBLE && nav != null -> null
            key in LEARN_ONLY || key in SHELL_ONLY ->
                if (shell.state == ShellBridge.State.Authorizing) "adb_authorizing" else "adb_required"
            else -> "accessibility_required"
        }
    }

    fun key(key: String, longPress: Boolean = false): ActionResult {
        reason(key)?.let { throw ApiProblem(409, it) }
        val nav = NavigationService.current
        // Global back/home are instant through accessibility; prefer them over spawning `input`.
        if (!longPress && nav != null && key in GLOBAL && nav.performGlobalAction(GLOBAL.getValue(key))) {
            return ActionResult()
        }
        if (!longPress && nav != null && Build.VERSION.SDK_INT >= 33 && key in DPAD_GLOBAL &&
            nav.performGlobalAction(DPAD_GLOBAL.getValue(key))
        ) return ActionResult()
        val code = code(key)
        if (shell.state == ShellBridge.State.Ready && code != null) {
            shell.key(code, longPress)
            return ActionResult("submitted", "key_submitted")
        }
        if (nav != null && key in DPAD && nav.moveFocus(key)) return ActionResult()
        if (nav != null && key == "ok" && nav.clickFocused()) return ActionResult()
        throw ApiProblem(409, if (nav == null) "accessibility_required" else "no_focus")
    }

    fun startLearning(key: String) {
        require(key in KEYS)
        val nav = NavigationService.current ?: throw ApiProblem(409, "accessibility_required")
        learning = Learning(key, "listening", null)
        nav.learnNextKey { code ->
            learning = if (code == null) Learning(key, "timeout", null) else {
                prefs.edit().putInt(key, code).apply()
                Learning(key, "learned", code)
            }
        }
    }

    companion object {
        private val DPAD = setOf("up", "down", "left", "right")
        private val GLOBAL = mapOf(
            "back" to AccessibilityService.GLOBAL_ACTION_BACK,
            "home" to AccessibilityService.GLOBAL_ACTION_HOME,
            "recents" to AccessibilityService.GLOBAL_ACTION_RECENTS,
        )
        private val DPAD_GLOBAL = if (Build.VERSION.SDK_INT >= 33) mapOf(
            "up" to AccessibilityService.GLOBAL_ACTION_DPAD_UP,
            "down" to AccessibilityService.GLOBAL_ACTION_DPAD_DOWN,
            "left" to AccessibilityService.GLOBAL_ACTION_DPAD_LEFT,
            "right" to AccessibilityService.GLOBAL_ACTION_DPAD_RIGHT,
            "ok" to AccessibilityService.GLOBAL_ACTION_DPAD_CENTER,
        ) else emptyMap()
        private val ACCESSIBLE = DPAD + GLOBAL.keys + "ok"

        /** Android KeyEvent codes; vendor keys (focus, keystone) are learned from the physical remote. */
        private val DEFAULT_CODES = mapOf(
            "up" to 19, "down" to 20, "left" to 21, "right" to 22, "ok" to 23,
            "back" to 4, "home" to 3, "recents" to 187, "menu" to 82, "settings" to 176,
            "power" to 26, "standby" to 223, "wakeup" to 224, "input" to 178,
            "playPause" to 85, "next" to 87, "previous" to 88,
        )
        private val SHELL_ONLY = setOf("menu", "settings", "power", "standby", "wakeup", "input", "playPause", "next", "previous")
        private val LEARN_ONLY = setOf("focusUp", "focusDown", "autoFocus", "keystone", "custom1", "custom2")
        val KEYS = DEFAULT_CODES.keys + LEARN_ONLY
    }
}
