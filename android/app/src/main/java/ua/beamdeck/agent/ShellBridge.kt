package ua.beamdeck.agent

import android.content.Context
import dadb.AdbKeyPair
import dadb.Dadb
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Talks to the projector's own adbd over loopback, the way vendor receivers get shell-level input.
 * Shell uid may inject any key (focus motor, power, menu) on every Android version.
 * The user enables network ADB once and accepts the RSA prompt on the projector screen.
 * Only [probe] opens the session; commands fail fast with a reason code until it is ready.
 */
internal class ShellBridge(context: Context) {
    enum class State { Off, Authorizing, Ready }

    private val dir = File(context.filesDir, "adb").apply { mkdirs() }
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "beamdeck-adb").apply { isDaemon = true } }
    @Volatile private var adb: Dadb? = null
    @Volatile var state = State.Off
        private set

    private fun keys(): AdbKeyPair {
        val private = File(dir, "adbkey")
        val public = File(dir, "adbkey.pub")
        if (!private.isFile || !public.isFile) AdbKeyPair.generate(private, public)
        return AdbKeyPair.read(private, public)
    }

    /** Runs on the worker so a stalled adbd never blocks the main thread. */
    private fun <T> onWorker(timeoutMs: Long, block: () -> T): T = try {
        worker.submit<T> { block() }.get(timeoutMs, TimeUnit.MILLISECONDS)
    } catch (wrapped: java.util.concurrent.ExecutionException) {
        throw wrapped.cause ?: wrapped
    } catch (_: java.util.concurrent.TimeoutException) {
        throw ApiProblem(504, "adb_timeout")
    }

    private fun connection(): Dadb = adb ?: throw ApiProblem(409, if (state == State.Authorizing) "adb_authorizing" else "adb_required")

    /** Opens the loopback session; blocks while the projector shows "Allow debugging?" (worker thread only). */
    private fun connect() {
        if (adb != null) return
        val listening = runCatching {
            java.net.Socket().use { it.connect(java.net.InetSocketAddress("127.0.0.1", 5555), 500) }
        }.isSuccess
        if (!listening) { state = State.Off; return }
        state = State.Authorizing
        state = try {
            // One connection waits for the user's answer instead of stacking a new prompt every retry.
            val opened = Dadb.create("127.0.0.1", 5555, keys(), 3_000, 90_000)
            opened.open("exec:true").use { stream -> stream.source.readByteArray() }
            adb = opened
            State.Ready
        } catch (_: Exception) {
            State.Off
        }
    }

    private fun exec(command: String, limit: Int = 64 * 1024): ByteArray = try {
        connection().open("exec:$command").use { stream ->
            val source = stream.source
            val out = okio.Buffer()
            while (out.size < limit && source.read(out, 8192) != -1L) Unit
            out.readByteArray()
        }
    } catch (problem: ApiProblem) {
        throw problem
    } catch (_: Exception) {
        runCatching { adb?.close() }
        adb = null
        state = State.Off
        probe()
        throw ApiProblem(503, "adb_lost")
    }

    /** Probes in the background; callers read [state]. */
    fun probe() {
        if (adb != null || probing.getAndSet(true)) return
        Thread({ try { connect() } finally { probing.set(false) } }, "beamdeck-adb-connect").apply { isDaemon = true }.start()
    }

    private val probing = java.util.concurrent.atomic.AtomicBoolean(false)

    fun key(code: Int, longPress: Boolean = false) {
        require(code in 1..999)
        onWorker(4_000) { exec("input keyevent ${if (longPress) "--longpress " else ""}$code") }
    }

    fun tap(x: Int, y: Int) {
        onWorker(4_000) { exec("input tap $x $y") }
    }

    fun swipe(x1: Int, y1: Int, x2: Int, y2: Int, ms: Int) {
        onWorker(4_000) { exec("input swipe $x1 $y1 $x2 $y2 ${ms.coerceIn(30, 2000)}") }
    }

    /** Projector screen as PNG, for the live preview on the phone. */
    fun screenshot(): ByteArray = onWorker(8_000) { exec("screencap -p", 12 * 1024 * 1024) }

    fun close() {
        worker.execute { runCatching { adb?.close() }; adb = null }
        worker.shutdown()
    }
}

internal object ScreenShot {
    /** PNG from `screencap` → small JPEG for the phone preview. */
    fun jpeg(png: ByteArray): ByteArray {
        val bitmap = android.graphics.BitmapFactory.decodeByteArray(png, 0, png.size) ?: throw ApiProblem(503, "adb_lost")
        val width = minOf(960, bitmap.width)
        val scaled = android.graphics.Bitmap.createScaledBitmap(bitmap, width, bitmap.height * width / bitmap.width, true)
        return java.io.ByteArrayOutputStream().use { out ->
            scaled.compress(android.graphics.Bitmap.CompressFormat.JPEG, 72, out)
            if (scaled !== bitmap) scaled.recycle()
            bitmap.recycle()
            out.toByteArray()
        }
    }
}
