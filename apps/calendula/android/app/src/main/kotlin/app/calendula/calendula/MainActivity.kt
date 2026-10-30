package app.calendula.calendula

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.app.AlertDialog
import android.app.Activity
import android.content.Intent
import android.provider.OpenableColumns
import java.io.ByteArrayOutputStream
import android.Manifest
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationManager
import android.location.LocationListener
import android.net.ConnectivityManager
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.os.Bundle
import android.net.Uri

class MainActivity : FlutterActivity() {
    private var shareChannel: MethodChannel? = null
    private val shared = ArrayList<Map<String, Any>>()
    private var sharesInFlight = 0
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        receiveShare(intent)
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        receiveShare(intent)
    }
    @Suppress("DEPRECATION")
    private fun receiveShare(incoming: Intent?) {
        if (incoming == null || incoming.action !in listOf(Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE, Intent.ACTION_VIEW)) return
        if (shared.size + sharesInFlight >= 3) return
        sharesInFlight++
        Thread {
            val payload = HashMap<String, Any>()
            try {
                val text = incoming.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString() ?: incoming.clipData?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString() ?: ""
                val subject = incoming.getStringExtra(Intent.EXTRA_SUBJECT) ?: ""
                if (text.length + subject.length > 200000) throw IllegalArgumentException("Shared text exceeds 200,000 characters.")
                payload["text"] = text
                payload["subject"] = subject
                val uris = ArrayList<Uri>()
                if (incoming.action == Intent.ACTION_VIEW) incoming.data?.let { uris.add(it) }
                else if (incoming.action == Intent.ACTION_SEND_MULTIPLE) incoming.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.addAll(it) }
                else incoming.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.add(it) }
                if (uris.isEmpty()) incoming.clipData?.let { clip ->
                    for (n in 0 until minOf(clip.itemCount, 4)) clip.getItemAt(n).uri?.let { uris.add(it) }
                }
                if (uris.distinct().size > 3) throw IllegalArgumentException("Share up to three files at a time.")
                val files = ArrayList<Map<String, Any>>()
                var total = 0
                for (uri in uris.distinct()) {
                    if (uri.scheme != "content") throw IllegalArgumentException("Share a local attachment using Android's file permissions.")
                    var name = when (contentResolver.getType(uri)) {
                        "text/calendar", "application/ics" -> "invitation.ics"
                        "application/pdf" -> "invitation.pdf"
                        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" -> "schedule.xlsx"
                        "message/rfc822" -> "invitation.eml"
                        else -> "shared.txt"
                    }
                    contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                        if (cursor.moveToFirst() && !cursor.isNull(0)) name = cursor.getString(0).take(200)
                    }
                    val buffer = ByteArrayOutputStream()
                    contentResolver.openInputStream(uri)?.use { input ->
                        val bytes = ByteArray(8192)
                        while (true) {
                            val count = input.read(bytes)
                            if (count < 0) break
                            total += count
                            if (total > 20 * 1024 * 1024) throw IllegalArgumentException("Shared files exceed 20 MB in total.")
                            buffer.write(bytes, 0, count)
                        }
                    } ?: throw IllegalArgumentException("The shared attachment could not be read.")
                    files.add(mapOf("name" to name, "bytes" to buffer.toByteArray()))
                }
                payload["files"] = files
            } catch (e: Exception) {
                payload.clear()
                payload["error"] = if (e is IllegalArgumentException) e.message ?: "Invalid shared invitation." else "The shared attachment could not be read. Share it again from its mail app."
            }
            runOnUiThread {
                sharesInFlight--
                shared.add(payload)
                shareChannel?.invokeMethod("pending", null)
            }
        }.start()
    }
    private val mailAuthorization by lazy { MailAuthorization(this) }
    private var fileResult: MethodChannel.Result? = null
    private val csvRequest = 6217
    private val saveRequest = 6231
    private var saveResult: MethodChannel.Result? = null
    private var saveBytes: ByteArray? = null
    private var locationResult: MethodChannel.Result? = null
    private var locationCancel: CancellationSignal? = null
    private var locationListener: LocationListener? = null
    private val locationHandler = Handler(Looper.getMainLooper())
    private val locationTimeout = Runnable { finishLocation(null, "Location timed out. Try outdoors or choose an address.") }
    private val locationRequest = 6218
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        shareChannel = MethodChannel(engine.dartExecutor.binaryMessenger, "app.calendula/share").apply {
            setMethodCallHandler { call, result ->
                if (call.method == "takePending") {
                    val next = shared.toList()
                    shared.clear()
                    result.success(next)
                } else result.notImplemented()
            }
        }
        SyncGuard.register(engine, applicationContext)
        MethodChannel(engine.dartExecutor.binaryMessenger, "app.calendula/mail").setMethodCallHandler { call, result ->
            if (call.method == "gmailToken") mailAuthorization.authorize(
                call.argument<Boolean>("interactive") ?: false,
                call.argument<String>("email"),
                call.argument<Boolean>("chooseAccount") ?: false,
                result)
            else result.notImplemented()
        }
        PrivateTransit.configure(this, PrivateTransit.enabled(this), getSharedPreferences("public-transit-state", MODE_PRIVATE).getBoolean("background", true))
        MethodChannel(engine.dartExecutor.binaryMessenger, "app.calendula/private-transit").setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(PrivateTransit.status(this))
                "invalidateTimetable" -> { PrivateTransit.invalidateTimetable(this); result.success(null) }
                "configure" -> {
                    PrivateTransit.configure(this, call.argument<Boolean>("enabled") ?: true, call.argument<Boolean>("background") ?: true)
                    result.success(PrivateTransit.status(this))
                }
                "startActive" -> {
                    if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
                        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 6219)
                    startForegroundService(Intent(this, LiveUpdatesService::class.java))
                    result.success(null)
                }
                "stopActive" -> { stopService(Intent(this, LiveUpdatesService::class.java)); result.success(null) }
                "live", "timetable", "check", "google", "mail", "imapProxy" -> Thread {
                    try {
                        val value: Any = when (call.method) {
                            "imapProxy" -> PrivateTransit.imapProxy(applicationContext)
                            "live" -> PrivateTransit.live(applicationContext)
                            "timetable" -> PrivateTransit.timetable(applicationContext)
                            "google" -> PrivateTransit.google(applicationContext, call.argument<String>("key") ?: "", call.argument<String>("body") ?: "")
                            "mail" -> PrivateTransit.mail(applicationContext, call.argument<String>("url") ?: "", call.argument<String>("verb") ?: "GET", call.argument<String>("token") ?: "", call.argument<String>("body") ?: "")
                            else -> PrivateTransit.check(applicationContext)
                        }
                        runOnUiThread { result.success(value) }
                    } catch (e: Exception) { runOnUiThread { result.error("PRIVATE_NETWORK", e.message ?: "Private networking unavailable.", null) } }
                }.start()
                else -> result.notImplemented()
            }
        }
        MethodChannel(engine.dartExecutor.binaryMessenger, "app.calendula/network").setMethodCallHandler { call, result ->
            if (call.method == "metered") result.success((getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager).isActiveNetworkMetered)
            else result.notImplemented()
        }
        MethodChannel(engine.dartExecutor.binaryMessenger, "app.calendula/location").setMethodCallHandler { call, result ->
            if (call.method != "current") result.notImplemented()
            else if (locationResult != null) result.error("LOCATION_BUSY", "Location request is already running.", null)
            else {
                locationResult = result
                if (checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) != PackageManager.PERMISSION_GRANTED &&
                    checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
                    requestPermissions(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION), locationRequest)
                } else readLocation()
            }
        }
        MethodChannel(engine.dartExecutor.binaryMessenger, "app.calendula/import").setMethodCallHandler { call, result ->
            if (call.method == "saveFile") {
                if (saveResult != null) result.error("FILE_BUSY", "A save chooser is already open.", null)
                else {
                    val bytes = call.argument<ByteArray>("bytes")
                    if (bytes == null || bytes.size > 8 * 1024 * 1024) result.error("FILE_SIZE", "Encrypted export exceeds its size limit.", null)
                    else {
                        saveBytes = bytes; saveResult = result
                        try { startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply { addCategory(Intent.CATEGORY_OPENABLE); type = "application/octet-stream"; putExtra(Intent.EXTRA_TITLE, "calendar.calsync") }, saveRequest) }
                        catch (_: Exception) { saveBytes = null; saveResult = null; result.error("FILE_SAVE", "Save chooser is unavailable.", null) }
                    }
                }
            } else if (call.method != "pickCsv") result.notImplemented()
            else if (fileResult != null) result.error("FILE_BUSY", "A file chooser is already open", null)
            else {
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                    putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("text/csv", "text/comma-separated-values", "text/plain", "application/vnd.ms-excel", "application/octet-stream"))
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                fileResult = result
                try { startActivityForResult(intent, csvRequest) }
                catch (_: Exception) { fileResult = null; result.error("FILE_OPEN", "File chooser is unavailable", null) }
            }
        }
        MethodChannel(engine.dartExecutor.binaryMessenger, "app.calendula/widget").setMethodCallHandler { call, result ->
            if (call.method == "update") {
                try { DayWidget.write(this, call.arguments as Map<*, *>); result.success(null) }
                catch (_: Exception) { result.error("WIDGET_CACHE", "Widget could not be updated", null) }
            } else if (call.method == "preview") {
                try {
                    val view = DayWidget.views(this).apply(this, null)
                    val dialog = AlertDialog.Builder(this).setView(view).setPositiveButton("Close", null).create()
                    dialog.show()
                    val metrics = resources.displayMetrics
                    // Leave room for all three day entries, the two journey rows
                    // and Close, while fitting smaller phone displays too.
                    dialog.window?.setLayout(
                        minOf((340 * metrics.density).toInt(), metrics.widthPixels - (32 * metrics.density).toInt()),
                        minOf((520 * metrics.density).toInt(), metrics.heightPixels - (96 * metrics.density).toInt()))
                    result.success(null)
                } catch (_: Exception) { result.error("WIDGET_PREVIEW", "Widget preview unavailable", null) }
            } else result.notImplemented()
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grants: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grants)
        if (requestCode != locationRequest) return
        if (checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
            checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED) readLocation()
        else finishLocation(null, "Location permission was not granted. Choose home or another address.")
    }

    @Suppress("MissingPermission", "DEPRECATION")
    private fun readLocation() {
        val manager = getSystemService(LOCATION_SERVICE) as LocationManager
        try {
            val fine = checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
            val providers = listOf(LocationManager.NETWORK_PROVIDER, LocationManager.GPS_PROVIDER).filter {
                manager.isProviderEnabled(it) && (it != LocationManager.GPS_PROVIDER || fine)
            }
            if (providers.isEmpty()) { finishLocation(null, "Location is turned off or unavailable. Enable it or choose an address."); return }
            val known = providers.mapNotNull { manager.getLastKnownLocation(it) }.filter {
                val age = (SystemClock.elapsedRealtimeNanos() - it.elapsedRealtimeNanos) / 1_000_000
                age in 0..120_000 && it.hasAccuracy() && it.accuracy <= 1000
            }.minByOrNull { it.accuracy }
            if (known != null) { finishLocation(known, null); return }
            locationHandler.postDelayed(locationTimeout, 30_000)
            if (Build.VERSION.SDK_INT >= 30) {
                val cancel = CancellationSignal()
                locationCancel = cancel
                providers.forEach { provider -> manager.getCurrentLocation(provider, cancel, mainExecutor) { point ->
                    if (point != null) finishLocation(point, null)
                } }
            } else {
                val listener = object : LocationListener { override fun onLocationChanged(point: Location) { finishLocation(point, null) } }
                locationListener = listener
                manager.requestSingleUpdate(providers.first(), listener, Looper.getMainLooper())
            }
        } catch (_: Exception) { finishLocation(null, "Location could not be read. Choose an address or try again.") }
    }

    @Suppress("MissingPermission")
    private fun finishLocation(point: Location?, error: String?) {
        val result = locationResult ?: return
        locationResult = null
        locationHandler.removeCallbacks(locationTimeout)
        locationCancel?.cancel(); locationCancel = null
        locationListener?.let { (getSystemService(LOCATION_SERVICE) as LocationManager).removeUpdates(it) }
        locationListener = null
        if (point != null) result.success(mapOf("latitude" to point.latitude, "longitude" to point.longitude, "accuracy" to point.accuracy.toDouble()))
        else result.error("LOCATION_UNAVAILABLE", error, null)
    }

    override fun onDestroy() {
        mailAuthorization.close()
        finishLocation(null, "Location request ended when the app closed.")
        super.onDestroy()
    }

    @Deprecated("Used to receive the document chosen by the system file picker")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (mailAuthorization.activityResult(requestCode, resultCode, data)) return
        if (requestCode == saveRequest) {
            val result = saveResult; val bytes = saveBytes
            saveResult = null; saveBytes = null
            if (result == null || bytes == null) return
            if (resultCode != Activity.RESULT_OK || data?.data == null) { result.success(false); return }
            Thread {
                try { contentResolver.openOutputStream(data.data!!, "wt")?.use { it.write(bytes); it.flush() } ?: throw IllegalStateException(); runOnUiThread { result.success(true) } }
                catch (_: Exception) { runOnUiThread { result.error("FILE_SAVE", "Encrypted export could not be written.", null) } }
            }.start()
            return
        }
        if (requestCode != csvRequest) return
        val result = fileResult ?: return
        fileResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { result.success(null); return }
        // No broad storage access or persistent grant. Only the selected file is read.
        Thread {
            try {
                var name = "schedule.csv"
                contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) name = cursor.getString(0).take(200)
                }
                val buffer = ByteArrayOutputStream()
                contentResolver.openInputStream(uri)?.use { stream ->
                    val chunk = ByteArray(8192)
                    while (true) {
                        val count = stream.read(chunk)
                        if (count < 0) break
                        if (buffer.size() + count > 2 * 1024 * 1024) throw IllegalArgumentException("SIZE")
                        buffer.write(chunk, 0, count)
                    }
                } ?: throw IllegalArgumentException("STREAM")
                val bytes = buffer.toByteArray()
                runOnUiThread { result.success(mapOf("name" to name, "bytes" to bytes)) }
            } catch (e: Exception) {
                val message = if (e is IllegalArgumentException && e.message == "SIZE") "Choose a CSV file smaller than 2 MB." else "The selected file could not be read."
                runOnUiThread { result.error("FILE_READ", message, null) }
            }
        }.start()
    }
}
