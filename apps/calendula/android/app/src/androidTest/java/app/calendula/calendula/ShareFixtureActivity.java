package app.calendula.calendula;
import android.app.Activity;
import android.content.ClipData;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;

/** Own test package; hands a fixture to the real receiving activity. */
public class ShareFixtureActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        boolean text = "text".equals(getIntent().getStringExtra("fixture"));
        Intent shared = new Intent(Intent.ACTION_SEND);
        shared.setClassName("app.calendula.calendula", "app.calendula.calendula.MainActivity");
        shared.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        if (text) {
            shared.setType("text/plain");
            shared.putExtra(Intent.EXTRA_SUBJECT, "Synthetic mail invitation");
            shared.putExtra(Intent.EXTRA_TEXT, "Shared text check 2026-10-06 18:00–20:00 | Praha");
        } else {
            Uri uri = Uri.parse("content://app.calendula.calendula.test.share/invitation.ics");
            shared.setType("text/calendar");
            shared.putExtra(Intent.EXTRA_STREAM, uri);
            shared.setClipData(ClipData.newRawUri("Synthetic invitation", uri));
            shared.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        }
        startActivity(shared); finish();
    }
}
