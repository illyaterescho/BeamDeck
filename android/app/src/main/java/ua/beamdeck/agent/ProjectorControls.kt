package ua.beamdeck.agent

import android.accessibilityservice.AccessibilityService
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Build
import android.os.SystemClock
import android.view.KeyEvent
import org.json.JSONArray
import org.json.JSONObject
import java.text.Collator

internal data class ActionResult(val outcome: String = "applied", val code: String = "ok") {
    fun json() = JSONObject().put("outcome", outcome).put("code", code)
}

internal class ProjectorControls(private val service: AgentService) {
    private val audio = service.getSystemService(AudioManager::class.java)
    private val media = service.getSystemService(MediaSessionManager::class.java)
    private val mediaComponent = ComponentName(service, MediaAccessService::class.java)
    private val stream = AudioManager.STREAM_MUSIC
    private val minVolume get() = if (Build.VERSION.SDK_INT >= 28) audio.getStreamMinVolume(stream) else 0
    private val maxVolume get() = audio.getStreamMaxVolume(stream)
    private val fixedVolume get() = audio.isVolumeFixed || minVolume == maxVolume

    private data class AppEntry(val component: ComponentName, val category: String, val label: String) {
        val id get() = component.flattenToShortString()
        fun json() = JSONObject().put("id", id).put("label", label)
    }

    private data class Playback(val controller: MediaController, val state: PlaybackState) {
        val playing get() = state.state in activePlaybackStates
    }

    private fun currentPlayback(): Pair<Playback?, String?> {
        val sessions = try {
            media.getActiveSessions(mediaComponent)
        } catch (_: SecurityException) {
            return null to "media_access_required"
        }
        val playback = sessions.mapNotNull { controller ->
            controller.playbackState?.let { Playback(controller, it) }
        }
        val selected = playback.firstOrNull { it.playing } ?: playback.firstOrNull {
            it.state.state != PlaybackState.STATE_NONE && it.state.state != PlaybackState.STATE_ERROR
        }
        return selected to if (selected == null) "no_media" else null
    }

    private fun volumeReason(): String? = if (fixedVolume) "fixed_volume" else null
    private fun launchReason(): String? =
        if (NavigationService.current == null && MainActivity.foreground == null) "launch_blocked" else null

    private fun navigationReason(action: Int?): String? {
        if (action == null) return "unsupported"
        val navigator = NavigationService.current ?: return "accessibility_required"
        if (Build.VERSION.SDK_INT >= 30 && navigator.systemActions.none { it.id == action }) return "unsupported"
        return null
    }

    private fun mediaKey(command: String, playback: Playback): Int? {
        val actions = playback.state.actions
        fun has(action: Long) = actions and action != 0L
        return when (command) {
            "previous" -> KeyEvent.KEYCODE_MEDIA_PREVIOUS.takeIf { has(PlaybackState.ACTION_SKIP_TO_PREVIOUS) }
            "next" -> KeyEvent.KEYCODE_MEDIA_NEXT.takeIf { has(PlaybackState.ACTION_SKIP_TO_NEXT) }
            "playPause" -> when {
                playback.playing && has(PlaybackState.ACTION_PAUSE) -> KeyEvent.KEYCODE_MEDIA_PAUSE
                !playback.playing && has(PlaybackState.ACTION_PLAY) -> KeyEvent.KEYCODE_MEDIA_PLAY
                has(PlaybackState.ACTION_PLAY_PAUSE) -> KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
                else -> null
            }
            else -> null
        }
    }

    private fun mediaReason(command: String, playback: Playback?, reason: String?): String? = when {
        reason != null -> reason
        playback == null || mediaKey(command, playback) == null -> "media_action_unavailable"
        else -> null
    }

    private fun capability(reason: String?): JSONObject = JSONObject().put("available", reason == null).apply {
        if (reason != null) put("reason", reason)
    }

    private fun capabilities(playback: Playback?, mediaReason: String?): JSONObject {
        val result = JSONObject()
        for (command in volumeCommands + "volume") result.put(command, capability(volumeReason()))
        for (command in navigationCommands) result.put(command, capability(navigationReason(navigation[command])))
        for (command in mediaCommands) result.put(command, capability(mediaReason(command, playback, mediaReason)))
        result.put("launch", capability(launchReason()))
        result.put("sleep", capability(volumeReason()))
        return result
    }

