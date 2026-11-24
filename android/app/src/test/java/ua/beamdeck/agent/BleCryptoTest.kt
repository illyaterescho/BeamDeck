package ua.beamdeck.agent

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File
import java.math.BigInteger
import java.security.KeyFactory
import java.security.interfaces.ECPublicKey
import java.security.spec.ECPrivateKeySpec

/** Vector produced by apple/Tools/ble-vector.swift with CryptoKit: proves the phone and projector agree. */
class BleCryptoTest {
    private fun hex(value: String) = ByteArray(value.length / 2) { value.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }

    @Test
    fun cryptoKitVectorDecrypts() {
        val vector = JSONObject(javaClass.getResource("/ble-vector.json")!!.readText())
        val params = (BleCrypto.keyPair().public as ECPublicKey).params
        val server = KeyFactory.getInstance("EC").generatePrivate(ECPrivateKeySpec(BigInteger(1, hex(vector.getString("serverPrivate"))), params))
        val key = BleCrypto.sessionKey(server, hex(vector.getString("clientPublic")), hex(vector.getString("salt")))!!
        assertArrayEquals(hex(vector.getString("key")), key.encoded)
        assertEquals(vector.getString("plain"), BleCrypto.open(key, hex(vector.getString("sealed"))).decodeToString())
        // Reverse direction: the phone opens this with the same key (checked by the Swift tool).
        System.getProperty("bleOut")?.let { File(it).writeText(hex(BleCrypto.seal(key, """{"id":1,"ok":true}""".toByteArray()))) }
    }
}
