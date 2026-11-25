package ua.beamdeck.agent

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import org.json.JSONArray
import org.json.JSONObject
import java.net.URI

internal class SystemProjectorController(private val context: Context) {
    fun status(): JSONObject {
        val vendor = vendorIntent()
        return JSONObject()
            .put("focus", "unsupported")
            .put("keystone", "player_only")
            .put("hardwareAutoKeystone", "unsupported")
            .put("vendorLauncher", vendor?.component?.flattenToShortString() ?: JSONObject.NULL)
            .put("canOpen", NavigationService.current != null || MainActivity.foreground != null || CinemaActivity.current != null || MirrorActivity.current != null)
            .put("keyboard", keyboardReason() ?: "ready")
            .put("display", if (MirrorActivity.current != null) "mirror" else CinemaActivity.current?.mode ?: "closed")
            .put("playing", CinemaActivity.current?.playing() ?: false)
    }

    fun diagnostics(): JSONObject {
        val packageInfo = runCatching {
            @Suppress("DEPRECATION")
            context.packageManager.getPackageInfo(VENDOR, android.content.pm.PackageManager.GET_ACTIVITIES)
        }.getOrNull()
        val activities = packageInfo?.activities.orEmpty().filter { it.exported && it.enabled }.take(40)
        return status().put("vendorPackage", VENDOR).put("vendorVisible", packageInfo != null)
            .put("exportedActivities", JSONArray(activities.map {
                JSONObject().put("component", it.name).put("permission", it.permission ?: JSONObject.NULL)
            }))
    }

    fun open(destination: String, value: String): ActionResult {
        val intent = when (destination) {
            "settings" -> vendorIntent() ?: Intent(Settings.ACTION_SETTINGS)
            "grid", "player" -> Intent(context, CinemaActivity::class.java).putExtra("mode", destination)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            "url" -> {
                val target = runCatching { URI(value) }.getOrNull()
                if (target?.scheme?.lowercase() !in setOf("http", "https") || target?.host.isNullOrBlank() || target?.userInfo != null) {
                    throw ApiProblem(400, "invalid_url")
                }
                Intent(Intent.ACTION_VIEW, Uri.parse(value)).addCategory(Intent.CATEGORY_BROWSABLE)
            }
            else -> throw ApiProblem(400, "bad_request")
        }
        val owner = (NavigationService.current as? Context) ?: MainActivity.foreground ?: CinemaActivity.current ?: MirrorActivity.current
            ?: throw ApiProblem(409, "launch_blocked")
        try {
            owner.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (_: ActivityNotFoundException) {
            throw ApiProblem(404, "not_found")
        } catch (_: SecurityException) {
            throw ApiProblem(409, "rejected")
        }
        return ActionResult("submitted", "launch_submitted")
    }

    private fun vendorIntent(): Intent? {
        val pm = context.packageManager
        val intent = pm.getLeanbackLaunchIntentForPackage(VENDOR) ?: pm.getLaunchIntentForPackage(VENDOR) ?: return null
        @Suppress("DEPRECATION")
        val exported = pm.resolveActivity(intent, 0)?.activityInfo?.let {
            it.exported && it.enabled && (it.permission.isNullOrBlank() ||
                context.checkSelfPermission(it.permission) == android.content.pm.PackageManager.PERMISSION_GRANTED)
        }
        return intent.takeIf { exported == true }
    }

    fun keyboardReason(): String? {
        val input = runCatching { Settings.Secure.getString(context.contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD) }.getOrNull()
        if (input?.substringBefore('/') != context.packageName) return "keyboard_required"
        return BeamKeyboard.current?.let { it.reason() } ?: if (BeamKeyboard.current != null) null else "field_required"
    }

    fun type(action: String, text: String): ActionResult {
        keyboardReason()?.let { throw ApiProblem(409, it) }
        return BeamKeyboard.current?.input(action, text) ?: throw ApiProblem(409, "field_required")
    }

    companion object {
        private const val VENDOR = "com.htc.magcubicos"
    }
}
