package app.calendula.calendula;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import java.io.FileNotFoundException;
import java.nio.charset.StandardCharsets;

/** Test APK only: supplies one synthetic attachment with a temporary URI grant. */
public class SharedFixtureProvider extends ContentProvider {
    static final String ICS = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:android-share-fixture\nSUMMARY:Shared attachment check\nLOCATION:Praha\nDTSTART:20261006T160000Z\nDTEND:20261006T180000Z\nEND:VEVENT\nEND:VCALENDAR\n";
    @Override public boolean onCreate() { return true; }
    @Override public String getType(Uri uri) { return "text/calendar"; }
    @Override public Cursor query(Uri uri, String[] projection, String selection, String[] args, String sort) {
        String[] columns = projection == null ? new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE} : projection;
        MatrixCursor cursor = new MatrixCursor(columns);
        Object[] row = new Object[columns.length];
        for (int i = 0; i < columns.length; i++) row[i] = columns[i].equals(OpenableColumns.DISPLAY_NAME) ? "synthetic-invitation.ics" : ICS.length();
        cursor.addRow(row); return cursor;
    }
    @Override public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        if (!mode.equals("r")) throw new FileNotFoundException("Read only");
        try {
            ParcelFileDescriptor[] pipe = ParcelFileDescriptor.createPipe();
            new Thread(() -> {
                try (var output = new ParcelFileDescriptor.AutoCloseOutputStream(pipe[1])) { output.write(ICS.getBytes(StandardCharsets.UTF_8)); }
                catch (Exception ignored) { }
            }).start();
            return pipe[0];
        } catch (Exception e) { throw new FileNotFoundException("Fixture unavailable"); }
    }
    @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException(); }
    @Override public int delete(Uri uri, String selection, String[] args) { throw new UnsupportedOperationException(); }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] args) { throw new UnsupportedOperationException(); }
}
