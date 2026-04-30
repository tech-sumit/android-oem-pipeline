package dev.mayaos.updater;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;
import android.os.SystemProperties;
import android.util.Log;

import org.json.JSONObject;
import org.json.JSONArray;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;

/**
 * Foreground service that polls ota.mayaos.dev for an update on the channel
 * pinned via {@code ro.mayaos.channel} (default {@code stable}). When a newer
 * build is available, it hands the system / vendor / boot images to AOSP's
 * update_engine for an A/B install.
 *
 * <p>Started by:
 * <ul>
 *   <li>{@link BootReceiver} on BOOT_COMPLETED</li>
 *   <li>WorkManager periodic job (every 6h) -- queued by {@link MainActivity}</li>
 *   <li>MDF: {@code adb shell am start-foreground-service -n
 *       dev.mayaos.updater/.UpdateCheckService --es channel canary}</li>
 * </ul>
 */
public class UpdateCheckService extends Service {
    private static final String TAG = "MayaOSUpdater";
    private static final String CHANNEL_PROP = "ro.mayaos.channel";
    private static final String VERSION_PROP = "ro.mayaos.version";
    private static final String OTA_URL_BASE = "https://ota.mayaos.dev";
    private static final String NOTIF_CHANNEL = "mayaos-updater";
    private static final int NOTIF_ID = 5260;

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        startForegroundWithNotification();

        String channel = (intent != null && intent.hasExtra("channel"))
                ? intent.getStringExtra("channel")
                : SystemProperties.get(CHANNEL_PROP, "stable");
        Log.i(TAG, "channel: " + channel);

        new Thread(() -> checkForUpdate(channel)).start();
        return START_NOT_STICKY;
    }

    private void startForegroundWithNotification() {
        NotificationManager nm = getSystemService(NotificationManager.class);
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(new NotificationChannel(
                    NOTIF_CHANNEL, "MayaOS Updater", NotificationManager.IMPORTANCE_LOW));
        }
        Notification notif = new Notification.Builder(this, NOTIF_CHANNEL)
                .setContentTitle("MayaOS")
                .setContentText("Checking for updates")
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setOngoing(true)
                .build();
        startForeground(NOTIF_ID, notif);
    }

    private void checkForUpdate(String channel) {
        try {
            String currentVersion = SystemProperties.get(VERSION_PROP, "");
            JSONObject channelDoc = fetchJson(OTA_URL_BASE + "/" + channel + ".json");
            JSONArray builds = channelDoc.optJSONArray("builds");
            if (builds == null || builds.length() == 0) {
                Log.i(TAG, "no builds in channel " + channel);
                return;
            }
            JSONObject latest = builds.getJSONObject(0);
            String latestId = latest.getString("id");
            if (latestId.equals(currentVersion)) {
                Log.i(TAG, "already on " + latestId);
                reportAttempt(channel, latestId, "no-op");
                return;
            }
            Log.i(TAG, "update available: " + currentVersion + " -> " + latestId);
            reportAttempt(channel, latestId, "downloading");
            UpdateEngineBridge.installAB(this, latest);
            reportAttempt(channel, latestId, "scheduled");
        } catch (Exception e) {
            Log.e(TAG, "update check failed", e);
        } finally {
            stopForeground(STOP_FOREGROUND_REMOVE);
            stopSelf();
        }
    }

    private JSONObject fetchJson(String url) throws Exception {
        HttpURLConnection conn = (HttpURLConnection) new URL(url).openConnection();
        conn.setConnectTimeout(10_000);
        conn.setReadTimeout(15_000);
        try (BufferedReader r = new BufferedReader(new InputStreamReader(conn.getInputStream()))) {
            StringBuilder sb = new StringBuilder();
            String line;
            while ((line = r.readLine()) != null) sb.append(line);
            return new JSONObject(sb.toString());
        } finally { conn.disconnect(); }
    }

    /** Best-effort report back to MDF; failures are logged and ignored. */
    private void reportAttempt(String channel, String buildId, String state) {
        try {
            String mdf = SystemProperties.get("ro.mayaos.mdf_endpoint", "");
            if (mdf.isEmpty()) return;
            HttpURLConnection conn = (HttpURLConnection) new URL(
                    mdf + "/mdf/ota-channel/devices/local/attempt").openConnection();
            conn.setRequestMethod("POST");
            conn.setRequestProperty("Content-Type", "application/json");
            conn.setDoOutput(true);
            String body = String.format(
                "{\"channel\":\"%s\",\"buildId\":\"%s\",\"state\":\"%s\",\"ts\":%d}",
                channel, buildId, state, System.currentTimeMillis());
            conn.getOutputStream().write(body.getBytes());
            conn.getResponseCode();
            conn.disconnect();
        } catch (Exception ignored) { /* best-effort */ }
    }

    @Override public IBinder onBind(Intent intent) { return null; }
}
