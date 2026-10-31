package dev.kanan.myphone

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.DisplayMetrics
import android.view.WindowManager
import org.json.JSONObject
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import kotlin.concurrent.thread
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Shares the phone screen with a PC running myPhone.
 * Screen -> VirtualDisplay -> hardware H.264 encoder -> TCP to the PC (port 4749).
 * The PC sends back input events, which ControlService turns into taps/swipes/text.
 *
 * Frames on the socket, both ways: [type: 1 byte][length: 4 bytes BE][payload].
 *   phone -> PC: 0 hello {id}, 1 info {w,h,control}, 2 H.264 (Annex-B)
 *   PC -> phone: 10 input JSON
 */
class MirrorService : Service() {
    companion object {
        const val EXTRA_CODE = "code"
        const val EXTRA_DATA = "data"
        const val EXTRA_HOST = "host"
        const val EXTRA_PORT = "port"
        const val EXTRA_ID = "id"
        const val ACTION_STOP = "dev.kanan.myphone.STOP_MIRROR"
        @Volatile var running = false
    }

    private var projection: MediaProjection? = null
    private var codec: MediaCodec? = null
    private var display: VirtualDisplay? = null
    private var socket: Socket? = null
    @Volatile private var stopped = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP || intent == null) {
            stop()
            return START_NOT_STICKY
        }
        // Android 14: the foreground service must be running before getMediaProjection().
        if (Build.VERSION.SDK_INT >= 29) startForeground(7, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        else startForeground(7, notification())
        running = true
        thread(name = "mirror") {
            try {
                run(intent)
            } catch (e: Exception) {
                android.util.Log.w("myPhone", "mirror ended: $e")
            } finally {
                Handler(Looper.getMainLooper()).post { stop() }
            }
        }
        return START_NOT_STICKY
    }

    private fun notification(): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) nm.createNotificationChannel(NotificationChannel("mirror", "Screen sharing", NotificationManager.IMPORTANCE_LOW))
        val stop = PendingIntent.getService(this, 0, Intent(this, MirrorService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE)
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, "mirror") else @Suppress("DEPRECATION") Notification.Builder(this)
        return b.setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Sharing your screen with your PC")
            .setContentText("Tap Stop to end")
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, "Stop", stop).build())
            .build()
    }

    private fun realSize(): Pair<Int, Int> {
        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        return if (Build.VERSION.SDK_INT >= 30) {
            val b = wm.maximumWindowMetrics.bounds
            b.width() to b.height()
        } else {
            val m = DisplayMetrics()
            @Suppress("DEPRECATION") wm.defaultDisplay.getRealMetrics(m)
            m.widthPixels to m.heightPixels
        }
    }

    private fun run(intent: Intent) {
        val host = intent.getStringExtra(EXTRA_HOST)!!
        val port = intent.getIntExtra(EXTRA_PORT, 4749)
        val s = Socket().apply {
            tcpNoDelay = true
            connect(InetSocketAddress(host, port), 6000)
        }
        socket = s
        val out = DataOutputStream(BufferedOutputStream(s.getOutputStream(), 1 shl 16))
        fun send(type: Int, payload: ByteArray, len: Int = payload.size) {
            synchronized(out) {
                out.writeByte(type)
                out.writeInt(len)
                out.write(payload, 0, len)
                out.flush()
            }
        }
        send(0, JSONObject().put("id", intent.getStringExtra(EXTRA_ID)).toString().toByteArray())

        // Encode at most 1600 px on the long side (sharp, and easy on Wi-Fi); dimensions multiple of 16.
        val (rw, rh) = realSize()
        val scale = minOf(1.0, 1600.0 / max(rw, rh))
        val w = ((rw * scale) / 16).roundToInt() * 16
        val h = ((rh * scale) / 16).roundToInt() * 16
        send(1, JSONObject().put("w", w).put("h", h).put("control", ControlService.instance != null).toString().toByteArray())

        // PC -> phone input. Coordinates arrive normalized (0..1).
        thread(name = "mirror-input") {
            try {
                val inp = DataInputStream(s.getInputStream())
                while (!stopped) {
                    val type = inp.readByte().toInt()
                    val len = inp.readInt()
                    val buf = ByteArray(len)
                    inp.readFully(buf)
                    if (type == 10) ControlService.instance?.handle(JSONObject(String(buf)), rw, rh)
                }
            } catch (_: Exception) {
            }
            Handler(Looper.getMainLooper()).post { stop() }
        }

        val mpm = getSystemService(MediaProjectionManager::class.java)
        @Suppress("DEPRECATION")
        val data: Intent = intent.getParcelableExtra(EXTRA_DATA)!!
        val mp = mpm.getMediaProjection(intent.getIntExtra(EXTRA_CODE, 0), data) ?: throw IllegalStateException("screen capture was not granted")
        projection = mp
        mp.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                Handler(Looper.getMainLooper()).post { stop() }
            }
        }, Handler(Looper.getMainLooper()))

        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, 6_000_000)
            setInteger(MediaFormat.KEY_FRAME_RATE, 60)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
            setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 33_000) // steady ~30 fps even on a still screen: the PC decoder runs a few frames behind
            setInteger(MediaFormat.KEY_PRIORITY, 0) // realtime
            if (Build.VERSION.SDK_INT >= 30) setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
        }
        val c = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        codec = c
        c.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        val surface = c.createInputSurface()
        c.start()
        display = mp.createVirtualDisplay("myPhone", w, h, resources.displayMetrics.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, surface, null, null)

        val info = MediaCodec.BufferInfo()
        var chunk = ByteArray(1 shl 18)
        while (!stopped) {
            val idx = c.dequeueOutputBuffer(info, 100_000)
            if (idx < 0) continue
            val buf = c.getOutputBuffer(idx)!!
            if (info.size > 0) {
                if (chunk.size < info.size) chunk = ByteArray(info.size)
                buf.position(info.offset)
                buf.get(chunk, 0, info.size)
                send(2, chunk, info.size) // SPS/PPS (codec config) and frames, all Annex-B
            }
            c.releaseOutputBuffer(idx, false)
        }
    }

    private fun stop() {
        if (stopped && !running) return
        stopped = true
        running = false
        try { display?.release() } catch (_: Exception) {}
        try { codec?.stop(); codec?.release() } catch (_: Exception) {}
        try { projection?.stop() } catch (_: Exception) {}
        try { socket?.close() } catch (_: Exception) {}
        display = null; codec = null; projection = null; socket = null
        if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE) else @Suppress("DEPRECATION") stopForeground(true)
        stopSelf()
    }

    override fun onDestroy() {
        stop()
        super.onDestroy()
    }
}
