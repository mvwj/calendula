package app.calendula.calendula

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/** Serializes vault transactions across visible and headless Flutter engines. */
object SyncGuard {
    private val gate = Semaphore(1, true)
    private val main = Handler(Looper.getMainLooper())
    private val sequence = AtomicLong(0)
    @Volatile private var owner = 0L
    private val publicGate = Semaphore(1, true)
    @Volatile private var publicOwner = 0L
    fun register(engine: FlutterEngine, context: android.content.Context) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "app.calendula/public-index").setMethodCallHandler { call, result ->
            when (call.method) {
                "acquire" -> Thread {
                    if (!publicGate.tryAcquire(15, TimeUnit.SECONDS)) main.post { result.error("INDEX_BUSY", "A public index update is running.", null) }
                    else {
                        val token = sequence.incrementAndGet(); publicOwner = token
                        main.post { result.success(token) }
                        main.postDelayed({ releasePublic(token) }, 180_000)
                    }
                }.start()
                "release" -> { releasePublic((call.arguments as? Number)?.toLong() ?: 0); result.success(null) }
                else -> result.notImplemented()
            }
        }
        MethodChannel(engine.dartExecutor.binaryMessenger, "app.calendula/sync-guard").setMethodCallHandler { call, result ->
            when (call.method) {
                "acquire" -> Thread {
                    if (!gate.tryAcquire(15, TimeUnit.SECONDS)) main.post { result.error("SYNC_BUSY", "Another calendar transaction is running.", null) }
                    else {
                        val token = sequence.incrementAndGet(); owner = token
                        main.post { result.success(token) }
                        main.postDelayed({ release(token) }, 30_000)
                    }
                }.start()
                "release" -> { release((call.arguments as? Number)?.toLong() ?: 0); result.success(null) }
                "configureBackground" -> {
                    val enabled = call.arguments == true
                    val manager = androidx.work.WorkManager.getInstance(context.applicationContext)
                    if (!enabled) manager.cancelUniqueWork("calendar-sync")
                    else {
                        val constraints = androidx.work.Constraints.Builder().setRequiredNetworkType(androidx.work.NetworkType.CONNECTED).setRequiresBatteryNotLow(true).build()
                        val request = androidx.work.PeriodicWorkRequestBuilder<CalendarSyncWorker>(15, TimeUnit.MINUTES).setConstraints(constraints).build()
                        manager.enqueueUniquePeriodicWork("calendar-sync", androidx.work.ExistingPeriodicWorkPolicy.UPDATE, request)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
    @Synchronized private fun release(token: Long) {
        if (token != 0L && owner == token) { owner = 0; gate.release() }
    }
    @Synchronized private fun releasePublic(token: Long) {
        if (token != 0L && publicOwner == token) { publicOwner = 0; publicGate.release() }
    }
}
class CalendarSyncWorker(c: android.content.Context,p: androidx.work.WorkerParameters) : androidx.work.Worker(c,p) {
    override fun doWork(): Result = try {
        if (WidgetRefresh.run(applicationContext, null, "synchronizeCalendar")) Result.success() else Result.retry()
    } catch (_: Exception) { Result.retry() }
}
