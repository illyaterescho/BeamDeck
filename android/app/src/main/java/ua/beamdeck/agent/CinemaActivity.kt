package ua.beamdeck.agent

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.RenderEffect
import android.graphics.RuntimeShader
import android.graphics.SurfaceTexture
import android.media.MediaPlayer
import android.media.audiofx.Equalizer
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Gravity
import android.view.Surface
import android.view.TextureView
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import java.lang.ref.WeakReference

class CinemaActivity : Activity(), TextureView.SurfaceTextureListener {
    private val controller by lazy { GeometryController(this) }
    private var settings = CinemaSettings()
    private var geometry = Geometry.identity
    private val main = Handler(Looper.getMainLooper())
    private lateinit var root: FrameLayout
    private lateinit var texture: TextureView
    private lateinit var videoStage: VideoStage
    private lateinit var caption: TextView
    private lateinit var message: TextView
    private lateinit var grid: Grid
    private var video: MediaPlayer? = null
    private var eq: Equalizer? = null
    private var dynamics: AudioEffectsController? = null
    private var pending: Uri? = null
    private var videoSurface: Surface? = null
    private var ready = false
    private var position = 0
    private var resumePlayback = false
    private var subtitles = emptyList<Cue>()
    private var captionJob = 0
    private var shader: Any? = null
    private var frames = 0
    private var lastFrameSample = 0L
    private var fps = 0
    private var slowSamples = 0
    private var renderAvailable = false
    private var luma: Float? = null
    private val sampleBitmap by lazy { Bitmap.createBitmap(24, 14, Bitmap.Config.ARGB_8888) }
    private val samplePixels = IntArray(24 * 14)
    internal var mode = "grid"
        private set

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val source = AgentService.current?.geometryController ?: controller
        settings = source.loadSettings()
        geometry = source.geometry
        drawMode(intent.getStringExtra("mode") ?: "grid")
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val next = intent.getStringExtra("mode")
        if (next == "grid" || next == "player") {
            if (next != mode) drawMode(next)
            hideBars()
        }
    }

    override fun onResume() {
        super.onResume()
        visible = WeakReference(this)
        AgentService.current?.geometryController?.let {
            updateGeometry(it.geometry)
            updateSettings(it.loadSettings())
        }
        hideBars()
        if (resumePlayback && ready) { video?.start(); resumePlayback = false }
        main.removeCallbacks(tick)
        main.post(tick)
    }

    override fun onPause() {
        if (current === this) visible.clear()
        if (playing()) {
            resumePlayback = true
            video?.pause()
        }
        main.removeCallbacks(tick)
        super.onPause()
    }

    override fun onDestroy() {
        releaseVideo()
        videoSurface?.release()
        super.onDestroy()
    }

    private fun hideBars() {
        if (Build.VERSION.SDK_INT >= 30) {
            window.insetsController?.let {
                it.hide(WindowInsets.Type.systemBars())
                it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_FULLSCREEN or
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
        }
    }

    private fun drawMode(next: String) {
        if (ready) {
            position = video?.currentPosition ?: 0
            resumePlayback = playing()
        }
        releaseVideo()
        videoSurface?.release()
        videoSurface = null
        mode = next
        root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        if (mode == "grid") {
            grid = Grid()
            root.addView(grid, FrameLayout.LayoutParams(-1, -1))
        } else {
            texture = TextureView(this).apply {
                isOpaque = false
                surfaceTextureListener = this@CinemaActivity
            }
            videoStage = VideoStage().apply { addView(texture, FrameLayout.LayoutParams(-1, -1)) }
            root.addView(videoStage, FrameLayout.LayoutParams(-1, -1))
            caption = TextView(this).apply { gravity = Gravity.CENTER; setPadding(14, 7, 14, 7); visibility = View.GONE }
            root.addView(caption, FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL))
            message = TextView(this).apply {
                gravity = Gravity.CENTER; setTextColor(Color.WHITE)
                text = "Виберіть відеофайл на проєкторі"
                textSize = 18f
            }
            root.addView(message, FrameLayout.LayoutParams(-1, -2, Gravity.CENTER))
            val actions = LinearLayout(this).apply { gravity = Gravity.CENTER }
            action(actions, "Відео") { pickVideo() }
            action(actions, "Субтитри") { choose(CAPTIONS, "*/*") }
            action(actions, "Пауза / Play") { runCatching { togglePlayback() } }
            root.addView(actions, FrameLayout.LayoutParams(-1, -2, Gravity.TOP))
        }
        setContentView(root)
        applyCaptions()
        hideBars()
    }

    private fun action(bar: LinearLayout, name: String, run: () -> Unit) {
        bar.addView(Button(this).apply {
            text = name
            isAllCaps = false
            setOnClickListener { run() }
        })
    }

    internal fun pickVideo() { choose(VIDEO, "video/*") }
    private fun choose(code: Int, mime: String) {
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).setType(mime).addCategory(Intent.CATEGORY_OPENABLE), code)
        } catch (_: android.content.ActivityNotFoundException) {
            message.text = "Файловий picker недоступний на цій прошивці."
            message.visibility = View.VISIBLE
        }
    }

    @Deprecated("Activity results for the platform document picker")
    override fun onActivityResult(request: Int, result: Int, data: Intent?) {
        super.onActivityResult(request, result, data)
        if (result != RESULT_OK) return
        val uri = data?.data ?: return
        if (request == VIDEO) {
            position = 0
            resumePlayback = true
            pending = uri
            subtitles = emptyList()
            startVideo()
        } else if (request == CAPTIONS) {
            val job = ++captionJob
            Thread {
                val cues = runCatching {
                    val data = contentResolver.openInputStream(uri)?.use { stream ->
                        val buffer = java.io.ByteArrayOutputStream()
                        val chunk = ByteArray(8192)
                        while (true) {
                            val count = stream.read(chunk)
                            if (count < 0) break
                            check(buffer.size() + count <= 1_048_576)
                            buffer.write(chunk, 0, count)
                        }
                        buffer.toString("UTF-8")
                    } ?: error("unreadable")
                    parseCues(data).also { check(it.isNotEmpty()) }
                }
                main.post {
                    if (isDestroyed || job != captionJob || mode != "player") return@post
                    cues.onSuccess { subtitles = it }.onFailure {
                        message.text = "Виберіть файл субтитрів SRT або WebVTT."
                        message.visibility = View.VISIBLE
                        main.postDelayed({ if (ready) message.visibility = View.GONE }, 2500)
                    }
                }
            }.start()
        }
    }

    override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) {
        videoSurface?.release()
        videoSurface = Surface(surface)
        startVideo()
        applyTransform()
    }

    override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) {
        applyTransform()
        applyEffects()
    }
    override fun onSurfaceTextureUpdated(surface: SurfaceTexture) { if (playing()) frames++ }
    override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
        if (ready) {
            position = video?.currentPosition ?: 0
            resumePlayback = resumePlayback || playing()
        }
        releaseVideo()
        videoSurface?.release()
        videoSurface = null
        return true
    }

    private fun startVideo() {
        val surface = videoSurface ?: return
        val uri = pending ?: return
        releaseVideo()
        renderAvailable = false
        ready = false
        message.visibility = View.VISIBLE
        message.text = "Відкриваємо відео…"
        val player = MediaPlayer()
        video = player
        try {
            player.setDataSource(this, uri)
            player.setSurface(surface)
            player.setOnPreparedListener {
                if (video !== it) return@setOnPreparedListener
                ready = true
                message.visibility = View.GONE
                applyTransform()
                if (position > 0) it.seekTo(position)
                eq = runCatching { Equalizer(0, it.audioSessionId) }.getOrNull()
                dynamics = AudioEffectsController(it.audioSessionId)
                applyAudio()
                applyEffects()
                if (resumePlayback) {
                    it.start()
                    resumePlayback = false
                }
            }
            player.setOnVideoSizeChangedListener { _, _, _ -> applyTransform() }
            player.setOnErrorListener { _, _, _ -> playerError(); true }
            player.prepareAsync()
        } catch (_: Exception) {
            playerError()
        }
    }

    private fun playerError() {
        message.text = "Android не зміг відтворити цей файл."
        message.visibility = View.VISIBLE
        releaseVideo()
    }

    private fun releaseVideo() {
        ready = false
        luma = null
        dynamics?.release()
        dynamics = null
        eq?.release()
        eq = null
        video?.release()
        video = null
    }

    internal fun playing(): Boolean = ready && runCatching { video?.isPlaying == true }.getOrDefault(false)
    internal fun hasVideo() = ready
    internal fun features() = org.json.JSONObject().put("ready", ready).put("effects", renderAvailable)
        .put("audio", eq != null).put("compression", dynamics?.available == true)
        .put("sceneBrightness", luma?.let { (it * 100).toInt() } ?: org.json.JSONObject.NULL)
        .put("fps", fps).put("reduced", slowSamples >= 2 || settings.lowPower)

    internal fun togglePlayback(): ActionResult {
        val player = video?.takeIf { ready } ?: throw ApiProblem(409, "video_required")
        if (playing()) {
            player.pause()
            resumePlayback = false
        } else player.start()
        return ActionResult()
    }

    internal fun updateGeometry(value: Geometry) {
        geometry = value
        if (mode == "grid" && ::grid.isInitialized) grid.invalidate()
        if (mode == "player" && ::texture.isInitialized) applyTransform()
    }

    internal fun updateSettings(value: CinemaSettings) {
        settings = value
        if (mode == "player") {
            applyAudio()
            applyEffects()
            applyCaptions()
        }
    }

    private fun applyTransform() {
        if (mode != "player" || !::texture.isInitialized || texture.width <= 0 || texture.height <= 0) return
        val w = texture.width.toFloat()
        val h = texture.height.toFloat()
        videoStage.setProjection(geometry, w, h)
        val player = video
        if (ready && player != null && player.videoWidth > 0 && player.videoHeight > 0) {
            val scale = minOf(w / player.videoWidth, h / player.videoHeight)
            val x = (w - player.videoWidth * scale) / 2
            val y = (h - player.videoHeight * scale) / 2
            val fit = Matrix().apply { setRectToRect(RectF(0f, 0f, w, h), RectF(x, y, w - x, h - y), Matrix.ScaleToFit.FILL) }
            texture.setTransform(fit)
        } else texture.setTransform(null)
    }

    private fun applyEffects() {
        if (Build.VERSION.SDK_INT < 33 || mode != "player" || !ready || texture.width == 0) return
        renderAvailable = runCatching {
            val effect = (shader as? RuntimeShader) ?: RuntimeShader(SHADER).also { shader = it }
            if (!settings.enabled) texture.setRenderEffect(null)
            else {
                val softness = if (settings.lowPower || slowSamples >= 2) 0f else settings.smoothing / 100f
                effect.setFloatUniform("layoutData", texture.width.toFloat(), settings.split / 100f, softness)
                effect.setFloatUniform("grade", settings.contrast / 100f, settings.saturation / 100f, settings.warmth / 100f)
                val adaptive = if (settings.adaptive && !settings.lowPower) luma?.let {
                    (1.35f - it * 1.75f).coerceIn(.45f, 1.25f)
                } ?: 1f else 1f
                effect.setFloatUniform("tone", (settings.shadow / 100f * adaptive).coerceAtMost(1f), 1f + settings.gamma / 100f)
                texture.setRenderEffect(RenderEffect.createRuntimeShaderEffect(effect, "source"))
            }
        }.isSuccess
    }

    private fun applyAudio() {
        dynamics?.update(settings.compression)
        val equalizer = eq ?: return
        runCatching {
            for (index in 0 until equalizer.numberOfBands.toInt()) {
                val band = index.toShort()
                val hz = equalizer.getCenterFreq(band) / 1000
                val gain = when (hz) {
                    in 400..4200 -> 480
                    in 0..180 -> -230
                    else -> 0
                } * settings.dialogue / 100
                val range = equalizer.bandLevelRange
                equalizer.setBandLevel(band, gain.coerceIn(range[0].toInt(), range[1].toInt()).toShort())
            }
            equalizer.enabled = settings.dialogue > 0
        }.onFailure {
            equalizer.release()
            eq = null
        }
    }

    private fun applyCaptions() {
        if (mode != "player" || !::caption.isInitialized) return
        caption.textSize = settings.captionSize.toFloat()
        caption.setTextColor(when (settings.captionColor) {
            "ivory" -> 0xfffff0dc.toInt()
            "yellow" -> 0xffffde72.toInt()
            else -> Color.WHITE
        })
        caption.setShadowLayer(3f, 1f, 2f, Color.BLACK)
        caption.setBackgroundColor(if (settings.captionBackground) 0xc9000000.toInt() else Color.TRANSPARENT)
    }

    private val tick = object : Runnable {
        override fun run() {
            if (mode == "player") {
                val now = SystemClock.elapsedRealtime()
                val elapsed = now - lastFrameSample
                if (elapsed >= 2000) {
                    fps = if (lastFrameSample > 0 && playing()) (1000 * frames / elapsed).toInt() else 0
                    frames = 0
                    lastFrameSample = now
                    val previous = slowSamples >= 2
                    if (playing() && fps in 1..19) slowSamples = minOf(4, slowSamples + 1)
                    if (playing() && fps >= 22) slowSamples = maxOf(0, slowSamples - 1)
                    if (settings.adaptive && !settings.lowPower && slowSamples < 2 && playing()) sampleBrightness()
                    if (previous != (slowSamples >= 2)) applyEffects()
                }
                val player = video
                val currentMs = if (ready && player != null) player.currentPosition - settings.captionDelay else -1
                val cue = if (settings.captions && currentMs >= 0) subtitles.firstOrNull { currentMs in it.start until it.end } else null
                if (cue != null) {
                    caption.text = cue.text
                    val layout = caption.layoutParams as FrameLayout.LayoutParams
                    val bottom = root.height * settings.captionPosition / 100
                    if (layout.bottomMargin != bottom) { layout.bottomMargin = bottom; caption.layoutParams = layout }
                }
                caption.visibility = if (cue == null) View.GONE else View.VISIBLE
            }
            main.postDelayed(this, 150)
        }
    }

    private fun sampleBrightness() {
        val sample = runCatching { texture.getBitmap(sampleBitmap) }.getOrNull() ?: return
        sample.getPixels(samplePixels, 0, 24, 0, 0, 24, 14)
        val average = samplePixels.sumOf { pixel ->
            Color.red(pixel) * .2126 + Color.green(pixel) * .7152 + Color.blue(pixel) * .0722
        }.toFloat() / (samplePixels.size * 255)
        luma = luma?.let { it * .62f + average * .38f } ?: average
        if (settings.enabled && settings.shadow > 0) applyEffects()
    }

    private data class Cue(val start: Int, val end: Int, val text: String)
    private fun parseCues(text: String): List<Cue> {
        fun ms(input: String): Int {
            val pieces = input.replace(',', '.').split(':')
            return pieces.dropLast(1).fold(0) { value, piece -> value * 60 + piece.toInt() } * 60_000 +
                (pieces.last().toFloat() * 1000).toInt()
        }
        val time = "(?:[0-9]{1,2}:)?[0-9]{2}:[0-9]{2}[.,][0-9]{3}"
        val grammar = Regex("(?m)^($time)[ \\t]+-->[ \\t]+($time)[^\\n]*\\n")
        return text.replace("\r", "").split(Regex("\\n[ \\t]*\\n")).mapNotNull { block ->
            val match = grammar.find(block) ?: return@mapNotNull null
            val payload = block.substring(match.range.last + 1).replace(Regex("<[^>]*>"), "").trim().take(650)
            if (payload.isEmpty()) return@mapNotNull null
            Cue(ms(match.groupValues[1]), ms(match.groupValues[2]), payload)
        }.sortedBy { it.start }
    }

    private inner class VideoStage : FrameLayout(this@CinemaActivity) {
        private val warp = Matrix()
        private val source = FloatArray(8)
        private val target = FloatArray(8)

        fun setProjection(value: Geometry, w: Float, h: Float) {
            source[2] = w
            source[4] = w
            source[5] = h
            source[7] = h
            value.corners.forEachIndexed { i, corner ->
                target[2 * i] = corner.x.toFloat() * w
                target[2 * i + 1] = corner.y.toFloat() * h
            }
            if (warp.setPolyToPoly(source, 0, target, 0, 4)) invalidate()
        }

        override fun dispatchDraw(canvas: Canvas) {
            val layer = canvas.save()
            canvas.concat(warp)
            super.dispatchDraw(canvas)
            canvas.restoreToCount(layer)
        }
    }

    private inner class Grid : View(this@CinemaActivity) {
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        private val matrix = Matrix()
        private val base = FloatArray(8)
        private val destination = FloatArray(8)
        private val markerX = floatArrayOf(.065f, .935f, .935f, .065f)
        private val markerY = floatArrayOf(.065f, .065f, .935f, .935f)
        private val colors = intArrayOf(0xff00ecff.toInt(), 0xffff00d4.toInt(), 0xffffeb00.toInt(), 0xff2bff00.toInt())
        private val swatches = intArrayOf(0xff303030.toInt(), 0xff777777.toInt(), 0xffc0c0c0.toInt(), Color.WHITE)
        override fun onDraw(canvas: Canvas) {
            val w = width.toFloat()
            val h = height.toFloat()
            base[2] = w
            base[4] = w
            base[5] = h
            base[7] = h
            geometry.corners.forEachIndexed { index, corner ->
                destination[2 * index] = corner.x.toFloat() * w
                destination[2 * index + 1] = corner.y.toFloat() * h
            }
            if (!matrix.setPolyToPoly(base, 0, destination, 0, 4)) return
            canvas.save()
            canvas.concat(matrix)
            paint.strokeWidth = maxOf(1.3f, w / 440)
            for (i in 1..11) {
                paint.color = if (i == 6) Color.WHITE else 0xff77838f.toInt()
                val x = w * i / 12
                val y = h * i / 12
                canvas.drawLine(x, h * .022f, x, h * .978f, paint)
                canvas.drawLine(w * .022f, y, w * .978f, y, paint)
            }
            paint.color = Color.WHITE
            paint.style = Paint.Style.STROKE
            canvas.drawRect(w * .02f, h * .02f, w * .98f, h * .98f, paint)
            paint.style = Paint.Style.FILL
            for (i in colors.indices) {
                val x = markerX[i]
                val y = markerY[i]
                paint.color = colors[i]
                canvas.drawRect(w * (x - .025f), h * (y - .026f), w * (x + .025f), h * (y + .026f), paint)
            }
            swatches.forEachIndexed { i, color ->
                paint.color = color
                val x = .38f + .06f * i
                canvas.drawRect(w * x, h * .56f, w * (x + .055f), h * .61f, paint)
            }
            canvas.restore()
        }
    }

    companion object {
        private var visible = WeakReference<CinemaActivity>(null)
        internal val current: CinemaActivity? get() = visible.get()
        private const val VIDEO = 31
        private const val CAPTIONS = 32
        private const val SHADER = """
            uniform shader source;
            uniform float3 layoutData;
            uniform float3 grade;
            uniform float2 tone;
            half4 main(float2 p) {
                half4 original = source.eval(p);
                if (p.x > layoutData.x * layoutData.y || original.a < .001) return original;
                float3 c = float3(original.rgb);
                if (layoutData.z > .001) {
                    float3 mean = float3(source.eval(p + float2(1,0)).rgb + source.eval(p - float2(1,0)).rgb
                      + source.eval(p + float2(0,1)).rgb + source.eval(p - float2(0,1)).rgb) * .25;
                    float edge = length(c - mean);
                    c = mix(c, mean, layoutData.z * .68 * (1 - smoothstep(.045,.17,edge)));
                }
                float light = dot(c, float3(.2126,.7152,.0722));
                float lift = .34 * tone.x * smoothstep(.015,.095,light) * (1 - smoothstep(.075,.44,light));
                c = mix(float3(light), c, 1 + grade.y) + lift;
                c = (c - .5) * (1 + grade.x) + .5;
                c = pow(clamp(c, 0, 1), float3(1 / tone.y));
                c *= float3(1 + .15 * grade.z, 1, 1 - .15 * grade.z);
                return half4(half3(clamp(c,0,1)), original.a);
            }
        """
    }
}
