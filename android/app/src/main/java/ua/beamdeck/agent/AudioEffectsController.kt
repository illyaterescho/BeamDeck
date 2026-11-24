package ua.beamdeck.agent

import android.annotation.TargetApi
import android.media.audiofx.AudioEffect
import android.media.audiofx.DynamicsProcessing
import android.os.Build

internal class AudioEffectsController(private val sessionId: Int) {
    private var effect: AudioEffect? = if (Build.VERSION.SDK_INT >= 28) create() else null
    val available get() = effect != null

    fun update(level: Int) {
        if (Build.VERSION.SDK_INT >= 28) runCatching { applyLevel(level) }.onFailure { release() }
    }

    fun release() {
        effect?.release()
        effect = null
    }

    @TargetApi(28)
    private fun create(): AudioEffect? = runCatching {
        val config = DynamicsProcessing.Config.Builder(
            DynamicsProcessing.VARIANT_FAVOR_TIME_RESOLUTION, 2,
            false, 0, true, 1, false, 0, false,
        ).build()
        DynamicsProcessing(0, sessionId, config)
    }.getOrNull()

    @TargetApi(28)
    private fun applyLevel(level: Int) {
        val dynamics = effect as? DynamicsProcessing ?: return
        val amount = level / 100f
        val band = dynamics.getMbcBandByChannelIndex(0, 0)
        band.threshold = -18f - 9f * amount
        band.ratio = 1f + 3.5f * amount
        band.attackTime = 12f
        band.releaseTime = 180f
        band.postGain = 2f * amount
        band.kneeWidth = 8f
        dynamics.setMbcBandAllChannelsTo(0, band)
        check(dynamics.setEnabled(level > 0) == AudioEffect.SUCCESS)
    }
}
