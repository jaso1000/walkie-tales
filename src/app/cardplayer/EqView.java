package app.cardplayer;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.os.SystemClock;
import android.view.View;

/** A small "dancing bars" animation shown while music plays (decorative, not a real analyser). */
final class EqView extends View {
    private static final int BARS = 4;
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final float[] phase = {0f, 1.3f, 2.1f, 0.6f};
    private final long start = SystemClock.uptimeMillis();
    private boolean playing;
    private float level; // eases toward 1 while playing, 0 when paused

    EqView(Context c) {
        super(c);
        paint.setColor(Color.WHITE);
    }

    void setColor(int c) {
        paint.setColor(c);
        invalidate();
    }

    void setPlaying(boolean on) {
        if (on == playing) return;
        playing = on;
        invalidate();
    }

    @Override
    protected void onDraw(Canvas cv) {
        level += ((playing ? 1f : 0f) - level) * 0.18f;
        float w = getWidth(), h = getHeight();
        float bw = w / (BARS * 2 - 1);
        float t = (SystemClock.uptimeMillis() - start) / 1000f;
        for (int i = 0; i < BARS; i++) {
            double v = Math.sin(t * (5 + i * 1.7) + phase[i]) * Math.sin(t * (2.3 + i) + phase[i] * 2);
            float bh = Math.max(bw, h * (0.18f + 0.82f * (float) Math.abs(v) * level));
            float x = i * bw * 2;
            cv.drawRoundRect(x, h - bh, x + bw, h, bw / 2, bw / 2, paint);
        }
        if (playing || level > 0.01f) postInvalidateDelayed(50); // ~20 fps is plenty and easy on the battery
    }
}
