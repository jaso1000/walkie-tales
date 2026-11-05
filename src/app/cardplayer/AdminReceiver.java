package app.cardplayer;

import android.app.admin.DeviceAdminReceiver;

/** Lets WalkieTales be the device owner so it can run as a true kiosk (no notification shade, no Home/Recents). */
public class AdminReceiver extends DeviceAdminReceiver { }
