package app.calendula.calendula

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.io.File

/** Calculate locally after the existing public download; no extra HTTP or GPS. */
object WidgetRefresh {
    private val main = Handler(Looper.getMainLooper())
    private val lock = Any()
    fun run(context: Context, feed: ByteArray?, entryPoint: String = "refreshDayWidget"): Boolean = synchronized(lock) {
        if (Looper.myLooper() == Looper.getMainLooper()) return@synchronized false
        val done = CountDownLatch(1)
        val completed = AtomicBoolean(false)
        var engine: FlutterEngine? = null
        main.post {
            try {
                val loader = FlutterInjector.instance().flutterLoader()
                loader.startInitialization(context); loader.ensureInitializationComplete(context, null)
                val runtime = FlutterEngine(context.applicationContext)
                SyncGuard.register(runtime, context)
                engine = runtime
                MethodChannel(runtime.dartExecutor.binaryMessenger, "app.calendula/background").setMethodCallHandler { call, result ->
                    when (call.method) {
                        "timetableCache" -> {
                            val file = File(context.filesDir, "public-background-pid.zip")
                            val day = context.getSharedPreferences("public-transit-state", Context.MODE_PRIVATE).getString("scheduleDay", "")
                            result.success(if (file.exists() && file.length() <= 150L * 1024 * 1024) mapOf("path" to file.path, "day" to day) else null)
                        }
                        "liveCache" -> result.success(feed ?: try {
                            val file = File(context.filesDir, "public-live.pb")
                            if (file.exists() && file.length() <= 8 * 1024 * 1024) file.readBytes() else null
                        } catch (_: Exception) { null })
                        "complete" -> {
                            completed.set(call.arguments == true)
                            if (call.arguments == true && entryPoint == "refreshDayWidget") context.getSharedPreferences("public-transit-state", Context.MODE_PRIVATE).edit().putLong("widgetCalculated", System.currentTimeMillis()).apply()
                            result.success(null); done.countDown()
                        }
                        else -> result.notImplemented()
                    }
                }
                MethodChannel(runtime.dartExecutor.binaryMessenger, "app.calendula/widget").setMethodCallHandler { call, result ->
                    if (call.method == "update") try { DayWidget.write(context, call.arguments as Map<*, *>); result.success(null) }
                    catch (_: Exception) { result.error("WIDGET", "Widget could not be refreshed.", null) }
                    else result.notImplemented()
                }
                runtime.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(loader.findAppBundlePath(), entryPoint))
            } catch (_: Exception) { done.countDown() }
        }
        try { done.await(75, TimeUnit.SECONDS) && completed.get() }
        finally { main.post { engine?.destroy() } }
    }
}
