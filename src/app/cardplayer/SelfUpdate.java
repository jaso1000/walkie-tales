package app.cardplayer;

import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageInstaller;
import android.content.pm.PackageManager;
import android.content.pm.Signature;
import android.os.Build;
import android.util.Log;

import java.io.File;
import java.io.FileInputStream;
import java.io.OutputStream;
import java.util.Arrays;

/**
 * Installs a new version of this app sent over the remote. Only a device-owner app can do this without
 * someone tapping "Install". Android also refuses any APK not signed with the key the app already has.
 */
public final class SelfUpdate {
    private SelfUpdate() { }

    /** Why this APK can't be installed, or null if it looks good. */
    static String problem(Context c, File apk) {
        try {
            PackageManager pm = c.getPackageManager();
            int flags = Build.VERSION.SDK_INT >= 28 ? PackageManager.GET_SIGNING_CERTIFICATES : 0;
            PackageInfo next = pm.getPackageArchiveInfo(apk.getPath(), flags);
            if (next == null || !c.getPackageName().equals(next.packageName)) return "That isn't a WalkieTales update";
            PackageInfo now = pm.getPackageInfo(c.getPackageName(), flags);
            if (versionCode(next) <= versionCode(now)) return "Already on version " + now.versionName + " or newer";
            if (Build.VERSION.SDK_INT >= 28 && next.signingInfo != null && now.signingInfo != null) {
                Signature[] a = next.signingInfo.getApkContentsSigners(), b = now.signingInfo.getApkContentsSigners();
                if (!Arrays.equals(a, b)) return "That update isn't signed with this player's key";
            }
            return null;
        } catch (Exception e) {
            return "Couldn't read that update";
        }
    }

    @SuppressWarnings("deprecation")
    private static long versionCode(PackageInfo p) {
        return Build.VERSION.SDK_INT >= 28 ? p.getLongVersionCode() : p.versionCode;
    }

    static String versionName(Context c, File apk) {
        PackageInfo p = c.getPackageManager().getPackageArchiveInfo(apk.getPath(), 0);
        return p != null ? p.versionName : "";
    }

    /** Starts the install; the app is closed and restarted by Android when it finishes. */
    static void install(Context c, File apk) throws Exception {
        PackageInstaller pi = c.getPackageManager().getPackageInstaller();
        PackageInstaller.SessionParams params = new PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL);
        params.setAppPackageName(c.getPackageName());
        if (Build.VERSION.SDK_INT >= 31) params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED);
        int id = pi.createSession(params);
        try (PackageInstaller.Session s = pi.openSession(id)) {
            try (FileInputStream in = new FileInputStream(apk);
                 OutputStream out = s.openWrite("base.apk", 0, apk.length())) {
                byte[] buf = new byte[64 * 1024];
                int n;
                while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
                s.fsync(out);
            }
            PendingIntent done = PendingIntent.getBroadcast(c, id, new Intent(c, Receiver.class),
                    PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_MUTABLE);
            s.commit(done.getIntentSender());
        }
    }

    /** Hears how an install went, and reopens the player once it's been replaced. */
    public static class Receiver extends BroadcastReceiver {
        @Override
        public void onReceive(Context c, Intent i) {
            if (Intent.ACTION_MY_PACKAGE_REPLACED.equals(i.getAction())) {
                c.startActivity(new Intent(c, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
                return;
            }
            int status = i.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE);
            if (status != PackageInstaller.STATUS_SUCCESS) {
                Log.w("WalkieTales", "Update failed: " + status + " " + i.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE));
            }
        }
    }
}
