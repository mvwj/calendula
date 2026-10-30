package app.calendula.calendula

import android.app.*
import android.content.Intent
import android.os.*
import java.util.concurrent.Executors

class LiveUpdatesService : Service() {
    companion object { @Volatile var until = 0L }
    private val handler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private var refreshLock: PowerManager.WakeLock? = null
    private val inFlight = java.util.concurrent.atomic.AtomicBoolean(false)
    private val loop = object : Runnable {
        override fun run() {
            if (System.currentTimeMillis() >= until || !PrivateTransit.enabled(this@LiveUpdatesService)) { stopSelf(); return }
            if (inFlight.compareAndSet(false, true)) executor.execute {
                try {
                    val feed = if (DayWidget.upcomingJourney(this@LiveUpdatesService, System.currentTimeMillis())) PrivateTransit.live(this@LiveUpdatesService) else null
                    WidgetRefresh.run(this@LiveUpdatesService, feed)
                } catch (_: Exception) {
                    // Provider pauses still allow local recalculation and
                    // removal of expired delay predictions.
                    try { WidgetRefresh.run(this@LiveUpdatesService, null) } catch (_: Exception) {}
                } finally { inFlight.set(false) }
            }
            handler.postDelayed(this, 120_000)
        }
    }
    override fun onCreate() {
        super.onCreate()
        refreshLock = (getSystemService(POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Calendula:live-updates")
            .apply { setReferenceCounted(false) }
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(NotificationChannel("journey-updates", "Live journey updates", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stop = PendingIntent.getService(this, 1, Intent(this, LiveUpdatesService::class.java).setAction("stop"), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val notification = Notification.Builder(this, "journey-updates").setSmallIcon(android.R.drawable.ic_menu_directions)
            .setContentTitle("Calendula · live updates").setContentText("Private PID refresh every 2 minutes, for up to 90 minutes")
            .setContentIntent(open).setOngoing(true).addAction(Notification.Action.Builder(null, "Stop", stop).build()).build()
        startForeground(73, notification)
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "stop") { stopSelf(); return START_NOT_STICKY }
        until = System.currentTimeMillis() + 90 * 60_000
        refreshLock?.acquire(90 * 60_000L)
        handler.removeCallbacks(loop); handler.post(loop)
        return START_NOT_STICKY
    }
    override fun onTimeout(startId: Int, fgsType: Int) { stopSelf() }
    override fun dump(fd: java.io.FileDescriptor, writer: java.io.PrintWriter, args: Array<out String>?) {
        // Diagnostics expose public feed timing only, never calendar windows,
        // coordinates, API keys or route inputs.
        writer.println("activeUntilMillis=$until")
        writer.println("lastPublicDownloadMillis=${PrivateTransit.status(this)["liveChecked"]}")
        writer.println("publicRetryAtMillis=${PrivateTransit.status(this)["liveRetryAt"]}")
        writer.println("publicUpdateError=${PrivateTransit.status(this)["error"]}")
        writer.println("refreshWakeLockHeld=${refreshLock?.isHeld == true}")
    }
    override fun onBind(intent: Intent?) = null
    override fun onDestroy() { until = 0; handler.removeCallbacksAndMessages(null); executor.shutdownNow(); refreshLock?.let { if (it.isHeld) it.release() }; super.onDestroy() }
}
