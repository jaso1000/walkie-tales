package app.cardplayer;

import android.content.Context;
import android.content.SharedPreferences;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.Shader;

import java.io.BufferedOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.util.Random;

/**
 * Sleep sounds made on the phone (no downloads, work offline): rain, ocean waves, white noise and a heartbeat,
 * as 60-second WAV loops whose end blends into their start, in a "Sleep Sounds" folder that loops each track.
 * Made once; if a grown-up deletes the folder it stays deleted.
 */
final class SleepSounds {
    private SleepSounds() { }

    static final String FOLDER = "Sleep Sounds";
    static final String LOOP_MARK = ".loop"; // a folder holding this file repeats each track forever
    private static final int RATE = 22050, SECONDS = 60, N = RATE * SECONDS, FADE = RATE * 2;

    static boolean loops(String folder) {
        return folder != null && new File(new File(Store.root(), folder), LOOP_MARK).exists();
    }

    /** Make the folder the first time (in the background: it takes a few seconds). */
    static void ensure(Context c, Runnable done) {
        SharedPreferences p = Store.prefs(c);
        if (p.getBoolean("sleep_sounds_made", false)) return;
        new Thread(() -> {
            try {
                File dir = new File(Store.root(), FOLDER);
                if (!dir.isDirectory() && !dir.mkdirs()) return;
                new File(dir, LOOP_MARK).createNewFile();
                write(new File(dir, "01 - Rain.wav"), rain());
                write(new File(dir, "02 - Ocean Waves.wav"), ocean());
                write(new File(dir, "03 - White Noise.wav"), white());
                write(new File(dir, "04 - Heartbeat.wav"), heartbeat());
                cover(new File(dir, "cover.png"));
                p.edit().putBoolean("sleep_sounds_made", true).apply();
                if (done != null) done.run();
            } catch (Exception e) {
                android.util.Log.w("WalkieTales", "sleep sounds: " + e);
            }
        }, "sleep-sounds").start();
    }

    // ------------------------------------------------------------ the sounds (-1..1, N samples, seamless)

    /** Make len+FADE samples, then blend the extra tail into the start so the loop has no seam. */
    private static float[] seamless(float[] x) {
        float[] out = new float[N];
        System.arraycopy(x, 0, out, 0, N);
        for (int i = 0; i < FADE; i++) {
            float t = i / (float) FADE;
            out[i] = x[i] * t + x[N + i] * (1 - t);
        }
        return out;
    }

    private static float[] white() {
        Random r = new Random(1);
        float[] x = new float[N + FADE];
        for (int i = 0; i < x.length; i++) x[i] = (r.nextFloat() * 2 - 1) * 0.35f;
        return seamless(x);
    }

    private static float[] pink(Random r, int n) { // Paul Kellet's filter
        float b0 = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0, b5 = 0, b6 = 0;
        float[] x = new float[n];
        for (int i = 0; i < n; i++) {
            float w = r.nextFloat() * 2 - 1;
            b0 = 0.99886f * b0 + w * 0.0555179f; b1 = 0.99332f * b1 + w * 0.0750759f; b2 = 0.96900f * b2 + w * 0.1538520f;
            b3 = 0.86650f * b3 + w * 0.3104856f; b4 = 0.55000f * b4 + w * 0.5329522f; b5 = -0.7616f * b5 - w * 0.0168980f;
            x[i] = (b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362f) * 0.11f;
            b6 = w * 0.115926f;
        }
        return x;
    }

    private static float[] brown(Random r, int n) {
        float[] x = new float[n];
        float last = 0;
        for (int i = 0; i < n; i++) {
            last = (last + 0.02f * (r.nextFloat() * 2 - 1)) / 1.02f;
            x[i] = last * 3.5f;
        }
        return x;
    }

    private static float[] rain() {
        Random r = new Random(2);
        float[] x = pink(r, N + FADE);
        for (int i = 0; i < x.length; i++) x[i] *= 0.9f;
        // drops: short bright ticks scattered through it
        for (int d = 0; d < 900; d++) {
            int at = r.nextInt(x.length - 400);
            float amp = 0.05f + r.nextFloat() * 0.12f;
            for (int k = 0; k < 400; k++) x[at + k] += (r.nextFloat() * 2 - 1) * amp * (float) Math.exp(-k / 40.0);
        }
        return seamless(x);
    }

