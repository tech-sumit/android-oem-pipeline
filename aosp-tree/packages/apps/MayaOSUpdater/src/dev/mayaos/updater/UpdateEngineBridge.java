package dev.mayaos.updater;

import android.content.Context;
import android.os.UpdateEngine;
import android.os.UpdateEngineCallback;
import android.util.Log;

import org.json.JSONObject;

/**
 * Thin wrapper around AOSP's {@link android.os.UpdateEngine} -- builds the
 * payload metadata + property strings the engine expects from a JSON entry
 * shaped like the one produced by {@code ota/tools/append.py}.
 *
 * <p>The properties array MUST include the SHA256 of each partition payload
 * to match what the OTA index promised; otherwise update_engine refuses
 * the install with a {@code kErrorCodeDownloadInvalidMetadataMagicString}-like
 * code.
 */
public final class UpdateEngineBridge {
    private static final String TAG = "MayaOSUpdater";

    private UpdateEngineBridge() {}

    public static void installAB(Context ctx, JSONObject build) {
        try {
            String[] props = new String[] {
                "FILE_HASH=" + build.getJSONObject("system_img").getString("sha256"),
                "FILE_SIZE=" + build.getJSONObject("system_img").getLong("size"),
                "BUILD_FINGERPRINT=" + build.getString("fingerprint"),
            };
            UpdateEngine engine = new UpdateEngine();
            engine.bind(new UpdateEngineCallback() {
                @Override
                public void onStatusUpdate(int status, float percent) {
                    Log.i(TAG, "update_engine status=" + status + " pct=" + percent);
                }
                @Override
                public void onPayloadApplicationComplete(int errorCode) {
                    Log.i(TAG, "update_engine payload complete: " + errorCode);
                }
            });
            engine.applyPayload(
                build.getJSONObject("system_img").getString("url"),
                0L,
                build.getJSONObject("system_img").getLong("size"),
                props);
        } catch (Exception e) {
            Log.e(TAG, "applyPayload failed", e);
        }
    }
}
