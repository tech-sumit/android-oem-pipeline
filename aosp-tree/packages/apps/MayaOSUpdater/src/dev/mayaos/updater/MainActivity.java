package dev.mayaos.updater;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.os.SystemProperties;
import android.view.View;
import android.widget.Button;
import android.widget.TextView;

import androidx.work.PeriodicWorkRequest;
import androidx.work.Constraints;
import androidx.work.ExistingPeriodicWorkPolicy;
import androidx.work.NetworkType;
import androidx.work.WorkManager;
import androidx.work.Worker;
import androidx.work.WorkerParameters;

import java.util.concurrent.TimeUnit;

/**
 * UI for the operator: shows current channel + version + "check now".
 *
 * <p>On first launch we also queue a {@link UpdateWorker} that runs every
 * 6h so devices in the wild stay current even if MDF can't reach them.
 */
public class MainActivity extends Activity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);

        TextView channelTv = findViewById(R.id.channel);
        TextView versionTv = findViewById(R.id.version);
        Button   checkBtn  = findViewById(R.id.check_now);

        channelTv.setText(getString(R.string.channel_fmt,
                SystemProperties.get("ro.mayaos.channel", "stable")));
        versionTv.setText(getString(R.string.version_fmt,
                SystemProperties.get("ro.mayaos.version", "unknown")));

        checkBtn.setOnClickListener(v -> {
            startForegroundService(new Intent(this, UpdateCheckService.class));
        });

        queuePeriodicCheck();
    }

    private void queuePeriodicCheck() {
        PeriodicWorkRequest req = new PeriodicWorkRequest.Builder(
                UpdateWorker.class, 6, TimeUnit.HOURS)
            .setConstraints(new Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED).build())
            .build();
        WorkManager.getInstance(this).enqueueUniquePeriodicWork(
            "mayaos-update-check", ExistingPeriodicWorkPolicy.KEEP, req);
    }

    public static class UpdateWorker extends Worker {
        public UpdateWorker(android.content.Context c, WorkerParameters p) { super(c, p); }
        @Override
        public Result doWork() {
            getApplicationContext().startForegroundService(
                new Intent(getApplicationContext(), UpdateCheckService.class));
            return Result.success();
        }
    }
}
