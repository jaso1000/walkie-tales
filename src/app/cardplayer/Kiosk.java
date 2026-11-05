package app.cardplayer;

import android.app.Activity;
import android.app.ActivityManager;
import android.app.admin.DevicePolicyManager;
import android.content.ComponentName;
import android.content.Context;

/**
 * Kiosk lock.
 *
 * If Walkie Tales is the device owner (set once with
 * {@code adb shell dpm set-device-owner app.cardplayer/.AdminReceiver}) the lock is total:
 * no notification shade, no Home / Recents, no "pin app?" prompt.
 * Otherwise it falls back to ordinary Android app pinning.
 */
final class Kiosk {
    private Kiosk() { }

    /** Set while a grown-up has stepped out to Android settings; cleared when the player comes back. */
    static boolean steppedOut;

    static ComponentName admin(Context c) {
        return new ComponentName(c, AdminReceiver.class);
    }

    static DevicePolicyManager dpm(Context c) {
        return (DevicePolicyManager) c.getSystemService(Context.DEVICE_POLICY_SERVICE);
    }

    static boolean isOwner(Context c) {
        try {
            return dpm(c).isDeviceOwnerApp(c.getPackageName());
        } catch (Exception e) {
            return false;
        }
    }

    /** Locked by default when we're device owner (that's why it was set up); off otherwise. */
    static boolean wanted(Context c) {
        return Store.prefs(c).getBoolean("kiosk_lock", isOwner(c));
    }

    static boolean isLocked(Context c) {
        ActivityManager am = (ActivityManager) c.getSystemService(Context.ACTIVITY_SERVICE);
        return am.getLockTaskModeState() != ActivityManager.LOCK_TASK_MODE_NONE;
    }

    static void lock(Activity a) {
        if (isOwner(a)) {
            DevicePolicyManager d = dpm(a);
            ComponentName adm = admin(a);
            try {
                d.setLockTaskPackages(adm, new String[]{a.getPackageName()});
                // Keep only the power menu (so a grown-up can still restart the phone).
                d.setLockTaskFeatures(adm, DevicePolicyManager.LOCK_TASK_FEATURE_GLOBAL_ACTIONS);
                d.setStatusBarDisabled(adm, true);
            } catch (Exception ignored) { }
        }
        if (!isLocked(a)) {
            try { a.startLockTask(); } catch (Exception ignored) { }
        }
    }

    static void unlock(Activity a) {
        try { a.stopLockTask(); } catch (Exception ignored) { }
        if (isOwner(a)) {
            try { dpm(a).setStatusBarDisabled(admin(a), false); } catch (Exception ignored) { }
        }
    }

    /** Give up device-owner control (needed before uninstalling the app or using the phone normally). */
    static void release(Activity a) {
        unlock(a);
        if (isOwner(a)) {
            try { dpm(a).setLockTaskPackages(admin(a), new String[0]); } catch (Exception ignored) { }
            try { dpm(a).clearDeviceOwnerApp(a.getPackageName()); } catch (Exception ignored) { }
        }
        Store.prefs(a).edit().putBoolean("kiosk_lock", false).apply();
    }
}
