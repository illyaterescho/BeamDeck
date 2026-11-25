package ua.beamdeck.agent

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.TypedValue
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import java.lang.ref.WeakReference
import java.util.UUID

/** Owns an ephemeral mirror session on the main thread. Only the latest frame is retained. */
internal class MirrorController {
    private data class Session(val owner: String, val id: String, var lastFrame: Long)

    private val main = Handler(Looper.getMainLooper())
    private var active: Session? = null
    var picture: Bitmap? = null
        private set

    private val expiry = object : Runnable {
        override fun run() {
            val session = active ?: return
            val remaining = 10_000 - (SystemClock.elapsedRealtime() - session.lastFrame)
            if (remaining > 0) main.postDelayed(this, remaining) else clear()
        }
    }

    fun start(owner: String): String {
        if (active?.owner?.let { it != owner } == true) throw ApiProblem(409, "mirror_busy")
        if (MirrorActivity.current == null) {
            val foreground = MainActivity.foreground ?: CinemaActivity.current ?: NavigationService.current
                ?: throw ApiProblem(409, "launch_blocked")
            try {
                MirrorActivity.open(foreground)
            } catch (_: SecurityException) {
                throw ApiProblem(409, "launch_blocked")
            }
        }
        val id = UUID.randomUUID().toString()
        active = Session(owner, id, SystemClock.elapsedRealtime())
        picture = null
        MirrorActivity.current?.redraw()
        main.removeCallbacks(expiry)
        main.postDelayed(expiry, 10_000)
        return id
    }

    fun verify(owner: String, id: String) {
        if (active?.let { it.owner == owner && it.id == id } != true) throw ApiProblem(409, "mirror_ended")
    }

    fun publish(owner: String, id: String, frame: Bitmap) {
        keepAlive(owner, id)
        picture = frame
        MirrorActivity.current?.redraw()
    }

    fun keepAlive(owner: String, id: String) {
        verify(owner, id)
        active?.lastFrame = SystemClock.elapsedRealtime()
    }

    fun stop(owner: String, id: String) {
        verify(owner, id)
        clear()
    }

    fun clear(closeActivity: Boolean = true) {
        active = null
        picture = null
        main.removeCallbacks(expiry)
        if (closeActivity) MirrorActivity.current?.finish()
    }

    companion object {
        const val MAX_BYTES = 384 * 1024

        fun decode(data: ByteArray): Bitmap {
            if (data.size < 4 || data[0] != 0xff.toByte() || data[1] != 0xd8.toByte() || data[2] != 0xff.toByte()) {
                throw ApiProblem(400, "invalid_frame")
            }
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
            if (bounds.outWidth !in 1..1024 || bounds.outHeight !in 1..1024) throw ApiProblem(400, "invalid_frame")
            return BitmapFactory.decodeByteArray(data, 0, data.size) ?: throw ApiProblem(400, "invalid_frame")
        }
    }
}

class MirrorActivity : Activity() {
    private lateinit var preview: MirrorView

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        preview = MirrorView(this)
        setContentView(preview)
    }

    override fun onResume() {
        super.onResume()
        visible = WeakReference(this)
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
        redraw()
    }

    override fun onPause() {
        if (current === this) visible.clear()
        super.onPause()
    }

    override fun onDestroy() {
        if (isFinishing) AgentService.current?.mirror?.clear(closeActivity = false)
        super.onDestroy()
    }

    internal fun redraw() { preview.postInvalidateOnAnimation() }

    private class MirrorView(context: Context) : View(context) {
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
        private val transform = Matrix()
        private val image = Matrix()
        private val destination = FloatArray(8)
        private val geometrySource = FloatArray(8)

        override fun onDraw(canvas: Canvas) {
            canvas.drawColor(Color.BLACK)
            val service = AgentService.current
            val bitmap = service?.mirror?.picture
            if (bitmap == null) {
                paint.color = Color.WHITE
                paint.textSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, 24f, resources.displayMetrics)
                paint.textAlign = Paint.Align.CENTER
                canvas.drawText("Очікування екрана iPhone", width / 2f, height / 2f, paint)
                return
            }
            val x = width.toFloat()
            val y = height.toFloat()
            val scale = minOf(x / bitmap.width, y / bitmap.height)
            val left = (x - bitmap.width * scale) / 2
            val top = (y - bitmap.height * scale) / 2
            geometrySource[2] = x
            geometrySource[4] = x
            geometrySource[5] = y
            geometrySource[7] = y
            (service?.geometryController?.geometry ?: Geometry.identity).corners.forEachIndexed { index, corner ->
                destination[index * 2] = corner.x.toFloat() * x
                destination[index * 2 + 1] = corner.y.toFloat() * y
            }
            transform.reset()
            transform.setPolyToPoly(geometrySource, 0, destination, 0, 4)
            image.setScale(scale, scale)
            image.postTranslate(left, top)
            image.postConcat(transform)
            canvas.drawBitmap(bitmap, image, paint)
        }
    }

    companion object {
        private var visible = WeakReference<MirrorActivity>(null)
        internal val current: MirrorActivity? get() = visible.get()

        internal fun open(context: Context) {
            context.startActivity(Intent(context, MirrorActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP))
        }
    }
}
