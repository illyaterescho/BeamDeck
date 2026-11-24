package ua.beamdeck.agent

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import java.net.Inet4Address

internal data class Lan(val ipv4: String, val prefix: Int) {
    val host = "$ipv4:$PORT"
    val url = "http://$host"

    fun contains(peer: String): Boolean {
        val localBits = bits(ipv4) ?: return false
        val peerBits = bits(peer) ?: return false
        val mask = -1 shl (32 - prefix)
        return privateIpv4(peerBits) && (localBits and mask) == (peerBits and mask)
    }

    companion object {
        const val PORT = 8765

        private fun bits(address: String): Int? {
            val bytes = address.split('.')
            if (bytes.size != 4) return null
            var value = 0
            for (byte in bytes) {
                val part = byte.toIntOrNull() ?: return null
                if (part !in 0..255) return null
                value = (value shl 8) or part
            }
            return value
        }

        private fun privateIpv4(bits: Int): Boolean {
            val a = bits ushr 24
            val b = (bits ushr 16) and 255
            return a == 10 || a == 172 && b in 16..31 || a == 192 && b == 168 || a == 169 && b == 254
        }

        @Suppress("DEPRECATION")
        fun find(context: Context): Lan? {
            val connectivity = context.getSystemService(ConnectivityManager::class.java)
            return (listOfNotNull(connectivity.activeNetwork) + connectivity.allNetworks)
                .distinct()
                .asSequence()
                .filter { network ->
                    val caps = connectivity.getNetworkCapabilities(network)
                    caps != null && (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                        caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET))
                }
                .flatMap { network -> connectivity.getLinkProperties(network)?.linkAddresses.orEmpty().asSequence() }
                .firstNotNullOfOrNull { link ->
                    val address = (link.address as? Inet4Address)?.hostAddress ?: return@firstNotNullOfOrNull null
                    if (link.prefixLength in 1..31 && bits(address)?.let(::privateIpv4) == true) {
                        Lan(address, link.prefixLength)
                    } else null
                }
        }
    }
}
