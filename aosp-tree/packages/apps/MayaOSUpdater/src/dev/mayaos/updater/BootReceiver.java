package dev.mayaos.updater;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Kick a one-shot OTA check on every boot so freshly-restored snapshots
 *  fast-path themselves to the latest channel build. */
public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context ctx, Intent intent) {
        if (!Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) return;
        ctx.startForegroundService(new Intent(ctx, UpdateCheckService.class));
    }
}
