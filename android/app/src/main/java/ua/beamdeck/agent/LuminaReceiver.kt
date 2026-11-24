package ua.beamdeck.agent

import android.os.Build
import android.os.SystemClock
import io.ktor.client.HttpClient
import io.ktor.client.engine.cio.CIO
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsChannel
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.utils.io.core.readBytes
import io.ktor.utils.io.readRemaining
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject

/** The stock receiver is discovered on this Android device, never at a client-supplied address. */
internal class LuminaReceiver(private val lan: Lan) {
    internal data class Device(val host: String, val commands: Set<String>) {
        fun supports(action: String): Boolean = ACTIONS[action]?.let { it in commands } == true
    }

    private val client = HttpClient(CIO) {
        followRedirects = false
        install(HttpTimeout) {
            requestTimeoutMillis = 950
            connectTimeoutMillis = 350
            socketTimeoutMillis = 700
        }
        engine {
            endpoint.connectAttempts = 1
        }
    }
    private val probeLock = Mutex()
    private val commandLock = Mutex()
    private var expiresAt = 0L
    private var detected: Device? = null

    suspend fun discover(): Device? = probeLock.withLock {
        if (SystemClock.elapsedRealtime() < expiresAt) return@withLock detected
        detected = listOf("127.0.0.1", lan.ipv4).distinct().firstNotNullOfOrNull { host ->
            inspect(host)
        }
        expiresAt = SystemClock.elapsedRealtime() + if (detected == null) 10_000 else 30_000
        detected
    }

    private suspend fun inspect(host: String): Device? {
        return try {
            val data = json(client.get("http://$host:8899/api/v1/device"))
            val commands = data.optJSONArray("commands") ?: return null
            val advertised = (0 until minOf(commands.length(), 256)).map { commands.optString(it) }.toSet()
            if (!data.optString("version").matches(Regex("v?\\d+\\.\\d+(?:\\.\\d+)?")) ||
                (data.optString("name") != Build.MODEL && data.optString("ip") != lan.ipv4) ||
                "VOL_UP" !in advertised || "NAV_OK" !in advertised
            ) return null
            Device(host, advertised.intersect(ACTIONS.values.toSet()))
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            null
        }
    }

    suspend fun submit(device: Device, action: String, authorize: () -> Unit): ActionResult = commandLock.withLock {
        val command = ACTIONS[action]?.takeIf { it in device.commands } ?: throw ApiProblem(409, "unsupported")
        authorize()
        val result = try {
            val payload = JSONObject().put("command", command).toString()
            json(client.post("http://${device.host}:8899/api/v1/command") {
                contentType(ContentType.Application.Json)
                setBody(payload)
            })
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            probeLock.withLock {
                if (detected === device) {
                    detected = null
                    expiresAt = SystemClock.elapsedRealtime() + 2500
                }
            }
            throw ApiProblem(503, "lumina_unavailable")
        }
        if (result.optString("status") != "ok" || result.optString("command") != command) {
            throw ApiProblem(409, "rejected")
        }
        ActionResult("submitted", "lumina_submitted")
    }

    private suspend fun json(response: HttpResponse): JSONObject {
        check(response.status.value == 200)
        val bytes = response.bodyAsChannel().readRemaining(32_769).readBytes()
        check(bytes.size <= 32_768)
        return JSONObject(bytes.decodeToString(throwOnInvalidSequence = true))
    }

    fun close() = client.close()

    companion object {
        val navigation = setOf("up", "down", "left", "right", "ok", "back", "home")
        val focus = setOf("focusUp", "focusDown", "autoFocus")
        val volume = setOf("volumeUp", "volumeDown", "mute")

        private val ACTIONS = mapOf(
            "up" to "NAV_UP", "down" to "NAV_DOWN", "left" to "NAV_LEFT", "right" to "NAV_RIGHT",
            "ok" to "NAV_OK", "back" to "NAV_BACK", "home" to "NAV_HOME",
            "focusUp" to "FOCUS_UP", "focusDown" to "FOCUS_DOWN", "autoFocus" to "AUTO_FOCUS",
            "volumeUp" to "VOL_UP", "volumeDown" to "VOL_DOWN", "mute" to "VOL_MUTE",
        )
    }
}
