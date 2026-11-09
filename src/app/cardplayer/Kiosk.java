package app.cardplayer;

import android.app.Activity;
import android.app.ActivityManager;
import android.app.admin.DevicePolicyManager;
import android.content.ComponentName;
import android.content.Context;

/**
 * Kiosk lock.
 *
 * If WalkieTales is the device owner (set once with
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
                applyFeatures(a);
                d.setStatusBarDisabled(adm, true);
                // No swipe lock screen after the screen sleeps: the player comes straight back on a tap.
                // (Android only allows this when there's no PIN, pattern or password on the phone.)
                d.setKeyguardDisabled(adm, true);
            } catch (Exception ignored) { }
        }
        if (!isLocked(a)) {
            try { a.startLockTask(); } catch (Exception ignored) { }
        }
    }

    /**
     * The power menu (hold the power button) is the only system feature left while locked, and a grown-up can
     * turn that off too so it can't be switched off. Holding power for ~15 seconds still force-restarts the
     * phone (that's in the hardware), and the player comes straight back after a restart.
     */
    static void applyFeatures(Context c) {
        if (!isOwner(c)) return;
        boolean menu = Store.prefs(c).getBoolean("power_menu", true);
        try {
            dpm(c).setLockTaskFeatures(admin(c), menu ? DevicePolicyManager.LOCK_TASK_FEATURE_GLOBAL_ACTIONS
                    : DevicePolicyManager.LOCK_TASK_FEATURE_NONE);
        } catch (Exception ignored) { }
    }

    /** Switch the display off now. Returns false if Android won't allow it (the black screen stays instead). */
    static boolean screenOff(Context c) {
        try {
            dpm(c).lockNow();
            return true;
        } catch (Exception e) {
            android.util.Log.w("WalkieTales", "lockNow not allowed: " + e);
            return false;
        }
    }

    /**
     * Fallback when lockNow isn't allowed: let the screen time out after 5 seconds (also while charging).
     * The previous values are remembered and put back by {@link #restoreTimeout}.
     */
    static void shortTimeout(Context c) {
        if (!isOwner(c)) return;
        android.content.SharedPreferences p = Store.prefs(c);
        android.content.ContentResolver cr = c.getContentResolver();
        try {
            if (!p.contains("saved_timeout")) {
                p.edit().putInt("saved_timeout", android.provider.Settings.System.getInt(cr, android.provider.Settings.System.SCREEN_OFF_TIMEOUT, 60000))
                        .putInt("saved_stay_on", android.provider.Settings.Global.getInt(cr, android.provider.Settings.Global.STAY_ON_WHILE_PLUGGED_IN, 0))
                        .commit();
            }
            dpm(c).setSystemSetting(admin(c), android.provider.Settings.System.SCREEN_OFF_TIMEOUT, "5000");
            dpm(c).setGlobalSetting(admin(c), android.provider.Settings.Global.STAY_ON_WHILE_PLUGGED_IN, "0");
        } catch (Exception e) {
            android.util.Log.w("WalkieTales", "short timeout failed: " + e);
        }
    }

    static void restoreTimeout(Context c) {
        android.content.SharedPreferences p = Store.prefs(c);
        if (!p.contains("saved_timeout") || !isOwner(c)) return;
        try {
            dpm(c).setSystemSetting(admin(c), android.provider.Settings.System.SCREEN_OFF_TIMEOUT, String.valueOf(p.getInt("saved_timeout", 60000)));
            dpm(c).setGlobalSetting(admin(c), android.provider.Settings.Global.STAY_ON_WHILE_PLUGGED_IN, String.valueOf(p.getInt("saved_stay_on", 0)));
        } catch (Exception ignored) { }
        p.edit().remove("saved_timeout").remove("saved_stay_on").apply();
    }

    /** How long the screen stays on after the last touch, when nothing is keeping it on. */
    static void setTimeout(Context c, int secs) {
        if (!isOwner(c) || Store.prefs(c).contains("saved_timeout")) return; // not while switched off from the remote
        try {
            String v = String.valueOf(Math.max(15, secs) * 1000);
            if (!v.equals(android.provider.Settings.System.getString(c.getContentResolver(), android.provider.Settings.System.SCREEN_OFF_TIMEOUT))) {
                dpm(c).setSystemSetting(admin(c), android.provider.Settings.System.SCREEN_OFF_TIMEOUT, v);
            }
        } catch (Exception ignored) { }
    }

    /** Android's own "stay awake while charging" option (the app decides when to keep the screen on instead). */
    static void setStayOnWhileCharging(Context c, boolean on) {
        if (!isOwner(c) || Store.prefs(c).contains("saved_timeout")) return;
        try {
            String v = on ? "3" : "0";
            if (!v.equals(android.provider.Settings.Global.getString(c.getContentResolver(), android.provider.Settings.Global.STAY_ON_WHILE_PLUGGED_IN))) {
                dpm(c).setGlobalSetting(admin(c), android.provider.Settings.Global.STAY_ON_WHILE_PLUGGED_IN, v);
            }
        } catch (Exception ignored) { }
    }

    /** Restart the phone (device owner only): the way to switch it off and on while the power menu is blocked. */
    static boolean reboot(Context c) {
        if (!isOwner(c)) return false;
        try {
            dpm(c).reboot(admin(c));
            return true;
        } catch (Exception e) {
            return false;
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
            try { dpm(a).setKeyguardDisabled(admin(a), false); } catch (Exception ignored) { } // a normal phone again
            try { dpm(a).setLockTaskPackages(admin(a), new String[0]); } catch (Exception ignored) { }
            try { dpm(a).clearDeviceOwnerApp(a.getPackageName()); } catch (Exception ignored) { }
        }
        Store.prefs(a).edit().putBoolean("kiosk_lock", false).apply();
    }
}
