package app.calendula.calendula;
import android.app.Activity;
import android.app.Instrumentation;
import android.os.Bundle;

/** Dispatches explicitly requested owner-authorized native checks. */
public class SyncDeviceInstrumentation extends Instrumentation {
    private String config, mode;
    @Override public void onCreate(Bundle args) {
        super.onCreate(args);
        config = args.getString("checkConfig", "");
        mode = args.getString("checkMode", "isolated");
        start();
    }
    @Override public void onStart() {
        Bundle result = new Bundle();
        String report = DeviceCheckBridge.run(getTargetContext(), mode, config);
        result.putString("stream", report);
        finish(report.startsWith("PASS") ? Activity.RESULT_OK : Activity.RESULT_CANCELED, result);
    }
}
