package app.cardplayer;

import android.content.Context;
import android.media.AudioAttributes;
import android.os.Build;
import android.os.VibrationAttributes;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.provider.Settings;

/**
 * Small taps of vibration for the player's buttons. Uses the phone's own crisp click effects when its vibration
 * driver has them, and a short plain buzz when it doesn't (the Galaxy S10 on LineageOS has no "heavy click", so
 * Android's own press-and-hold feedback was silent there). Follows the phone's "Touch feedback" setting.
 */
final class Haptic {
    static final int TICK = 0;   // small things: volume, skip, tabs, opening the Library
    static final int CLICK = 1;  // choosing something: play/pause, a tile, a song
    static final int HEAVY = 2;  // press-and-hold actions

    private Haptic() { }

    static void play(Context c, int kind) {
        try {
            Vibrator v = (Vibrator) c.getSystemService(Context.VIBRATOR_SERVICE);
            if (v == null || !v.hasVibrator()) return;
            if (Settings.System.getInt(c.getContentResolver(),
                    Settings.System.HAPTIC_FEEDBACK_ENABLED, 1) == 0) return;
            VibrationEffect e = null;
            if (Build.VERSION.SDK_INT >= 30) {
                int id = kind == TICK ? VibrationEffect.EFFECT_TICK
                        : kind == CLICK ? VibrationEffect.EFFECT_CLICK : VibrationEffect.EFFECT_HEAVY_CLICK;
                if (v.areAllEffectsSupported(id) == Vibrator.VIBRATION_EFFECT_SUPPORT_YES) e = VibrationEffect.createPredefined(id);
            }
            if (e == null) {
                long ms = kind == TICK ? 14 : kind == CLICK ? 24 : 40;
                int amp = !v.hasAmplitudeControl() ? VibrationEffect.DEFAULT_AMPLITUDE
                        : kind == TICK ? 110 : kind == CLICK ? 180 : 255;
                e = VibrationEffect.createOneShot(ms, amp);
            }
            if (Build.VERSION.SDK_INT >= 33) {
                v.vibrate(e, VibrationAttributes.createForUsage(VibrationAttributes.USAGE_TOUCH));
            } else {
                v.vibrate(e, new AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION).build());
            }
        } catch (Exception ignored) { }
    }
}
