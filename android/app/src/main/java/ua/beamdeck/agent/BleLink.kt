package ua.beamdeck.agent

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelUuid
import android.os.SystemClock
import org.json.JSONException
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.crypto.spec.SecretKeySpec

/**
 * BLE GATT link, the Lumina Go style transport: the projector advertises, the phone connects directly.
 *
 * Wire format (see PROTOCOL.md): every GATT value is `[flags][chunk]`, flags bit 0x80 marks the last chunk.
 * Reassembled frames: 0x01 client hello (P-256 X9.63 key), 0x02 server hello (key + 16-byte salt),
 * 0x03 sealed JSON (AES-256-GCM, 12-byte nonce || ciphertext || tag), key = HKDF-SHA256(ECDH, salt, INFO).
 */
@SuppressLint("MissingPermission")
internal class BleLink(
    private val context: Context,
    private val sessions: Sessions,
    private val router: () -> CommandRouter?,
) {
    private val manager = context.getSystemService(BluetoothManager::class.java)
    private val io = Executors.newSingleThreadScheduledExecutor { Thread(it, "beamdeck-ble").apply { isDaemon = true } }
    private val work = Executors.newSingleThreadExecutor { Thread(it, "beamdeck-ble-work").apply { isDaemon = true } }
    private val random = SecureRandom()
    private val peers = HashMap<String, Peer>() // io thread only
    private var server: BluetoothGattServer? = null
    private var tx: BluetoothGattCharacteristic? = null
    private var advertising = false
    private var statusBusy = false
    @Volatile var state = "off"
        private set
    @Volatile var connected = 0
        private set

    private class Peer(val device: BluetoothDevice) {
        var mtu = 23
        var key: SecretKeySpec? = null
        var token: String? = null
        var subscribed = false
        var lastStatus: String? = null
        var sendingSince = 0L
        val inbox = ByteArrayOutputStream()
        val outbox = ArrayDeque<ByteArray>()
    }

    fun start() {
        io.execute { ensureRunning() }
        io.scheduleWithFixedDelay({ runCatching { tick() } }, 1500, 1500, TimeUnit.MILLISECONDS)
    }

    fun stop() {
        io.execute {
            runCatching { manager.adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback) }
            runCatching { server?.close() }
            server = null
            peers.clear()
            advertising = false
            state = "off"
        }
        io.shutdown()
        work.shutdown()
    }

    private fun permitted(): Boolean = Build.VERSION.SDK_INT < 31 || listOf(
        Manifest.permission.BLUETOOTH_ADVERTISE, Manifest.permission.BLUETOOTH_CONNECT,
    ).all { context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }

    private fun ensureRunning() {
        val adapter = manager?.adapter
        state = when {
            adapter == null -> "unsupported"
            !permitted() -> "permission_required"
            !adapter.isEnabled -> "bluetooth_off"
            adapter.bluetoothLeAdvertiser == null -> "unsupported"
            else -> state
        }
        if (adapter == null || !permitted() || !adapter.isEnabled) {
            if (server != null) { runCatching { server?.close() }; server = null; peers.clear(); advertising = false }
            return
        }
        val advertiser = adapter.bluetoothLeAdvertiser ?: return
        if (server == null) {
            val opened = manager.openGattServer(context, callback) ?: run { state = "unsupported"; return }
            val service = BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)
            service.addCharacteristic(BluetoothGattCharacteristic(RX,
                BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
                BluetoothGattCharacteristic.PERMISSION_WRITE))
            val notify = BluetoothGattCharacteristic(TX, BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                BluetoothGattCharacteristic.PERMISSION_READ)
            notify.addDescriptor(BluetoothGattDescriptor(CCCD,
                BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE))
            service.addCharacteristic(notify)
            opened.addService(service)
            server = opened
            tx = notify
        }
        if (!advertising) {
            advertising = true
            val settings = AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
                .setConnectable(true).setTimeout(0).build()
            val data = AdvertiseData.Builder().addServiceUuid(ParcelUuid(SERVICE)).setIncludeDeviceName(false).build()
            val scan = AdvertiseData.Builder().setIncludeDeviceName(true).build()
            runCatching { advertiser.startAdvertising(settings, data, scan, advertiseCallback) }
                .onFailure { advertising = false; state = "unsupported" }
        }
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) { state = "advertising" }
        override fun onStartFailure(errorCode: Int) {
            io.execute {
                if (errorCode == ADVERTISE_FAILED_ALREADY_STARTED) { state = "advertising"; return@execute }
                if (errorCode == ADVERTISE_FAILED_DATA_TOO_LARGE) {
                    // The projector name does not fit the scan response; advertise the service alone.
                    val settings = AdvertiseSettings.Builder().setConnectable(true).setTimeout(0)
                        .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY).build()
                    runCatching {
                        manager.adapter?.bluetoothLeAdvertiser?.startAdvertising(settings,
                            AdvertiseData.Builder().addServiceUuid(ParcelUuid(SERVICE)).build(), this)
                    }
                    return@execute
                }
                advertising = false
                state = "advertise_failed"
            }
        }
    }

    private val callback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            io.execute {
                if (newState == BluetoothProfile.STATE_CONNECTED) peers[device.address] = Peer(device)
                else peers.remove(device.address)
                connected = peers.size
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            io.execute { peers[device.address]?.mtu = mtu.coerceIn(23, 517) }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice, requestId: Int, characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray?,
        ) {
            val ok = characteristic.uuid == RX && !preparedWrite && offset == 0 && value != null && value.isNotEmpty()
            if (responseNeeded) {
                server?.sendResponse(device, requestId,
                    if (ok) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED, 0, null)
            }
            if (ok) io.execute { receive(device, value!!) }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice, requestId: Int, descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray?,
        ) {
            if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            io.execute {
                peers[device.address]?.subscribed = descriptor.uuid == CCCD &&
                    value?.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == true
            }
        }

        override fun onDescriptorReadRequest(device: BluetoothDevice, requestId: Int, offset: Int, descriptor: BluetoothGattDescriptor) {
            val on = peers[device.address]?.subscribed == true
            server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0,
                if (on) BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE else BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE)
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            io.execute { peers[device.address]?.let { it.sendingSince = 0; pump(it) } }
        }
    }

    // ---- framing ----

    private fun receive(device: BluetoothDevice, value: ByteArray) {
        val peer = peers[device.address] ?: Peer(device).also { peers[device.address] = it; connected = peers.size }
        if (peer.inbox.size() + value.size > MAX_FRAME) { peer.inbox.reset(); return }
        peer.inbox.write(value, 1, value.size - 1)
        if (value[0].toInt() and 0x80 == 0) return
        val frame = peer.inbox.toByteArray()
        peer.inbox.reset()
        runCatching { handleFrame(peer, frame) }
    }

    private fun send(peer: Peer, frame: ByteArray) {
        val chunk = (peer.mtu - 4).coerceAtLeast(19)
        var offset = 0
        do {
            val end = minOf(frame.size, offset + chunk)
            val part = ByteArray(1 + end - offset)
            part[0] = if (end == frame.size) 0x80.toByte() else 0
            System.arraycopy(frame, offset, part, 1, end - offset)
            peer.outbox.addLast(part)
            offset = end
        } while (offset < frame.size)
        if (peer.outbox.size > 600) repeat(peer.outbox.size - 600) { peer.outbox.removeFirst() }
        pump(peer)
    }

    private fun pump(peer: Peer) {
        val now = SystemClock.elapsedRealtime()
        if (peer.sendingSince != 0L && now - peer.sendingSince < 800) return
        val part = peer.outbox.removeFirstOrNull() ?: return
        val characteristic = tx ?: return
        val gatt = server ?: return
        peer.sendingSince = now
        val sent = if (Build.VERSION.SDK_INT >= 33) {
            gatt.notifyCharacteristicChanged(peer.device, characteristic, false, part) == android.bluetooth.BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION")
            characteristic.value = part
            @Suppress("DEPRECATION")
            gatt.notifyCharacteristicChanged(peer.device, characteristic, false)
        }
        if (!sent) { peer.sendingSince = 0; peer.outbox.addFirst(part) }
    }

    // ---- crypto ----

    private fun handleFrame(peer: Peer, frame: ByteArray) {
        when (frame.firstOrNull()?.toInt()) {
            0x01 -> handshake(peer, frame.copyOfRange(1, frame.size))
            0x03 -> {
                val key = peer.key ?: return
                val plain = runCatching { BleCrypto.open(key, frame.copyOfRange(1, frame.size)) }.getOrNull() ?: return
                request(peer, plain.decodeToString())
            }
        }
    }

    private fun handshake(peer: Peer, clientKey: ByteArray) {
        val pair = BleCrypto.keyPair()
        val salt = ByteArray(16).also(random::nextBytes)
        peer.key = BleCrypto.sessionKey(pair.private, clientKey, salt) ?: return
        peer.token = null
        peer.lastStatus = null
        send(peer, byteArrayOf(0x02) + BleCrypto.x963(pair.public) + salt)
    }

    private fun reply(peer: Peer, message: JSONObject) {
        val key = peer.key ?: return
        send(peer, byteArrayOf(0x03) + BleCrypto.seal(key, message.toString().toByteArray()))
    }

    // ---- requests ----

    private fun request(peer: Peer, text: String) {
        val message = try { JSONObject(text) } catch (_: JSONException) { return }
        val id = message.opt("id") as? Int ?: return
        val op = message.opt("op") as? String ?: return
        val address = peer.device.address
        work.execute {
            val response = try {
                when (op) {
                    "pair" -> {
                        val pin = (message.opt("pin") as? String)?.takeIf { it.matches(Regex("[0-9]{6}")) }
                            ?: throw ApiProblem(400, "bad_request")
                        val token = sessions.pair("ble:$address", pin)
                        io.execute { peers[address]?.token = token }
                        JSONObject().put("paired", true).put("token", token)
                    }
                    "auth" -> {
                        val token = message.opt("token") as? String
                        if (!sessions.valid(token)) throw ApiProblem(401, "unauthorized")
                        io.execute { peers[address]?.token = token }
                        JSONObject().put("paired", true)
                    }
                    else -> {
                        if (!sessions.valid(tokenOf(address))) throw ApiProblem(401, "unauthorized")
                        val commands = router() ?: throw ApiProblem(503, "busy")
                        commands.handle(op, message)
                    }
                }.put("id", id).put("ok", true)
            } catch (problem: ApiProblem) {
                JSONObject().put("id", id).put("ok", false).put("error", problem.code)
            } catch (_: Exception) {
                JSONObject().put("id", id).put("ok", false).put("error", "internal_error")
            }
            io.execute { peers[address]?.let { reply(it, response) } }
        }
    }

    private fun tokenOf(address: String): String? =
        io.submit<String?> { peers[address]?.token }.get(1, TimeUnit.SECONDS)

    private fun tick() {
        ensureRunning()
        val listeners = peers.values.filter { it.subscribed && it.key != null && it.token != null }
        listeners.forEach { if (it.sendingSince != 0L) pump(it) }
        if (listeners.isEmpty() || statusBusy) return
        statusBusy = true
        work.execute {
            val status = runCatching { router()?.status()?.toString() }.getOrNull()
            io.execute {
                statusBusy = false
                if (status == null) return@execute
                for (peer in peers.values) {
                    if (!peer.subscribed || peer.key == null || !sessions.valid(peer.token)) continue
                    if (peer.lastStatus == status) continue
                    peer.lastStatus = status
                    reply(peer, JSONObject().put("op", "status").put("status", JSONObject(status)))
                }
            }
        }
    }

    companion object {
        val SERVICE: UUID = UUID.fromString("6b1e0001-5eaf-4c1a-9c1e-bea3decc0001")
        val RX: UUID = UUID.fromString("6b1e0002-5eaf-4c1a-9c1e-bea3decc0001")
        val TX: UUID = UUID.fromString("6b1e0003-5eaf-4c1a-9c1e-bea3decc0001")
        private val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        private const val MAX_FRAME = 16 * 1024
    }
}
