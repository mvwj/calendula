package app.calendula.calendula

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.widget.RemoteViews
import java.io.File
import java.security.KeyStore
import java.time.LocalDate
import java.time.ZoneId
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONObject

/** Minimal widget cache stays encrypted at rest, separately from the calendar. */
class DayWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) manager.updateAppWidget(id, views(context))
    }
    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action == Intent.ACTION_DATE_CHANGED || intent.action == Intent.ACTION_TIME_CHANGED || intent.action == Intent.ACTION_TIMEZONE_CHANGED) refresh(context)
    }
    companion object {
        private const val ALIAS = "calendula.widget.v1"
        private fun key(): SecretKey {
            val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
            val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            generator.init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT).setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
            return generator.generateKey()
        }
        @Synchronized fun write(context: Context, data: Map<*, *>) {
            val previous = read(context)
            val incomingRevision = (data["revision"] as? Number)?.toLong() ?: 0
            if (previous != null) {
                val oldRevision = previous.optLong("revision", 0)
                if (oldRevision > incomingRevision) return
                if (oldRevision == incomingRevision && previous.optLong("calculatedAt", 0) > ((data["calculatedAt"] as? Number)?.toLong() ?: 0)) return
            }
            val json = JSONObject(data).toString().toByteArray(Charsets.UTF_8)
            require(json.size <= 32768)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
            val bytes = cipher.iv + cipher.doFinal(json)
            val file = AtomicFile(File(context.filesDir, "widget.vault"))
            val stream = file.startWrite()
            try { stream.write(bytes); file.finishWrite(stream) } catch (e: Exception) { file.failWrite(stream); throw e }
            refresh(context)
        }
        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, DayWidget::class.java))
            for (id in ids) manager.updateAppWidget(id, views(context))
        }
        @Synchronized private fun read(context: Context): JSONObject? = try {
            val bytes = AtomicFile(File(context.filesDir, "widget.vault")).readFully()
            if (bytes.size !in 29..65536) null else {
                val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
                    init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
                }
                JSONObject(String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8))
            }
        } catch (_: Exception) { null }
        fun upcomingJourney(context: Context, now: Long): Boolean {
            return try {
                val data = read(context) ?: return false
                val windows = data.optJSONArray("upcoming") ?: return false
                (0 until windows.length()).any { i ->
                    val window = windows.getJSONArray(i)
                    now >= window.getLong(0) - 90 * 60_000 && now <= window.getLong(1)
                }
            } catch (_: Exception) { false }
        }
        fun views(context: Context): RemoteViews {
            val view = RemoteViews(context.packageName, R.layout.day_widget)
            val today = LocalDate.now(ZoneId.of("Europe/Prague")).toString()
            var data = read(context)
            val generated = data?.optLong("liveGenerated", 0) ?: 0
            val day = data?.optJSONObject("days")?.optJSONObject(today)
            if (day != null) data = day
            val valid = day != null || data?.optString("date") == today
            view.setTextViewText(R.id.widget_heading, if(valid) data!!.optString("heading") else "A new day")
            view.setTextViewText(R.id.widget_leave, if(valid) data!!.optString("leave") else "Open Calendula to refresh")
            view.setTextViewText(R.id.widget_events, if(valid) data!!.optString("events").ifBlank { "A little room to breathe." } else "Your private plans stay on this device.")
            view.setTextViewText(R.id.widget_note, if(valid) data!!.optString("note") else "Tap to open your calendar")
            val nowAge = System.currentTimeMillis() - (data?.optLong("nowAt", 0) ?: 0)
            val nowText = if (valid && nowAge in 0..180_000) data!!.optString("departNow") else ""
            view.setTextViewText(R.id.widget_now, nowText)
            view.setViewVisibility(R.id.widget_now, if (nowText.isBlank()) android.view.View.GONE else android.view.View.VISIBLE)
            if (valid) {
                val checked = context.getSharedPreferences("public-transit-state", Context.MODE_PRIVATE).getLong("liveChecked", 0)
                if (checked > 0) {
                    val clock = java.time.Instant.ofEpochMilli(checked).atZone(ZoneId.of("Europe/Prague")).format(java.time.format.DateTimeFormatter.ofPattern("HH:mm"))
                    val age = System.currentTimeMillis() - if (generated > 0) generated else checked
                    val base = data!!.optString("note")
                    view.setTextViewText(R.id.widget_note, if (age > 180_000 && base.contains("predictions")) "PID data older than 3 minutes · open to replan" else "$base · PID $clock")
                }
            }
            val intent = Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            view.setOnClickPendingIntent(R.id.widget_root, PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            return view
        }
    }
}