    fun volumeStatus(): JSONObject = JSONObject()
        .put("min", minVolume)
        .put("max", maxVolume)
        .put("current", audio.getStreamVolume(stream))
        .put("muted", audio.isStreamMute(stream))

    fun snapshot(): JSONObject {
        service.expireSleep()
        val (playback, mediaReason) = currentPlayback()
        val volume = volumeStatus()
        val device = JSONObject().put("model", Build.MODEL).put("manufacturer", Build.MANUFACTURER)
            .put("android", Build.VERSION.RELEASE).put("api", Build.VERSION.SDK_INT)
        val nowPlaying = JSONObject().put("playing", playback?.playing ?: JSONObject.NULL)
            .put("app", playback?.controller?.packageName?.let(::appLabel) ?: JSONObject.NULL)
        return JSONObject().put("device", device).put("volume", volume).put("media", nowPlaying)
            .put("capabilities", capabilities(playback, mediaReason)).put("sleep", service.sleepStatus())
    }

    private fun appLabel(packageName: String): String = try {
        val pm = service.packageManager
        @Suppress("DEPRECATION")
        pm.getApplicationLabel(pm.getApplicationInfo(packageName, 0)).toString()
    } catch (_: PackageManager.NameNotFoundException) {
        packageName
    }

    private fun entries(): List<AppEntry> {
        val pm = service.packageManager
        val collator = Collator.getInstance()
        return listOf(Intent.CATEGORY_LEANBACK_LAUNCHER, Intent.CATEGORY_LAUNCHER)
            .flatMap { category ->
                @Suppress("DEPRECATION")
                pm.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(category), 0).mapNotNull { entry ->
                    val info = entry.activityInfo
                    if (!info.exported || !info.enabled || !info.applicationInfo.enabled ||
                        info.packageName == service.packageName) return@mapNotNull null
                    AppEntry(ComponentName(info.packageName, info.name), category, entry.loadLabel(pm).toString().take(120))
                }
            }
            .distinctBy { it.component.packageName }
            .sortedWith { first, second -> collator.compare(first.label, second.label) }
    }

    fun apps() = JSONObject().put("apps", JSONArray(entries().map(AppEntry::json)))

    fun launch(id: String): ActionResult {
        requireAvailable(launchReason())
        val app = entries().find { it.id == id } ?: throw ApiProblem(404, "not_found")
        return launch(app)
    }

    private fun launch(app: AppEntry): ActionResult {
        val context: Context = NavigationService.current ?: MainActivity.foreground ?: throw ApiProblem(409, "launch_blocked")
        val intent = Intent(Intent.ACTION_MAIN).addCategory(app.category).setComponent(app.component)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
        try {
            context.startActivity(intent)
        } catch (_: ActivityNotFoundException) {
            throw ApiProblem(404, "not_found")
        } catch (_: SecurityException) {
            throw ApiProblem(409, "rejected")
        }
        // The platform provides no confirmation of a visible activity launch here.
        return ActionResult("submitted", "launch_submitted")
    }

    fun scene(id: String, percent: Int): ActionResult {
        requireAvailable(launchReason())
        requireAvailable(volumeReason())
        val app = entries().find { it.id == id } ?: throw ApiProblem(404, "not_found")
        val previous = audio.getStreamVolume(stream)
        val wasMuted = audio.isStreamMute(stream)
        val level = minVolume + ((maxVolume - minVolume) * percent + 50) / 100
        setVolume(level)
        return try {
            launch(app)
        } catch (error: ApiProblem) {
            if (previous != audio.getStreamVolume(stream) || wasMuted != audio.isStreamMute(stream)) {
                throw ApiProblem(409, "partial_scene")
            }
            throw error
        }
    }

    private fun requireAvailable(reason: String?) {
        if (reason != null) throw ApiProblem(409, reason)
    }

    fun setVolume(level: Int, showUi: Boolean = false): ActionResult {
        requireAvailable(volumeReason())
        if (level !in minVolume..maxVolume) throw ApiProblem(400, "bad_request")
        try {
            audio.setStreamVolume(stream, level, if (showUi) AudioManager.FLAG_SHOW_UI else 0)
        } catch (_: SecurityException) {
            throw ApiProblem(409, "rejected")
        }
        if (audio.getStreamVolume(stream) != level) throw ApiProblem(409, "rejected")
        return ActionResult()
    }

    private fun changeMute(mute: Boolean, showUi: Boolean = false) {
        requireAvailable(volumeReason())
        try {
            audio.adjustStreamVolume(stream, if (mute) AudioManager.ADJUST_MUTE else AudioManager.ADJUST_UNMUTE, if (showUi) AudioManager.FLAG_SHOW_UI else 0)
        } catch (_: SecurityException) {
            throw ApiProblem(409, "rejected")
        }
        if (audio.isStreamMute(stream) != mute) throw ApiProblem(409, "rejected")
    }

    fun command(command: String): ActionResult {
        if (command == "mute") {
            changeMute(!audio.isStreamMute(stream), showUi = true)
            return ActionResult()
        }
        if (command == "volumeUp" || command == "volumeDown") {
            val amount = if (command == "volumeUp") 1 else -1
            return setVolume((audio.getStreamVolume(stream) + amount).coerceIn(minVolume, maxVolume), showUi = true)
        }
        if (command in navigationCommands) {
            val action = navigation[command]
            requireAvailable(navigationReason(action))
            if (NavigationService.current?.performGlobalAction(checkNotNull(action)) != true) throw ApiProblem(409, "rejected")
            return ActionResult()
        }
        if (command in mediaCommands) {
            val (playback, reason) = currentPlayback()
            requireAvailable(mediaReason(command, playback, reason))
            val active = checkNotNull(playback)
            dispatch(active.controller, checkNotNull(mediaKey(command, active)))
            return ActionResult("submitted", "media_submitted")
        }
        throw ApiProblem(400, "bad_request")
    }

    private fun dispatch(controller: MediaController, code: Int) {
        val now = SystemClock.uptimeMillis()
        val down = controller.dispatchMediaButtonEvent(KeyEvent(now, now, KeyEvent.ACTION_DOWN, code, 0))
        val up = controller.dispatchMediaButtonEvent(KeyEvent(now, SystemClock.uptimeMillis(), KeyEvent.ACTION_UP, code, 0))
        if (!down || !up) throw ApiProblem(409, "rejected")
    }

    fun setSleep(minutes: Int): ActionResult {
        if (minutes > 0) requireAvailable(volumeReason())
        service.scheduleSleep(minutes)
        return ActionResult()
    }

    fun sleepEffects(): String {
        val muted = runCatching { changeMute(true) }.isSuccess
        val (playback, mediaReason) = runCatching { currentPlayback() }.getOrElse { null to "unavailable" }
        if (playback?.playing != true) return when {
            !muted -> "failed"
            mediaReason == null || mediaReason == "no_media" -> "completed"
            else -> "partial"
        }
        val pauseSent = runCatching {
            dispatch(playback.controller, checkNotNull(mediaKey("playPause", playback)))
        }.isSuccess
        return when {
            muted && pauseSent -> "submitted"
            muted || pauseSent -> "partial"
            else -> "failed"
        }
    }

    companion object {
        private val activePlaybackStates = setOf(
            PlaybackState.STATE_PLAYING, PlaybackState.STATE_BUFFERING,
            PlaybackState.STATE_FAST_FORWARDING, PlaybackState.STATE_REWINDING,
        )
        private val volumeCommands = listOf("volumeUp", "volumeDown", "mute")
        private val mediaCommands = setOf("playPause", "previous", "next")
        private val navigationCommands = setOf("back", "home", "up", "down", "left", "right", "ok")
        private val navigation = mapOf(
            "back" to AccessibilityService.GLOBAL_ACTION_BACK,
            "home" to AccessibilityService.GLOBAL_ACTION_HOME,
        ) + if (Build.VERSION.SDK_INT >= 33) {
            mapOf(
                "up" to AccessibilityService.GLOBAL_ACTION_DPAD_UP,
                "down" to AccessibilityService.GLOBAL_ACTION_DPAD_DOWN,
                "left" to AccessibilityService.GLOBAL_ACTION_DPAD_LEFT,
                "right" to AccessibilityService.GLOBAL_ACTION_DPAD_RIGHT,
                "ok" to AccessibilityService.GLOBAL_ACTION_DPAD_CENTER,
            )
        } else emptyMap()
    }
}
