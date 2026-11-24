package ua.beamdeck.agent

import android.content.res.AssetManager
import android.os.SystemClock
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.server.application.ApplicationCall
import io.ktor.server.application.ApplicationCallPipeline
import io.ktor.server.application.call
import io.ktor.server.application.install
import io.ktor.server.cio.CIO
import io.ktor.server.engine.embeddedServer
import io.ktor.server.request.contentLength
import io.ktor.server.request.contentType
import io.ktor.server.request.httpMethod
import io.ktor.server.request.path
import io.ktor.server.request.receiveChannel
import io.ktor.server.response.header
import io.ktor.server.response.respondBytes
import io.ktor.server.response.respondText
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.route
import io.ktor.server.routing.routing
import io.ktor.server.websocket.WebSockets
import io.ktor.server.websocket.webSocket
import io.ktor.utils.io.readFully
import io.ktor.websocket.CloseReason
import io.ktor.websocket.Frame
import io.ktor.websocket.close
import io.ktor.websocket.send
import io.ktor.websocket.readText
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONException
import org.json.JSONObject
import org.json.JSONTokener
import java.io.FileNotFoundException

internal class LocalServer(
    private val lan: Lan,
    private val assets: AssetManager,
    private val sessions: Sessions,
    private val controls: ProjectorControls,
    private val geometry: GeometryController,
    private val projector: SystemProjectorController,
) {
    private val liveSlots = Semaphore(4)
    private val editorSlots = Semaphore(3)
    private val requests = RequestBudget()
    private val lumina = LuminaReceiver(lan)

    private val engine = embeddedServer(CIO, host = lan.ipv4, port = Lan.PORT, configure = {
        connectionIdleTimeoutSeconds = 10
        workerGroupSize = 2
        callGroupSize = 4
    }) {
        install(WebSockets) {
            pingPeriodMillis = 12_000
            timeoutMillis = 5_000
            maxFrameSize = 1_024
        }

        intercept(ApplicationCallPipeline.Plugins) {
            call.response.header(HttpHeaders.CacheControl, "no-store")
            call.response.header("X-Content-Type-Options", "nosniff")
            call.response.header("Referrer-Policy", "no-referrer")
            call.response.header("X-Frame-Options", "DENY")
            val policy = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data: blob:; " +
                "connect-src 'self' ws://${lan.host}; manifest-src 'self'; worker-src 'self'; " +
                "base-uri 'none'; form-action 'self'; frame-ancestors 'none'"
            call.response.header("Content-Security-Policy", policy)
            val headers = call.request.headers
            val origin = headers[HttpHeaders.Origin]
            val peer = call.request.local.remoteAddress
            val validOrigin = origin == null || origin == lan.url
            val socketRoute = call.request.path() in setOf("/api/v1/live", "/api/v1/geometry/live")
            val failure = when {
                headers.getAll(HttpHeaders.Host) != listOf(lan.host) || !lan.contains(peer) || !validOrigin -> ApiProblem(403, "forbidden")
                call.request.path().startsWith("/api/") && !requests.allow(peer) -> ApiProblem(429, "rate_limited")
                socketRoute && origin != lan.url -> ApiProblem(403, "forbidden")
                socketRoute && !sessions.valid(call.sessionToken()) -> ApiProblem(401, "unauthorized")
                call.request.httpMethod == HttpMethod.Post && headers["X-BeamDeck-Request"] != "1" -> ApiProblem(403, "forbidden")
                else -> null
            }
            if (failure != null) {
                call.problem(failure)
                finish()
            }
        }

        routing {
            get("/") { call.asset("index.html", ContentType.Text.Html) }
            get("/manifest.webmanifest") { call.asset("manifest.webmanifest", ContentType.parse("application/manifest+json")) }
            get("/sw.js") { call.asset("sw.js", ContentType.Application.JavaScript) }
            for (size in listOf(180, 192, 512)) {
                get("/icon-$size.png") { call.asset("icon-$size.png", ContentType.Image.PNG) }
            }
            get("/assets/{name}") {
                val name = call.parameters["name"].orEmpty()
                if (!ASSET_NAME.matches(name)) call.problem(ApiProblem(404, "not_found"))
                else call.asset("assets/$name", if (name.endsWith(".css")) ContentType.Text.CSS else ContentType.Application.JavaScript)
            }
            route("/api/v1") {
                get("/status") { call.safe { readSnapshot() } }
                get("/capabilities") { call.safe { readSnapshot().getJSONObject("capabilities") } }
                get("/apps") { call.safe { device { controls.apps() } } }

                post("/pair") {
                    call.safe {
                        val input = body("pin").string("pin", PIN)
                        val token = sessions.pair(request.local.remoteAddress, input)
                        response.header(HttpHeaders.SetCookie, cookie(token, Sessions.MAX_AGE))
                        JSONObject().put("paired", true)
                    }
                }
                post("/logout") {
                    call.safe {
                        body()
                        val token = authenticated()
                        sessions.remove(token)
                        response.header(HttpHeaders.SetCookie, cookie("", 0))
                        JSONObject().put("paired", false)
                    }
                }
                post("/command") {
                    call.safe {
                        authenticated()
                        val command = body("command").string("command", COMMAND)
                        val receiver = lumina.discover()
                        if (receiver?.supports(command) == true) {
                            val before = if (command in LuminaReceiver.volume) device { controls.volumeStatus() } else null
                            val result = lumina.submit(receiver, command) { authenticated() }.json()
                            if (before != null) {
                                var updated = device { controls.volumeStatus() }
                                repeat(3) {
                                    if (updated.toString() == before.toString()) {
                                        delay(30)
                                        updated = device { controls.volumeStatus() }
                                    }
                                }
                                result.put("volume", updated)
                            }
                            result
                        } else {
                            device {
                                if (command in LuminaReceiver.focus) throw ApiProblem(409, "unsupported")
                                val result = controls.command(command).json()
                                if (command in LuminaReceiver.volume) result.put("volume", controls.volumeStatus())
                                result
                            }
                        }
                    }
                }
                post("/volume") {
                    call.safe {
                        authenticated()
                        val level = body("level").integer("level", 0..1000)
                        device { controls.setVolume(level, showUi = true).json().put("volume", controls.volumeStatus()) }
                    }
                }
                post("/launch") {
                    call.safe {
                        authenticated()
                        val app = body("appId").string("appId", APP_ID)
                        device { controls.launch(app).json() }
                    }
                }
                post("/scene") {
                    call.safe {
                        authenticated()
                        val input = body("appId", "percent")
                        val app = input.string("appId", APP_ID)
                        val percent = input.integer("percent", 0..100)
                        device { controls.scene(app, percent).json() }
                    }
                }
                post("/sleep") {
                    call.safe {
                        authenticated()
                        val minutes = body("minutes").integer("minutes", 0..180)
                        device { controls.setSleep(minutes).json() }
                    }
                }
                post("/input") {
                    call.safe {
                        authenticated()
                        val input = body("action", "text")
                        val action = input.string("action", Regex("text|delete|enter"))
                        val text = input.opt("text") as? String ?: throw ApiProblem(400, "bad_request")
                        if (text.length > 1500 || text.toByteArray().size > 4096 || text.any { it == '\u0000' } ||
                            (action == "text") != text.isNotEmpty()
                        ) throw ApiProblem(400, "bad_request")
                        device { projector.type(action, text).json() }
                    }
                }
                get("/cinema/diagnostics") { call.safe { device { projector.diagnostics() } } }
                post("/cinema/open") {
                    call.safe {
                        authenticated()
                        val input = body("destination", "value")
                        val destination = input.string("destination", Regex("settings|grid|player|url"))
                        val value = input.opt("value") as? String ?: throw ApiProblem(400, "bad_request")
                        if (value.length > 1500) throw ApiProblem(400, "bad_request")
                        device { projector.open(destination, value).json() }
                    }
                }
                post("/cinema/playback") {
                    call.safe {
                        authenticated()
                        body()
                        device {
                            val player = CinemaActivity.current?.takeIf { it.mode == "player" }
                                ?: throw ApiProblem(409, "video_required")
                            player.togglePlayback().json()
                        }
                    }
                }
                post("/cinema/settings") {
                    call.safe {
                        authenticated()
                        val change = body("settings").optJSONObject("settings") ?: throw ApiProblem(400, "bad_request")
                        val settings = CinemaSettings.parse(change)
                        device { geometry.saveSettings(settings); ActionResult().json() }
                    }
                }
                post("/geometry") {
                    call.safe {
                        authenticated()
                        val value = Geometry.parse(body("mode", "corners"))
                        device { geometry.apply(value, true); ActionResult().json() }
                    }
                }
                webSocket("/geometry/live") {
                    if (!editorSlots.tryAcquire()) {
                        close(CloseReason(CloseReason.Codes.TRY_AGAIN_LATER, "Editor busy"))
                        return@webSocket
                    }
                    val editor = Any()
                    var lastPreview = Long.MIN_VALUE / 2
                    var lastCommit = Long.MIN_VALUE / 2
                    var floodWindow = SystemClock.elapsedRealtime()
                    var frames = 0
                    try {
                        for (frame in incoming) {
                            val now = SystemClock.elapsedRealtime()
                            if (!sessions.valid(call.sessionToken())) {
                                close(CloseReason(CloseReason.Codes.VIOLATED_POLICY, "Session expired"))
                                break
                            }
                            if (now - floodWindow >= 1000L) { floodWindow = now; frames = 0 }
                            if (++frames > 55 || frame !is Frame.Text) {
                                close(CloseReason(CloseReason.Codes.VIOLATED_POLICY, "Geometry frame limit"))
                                break
                            }
                            val id: Int
                            var commit = false
                            val input = try {
                                JSONObject(frame.readText())
                            } catch (_: JSONException) {
                                continue
                            }
                            id = (input.opt("id") as? Int)?.takeIf { it > 0 } ?: continue
                            val result = try {
                                commit = input.opt("commit") as? Boolean ?: throw ApiProblem(400, "bad_request")
                                if (!commit && now - lastPreview < 33) continue
                                if (commit && now - lastCommit < 125) throw ApiProblem(429, "rate_limited")
                                val value = Geometry.parse(input)
                                call.device { geometry.apply(value, commit, editor) }
                                if (commit) lastCommit = now else lastPreview = now
                                JSONObject().put("accepted", true)
                            } catch (error: ApiProblem) {
                                JSONObject().put("accepted", false).put("code", error.code)
                            }
                            if (commit || !result.optBoolean("accepted")) {
                                withTimeout(2500) { send(Frame.Text(result.put("id", id).toString())) }
                            }
                        }
                    } finally {
                        withContext(NonCancellable + Dispatchers.Main.immediate) { geometry.discardPreview(editor) }
                        editorSlots.release()
                    }
                }
                webSocket("/live") {
                    if (!liveSlots.tryAcquire()) {
                        close(CloseReason(CloseReason.Codes.TRY_AGAIN_LATER, "Status stream busy"))
                        return@webSocket
                    }
                    try {
                        while (sessions.valid(call.sessionToken())) {
                            val status = call.readSnapshot()
                            withTimeout(4_000) { send(Frame.Text(status.toString())) }
                            delay(1_500)
                        }
                        close(CloseReason(CloseReason.Codes.VIOLATED_POLICY, "Session expired"))
                    } catch (_: ApiProblem) {
                        close(CloseReason(CloseReason.Codes.VIOLATED_POLICY, "Session expired"))
                    } finally {
                        liveSlots.release()
                    }
                }
            }
        }
    }

    private suspend fun ApplicationCall.readSnapshot(): JSONObject {
        authenticated()
        val receiver = lumina.discover()
        return device {
            val snapshot = controls.snapshot()
            val board = projector.status()
            val capabilities = snapshot.getJSONObject("capabilities")
            if (receiver != null) {
                for (name in LuminaReceiver.navigation + LuminaReceiver.volume) {
                    if (receiver.supports(name)) capabilities.put(name, JSONObject().put("available", true))
                }
                if (LuminaReceiver.navigation.any(receiver::supports)) board.put("navigation", "lumina")
            }
            for (name in LuminaReceiver.focus) {
                val available = receiver?.supports(name) == true
                capabilities.put(name, JSONObject().put("available", available).apply {
                    if (!available) put("reason", "unsupported")
                })
                if (available) board.put("focus", "lumina")
            }
            snapshot.put("geometry", geometry.geometry.json())
                .put("projector", board).put("cinema", geometry.loadSettings().json())
                .put("player", CinemaActivity.current?.features() ?: JSONObject()
                    .put("ready", false).put("effects", false).put("audio", false).put("compression", false)
                    .put("sceneBrightness", JSONObject.NULL).put("fps", 0).put("reduced", false))
        }
    }

    fun start() { engine.start(wait = false) }
    fun stop() {
        try { engine.stop(100, 500) } finally { lumina.close() }
    }

    private fun ApplicationCall.sessionToken() = request.cookies[COOKIE]

    private fun ApplicationCall.authenticated(): String {
        val token = sessionToken()
        if (token == null || !sessions.valid(token)) throw ApiProblem(401, "unauthorized")
        return token
    }

    private suspend fun <T> ApplicationCall.device(action: () -> T): T =
        withContext(Dispatchers.Main.immediate) { sessions.authorized(sessionToken(), action) }

    private suspend fun ApplicationCall.safe(action: suspend ApplicationCall.() -> JSONObject) {
        try {
            val result = action()
            respondText(result.toString(), ContentType.Application.Json)
        } catch (problem: ApiProblem) {
            problem(problem)
        } catch (_: TimeoutCancellationException) {
            problem(ApiProblem(408, "bad_request"))
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            problem(ApiProblem(500, "internal_error"))
        }
    }

    private suspend fun ApplicationCall.problem(problem: ApiProblem) {
        val body = JSONObject().put("error", JSONObject().put("code", problem.code))
        respondText(body.toString(), ContentType.Application.Json, HttpStatusCode.fromValue(problem.status))
    }

    private suspend fun ApplicationCall.asset(path: String, type: ContentType) {
        try {
            respondBytes(assets.open("remote/$path").use { it.readBytes() }, type)
        } catch (_: FileNotFoundException) {
            problem(ApiProblem(404, "not_found"))
        }
    }

    private suspend fun ApplicationCall.body(vararg keys: String): JSONObject {
        val length = request.contentLength()
        if (request.headers[HttpHeaders.TransferEncoding] != null || length == null ||
            length !in 2..MAX_BODY || !request.contentType().match(ContentType.Application.Json)
        ) throw ApiProblem(400, "bad_request")

        val bytes = ByteArray(length.toInt())
        withTimeout(3_000) { receiveChannel().readFully(bytes) }
        try {
            val tokener = JSONTokener(bytes.decodeToString(throwOnInvalidSequence = true))
            val value = tokener.nextValue() as? JSONObject ?: throw ApiProblem(400, "bad_request")
            if (tokener.nextClean() != '\u0000' || value.keys().asSequence().toSet() != keys.toSet()) {
                throw ApiProblem(400, "bad_request")
            }
            return value
        } catch (_: JSONException) {
            throw ApiProblem(400, "bad_request")
        } catch (_: IllegalArgumentException) {
            throw ApiProblem(400, "bad_request")
        }
    }

    private fun JSONObject.string(key: String, format: Regex): String =
        (opt(key) as? String)?.takeIf(format::matches) ?: throw ApiProblem(400, "bad_request")

    private fun JSONObject.integer(key: String, range: IntRange): Int =
        (opt(key) as? Int)?.takeIf { it in range } ?: throw ApiProblem(400, "bad_request")

    private fun cookie(token: String, seconds: Int) =
        "$COOKIE=$token; Path=/api; Max-Age=$seconds; HttpOnly; SameSite=Strict"

    private class RequestBudget {
        private var window = SystemClock.elapsedRealtime()
        private var count = 0
        private val byPeer = HashMap<String, Int>()

        @Synchronized
        fun allow(peer: String): Boolean {
            val now = SystemClock.elapsedRealtime()
            if (now - window >= 10_000) {
                window = now
                count = 0
                byPeer.clear()
            }
            val used = byPeer[peer] ?: 0
            if (count >= 340 || used >= 70) return false
            count++
            byPeer[peer] = used + 1
            return true
        }
    }

    companion object {
        private const val COOKIE = "BeamDeckSession"
        private const val MAX_BODY = 8_192L
        private val PIN = Regex("[0-9]{6}")
        private val APP_ID = Regex("[A-Za-z0-9_.$/]{3,300}")
        private val COMMAND = Regex("[a-zA-Z]{2,20}")
        private val ASSET_NAME = Regex("[A-Za-z0-9_.-]{1,100}\\.(?:css|js)")
    }
}
