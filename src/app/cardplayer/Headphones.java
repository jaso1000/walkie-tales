package app.cardplayer;

import android.annotation.SuppressLint;
import android.app.admin.DevicePolicyManager;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothManager;
import android.content.Context;
import android.media.AudioDeviceInfo;
import android.media.AudioManager;
import android.os.Build;

/**
 * The headphones button: Bluetooth on/off, and which headphones (if any) the sound is going to.
 *
 * Apps can't connect to a particular Bluetooth device (that's for system apps), but paired headphones
 * reconnect by themselves once Bluetooth is on and they're switched on. As device owner the player is
 * allowed to switch Bluetooth on and off, which Android otherwise forbids for new apps.
 */
final class Headphones {
    private Headphones() { }

    private static final String BLUETOOTH_CONNECT = "android.permission.BLUETOOTH_CONNECT";

    static BluetoothAdapter adapter(Context c) {
        BluetoothManager m = (BluetoothManager) c.getSystemService(Context.BLUETOOTH_SERVICE);
        return m != null ? m.getAdapter() : null;
    }

    static boolean hasBluetooth(Context c) {
        return adapter(c) != null;
    }

    static boolean bluetoothOn(Context c) {
        try {
            BluetoothAdapter a = adapter(c);
            return a != null && a.isEnabled();
        } catch (SecurityException e) {
            return false;
        }
    }

    /** The headphones or speaker the sound is going to now (Bluetooth or plugged in), or null for the phone's speaker. */
    static AudioDeviceInfo output(Context c) {
        AudioManager am = (AudioManager) c.getSystemService(Context.AUDIO_SERVICE);
        if (am == null) return null;
        for (AudioDeviceInfo d : am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)) {
            if (isHeadphones(d)) return d;
        }
        return null;
    }

    static boolean isHeadphones(AudioDeviceInfo d) {
        switch (d.getType()) {
            case AudioDeviceInfo.TYPE_BLUETOOTH_A2DP:
            case AudioDeviceInfo.TYPE_WIRED_HEADPHONES:
            case AudioDeviceInfo.TYPE_WIRED_HEADSET:
            case AudioDeviceInfo.TYPE_USB_HEADSET:
            case 26: // TYPE_BLE_HEADSET (Android 12)
            case 27: // TYPE_BLE_SPEAKER (Android 12)
                return true;
            default:
                return false;
        }
    }

    static boolean isBluetooth(AudioDeviceInfo d) {
        int t = d.getType();
        return t == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP || t == 26 || t == 27;
    }

    static String name(AudioDeviceInfo d) {
        CharSequence n = d.getProductName();
        String s = n != null ? n.toString().trim() : "";
        // Wired headphones report the phone's own model name, which means nothing to a child.
        if (s.isEmpty() || !isBluetooth(d) || s.equalsIgnoreCase(Build.MODEL)) return "Headphones";
        return s;
    }

    /** Switch Bluetooth on or off. Returns false if Android said no (for example in airplane mode on some phones). */
    @SuppressLint("MissingPermission")
    @SuppressWarnings("deprecation")
    static boolean setBluetooth(Context c, boolean on) {
        grantPermission(c);
        try {
            BluetoothAdapter a = adapter(c);
            if (a == null) return false;
            if (a.isEnabled() == on) return true;
            return on ? a.enable() : a.disable();
        } catch (SecurityException e) {
            return false;
        }
    }

    /** Android 12+ needs BLUETOOTH_CONNECT to switch Bluetooth; the device owner can grant it to itself. */
    static void grantPermission(Context c) {
        if (Build.VERSION.SDK_INT < 31 || !Kiosk.isOwner(c)) return;
        if (c.checkSelfPermission(BLUETOOTH_CONNECT) == android.content.pm.PackageManager.PERMISSION_GRANTED) return;
        try {
            Kiosk.dpm(c).setPermissionGrantState(Kiosk.admin(c), c.getPackageName(), BLUETOOTH_CONNECT,
                    DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED);
        } catch (Exception ignored) { }
    }
}
