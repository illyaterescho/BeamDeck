package ua.beamdeck.agent

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.hypot

internal data class Corner(val x: Double, val y: Double)

internal data class Geometry(val corners: List<Corner>, val mode: String) {
    fun json() = JSONObject().put("mode", mode).put("corners", JSONArray(corners.map {
        JSONArray().put(it.x).put(it.y)
    }))

    companion object {
        val identity = Geometry(listOf(Corner(0.0, 0.0), Corner(1.0, 0.0), Corner(1.0, 1.0), Corner(0.0, 1.0)), "manual")

        fun parse(input: JSONObject): Geometry {
            val mode = input.opt("mode") as? String
            val coordinates = input.optJSONArray("corners")
            if (mode !in setOf("manual", "auto") || coordinates?.length() != 4) throw ApiProblem(400, "invalid_geometry")
            val corners = List(4) { index ->
                val pair = coordinates.optJSONArray(index)
                if (pair?.length() != 2) throw ApiProblem(400, "invalid_geometry")
                val x = (pair.opt(0) as? Number)?.toDouble() ?: throw ApiProblem(400, "invalid_geometry")
                val y = (pair.opt(1) as? Number)?.toDouble() ?: throw ApiProblem(400, "invalid_geometry")
                if (x !in 0.0..1.0 || y !in 0.0..1.0) throw ApiProblem(400, "invalid_geometry")
                Corner(x, y)
            }
            val valid = corners.indices.all { index ->
                val a = corners[index]
                val b = corners[(index + 1) % 4]
                val c = corners[(index + 2) % 4]
                val cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
                cross >= .006 && hypot(b.x - a.x, b.y - a.y) >= .09
            }
            if (!valid) throw ApiProblem(400, "invalid_geometry")
            return Geometry(corners, checkNotNull(mode))
        }
    }
}

internal class GeometryController(context: Context) {
    private val store = context.getSharedPreferences("cinema", Context.MODE_PRIVATE)
    var geometry = runCatching { Geometry.parse(JSONObject(store.getString("geometry", "")!!)) }.getOrDefault(Geometry.identity)
        private set

    private var saved = geometry
    private var previewOwner: Any? = null

    fun apply(value: Geometry, commit: Boolean, editor: Any? = null) {
        if (editor != null && previewOwner != null && previewOwner !== editor) throw ApiProblem(409, "editor_busy")
        if (commit) {
            if (!store.edit().putString("geometry", value.json().toString()).commit()) throw ApiProblem(500, "internal_error")
            saved = value
            previewOwner = null
        } else previewOwner = editor
        update(value)
    }

    fun discardPreview(editor: Any) {
        if (previewOwner !== editor) return
        previewOwner = null
        update(saved)
    }

    private fun update(value: Geometry) {
        geometry = value
        CinemaActivity.current?.updateGeometry(value)
    }

    fun loadSettings(): CinemaSettings = runCatching { CinemaSettings.parse(JSONObject(store.getString("settings", "")!!)) }
        .getOrDefault(CinemaSettings())

    fun saveSettings(settings: CinemaSettings) {
        if (!store.edit().putString("settings", settings.json().toString()).commit()) throw ApiProblem(500, "internal_error")
        CinemaActivity.current?.updateSettings(settings)
    }
}
