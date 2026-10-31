package dev.kanan.myphone

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Build
import android.os.Bundle
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONObject

/**
 * Turns the PC's mouse/keyboard input into taps, swipes, system buttons and typing.
 * Only active while the user has enabled "myPhone" under Settings → Accessibility,
 * and only fed by MirrorService while a screen-sharing session the user started is running.
 */
class ControlService : AccessibilityService() {
    companion object {
        @Volatile var instance: ControlService? = null
    }

    override fun onServiceConnected() {
        instance = this
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        if (instance === this) instance = null
        return super.onUnbind(intent)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() {}

    /** [w], [h]: real screen size; event coordinates are 0..1. */
    fun handle(j: JSONObject, w: Int, h: Int) {
        fun px(x: Double) = (x * w).toFloat().coerceIn(0f, w - 1f)
        fun py(y: Double) = (y * h).toFloat().coerceIn(0f, h - 1f)
        when (j.optString("a")) {
            "tap" -> stroke(Path().apply { moveTo(px(j.getDouble("x")), py(j.getDouble("y"))) }, 40)
            "long" -> stroke(Path().apply { moveTo(px(j.getDouble("x")), py(j.getDouble("y"))) }, 650)
            "swipe" -> {
                val pts = j.getJSONArray("pts")
                if (pts.length() < 2) return
                val p = Path()
                for (i in 0 until pts.length()) {
                    val pt = pts.getJSONArray(i)
                    if (i == 0) p.moveTo(px(pt.getDouble(0)), py(pt.getDouble(1))) else p.lineTo(px(pt.getDouble(0)), py(pt.getDouble(1)))
                }
                stroke(p, j.optLong("ms", 250).coerceIn(40, 3000))
            }
            "scroll" -> {
                // Mouse wheel: a short fling. dy > 0 = wheel down = content moves up.
                val x = px(j.getDouble("x"))
                val y = py(j.getDouble("y"))
                val d = (j.getDouble("dy") * h * 0.35).toFloat()
                stroke(Path().apply { moveTo(x, y); lineTo(x, (y - d).coerceIn(1f, h - 2f)) }, 180)
            }
            "back" -> performGlobalAction(GLOBAL_ACTION_BACK)
            "home" -> performGlobalAction(GLOBAL_ACTION_HOME)
            "recents" -> performGlobalAction(GLOBAL_ACTION_RECENTS)
            "notifications" -> performGlobalAction(GLOBAL_ACTION_NOTIFICATIONS)
            "lock" -> if (Build.VERSION.SDK_INT >= 28) performGlobalAction(GLOBAL_ACTION_LOCK_SCREEN)
            "text" -> editFocused { it + j.getString("s") }
            "backspace" -> editFocused { it.dropLast(1) }
            "enter" -> {
                val n = rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return
                if (Build.VERSION.SDK_INT >= 30) n.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)
                else editFocused { "$it\n" }
            }
        }
    }

    private fun stroke(path: Path, ms: Long) {
        val g = GestureDescription.Builder().addStroke(GestureDescription.StrokeDescription(path, 0, ms)).build()
        dispatchGesture(g, null, null)
    }

    private fun editFocused(change: (String) -> String) {
        val n = rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return
        val showingHint = Build.VERSION.SDK_INT >= 26 && n.isShowingHintText
        val cur = if (showingHint) "" else (n.text?.toString() ?: "")
        val next = change(cur)
        n.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, next)
        })
        n.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, Bundle().apply {
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, next.length)
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, next.length)
        })
    }
}
