package dev.kanan.myphone

import android.app.Activity
import android.content.ClipboardManager
import android.content.Intent
import android.widget.Toast

/**
 * Invisible, opened by the "Send clipboard" Quick Settings tile. Android lets an app read
 * the clipboard only while one of its windows has focus, so this grabs it and closes.
 * The text goes (via broadcast) to the running myPhone engine, which sends it to the PC.
 */
class ClipActivity : Activity() {
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus) return
        val cm = getSystemService(ClipboardManager::class.java)
        val text = cm.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(this)?.toString()
        if (text.isNullOrEmpty()) {
            Toast.makeText(this, "Clipboard is empty", Toast.LENGTH_SHORT).show()
        } else {
            sendBroadcast(Intent("dev.kanan.myphone.SEND_CLIP").setPackage(packageName).putExtra("text", text))
            Toast.makeText(this, "Clipboard sent", Toast.LENGTH_SHORT).show()
        }
        finish()
        overridePendingTransition(0, 0)
    }
}
