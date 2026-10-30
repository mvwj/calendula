package app.calendula.calendula;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.os.SystemClock;
import android.os.PowerManager;
import java.io.File;
import java.io.FileInputStream;
import java.security.MessageDigest;
import java.util.Arrays;

/** Own-app checks: common-feed downloads or local headless widget updates.
 * Reads only technical stamps/encrypted cache bytes, never calendar, GPS or keys.
 */
public class PrivateRefreshInstrumentation extends SyncDeviceInstrumentation {
    private boolean extendedCheck;
    private boolean localPlans;
    @Override public void onCreate(Bundle args) {
        localPlans = "local-plans".equals(args.getString("checkMode", ""));
        extendedCheck = args.containsKey("checkMode") && !localPlans;
        super.onCreate(args);
    }
    @Override public void onStart() {
        if (extendedCheck) { super.onStart(); return; }
        if (localPlans) { checkLocalPlans(); return; }
        Context c = getTargetContext();
        Intent service = new Intent().setClassName(c, "app.calendula.calendula.LiveUpdatesService");
        Bundle result = new Bundle();
        int outcome = Activity.RESULT_CANCELED;
        try {
            SharedPreferences p = c.getSharedPreferences("public-transit-state", Context.MODE_PRIVATE);
            long baseline = p.getLong("liveChecked", 0);
            c.startForegroundService(service);
            long first = awaitDownload(p, baseline, 180_000);
            Bundle progress = new Bundle(); progress.putString("stream", "First private background download completed. Waiting for the next periodic download.\n");
            sendStatus(1, progress);
            long second = awaitDownload(p, first, 180_000);
            result.putString("stream", "PASS: two private PID downloads with no visible calendar UI.\n");
            result.putLong("firstPublicDownloadMillis", first);
            result.putLong("secondPublicDownloadMillis", second);
            result.putLong("intervalMillis", second - first);
            outcome = Activity.RESULT_OK;
        } catch (Throwable error) {
            result.putString("stream", "FAIL: " + error.getClass().getSimpleName() + ": " + error.getMessage() + "\n");
            SharedPreferences p = c.getSharedPreferences("public-transit-state", Context.MODE_PRIVATE);
            result.putLong("lastPublicDownloadMillis", p.getLong("liveChecked", 0));
            result.putLong("publicRetryAtMillis", p.getLong("liveRetryAt", 0));
            result.putString("publicUpdateError", p.getString("error", "none"));
        } finally {
            c.stopService(service);
        }
        finish(outcome, result);
    }
    private long awaitDownload(SharedPreferences p, long previous, long timeout) {
        long deadline = SystemClock.elapsedRealtime() + timeout;
        while (SystemClock.elapsedRealtime() < deadline) {
            long stamp = p.getLong("liveChecked", 0);
            if (stamp > previous) return stamp;
            SystemClock.sleep(500);
        }
        throw new AssertionError("Common feed did not refresh before its bounded deadline.");
    }

    /** Uses the production bounded service and encrypted widget cache. Reports
     * only stamps/digest-change booleans; never reads calendar, GPS or tokens.
     * The production headless planner itself reads the calendar locally. */
    private void checkLocalPlans() {
        Context c = getTargetContext();
        Bundle result = new Bundle();
        int outcome = Activity.RESULT_CANCELED;
        Intent service = new Intent().setClassName(c, "app.calendula.calendula.LiveUpdatesService");
        try {
            SharedPreferences p = c.getSharedPreferences("public-transit-state", Context.MODE_PRIVATE);
            PowerManager power = (PowerManager) c.getSystemService(Context.POWER_SERVICE);
            long liveBefore = p.getLong("liveChecked", 0);
            c.startForegroundService(service);
            Bundle progress = new Bundle();
            progress.putString("stream", "Local-plan service started. Turn off the screen for two headless updates.\n");
            sendStatus(1, progress);
            long deadline = SystemClock.elapsedRealtime() + 60_000;
            while (power.isInteractive() && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(250);
            if (power.isInteractive()) throw new AssertionError("Screen did not turn off within the bounded check.");
            long baseline = p.getLong("widgetCalculated", 0);
            byte[] before = widgetDigest(c);
            long first = awaitPlan(p, baseline, power, 165_000);
            byte[] afterFirst = widgetDigest(c);
            progress = new Bundle(); progress.putString("stream", "First headless widget update completed with screen off.\n");
            sendStatus(1, progress);
            long second = awaitPlan(p, first, power, 165_000);
            byte[] afterSecond = widgetDigest(c);
            if (Arrays.equals(before, afterFirst) || Arrays.equals(afterFirst, afterSecond))
                throw new AssertionError("Encrypted widget cache did not change twice.");
            result.putString("stream", "PASS: two headless plan updates with screen off; encrypted widget cache changed twice.\n");
            result.putLong("intervalMillis", second - first);
            result.putBoolean("screenOff", !power.isInteractive());
            result.putBoolean("widgetCacheChangedTwice", true);
            result.putBoolean("liveDownloadTimestampUnchanged", liveBefore == p.getLong("liveChecked", 0));
            outcome = Activity.RESULT_OK;
        } catch (Throwable error) {
            result.putString("stream", "FAIL: local-plan check " + error.getClass().getSimpleName() + "\n");
            if (error instanceof AssertionError) result.putString("failureReason", error.getMessage());
        } finally {
            c.stopService(service);
        }
        finish(outcome, result);
    }

    private long awaitPlan(SharedPreferences p, long previous, PowerManager power, long timeout) {
        long deadline = SystemClock.elapsedRealtime() + timeout;
        while (SystemClock.elapsedRealtime() < deadline) {
            if (power.isInteractive()) throw new AssertionError("Screen became interactive during the check.");
            long stamp = p.getLong("widgetCalculated", 0);
            if (stamp > previous) return stamp;
            SystemClock.sleep(500);
        }
        throw new AssertionError("Headless plan did not complete before its bounded deadline.");
    }

    private byte[] widgetDigest(Context c) throws Exception {
        File file = new File(c.getFilesDir(), "widget.vault");
        if (!file.exists()) return new byte[0];
        if (file.length() > 65536) throw new AssertionError("Widget cache exceeds its bound.");
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (FileInputStream input = new FileInputStream(file)) {
            byte[] buffer = new byte[4096];
            int count;
            while ((count = input.read(buffer)) != -1) digest.update(buffer, 0, count);
        }
        return digest.digest();
    }
}
