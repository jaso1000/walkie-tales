package app.cardplayer;

import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.Shader;

import java.io.File;
import java.io.FileOutputStream;

/**
 * The voice messages folder (recorded on the remote or in Grown-up settings → Messages). It gets its own picture, drawn
 * here, so the automatic cover search never puts a stranger's album on it. An older "From Mum & Dad" folder is renamed.
 * Same as the iPhone player (Messages.swift).
 */
final class Messages {
    static final String FOLDER = "Messages";
    private static final String OLD = "From Mum & Dad";

    /** On start: rename the old folder and make sure the folder (if there is one) has its picture. */
    static void ensure() {
        File root = Store.root();
        File old = new File(root, OLD), dir = new File(root, FOLDER);
        if (old.isDirectory() && !dir.exists()) old.renameTo(dir);
        else if (old.isDirectory()) { // both exist: move the old messages across
            File[] fs = old.listFiles();
            if (fs != null) for (File f : fs) if (Store.isAudio(f)) f.renameTo(uniqueIn(dir, f.getName()));
        }
        if (dir.isDirectory()) ensureCover(dir);
    }

    /** After a message is saved into the folder. */
    static void ensureCover(File dir) {
        try {
            new File(dir, ArtFinder.AUTO_COVER).delete(); // a cover the online search guessed for this folder
            File f = new File(dir, "cover.png");
            if (!f.isFile()) draw(f);
        } catch (Exception ignored) { }
    }

    static File uniqueIn(File dir, String name) {
        File out = new File(dir, name);
        int dot = name.lastIndexOf('.');
        String base = dot > 0 ? name.substring(0, dot) : name, ext = dot > 0 ? name.substring(dot) : "";
        for (int i = 2; out.exists(); i++) out = new File(dir, base + " " + i + ext);
        return out;
    }

    /** A warm envelope with a heart: "a message for you". */
    private static void draw(File f) throws Exception {
        int s = 600;
        Bitmap b = Bitmap.createBitmap(s, s, Bitmap.Config.ARGB_8888);
        Canvas c = new Canvas(b);
        Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        p.setShader(new LinearGradient(0, 0, s, s, 0xFFFF8A80, 0xFFF06292, Shader.TileMode.CLAMP));
        c.drawRect(0, 0, s, s, p);
        p.setShader(null);
        // envelope
        RectF env = new RectF(s * 0.17f, s * 0.30f, s * 0.83f, s * 0.74f);
        p.setColor(0x33000000);
        c.drawRoundRect(new RectF(env.left, env.top + 10, env.right, env.bottom + 10), 28, 28, p); // soft shadow
        p.setColor(0xFFFFFBF5);
        c.drawRoundRect(env, 28, 28, p);
        Paint line = new Paint(Paint.ANTI_ALIAS_FLAG);
        line.setStyle(Paint.Style.STROKE);
        line.setStrokeWidth(10);
        line.setStrokeJoin(Paint.Join.ROUND);
        line.setStrokeCap(Paint.Cap.ROUND);
        line.setColor(0xFFF3C6CF);
        Path flap = new Path();
        flap.moveTo(env.left + 18, env.top + 18);
        flap.lineTo(s * 0.5f, s * 0.53f);
        flap.lineTo(env.right - 18, env.top + 18);
        c.drawPath(flap, line);
        // heart on the flap
        float cx = s * 0.5f, cy = s * 0.53f, r = s * 0.075f;
        Path heart = new Path();
        heart.moveTo(cx, cy + r * 1.35f);
        heart.cubicTo(cx - r * 2.2f, cy - r * 0.2f, cx - r * 1.1f, cy - r * 1.9f, cx, cy - r * 0.75f);
        heart.cubicTo(cx + r * 1.1f, cy - r * 1.9f, cx + r * 2.2f, cy - r * 0.2f, cx, cy + r * 1.35f);
        heart.close();
        p.setColor(0xFFE53958);
        c.drawPath(heart, p);
        try (FileOutputStream o = new FileOutputStream(f)) { b.compress(Bitmap.CompressFormat.PNG, 100, o); }
        b.recycle();
    }

    private Messages() { }
}
