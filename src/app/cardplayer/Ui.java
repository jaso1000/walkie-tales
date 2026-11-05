package app.cardplayer;

import android.content.Context;
import android.content.res.ColorStateList;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.Shader;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.media.MediaMetadataRetriever;
import android.widget.ImageButton;
import android.widget.ImageView;
import android.widget.TextView;

import java.io.File;
import java.util.List;
import java.util.Locale;

/** Small view, colour and artwork helpers shared by both screens. */
final class Ui {
    private Ui() { }

    static final String[] COVER_NAMES = {"cover", "folder", "front", "album"};

    static int dp(Context c, float v) {
        return Math.round(v * c.getResources().getDisplayMetrics().density);
    }

    static TextView text(Context c, String s, float sp, int color, boolean bold) {
        TextView t = new TextView(c);
        t.setText(s);
        t.setTextSize(sp);
        t.setTextColor(color);
        t.setTypeface(Typeface.create("sans-serif", bold ? Typeface.BOLD : Typeface.NORMAL));
        return t;
    }

    static ImageButton roundButton(Context c, int icon, int color, int padDp) {
        ImageButton b = new ImageButton(c);
        b.setImageResource(icon);
        b.setColorFilter(Color.WHITE);
        b.setScaleType(ImageView.ScaleType.FIT_CENTER);
        int p = dp(c, padDp);
        b.setPadding(p, p, p, p);
        GradientDrawable bg = new GradientDrawable();
        bg.setShape(GradientDrawable.OVAL);
        bg.setColor(color);
        b.setBackground(new RippleDrawable(ColorStateList.valueOf(0x40FFFFFF), bg, null));
        b.setElevation(dp(c, 6));
        return b;
    }

    static GradientDrawable roundBg(ImageButton b) {
        return (GradientDrawable) ((RippleDrawable) b.getBackground()).getDrawable(0);
    }

    // ------------------------------------------------------------ colours

    static int colorFor(String name) {
        float hue = ((name.toLowerCase(Locale.ROOT).hashCode() % 360) + 360) % 360;
        return Color.HSVToColor(new float[]{hue, 0.6f, 0.85f});
    }

    static int shade(int c, float amount) {
        float k = 1f - amount;
        return Color.rgb((int) (Color.red(c) * k), (int) (Color.green(c) * k), (int) (Color.blue(c) * k));
    }

    static int tint(int c, float amount) {
        return Color.rgb(
                (int) (Color.red(c) + (255 - Color.red(c)) * amount),
                (int) (Color.green(c) + (255 - Color.green(c)) * amount),
                (int) (Color.blue(c) + (255 - Color.blue(c)) * amount));
    }

    /** A pleasant accent colour picked from a cover image (hue-averaged, weighted by saturation). */
    static int dominantColor(Bitmap b, int fallback) {
        try {
            Bitmap s = Bitmap.createScaledBitmap(b, 24, 24, true);
            float[] hsv = new float[3];
            double x = 0, y = 0, sat = 0, val = 0, wsum = 0;
            for (int py = 0; py < 24; py++) {
                for (int px = 0; px < 24; px++) {
                    Color.colorToHSV(s.getPixel(px, py), hsv);
                    double w = hsv[1] * hsv[2] + 0.02;
                    double rad = Math.toRadians(hsv[0]);
                    x += Math.cos(rad) * w;
                    y += Math.sin(rad) * w;
                    sat += hsv[1] * w;
                    val += hsv[2] * w;
                    wsum += w;
                }
            }
            if (s != b) s.recycle();
            if (wsum == 0) return fallback;
            float S = (float) (sat / wsum), V = (float) (val / wsum);
            if (S < 0.12f) return 0xFF7A8494; // greyscale cover: neutral slate
            float hue = (float) ((Math.toDegrees(Math.atan2(y, x)) + 360) % 360);
            return Color.HSVToColor(new float[]{hue, clamp(S * 1.2f, 0.4f, 0.75f), clamp(V, 0.6f, 0.85f)});
        } catch (Exception e) {
            return fallback;
        }
    }

    static float clamp(float v, float lo, float hi) {
        return Math.max(lo, Math.min(hi, v));
    }

    // ------------------------------------------------------------ artwork

    /** cover.jpg / folder.jpg / any image in the folder, else art embedded in the first track. */
    static Bitmap loadCover(File dir) {
        File[] files = dir.listFiles();
        if (files != null) {
            File any = null;
            for (File f : files) {
                String n = f.getName().toLowerCase(Locale.ROOT);
                if (!(n.endsWith(".jpg") || n.endsWith(".jpeg") || n.endsWith(".png") || n.endsWith(".webp"))) continue;
                if (any == null) any = f;
                for (String c : COVER_NAMES) if (n.startsWith(c + ".")) return decode(f, null);
            }
            if (any != null) return decode(any, null);
        }
        List<File> t = Store.listAudio(dir);
        if (!t.isEmpty()) return embeddedArt(t.get(0));
        return null;
    }

    static Bitmap embeddedArt(File track) {
        MediaMetadataRetriever r = new MediaMetadataRetriever();
        try {
            r.setDataSource(track.getAbsolutePath());
            byte[] pic = r.getEmbeddedPicture();
            if (pic != null) return decode(null, pic);
        } catch (Exception ignored) {
        } finally {
            try { r.release(); } catch (Exception ignored) { }
        }
        return null;
    }

    static Bitmap decode(File f, byte[] bytes) {
        try {
            BitmapFactory.Options o = new BitmapFactory.Options();
            o.inJustDecodeBounds = true;
            if (f != null) BitmapFactory.decodeFile(f.getAbsolutePath(), o);
            else BitmapFactory.decodeByteArray(bytes, 0, bytes.length, o);
            int s = 1;
            while (Math.max(o.outWidth, o.outHeight) / (s * 2) >= 800) s *= 2;
            o = new BitmapFactory.Options();
            o.inSampleSize = s;
            return f != null ? BitmapFactory.decodeFile(f.getAbsolutePath(), o)
                    : BitmapFactory.decodeByteArray(bytes, 0, bytes.length, o);
        } catch (OutOfMemoryError | RuntimeException e) {
            return null;
        }
    }

    static Bitmap letterArt(String letter, int c) {
        int s = 640;
        Bitmap b = Bitmap.createBitmap(s, s, Bitmap.Config.ARGB_8888);
        Canvas cv = new Canvas(b);
        Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        p.setShader(new LinearGradient(0, 0, s, s, tint(c, 0.25f), shade(c, 0.7f), Shader.TileMode.CLAMP));
        cv.drawRect(0, 0, s, s, p);
        p.setShader(null);
        p.setColor(0x1AFFFFFF);
        cv.drawCircle(s * 0.85f, s * 0.15f, s * 0.38f, p);
        cv.drawCircle(s * 0.1f, s * 0.95f, s * 0.3f, p);
        p.setColor(Color.WHITE);
        p.setTextAlign(Paint.Align.CENTER);
        p.setTextSize(s * 0.48f);
        p.setTypeface(Typeface.create("sans-serif", Typeface.BOLD));
        Paint.FontMetrics fm = p.getFontMetrics();
        cv.drawText(letter, s / 2f, s / 2f - (fm.ascent + fm.descent) / 2f, p);
        return b;
    }
}
