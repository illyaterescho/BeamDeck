package ua.beamdeck.agent

import org.json.JSONObject

internal data class CinemaSettings(
    val preset: String = "natural",
    val enabled: Boolean = false,
    val contrast: Int = 0,
    val saturation: Int = 0,
    val warmth: Int = 0,
    val shadow: Int = 0,
    val gamma: Int = 0,
    val smoothing: Int = 0,
    val split: Int = 100,
    val dialogue: Int = 0,
    val captions: Boolean = true,
    val captionSize: Int = 25,
    val captionPosition: Int = 8,
    val captionColor: String = "white",
    val captionBackground: Boolean = true,
    val captionDelay: Int = 0,
    val lowPower: Boolean = false,
    val adaptive: Boolean = false,
    val compression: Int = 0,
) {
    fun json() = JSONObject().put("preset", preset).put("enabled", enabled).put("contrast", contrast)
        .put("saturation", saturation).put("warmth", warmth).put("shadow", shadow).put("gamma", gamma)
        .put("smoothing", smoothing).put("split", split).put("dialogue", dialogue).put("captions", captions)
        .put("captionSize", captionSize).put("captionPosition", captionPosition).put("captionColor", captionColor)
        .put("captionBackground", captionBackground).put("captionDelay", captionDelay).put("lowPower", lowPower).put("adaptive", adaptive).put("compression", compression)

    companion object {
        fun parse(data: JSONObject): CinemaSettings {
            fun int(key: String, range: IntRange) =
                (data.opt(key) as? Int)?.takeIf { it in range } ?: throw ApiProblem(400, "bad_request")
            fun bool(key: String) = data.opt(key) as? Boolean ?: throw ApiProblem(400, "bad_request")
            fun string(key: String, choices: Set<String>) =
                (data.opt(key) as? String)?.takeIf { it in choices } ?: throw ApiProblem(400, "bad_request")
            return CinemaSettings(
                string("preset", setOf("natural", "cinema", "vivid", "custom")), bool("enabled"),
                int("contrast", -50..50), int("saturation", -100..100), int("warmth", -100..100),
                int("shadow", 0..100), int("gamma", -50..50), int("smoothing", 0..100), int("split", 0..100),
                int("dialogue", 0..100), bool("captions"), int("captionSize", 12..72), int("captionPosition", 2..40),
                string("captionColor", setOf("white", "ivory", "yellow")), bool("captionBackground"),
                int("captionDelay", -5000..5000), bool("lowPower"),
                if (data.has("adaptive")) bool("adaptive") else false,
                if (data.has("compression")) int("compression", 0..100) else 0,
            )
        }
    }
}
