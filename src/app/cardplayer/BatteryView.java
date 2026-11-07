package app.cardplayer;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.view.View;

/** A battery shape that fills up with the charge, with the percentage inside and a bolt while charging. */
final class BatteryView extends View {
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF rect = new RectF();
    private final Path bolt = new Path();
    private int pct = -1;
    private boolean charging;

    BatteryView(Context c) {
        super(c);
        paint.setTextAlign(Paint.Align.CENTER);
        paint.setTypeface(Typeface.create("sans-serif", Typeface.BOLD));
        setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_YES);
    }

    void set(int percent, boolean isCharging) {
        if (percent == pct && isCharging == charging) return;
        pct = percent;
        charging = isCharging;
        setContentDescription("Battery " + percent + "%" + (isCharging ? ", charging" : ""));
        invalidate();
    }

    @Override
    protected void onDraw(Canvas cv) {
        if (pct < 0) return;
        float d = getResources().getDisplayMetrics().density;
        float w = getWidth(), h = getHeight();
        float tipW = 3 * d, line = 1.5f * d, radius = 6 * d;
        float bodyRight = w - tipW - d;

        // the charge inside
        paint.setStyle(Paint.Style.FILL);
        paint.setColor(charging ? 0x8C4CC96A : pct <= 15 ? 0xB3FF5A5A : 0x47FFFFFF);
        float inset = line + d;
        float full = bodyRight - inset * 2;
        float level = full * Math.max(pct, 4) / 100f;
        rect.set(inset, inset, inset + level, h - inset);
        cv.drawRoundRect(rect, radius - inset, radius - inset, paint);

        // the outline and its tip
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(line);
        paint.setColor(0xB3FFFFFF);
        rect.set(line / 2, line / 2, bodyRight - line / 2, h - line / 2);
        cv.drawRoundRect(rect, radius, radius, paint);
        paint.setStyle(Paint.Style.FILL);
        rect.set(bodyRight + d * 0.5f, h * 0.32f, w, h * 0.68f);
        cv.drawRoundRect(rect, d, d, paint);

        // the number, with a bolt beside it while charging
        paint.setColor(0xFFFFFFFF);
        paint.setTextSize(12.5f * d * getResources().getConfiguration().fontScale);
        String text = pct + "%";
        Paint.FontMetrics fm = paint.getFontMetrics();
        float textW = paint.measureText(text);
        float boltW = charging ? 8 * d : 0;
        float cx = bodyRight / 2 + boltW / 2;
        cv.drawText(text, cx, h / 2 - (fm.ascent + fm.descent) / 2, paint);
        if (charging) {
            float x = cx - textW / 2 - boltW - d, top = h * 0.24f, bot = h * 0.76f, mid = h / 2;
            bolt.reset();
            bolt.moveTo(x + boltW * 0.65f, top);
            bolt.lineTo(x, mid + d * 0.6f);
            bolt.lineTo(x + boltW * 0.42f, mid + d * 0.6f);
            bolt.lineTo(x + boltW * 0.3f, bot);
            bolt.lineTo(x + boltW, mid - d * 0.6f);
            bolt.lineTo(x + boltW * 0.55f, mid - d * 0.6f);
            bolt.close();
            cv.drawPath(bolt, paint);
        }
    }
}
