package dev.kanan.myphone

import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.provider.Settings
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Receives "Share → myPhone" from other apps and hands the items to Flutter. */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var dartReady = false
    private val queue = mutableListOf<Map<String, Any>>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "myphone/share").apply {
            setMethodCallHandler { call, result ->
                if (call.method == "ready") {
                    dartReady = true
                    queue.forEach { invokeMethod("shared", it) }
                    queue.clear()
                    result.success(null)
                } else result.notImplemented()
            }
        }
        read(intent)
        setupMirror(flutterEngine)
    }

    // ---------- screen sharing to the PC ----------
    private var mirrorArgs: Map<*, *>? = null
    private var mirrorResult: MethodChannel.Result? = null

    private fun controlEnabled(): Boolean {
        val enabled = Settings.Secure.getString(contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
        return enabled.split(':').any { ComponentName.unflattenFromString(it)?.className == ControlService::class.java.name && it.startsWith(packageName) }
    }

    private fun setupMirror(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "myphone/mirror").setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(mapOf("control" to controlEnabled(), "sharing" to MirrorService.running))
                "openControlSettings" -> {
                    startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                }
                "stop" -> {
                    startService(Intent(this, MirrorService::class.java).setAction(MirrorService.ACTION_STOP))
                    result.success(null)
                }
                "start" -> {
                    // Android asks the user every session; nothing is captured without that tap.
                    mirrorArgs = call.arguments as Map<*, *>
                    mirrorResult = result
                    val mpm = getSystemService(MediaProjectionManager::class.java)
                    @Suppress("DEPRECATION")
                    startActivityForResult(mpm.createScreenCaptureIntent(), 4749)
                }
                else -> result.notImplemented()
            }
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 4749) return
        val args = mirrorArgs
        val res = mirrorResult
        mirrorArgs = null
        mirrorResult = null
        if (resultCode != Activity.RESULT_OK || data == null || args == null) {
            res?.success(false)
            return
        }
        val i = Intent(this, MirrorService::class.java)
            .putExtra(MirrorService.EXTRA_CODE, resultCode)
            .putExtra(MirrorService.EXTRA_DATA, data)
            .putExtra(MirrorService.EXTRA_HOST, args["host"] as String)
            .putExtra(MirrorService.EXTRA_PORT, (args["port"] as Number).toInt())
            .putExtra(MirrorService.EXTRA_ID, args["id"] as String)
        if (android.os.Build.VERSION.SDK_INT >= 26) startForegroundService(i) else startService(i)
        res?.success(true)
    }

    // Android 10+ only allows reading the clipboard once our window has focus.
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && dartReady) channel?.invokeMethod("focus", null)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        read(intent)
    }

    private fun deliver(items: Map<String, Any>) = runOnUiThread {
        if (dartReady) channel?.invokeMethod("shared", items) else queue.add(items)
    }

    private fun read(intent: Intent?) {
        if (intent == null) return
        val uris = when (intent.action) {
            Intent.ACTION_SEND -> listOfNotNull(intent.parcelable(Intent.EXTRA_STREAM))
            Intent.ACTION_SEND_MULTIPLE -> intent.parcelableList(Intent.EXTRA_STREAM)
            else -> return
        }
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)?.takeIf { uris.isEmpty() } ?: ""
        intent.action = Intent.ACTION_MAIN // don't re-handle on rotation
        // Copy off the UI thread: shared videos can be gigabytes.
        Thread {
            val paths = uris.mapNotNull { copy(it) }
            if (paths.isNotEmpty() || text.isNotEmpty()) deliver(mapOf("paths" to paths, "text" to text))
        }.start()
    }

    /** content:// URIs are only readable now, so copy into our cache with the original name. */
    private fun copy(uri: Uri): String? = try {
        var name = "shared-${System.currentTimeMillis()}"
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst() && !it.isNull(0)) name = it.getString(0)
        }
        name = name.substringAfterLast('/').ifBlank { "file" }
        val dir = File(cacheDir, "shared/${System.nanoTime()}").apply { mkdirs() }
        val out = File(dir, name)
        contentResolver.openInputStream(uri)!!.use { input -> out.outputStream().use { input.copyTo(it) } }
        out.absolutePath
    } catch (e: Exception) {
        null
    }

    @Suppress("DEPRECATION")
    private fun Intent.parcelable(key: String): Uri? =
        if (Build.VERSION.SDK_INT >= 33) getParcelableExtra(key, Uri::class.java) else getParcelableExtra(key)

    @Suppress("DEPRECATION")
    private fun Intent.parcelableList(key: String): List<Uri> =
        (if (Build.VERSION.SDK_INT >= 33) getParcelableArrayListExtra(key, Uri::class.java) else getParcelableArrayListExtra(key)) ?: emptyList()
}
