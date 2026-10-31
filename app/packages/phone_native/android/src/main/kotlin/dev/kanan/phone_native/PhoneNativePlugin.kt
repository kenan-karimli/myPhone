package dev.kanan.phone_native

import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.content.ClipboardManager
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

class PhoneNativePlugin : FlutterPlugin {
    companion object {
        // Shared across engines (UI + background service) in the same process.
        private var player: MediaPlayer? = null
        private var savedVolume = -1
        private val main = Handler(Looper.getMainLooper())
    }

    private var channel: MethodChannel? = null
    private var receiver: BroadcastReceiver? = null
    private var appCtx: Context? = null

    override fun onAttachedToEngine(b: FlutterPlugin.FlutterPluginBinding) {
        val ctx = b.applicationContext
        listenForClip(ctx)
        channel = MethodChannel(b.binaryMessenger, "phone_native").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "setClipboard" -> {
                        val cm = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        cm.setPrimaryClip(ClipData.newPlainText("myPhone", call.argument<String>("text") ?: ""))
                        result.success(null)
                    }
                    "getClipboard" -> {
                        val cm = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        result.success(cm.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(ctx)?.toString())
                    }
                    "ring" -> {
                        ring(ctx, call.argument<Int>("seconds") ?: 30)
                        result.success(null)
                    }
                    "stopRing" -> {
                        stop(ctx)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onDetachedFromEngine(b: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        receiver?.let { try { appCtx?.unregisterReceiver(it) } catch (_: Exception) {} }
        receiver = null
    }

    /** Text from the "Send clipboard" tile (ClipActivity) -> Dart, in every engine of this process. */
    private fun listenForClip(ctx: Context) {
        appCtx = ctx
        receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                i.getStringExtra("text")?.let { channel?.invokeMethod("sendClip", it) }
            }
        }
        val f = IntentFilter("dev.kanan.myphone.SEND_CLIP")
        if (Build.VERSION.SDK_INT >= 33) ctx.registerReceiver(receiver, f, Context.RECEIVER_NOT_EXPORTED)
        else ctx.registerReceiver(receiver, f)
    }

    private fun ring(ctx: Context, seconds: Int) {
        stop(ctx)
        val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        // Alarm stream plays even in silent/vibrate mode; max it for the ring, restore after.
        savedVolume = am.getStreamVolume(AudioManager.STREAM_ALARM)
        am.setStreamVolume(AudioManager.STREAM_ALARM, am.getStreamMaxVolume(AudioManager.STREAM_ALARM), 0)
        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM) ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        player = MediaPlayer().apply {
            setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
            setDataSource(ctx, uri)
            isLooping = true
            prepare()
            start()
        }
        main.postDelayed({ stop(ctx) }, seconds * 1000L)
    }

    private fun stop(ctx: Context) {
        main.removeCallbacksAndMessages(null)
        player?.let { try { it.stop() } catch (_: Exception) {}; it.release() }
        player = null
        if (savedVolume >= 0) {
            (ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager).setStreamVolume(AudioManager.STREAM_ALARM, savedVolume, 0)
            savedVolume = -1
        }
    }
}