    private static float[] ocean() {
        Random r = new Random(3);
        float[] x = brown(r, N + FADE);
        float[] y = new float[N];
        float[] s = seamless(x);
        for (int i = 0; i < N; i++) { // a wave every 10 s (6 per loop, so it repeats exactly)
            double ph = (i % (RATE * 10)) / (double) (RATE * 10);
            double swell = Math.pow(Math.sin(Math.PI * ph), 2);
            y[i] = (float) (s[i] * (0.25 + 0.75 * swell));
        }
        return y;
    }

    private static float[] heartbeat() {
        float[] y = new float[N];
        int beat = RATE; // 60 beats a minute: one a second, so the loop repeats exactly
        for (int b = 0; b < SECONDS; b++) {
            thump(y, b * beat, 1.0f);
            thump(y, b * beat + (int) (RATE * 0.28), 0.65f); // "lub-dub"
        }
        return y;
    }

    private static void thump(float[] y, int at, float amp) {
        int len = (int) (RATE * 0.16);
        for (int k = 0; k < len && at + k < y.length; k++) {
            double t = k / (double) RATE;
            double env = Math.sin(Math.PI * Math.min(1, t / 0.012)) * Math.exp(-t / 0.045);
            y[at + k] += (float) (amp * 0.8 * env * (Math.sin(2 * Math.PI * 48 * t) + 0.35 * Math.sin(2 * Math.PI * 96 * t)));
        }
    }

    // ------------------------------------------------------------ files

    private static void write(File f, float[] x) throws IOException {
        File tmp = new File(f.getPath() + ".part");
        try (OutputStream o = new BufferedOutputStream(new FileOutputStream(tmp))) {
            int data = x.length * 2;
            o.write(new byte[]{'R', 'I', 'F', 'F'}); le32(o, 36 + data); o.write(new byte[]{'W', 'A', 'V', 'E', 'f', 'm', 't', ' '});
            le32(o, 16); le16(o, 1); le16(o, 1); le32(o, RATE); le32(o, RATE * 2); le16(o, 2); le16(o, 16);
            o.write(new byte[]{'d', 'a', 't', 'a'}); le32(o, data);
            byte[] buf = new byte[8192];
            int n = 0;
            for (float v : x) {
                int s = Math.max(-32767, Math.min(32767, Math.round(v * 32767)));
                buf[n++] = (byte) s; buf[n++] = (byte) (s >> 8);
                if (n == buf.length) { o.write(buf); n = 0; }
            }
            o.write(buf, 0, n);
        }
        if (!tmp.renameTo(f)) throw new IOException("rename " + f);
    }

    private static void le32(OutputStream o, int v) throws IOException { o.write(v); o.write(v >> 8); o.write(v >> 16); o.write(v >> 24); }
    private static void le16(OutputStream o, int v) throws IOException { o.write(v); o.write(v >> 8); }

    /** A night-sky cover: deep blue, a moon and stars. */
    private static void cover(File f) throws IOException {
        int sz = 600;
        Bitmap b = Bitmap.createBitmap(sz, sz, Bitmap.Config.ARGB_8888);
        Canvas cv = new Canvas(b);
        Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        p.setShader(new LinearGradient(0, 0, 0, sz, 0xFF1B2A6B, 0xFF0A0F2E, Shader.TileMode.CLAMP));
        cv.drawRect(0, 0, sz, sz, p);
        p.setShader(null);
        Random r = new Random(4);
        p.setColor(0xCCFFFFFF);
        for (int i = 0; i < 40; i++) cv.drawCircle(r.nextInt(sz), r.nextInt(sz), 1.5f + r.nextFloat() * 3, p);
        p.setColor(0xFFFFE9A8);
        cv.drawCircle(sz * 0.55f, sz * 0.45f, sz * 0.22f, p);
        p.setColor(0xFF15214F);
        cv.drawCircle(sz * 0.65f, sz * 0.38f, sz * 0.2f, p); // the crescent's shadow
        p.setColor(Color.WHITE);
        try (FileOutputStream o = new FileOutputStream(f)) { b.compress(Bitmap.CompressFormat.PNG, 100, o); }
        b.recycle();
    }
}
