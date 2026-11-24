package ua.beamdeck.agent

import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import java.util.concurrent.ExecutionException
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit

/**
 * One command set for every transport (BLE, Wi-Fi RPC, the legacy HTTP routes).
 * Call from a background thread: Android state is read on the main thread, shell input runs off it.
 */
internal class CommandRouter(
    private val controls: ProjectorControls,
    private val projector: SystemProjectorController,
    private val geometry: GeometryController,
    val input: InputEngine,
    private val receiver: () -> JSONObject,
) {
    private val main = Handler(Looper.getMainLooper())

    fun <T> onMain(block: () -> T): T {
        if (Looper.myLooper() == Looper.getMainLooper()) return block()
        val task = FutureTask(block)
        main.post(task)
        return try {
            task.get(5, TimeUnit.SECONDS)
        } catch (wrapped: ExecutionException) {
            throw wrapped.cause ?: wrapped
        }
    }

    private fun capability(reason: String?) = JSONObject().put("available", reason == null).apply {
        if (reason != null) put("reason", reason)
    }

    fun status(): JSONObject {
        val state = onMain {
            val snapshot = controls.snapshot()
            snapshot.put("geometry", geometry.geometry.json())
                .put("projector", projector.status())
                .put("cinema", geometry.loadSettings().json())
                .put("player", CinemaActivity.current?.features() ?: JSONObject()
                    .put("ready", false).put("effects", false).put("audio", false).put("compression", false)
                    .put("sceneBrightness", JSONObject.NULL).put("fps", 0).put("reduced", false))
        }
        val caps = state.getJSONObject("capabilities")
        for (key in InputEngine.KEYS) {
            val viaKeys = input.reason(key)
            // Media keys stay available through the shell even without notification access.
            val mediaReady = key in MEDIA && caps.optJSONObject(key)?.optBoolean("available") == true
            if (!mediaReady) caps.put(key, capability(viaKeys))
        }
        caps.put("pointer", capability(if (NavigationService.current == null) "accessibility_required" else null))
        caps.put("screen", capability(when (input.shell.state) {
            ShellBridge.State.Ready -> null
            ShellBridge.State.Authorizing -> "adb_authorizing"
            ShellBridge.State.Off -> "adb_required"
        }))
        val nav = NavigationService.current
        state.put("receiver", receiver()
            .put("adb", input.shell.state.name.lowercase())
            .put("accessibility", nav != null)
            .put("foreground", nav?.foregroundPackage ?: JSONObject.NULL))
        state.put("learning", input.learning?.json() ?: JSONObject.NULL)
        return state
    }

    fun handle(op: String, body: JSONObject): JSONObject = when (op) {
        "status" -> status()
        "key" -> key(body.text("key", KEY), body.optBoolean("long", false))
        "volume" -> {
            val level = body.int("level", 0..1000)
            onMain { controls.setVolume(level, showUi = true).json().put("volume", controls.volumeStatus()) }
        }
        "apps" -> onMain { controls.apps() }
        "launch" -> body.text("appId", APP_ID).let { app -> onMain { controls.launch(app).json() } }
        "scene" -> {
            val app = body.text("appId", APP_ID)
            val percent = body.int("percent", 0..100)
            onMain { controls.scene(app, percent).json() }
        }
        "sleep" -> body.int("minutes", 0..180).let { minutes -> onMain { controls.setSleep(minutes).json() } }
        "text" -> {
            val action = body.text("action", Regex("text|delete|enter"))
            val text = body.opt("text") as? String ?: throw ApiProblem(400, "bad_request")
            if (text.length > 1500 || text.any { it == '\u0000' } || (action == "text") != text.isNotEmpty()) {
                throw ApiProblem(400, "bad_request")
            }
            onMain { projector.type(action, text).json() }
        }
        "open" -> {
            val destination = body.text("destination", Regex("settings|grid|player|url"))
            val value = (body.opt("value") as? String)?.takeIf { it.length <= 1500 } ?: ""
            onMain { projector.open(destination, value).json() }
        }
        "pointer" -> {
            val nav = navigation()
            val (x, y) = nav.pointer(body.delta("dx"), body.delta("dy"))
            ActionResult().json().put("x", x).put("y", y)
        }
        "click" -> {
            val nav = navigation()
            val (w, h) = nav.screenSize()
            val (x, y) = nav.cursorPosition() ?: (w / 2 to h / 2)
            tap(nav, x, y)
        }
        "tapAt" -> {
            val nav = navigation()
            val (w, h) = nav.screenSize()
            tap(nav, (body.unit("x") * (w - 1)).toInt(), (body.unit("y") * (h - 1)).toInt())
        }
        "scroll" -> {
            val nav = navigation()
            val (w, h) = nav.screenSize()
            val (x, y) = nav.cursorPosition() ?: (w / 2 to h / 2)
            val dx = body.delta("dx").toInt()
            val dy = body.delta("dy").toInt()
            val x2 = (x + dx).coerceIn(0, w - 1)
            val y2 = (y + dy).coerceIn(0, h - 1)
            if (!nav.swipe(x, y, x2, y2, 220)) throw ApiProblem(409, "rejected")
            ActionResult().json()
        }
        "learn" -> body.text("key", KEY).let { key ->
            if (key !in InputEngine.KEYS) throw ApiProblem(400, "bad_request")
            input.startLearning(key)
            ActionResult("submitted", "learning").json()
        }
        "forget" -> body.text("key", KEY).let { key ->
            if (key !in InputEngine.KEYS) throw ApiProblem(400, "bad_request")
            input.forget(key)
            ActionResult().json()
        }
        "keymap" -> JSONObject().put("keys", input.keymap())
        "adb" -> { input.shell.probe(); ActionResult("submitted", "adb_probe").json() }
        else -> throw ApiProblem(400, "bad_request")
    }

    private fun key(key: String, long: Boolean): JSONObject = when (key) {
        in VOLUME -> onMain { controls.command(key).json().put("volume", controls.volumeStatus()) }
        in MEDIA -> try {
            onMain { controls.command(key).json() }
        } catch (problem: ApiProblem) {
            if (input.reason(key) != null) throw problem
            input.key(key).json()
        }
        else -> input.key(key, long).json()
    }

    private fun navigation() = NavigationService.current ?: throw ApiProblem(409, "accessibility_required")

    private fun tap(nav: NavigationService, x: Int, y: Int): JSONObject {
        if (!nav.tap(x, y)) {
            if (input.shell.state != ShellBridge.State.Ready) throw ApiProblem(409, "rejected")
            input.shell.tap(x, y)
        }
        return ActionResult().json()
    }

    private fun JSONObject.text(key: String, format: Regex): String =
        (opt(key) as? String)?.takeIf(format::matches) ?: throw ApiProblem(400, "bad_request")

    private fun JSONObject.int(key: String, range: IntRange): Int =
        (opt(key) as? Int)?.takeIf { it in range } ?: throw ApiProblem(400, "bad_request")

    private fun JSONObject.number(key: String): Double =
        (opt(key) as? Number)?.toDouble()?.takeIf { it.isFinite() } ?: throw ApiProblem(400, "bad_request")

    private fun JSONObject.delta(key: String): Float = number(key).takeIf { it in -4000.0..4000.0 }?.toFloat()
        ?: throw ApiProblem(400, "bad_request")

    private fun JSONObject.unit(key: String): Double = number(key).takeIf { it in 0.0..1.0 }
        ?: throw ApiProblem(400, "bad_request")

    companion object {
        private val VOLUME = setOf("volumeUp", "volumeDown", "mute")
        private val MEDIA = setOf("playPause", "previous", "next")
        private val KEY = Regex("[a-zA-Z0-9]{2,20}")
        private val APP_ID = Regex("[A-Za-z0-9_.$/]{3,300}")
    }
}
