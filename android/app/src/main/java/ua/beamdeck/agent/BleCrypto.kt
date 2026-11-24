package ua.beamdeck.agent

import java.io.ByteArrayOutputStream
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.PublicKey
import java.security.SecureRandom
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** P-256 ECDH + HKDF-SHA256 + AES-256-GCM, byte-compatible with CryptoKit on the phone. */
internal object BleCrypto {
    private val INFO = "BeamDeck BLE v1".toByteArray()
    private val random = SecureRandom()

    fun keyPair(): KeyPair = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()

    /** Uncompressed X9.63 point, the format CryptoKit's `x963Representation` uses. */
    fun x963(key: PublicKey): ByteArray {
        val point = (key as ECPublicKey).w
        return byteArrayOf(4) + fixed(point.affineX) + fixed(point.affineY)
    }

    fun sessionKey(own: PrivateKey, peerX963: ByteArray, salt: ByteArray): SecretKeySpec? {
        if (peerX963.size != 65 || peerX963[0].toInt() != 4) return null
        val params = (keyPair().public as ECPublicKey).params
        val peer = runCatching {
            KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(
                BigInteger(1, peerX963.copyOfRange(1, 33)), BigInteger(1, peerX963.copyOfRange(33, 65))), params))
        }.getOrNull() ?: return null
        val secret = KeyAgreement.getInstance("ECDH").run { init(own); doPhase(peer, true); generateSecret() }
        return SecretKeySpec(hkdf(secret, salt, INFO, 32), "AES")
    }

    fun seal(key: SecretKeySpec, plain: ByteArray): ByteArray {
        val nonce = ByteArray(12).also(random::nextBytes)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(128, nonce)) }
        return nonce + cipher.doFinal(plain)
    }

    fun open(key: SecretKeySpec, sealed: ByteArray): ByteArray {
        require(sealed.size > 28)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, sealed, 0, 12))
        }
        return cipher.doFinal(sealed, 12, sealed.size - 12)
    }

    private fun fixed(value: BigInteger): ByteArray {
        val raw = value.toByteArray().let { if (it.size > 32) it.copyOfRange(it.size - 32, it.size) else it }
        return ByteArray(32 - raw.size) + raw
    }

    /** RFC 5869. */
    fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val prk = Mac.getInstance("HmacSHA256").run { init(SecretKeySpec(salt, "HmacSHA256")); doFinal(ikm) }
        val mac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(prk, "HmacSHA256")) }
        val out = ByteArrayOutputStream()
        var block = ByteArray(0)
        var counter = 1
        while (out.size() < length) {
            mac.update(block); mac.update(info); mac.update(counter.toByte())
            block = mac.doFinal()
            out.write(block)
            counter++
        }
        return out.toByteArray().copyOf(length)
    }
}
