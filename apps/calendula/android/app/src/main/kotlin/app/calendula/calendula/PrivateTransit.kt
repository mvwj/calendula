package app.calendula.calendula

import android.content.*
import android.net.ConnectivityManager
import android.os.*
import android.os.SystemClock
import androidx.work.*
import org.json.JSONObject
import org.torproject.jni.TorService
import java.io.File
import java.net.*
import java.time.*
import java.time.format.DateTimeFormatter
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.zip.GZIPInputStream
import javax.net.ssl.HttpsURLConnection

// One private transport for UI, periodic work and the active journey service.
// There is deliberately no direct network path or circuit-rotation retry.
object PrivateTransit {
    private val liveUrl = "https://api.golemio.cz/v2/vehiclepositions/gtfsrt/trip_updates.pb"
    private val scheduleUrl = "https://data.pid.cz/PID_GTFS.zip"
    private val mutex = Any()
    private val main = Handler(Looper.getMainLooper())
    private fun prefs(c: Context) = c.getSharedPreferences("public-transit-state", Context.MODE_PRIVATE)
    private fun today() = LocalDate.now(ZoneId.of("Europe/Prague")).toString()
    fun enabled(c: Context) = prefs(c).getBoolean("enabled", true)

    fun configure(c: Context, enabled: Boolean, background: Boolean) {
        prefs(c).edit().putBoolean("enabled", enabled).putBoolean("background", background).commit()
        val manager = WorkManager.getInstance(c)
        if (background) {
            // Local planning has no network constraint: an offline widget can
            // still roll to the next appointment and discard stale predictions.
            manager.enqueueUniquePeriodicWork("local-plans", ExistingPeriodicWorkPolicy.KEEP,
                PeriodicWorkRequest.Builder(TransitWorker::class.java, 15, TimeUnit.MINUTES)
                    .setConstraints(Constraints.Builder().setRequiresBatteryNotLow(true).build())
                    .setInputData(Data.Builder().putString("kind", "plan").build()).build())
        } else manager.cancelUniqueWork("local-plans")
        if (enabled && background) {
            manager.enqueueUniquePeriodicWork("private-live", ExistingPeriodicWorkPolicy.KEEP,
                PeriodicWorkRequest.Builder(TransitWorker::class.java, 15, TimeUnit.MINUTES)
                    .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).setRequiresBatteryNotLow(true).build())
                    .setInputData(Data.Builder().putString("kind", "live").build()).build())
            manager.enqueueUniquePeriodicWork("private-timetable", ExistingPeriodicWorkPolicy.KEEP,
                PeriodicWorkRequest.Builder(TransitWorker::class.java, 24, TimeUnit.HOURS)
                    .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.UNMETERED).setRequiresBatteryNotLow(true).setRequiresStorageNotLow(true).build())
                    .setInputData(Data.Builder().putString("kind", "timetable").build()).build())
        } else {
            manager.cancelUniqueWork("private-live")
            manager.cancelUniqueWork("private-timetable")
            c.stopService(Intent(c, LiveUpdatesService::class.java))
        }
    }

    fun status(c: Context): Map<String, Any?> {
        val p = prefs(c)
        return mapOf("enabled" to enabled(c), "background" to p.getBoolean("background", true),
            "liveChecked" to p.getLong("liveChecked", 0), "liveRetryAt" to p.getLong("liveRetryAt", 0),
            "scheduleChecked" to p.getString("scheduleDay", ""), "activeUntil" to LiveUpdatesService.until,
            "error" to p.getString("error", null), "transport" to "Embedded Tor 0.4.9.13")
    }

    private fun <T> throughTor(c: Context, action: (Int) -> T): T {
        if (!enabled(c)) throw IllegalStateException("Private networking is paused. No direct request was sent.")
        // Binding keeps this daemon alive only while our request/service needs it.
        TorService.getTorrc(c).writeText("SOCKSPort 0\nHTTPTunnelPort 127.0.0.1:auto\nClientOnly 1\nSafeLogging 1\nAvoidDiskWrites 1\n")
        val bound = CountDownLatch(1)
        var service: TorService? = null
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                service = (binder as TorService.LocalBinder).service
                bound.countDown()
            }
            override fun onServiceDisconnected(name: ComponentName) { service = null }
        }
        val didBind = CountDownLatch(1)
        var accepted = false
        main.post {
            accepted = c.bindService(Intent(c, TorService::class.java), connection, Context.BIND_AUTO_CREATE)
            didBind.countDown()
        }
        try {
            if (!didBind.await(10, TimeUnit.SECONDS) || !accepted || !bound.await(15, TimeUnit.SECONDS))
                throw IllegalStateException("Tor could not start. No direct request was sent.")
            val deadline = SystemClock.elapsedRealtime() + 90_000
            while (SystemClock.elapsedRealtime() < deadline) {
                val s = service
                if (!enabled(c)) throw IllegalStateException("Private networking is paused.")
                if (s != null && s.httpTunnelPort > 0 && s.getInfo("status/circuit-established") == "1")
                    return action(s.httpTunnelPort)
                Thread.sleep(200)
            }
            throw IllegalStateException("Tor is still connecting. Cached data remains available.")
        } finally {
            // Reuse the circuit/consensus for nearby refreshes instead of
            // bootstrapping Tor for every small download. Bounded idle lease.
            main.postDelayed({
                if (accepted) {
                    try { c.unbindService(connection) }
                    catch (_: IllegalArgumentException) { /* Context already released its binding. */ }
                }
            }, 5 * 60_000)
        }
    }

    private fun connection(url: String, port: Int): HttpsURLConnection {
        val proxy = Proxy(Proxy.Type.HTTP, InetSocketAddress("127.0.0.1", port))
        return (URL(url).openConnection(proxy) as HttpsURLConnection).apply {
            connectTimeout = 30_000; readTimeout = 30_000; instanceFollowRedirects = false
            setRequestProperty("User-Agent", "Calendula/0.1.3")
            setRequestProperty("Accept-Encoding", "gzip")
        }
    }

    fun imapProxy(c: Context): Int = synchronized(mutex) { throughTor(c) { it } }

    private fun read(conn: HttpsURLConnection, target: File, max: Long) {
        val start = SystemClock.elapsedRealtime()
        val stream = if (conn.contentEncoding == "gzip") GZIPInputStream(conn.inputStream) else conn.inputStream
        stream.use { input -> target.outputStream().use { output ->
            var size = 0L
            val chunk = ByteArray(32768)
            while (true) {
                val n = input.read(chunk); if (n < 0) break
                size += n
                if (size > max || SystemClock.elapsedRealtime() - start > 240_000) throw IllegalStateException("Download exceeds its bounds.")
                output.write(chunk, 0, n)
            }
            output.flush(); output.fd.sync()
        } }
    }

    private fun retry(conn: HttpsURLConnection, now: Long): Long {
        val header = conn.getHeaderField("Retry-After") ?: return 0
        header.toLongOrNull()?.let { return now + it.coerceIn(0, 604800) * 1000 }
        return try { ZonedDateTime.parse(header, DateTimeFormatter.RFC_1123_DATE_TIME).toInstant().toEpochMilli() } catch (_: Exception) { 0 }
    }

    private fun request(c: Context, kind: String, force: Boolean): File = synchronized(mutex) {
        val p = prefs(c); val now = System.currentTimeMillis()
        val file = File(c.filesDir, if (kind == "live") "public-live.pb" else "public-background-pid.zip")
        val usable = file.isFile && (kind != "timetable" || !p.getBoolean("invalidTimetable", false))
        if (!force && kind == "timetable" && p.getString("scheduleDay", "") == today() && usable) return@synchronized file
        val last = p.getLong("${kind}Attempt", 0)
        val minimum = if (kind == "live") 60_000 else 3600_000
        val retryAt = p.getLong("${kind}RetryAt", 0)
        if (now < retryAt || now < last + minimum) {
            if (usable) return@synchronized file
            throw IllegalStateException("Refresh is paused until the next allowed attempt.")
        }
        if (!enabled(c)) throw IllegalStateException("Private networking is paused.")
        p.edit().putLong("${kind}Attempt", now).commit()
        var retry = 0L; var code = 0
        val pending = File(file.path + ".pending")
        try {
            throughTor(c) { port ->
                val conn = connection(if (kind == "live") liveUrl else scheduleUrl, port)
                try {
                    if (kind == "timetable" && usable) {
                        p.getString("etag", null)?.let { conn.setRequestProperty("If-None-Match", it) }
                        p.getString("modified", null)?.let { conn.setRequestProperty("If-Modified-Since", it) }
                    }
                    code = conn.responseCode
                    retry = retry(conn, now)
                    if (code == 304 && usable) {
                        p.edit().putString("scheduleDay", today()).commit()
                    } else {
                        if (code != 200) throw IllegalStateException("Provider returned HTTP $code. Cached data is retained.")
                        read(conn, pending, if (kind == "live") 8L * 1024 * 1024 else 150L * 1024 * 1024)
                        if (!pending.renameTo(file)) throw IllegalStateException("Could not replace the public cache.")
                        if (kind == "timetable") p.edit().putString("etag", conn.getHeaderField("ETag"))
                            .putString("modified", conn.getHeaderField("Last-Modified")).putString("scheduleDay", today()).putBoolean("invalidTimetable", false).commit()
                    }
                    p.edit().putLong("${kind}Checked", System.currentTimeMillis()).putLong("${kind}RetryAt", 0)
                        .putInt("${kind}Failures", 0).remove("error").commit()
                } finally { conn.disconnect() }
            }
        } catch (e: Exception) {
            val failures = (p.getInt("${kind}Failures", 0) + 1).coerceAtMost(10)
            val backoff = if (kind == "live") (60_000L shl (failures - 1).coerceAtMost(4)).coerceAtMost(900_000) else 3600_000L
            val until = maxOf(now + (if (code == 401 || code == 403) 24 * 3600_000L else backoff), retry)
            p.edit().putInt("${kind}Failures", failures).putLong("${kind}RetryAt", until)
                .putString("error", e.message?.take(200) ?: "Private update failed.").commit()
            throw e
        } finally { pending.delete() }
        file
    }

    fun live(c: Context): ByteArray {
        val bytes = request(c, "live", false).readBytes()
        DayWidget.refresh(c)
        return bytes
    }
    fun timetable(c: Context): Map<String, Any?> {
        val f = request(c, "timetable", false)
        return mapOf("path" to f.path, "etag" to prefs(c).getString("etag", null), "modified" to prefs(c).getString("modified", null))
    }
    fun invalidateTimetable(c: Context) = synchronized(mutex) {
        prefs(c).edit().putBoolean("invalidTimetable", true).remove("scheduleDay")
            .remove("etag").remove("modified").commit()
    }
    fun check(c: Context): Map<String, Any?> = synchronized(mutex) {
        throughTor(c) { port ->
            val conn = connection("https://check.torproject.org/api/ip", port)
            try {
                if (conn.responseCode != 200) throw IllegalStateException("Tor verification failed.")
                val stream = if (conn.contentEncoding == "gzip") GZIPInputStream(conn.inputStream) else conn.inputStream
                val text = stream.bufferedReader().use {
                    val result = StringBuilder(); val chars = CharArray(512)
                    while (true) {
                        val count = it.read(chars); if (count < 0) break
                        if (result.length + count > 2048) throw IllegalStateException("Tor verification response exceeds its bound.")
                        result.append(chars, 0, count)
                    }
                    result.toString()
                }
                val result = JSONObject(text)
                if (!result.optBoolean("IsTor")) throw IllegalStateException("Tor was not verified. Networking remains private-only.")
                mapOf("isTor" to true, "ip" to result.optString("IP"))
            } finally { conn.disconnect() }
        }
    }

    fun mail(c: Context, target: String, verb: String, token: String, payload: String): Map<String, Any?> = synchronized(mutex) {
        val u = URL(target)
        require(u.protocol == "https" && u.port == -1 && u.userInfo == null && u.ref == null)
        val read = verb == "GET" && ((u.host == "gmail.googleapis.com" && u.path.startsWith("/gmail/v1/users/me/")) ||
            (u.host == "graph.microsoft.com" && u.path.startsWith("/v1.0/me/")))
        val auth = verb == "POST" && u.host == "login.microsoftonline.com" &&
            u.path in listOf("/common/oauth2/v2.0/devicecode", "/common/oauth2/v2.0/token")
        require(read || auth)
        require(token.length <= 32768 && !token.contains('\n') && !token.contains('\r') && payload.length <= 65536)
        throughTor(c) { port ->
            val conn = connection(target, port)
            try {
                conn.requestMethod = verb
                if (read) conn.setRequestProperty("Authorization", "Bearer $token")
                conn.setRequestProperty("Prefer", "outlook.body-content-type=\"text\"")
                if (auth) {
                    conn.doOutput = true
                    conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
                    conn.outputStream.use { it.write(payload.toByteArray(Charsets.UTF_8)) }
                }
                val code = conn.responseCode
                val output = java.io.ByteArrayOutputStream()
                val raw = if (code in 200..299) conn.inputStream else conn.errorStream
                if (raw != null) {
                    val stream = if (conn.contentEncoding == "gzip") GZIPInputStream(raw) else raw
                    stream.use { input ->
                        val bytes = ByteArray(8192)
                        while (true) {
                            val n = input.read(bytes); if (n < 0) break
                            require(output.size() + n <= 5 * 1024 * 1024)
                            output.write(bytes, 0, n)
                        }
                    }
                }
                mapOf("status" to code, "body" to output.toByteArray(), "retryAfter" to conn.getHeaderField("Retry-After"))
            } finally { conn.disconnect() }
        }
    }
    fun google(c: Context, key: String, payload: String): String = synchronized(mutex) {
        if (!key.matches(Regex("AIza[A-Za-z0-9_-]{20,100}")) || payload.length > 2048) throw IllegalArgumentException("Enter a valid Google Maps key.")
        val body = JSONObject(payload)
        val allowed = setOf("origin", "destination", "arrivalTime", "departureTime", "travelMode", "computeAlternativeRoutes", "languageCode")
        if (body.keys().asSequence().any { it !in allowed } || body.optString("travelMode") != "TRANSIT" || body.has("arrivalTime") == body.has("departureTime")) throw IllegalArgumentException("Invalid minimal route request.")
        for (field in listOf("origin", "destination")) {
            val point = body.getJSONObject(field)
            if (point.has("address")) {
                if (point.length() != 1 || point.getString("address").length !in 1..300) throw IllegalArgumentException("Invalid route address.")
            } else {
                val location = point.getJSONObject("location")
                val coordinates = location.getJSONObject("latLng")
                if (point.length() != 1 || location.length() != 1 || coordinates.length() != 2 || coordinates.getDouble("latitude") !in -90.0..90.0 || coordinates.getDouble("longitude") !in -180.0..180.0) throw IllegalArgumentException("Invalid route point.")
            }
        }
        val p = prefs(c); val now = System.currentTimeMillis()
        if (p.getString("googleDay", "") != today()) p.edit().putString("googleDay", today()).putInt("googleCount", 0).commit()
        if (p.getInt("googleCount", 0) >= 80) throw IllegalStateException("This device's 80-request daily Google budget is exhausted. Local routing remains available.")
        if (now < p.getLong("googleRetryAt", 0) || now < p.getLong("googleAttempt", 0) + 5000) throw IllegalStateException("Google refresh is paused. Try again later.")
        p.edit().putLong("googleAttempt", now).putInt("googleCount", p.getInt("googleCount", 0) + 1).commit()
        var code = 0; var explicitRetry = 0L
        try {
            throughTor(c) { port ->
                val conn = connection("https://routes.googleapis.com/directions/v2:computeRoutes", port)
                try {
                    conn.requestMethod = "POST"; conn.doOutput = true
                    conn.setRequestProperty("Content-Type", "application/json")
                    conn.setRequestProperty("X-Goog-Api-Key", key)
                    conn.setRequestProperty("X-Goog-FieldMask", "routes.duration,routes.distanceMeters,routes.legs.steps.travelMode,routes.legs.steps.staticDuration,routes.legs.steps.transitDetails,routes.legs.steps.navigationInstruction")
                    conn.outputStream.use { it.write(payload.toByteArray(Charsets.UTF_8)) }
                    code = conn.responseCode; explicitRetry = retry(conn, now)
                    if (code != 200) throw IllegalStateException("Google Routes returned HTTP $code. Check key access/quota; no direct retry is used.")
                    val stream = if (conn.contentEncoding == "gzip") GZIPInputStream(conn.inputStream) else conn.inputStream
                    val output = java.io.ByteArrayOutputStream()
                    stream.use { input ->
                        val buffer = ByteArray(8192)
                        while (true) {
                            val n = input.read(buffer); if (n < 0) break
                            if (output.size() + n > 2 * 1024 * 1024) throw IllegalStateException("Route response exceeds its bound.")
                            output.write(buffer, 0, n)
                        }
                    }
                    p.edit().putLong("googleRetryAt", 0).commit()
                    output.toString("UTF-8")
                } finally { conn.disconnect() }
            }
        } catch (e: Exception) {
            p.edit().putLong("googleRetryAt", maxOf(explicitRetry, now + if (code == 401 || code == 403) 24 * 3600_000L else if (code == 429) 900_000 else 60_000)).commit()
            throw e
        }
    }
}

class TransitWorker(c: Context, p: WorkerParameters) : Worker(c, p) {
    override fun doWork(): Result {
        if (inputData.getString("kind") == "plan") {
            val checked = applicationContext.getSharedPreferences("public-transit-state", Context.MODE_PRIVATE).getLong("widgetCalculated", 0)
            if (System.currentTimeMillis() - checked in 0..120_000) return Result.success()
            return if (WidgetRefresh.run(applicationContext, null)) Result.success() else Result.retry()
        }
        if (!PrivateTransit.enabled(applicationContext)) return Result.success()
        if (inputData.getString("kind") == "live" && !DayWidget.upcomingJourney(applicationContext, System.currentTimeMillis())) return Result.success()
        return try {
            val ok = if (inputData.getString("kind") == "timetable") {
                PrivateTransit.timetable(applicationContext)
                WidgetRefresh.run(applicationContext, null)
            } else WidgetRefresh.run(applicationContext, PrivateTransit.live(applicationContext))
            if (ok) Result.success() else Result.retry()
        } catch (_: Exception) {
            try { WidgetRefresh.run(applicationContext, null) } catch (_: Exception) {}
            Result.retry()
        }
    }
}
