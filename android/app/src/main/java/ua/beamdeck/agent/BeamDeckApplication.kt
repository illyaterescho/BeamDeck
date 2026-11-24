package ua.beamdeck.agent

import android.app.Application
import android.os.Build
import android.util.Log
import java.io.File

/** Keeps the last crash on disk so the receiver can show it on screen; TV firmwares often hide crash dialogs. */
class BeamDeckApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        val system = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            runCatching {
                crashFile(this).writeText(
                    "BeamDeck ${BuildConfigVersion.name} · ${Build.MANUFACTURER} ${Build.MODEL} · Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})\n" +
                        "Потік: ${thread.name}\n\n" + Log.getStackTraceString(error),
                )
            }
            system?.uncaughtException(thread, error)
        }
    }

    companion object {
        fun crashFile(app: android.content.Context) = File(app.filesDir, "last-crash.txt")
    }
}

internal object BuildConfigVersion {
    const val name = "0.3.1"
}
