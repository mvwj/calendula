package app.calendula.calendula

import android.app.Activity
import android.os.Bundle
import android.view.Gravity
import android.view.WindowManager
import android.widget.TextView
import java.lang.ref.WeakReference

/** Non-exported, own-app foreground for an explicitly requested device check.
 * Prevents Oppo's cached-process killer from stopping a read-only diagnostic. */
class DeviceCheckActivity : Activity() {
    companion object {
        private var active = WeakReference<DeviceCheckActivity>(null)
        fun finishCheck() { active.get()?.finish() }
    }
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        active = WeakReference(this)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val mail = intent.getStringExtra("checkMode") == "mail-read"
        setContentView(TextView(this).apply {
            text = if (mail) "Calendula · device check\n\nReading connected mail…\n\nOnly counts are reported. Messages stay on this device."
                else "Calendula · device check\n\nMeasuring local routes…\n\nUses common Prague places, without your calendar or GPS."
            textSize = 20f
            setTextColor(0xff253d36.toInt())
            setBackgroundColor(0xfff7f7f2.toInt())
            setPadding(48, 48, 48, 48)
            gravity = Gravity.CENTER
        })
    }
    override fun onDestroy() {
        if (active.get() === this) active.clear()
        super.onDestroy()
    }
}
