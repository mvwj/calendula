package app.calendula.calendula

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** Called by the separately installed, same-signature test instrumentation.
 * No activity/intent/network endpoint exposes this bridge. Flutter stays inside
 * the target APK so R8 can rename its embedding without breaking test-APK ABI.
 */
object DeviceCheckBridge {
    @JvmStatic fun run(context: Context, mode: String, config: String): String {
        val appContext = context.applicationContext
        val handler = Handler(Looper.getMainLooper())
        val done = CountDownLatch(1)
        val report = AtomicReference("FAIL: bounded device-check timeout\n")
        var engine: FlutterEngine? = null
        handler.post {
            try {
                if (mode == "mail-read" || mode == "journey") {
                    appContext.startActivity(Intent(appContext, DeviceCheckActivity::class.java)
                        .putExtra("checkMode", mode).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                }
                val loader = FlutterInjector.instance().flutterLoader()
                loader.startInitialization(context)
                loader.ensureInitializationComplete(context, null)
                val current = FlutterEngine(appContext)
                engine = current
                SyncGuard.register(current, appContext)
                MethodChannel(current.dartExecutor.binaryMessenger, "app.calendula/mail").setMethodCallHandler { call, result ->
                    if (call.method == "gmailToken" && call.argument<Boolean>("interactive") == false)
                        MailAuthorization.renewReadPermission(appContext, call.argument<String>("email"), result)
                    else result.error("MAIL_LOGIN", "Only existing read permission can be checked.", null)
                }
                MethodChannel(current.dartExecutor.binaryMessenger, "app.calendula/private-transit").setMethodCallHandler { call, result ->
                    if (call.method != "imapProxy" && call.method != "mail") result.notImplemented()
                    else Thread {
                        try {
                            val value: Any = if (call.method == "imapProxy") PrivateTransit.imapProxy(appContext)
                                else PrivateTransit.mail(appContext, call.argument<String>("url") ?: "", call.argument<String>("verb") ?: "GET", call.argument<String>("token") ?: "", call.argument<String>("body") ?: "")
                            handler.post { result.success(value) }
                        }
                        catch (_: Throwable) { handler.post { result.error("PRIVATE_NETWORK", "Private mail unavailable", null) } }
                    }.start()
                }
                MethodChannel(current.dartExecutor.binaryMessenger, "app.calendula/sync-check").setMethodCallHandler { call, result ->
                    when (call.method) {
                        "config" -> result.success(config)
                        "complete" -> { report.set(call.arguments.toString() + "\n"); result.success(null); done.countDown() }
                        else -> result.notImplemented()
                    }
                }
                val entry = when (mode) {
                    "cloud" -> "verifyCloudSync"; "mail" -> "verifyMailTransport"
                    "mail-read" -> "verifyMailboxRead"; "journey" -> "verifyJourneySpeed"
                    else -> "verifySyncDevice"
                }
                current.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(loader.findAppBundlePath(), entry))
            } catch (e: Throwable) { report.set("FAIL: initialization ${e.javaClass.simpleName}\n"); done.countDown() }
        }
        try { done.await(240, TimeUnit.SECONDS) }
        catch (_: InterruptedException) { Thread.currentThread().interrupt(); report.set("FAIL: interrupted\n") }
        finally { handler.post { engine?.destroy(); DeviceCheckActivity.finishCheck() } }
        return report.get()
    }
}
