# Tor's JNI library resolves configuration fields and callbacks by their
# original Java names. Keep the official bridge complete in release builds.
-keep class org.torproject.jni.** { *; }
-keep class app.calendula.calendula.SyncGuard { public *; }
-keep class app.calendula.calendula.DeviceCheckBridge { public *; }
