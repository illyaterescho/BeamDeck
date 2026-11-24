package ua.beamdeck.agent

import android.content.Context
import android.os.SystemClock
import android.util.Base64
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Locale

internal class ApiProblem(val status: Int, val code: String) : RuntimeException(code)

internal class Sessions(context: Context) {
    private val store = context.getSharedPreferences("pairing", Context.MODE_PRIVATE)
    private val random = SecureRandom()
    private val attemptsByPeer = HashMap<String, Int>()
    private var attemptWindow = SystemClock.elapsedRealtime()
    private var attempts = 0
    private var pin = ""
    private var validUntil = 0L

    @Synchronized
    fun rotate() {
        pin = String.format(Locale.ROOT, "%06d", random.nextInt(1_000_000))
        validUntil = SystemClock.elapsedRealtime() + 10 * 60_000L
    }

    @Synchronized
    fun displayedPin(): String? = pin.takeIf { SystemClock.elapsedRealtime() < validUntil }

    @Synchronized
    fun pair(peer: String, input: String): String {
        val now = SystemClock.elapsedRealtime()
        if (now - attemptWindow >= 60_000) {
            attemptsByPeer.clear()
            attemptWindow = now
            attempts = 0
        }
        val fromPeer = attemptsByPeer[peer] ?: 0
        if (fromPeer >= 5 || attempts >= 30) throw ApiProblem(429, "rate_limited")
        attemptsByPeer[peer] = fromPeer + 1
        attempts++
        if (now >= validUntil) throw ApiProblem(410, "pin_expired")
        if (!MessageDigest.isEqual(input.toByteArray(), pin.toByteArray())) throw ApiProblem(401, "bad_pin")

        val token = Base64.encodeToString(ByteArray(32).also(random::nextBytes),
            Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
        val wallTime = System.currentTimeMillis()
        val stored = store.all.mapNotNull { (key, value) -> (value as? Long)?.let { key to it } }
        val expired = stored.filter { it.second <= wallTime }
        val excess = stored.filter { it.second > wallTime }.sortedByDescending { it.second }.drop(MAX_SESSIONS - 1)
        val editor = store.edit()
        (expired + excess).forEach { (key, _) -> editor.remove(key) }
        if (!editor.putLong(digest(token), wallTime + MAX_AGE * 1000L).commit()) throw ApiProblem(500, "internal_error")
        return token
    }

    @Synchronized
    fun valid(token: String?): Boolean =
        token != null && TOKEN.matches(token) && store.getLong(digest(token), 0) > System.currentTimeMillis()

    @Synchronized
    fun <T> authorized(token: String?, action: () -> T): T {
        if (!valid(token)) throw ApiProblem(401, "unauthorized")
        return action()
    }

    @Synchronized
    fun remove(token: String) {
        check(store.edit().remove(digest(token)).commit())
    }

    @Synchronized
    fun clear() {
        check(store.edit().clear().commit())
        rotate()
    }

    private fun digest(token: String): String = Base64.encodeToString(
        MessageDigest.getInstance("SHA-256").digest(token.toByteArray()),
        Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
    )

    companion object {
        const val MAX_AGE = 30 * 24 * 60 * 60
        private const val MAX_SESSIONS = 12
        private val TOKEN = Regex("[A-Za-z0-9_-]{43}")
    }
}
