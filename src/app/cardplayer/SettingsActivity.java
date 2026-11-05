package app.cardplayer;

import android.app.Activity;
import android.app.ActivityManager;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Insets;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.WindowInsets;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.SeekBar;
import android.widget.Switch;
import android.widget.TextView;

import java.io.File;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/** Grown-up settings: link cards, per-folder options, volume limit, screen and kiosk options. */
public class SettingsActivity extends Activity {

    static final int BG = 0xFF101016;
    static final int ACCENT = 0xFFB9A6FF;
    static final int DIALOG = MainActivity.DIALOG_THEME;

    SharedPreferences prefs;
    LinearLayout list;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        prefs = Store.prefs(this);
        ScrollView sv = new ScrollView(this);
        sv.setBackgroundColor(BG);
        list = new LinearLayout(this);
        list.setOrientation(LinearLayout.VERTICAL);
        list.setPadding(0, 0, 0, dp(32));
        sv.addView(list);
        if (Build.VERSION.SDK_INT >= 30) {
            sv.setOnApplyWindowInsetsListener((v, ins) -> {
                Insets bars = ins.getInsets(WindowInsets.Type.systemBars());
                v.setPadding(0, bars.top, 0, bars.bottom);
                return ins;
            });
        }
        setContentView(sv);
    }

    @Override
    protected void onResume() {
        super.onResume();
        build();
    }

    void build() {
        list.removeAllViews();
        Map<String, String> cards = Store.loadCards();
        List<String> folders = Store.folders();

        // header
        LinearLayout head = new LinearLayout(this);
        head.setGravity(Gravity.CENTER_VERTICAL);
        head.setPadding(dp(20), dp(20), dp(8), dp(4));
        TextView t = Ui.text(this, "Grown-up settings", 26, 0xFFFFFFFF, true);
        head.addView(t, new LinearLayout.LayoutParams(0, -2, 1f));
        TextView done = Ui.text(this, "Done", 17, ACCENT, true);
        done.setPadding(dp(16), dp(12), dp(16), dp(12));
        done.setOnClickListener(v -> finish());
        head.addView(done);
        list.addView(head);

        section("Your child");
        String kid = prefs.getString("kid_name", "").trim();
        row("Name", kid.isEmpty() ? "Not set" : kid, v -> editName());

        section("Cards");
        toggle("Use NFC cards", null, "cards", true);
        row("Link a card", null, v -> pickLinkTarget(folders));
        row("Linked cards", cards.isEmpty() ? "None yet" : cards.size() + (cards.size() == 1 ? " card" : " cards"),
                v -> showCards());

        section("Library");
        if (folders.isEmpty()) {
            row("No folders yet", "Add folders of music to Music/Cards", null);
        }
        for (String f : folders) row(f, folderSummary(f, cards), v -> folderOptions(f));
        row("Shuffle everything", "Play every folder mixed together", v -> playNow(Store.ALL));
        toggle("Find missing covers online", null, "find_art", true);

        section("Sound");
        seek("Maximum volume", "max_volume", 10, 100, 70);
        toggle("Volume buttons on screen", null, "show_volume", true);
        toggle("Fade in", null, "fade_in", true);
        toggle("Say the name out loud", null, "announce", false);

        section("Bedtime");
        timeRow("Bedtime starts", "quiet_start", 19 * 60);
        timeRow("Bedtime ends", "quiet_end", 7 * 60);
        toggle("Screen off at bedtime", "Goes black 30 seconds after the last touch", "bedtime_dark", false);
        toggle("Quieter at bedtime", null, "quiet", false);
        seek("Bedtime maximum volume", "quiet_volume", 10, 100, 40);

        section("Browsing");
        toggle("Library button", null, "browse", true);
        toggle("Tracks button", null, "track_list", true);

        section("How cards work");
        toggle("Pause when the card is lifted off", null, "rest_mode", false);

        section("Screen");
        cycle("Dim the screen after", "dim_after", new int[]{30, 90, 300, 0},
                new String[]{"30 seconds", "90 seconds", "5 minutes", "Never"}, 90);
        cycle("Keep the screen on", "screen_on", new int[]{0, 2, 1},
                new String[]{"No", "While playing", "Always"}, 0);
        cycle("Screen turns off after", "screen_timeout", new int[]{30, 60, 120, 300},
                new String[]{"30 seconds", "1 minute", "2 minutes", "5 minutes"}, 60);
        toggle("Night light", null, "night_light", false);
        toggle("Clock on the night light", null, "night_clock", true);
        toggle("Clock and battery", null, "show_status", true);

        section("Safety");
        toggle("Grown-up sum before settings", null, "gate", true);
        lockToggle();
        if (Kiosk.isOwner(this)) {
            toggle("Power button can switch it off", null, "power_menu", true);
            row("Restart the phone", null,
                    v -> confirm("Restart the phone?", "It takes about a minute.", () -> {
                        if (!Kiosk.reboot(this)) {
                            new AlertDialog.Builder(this, DIALOG).setMessage("Android didn't allow the restart.")
                                    .setPositiveButton("OK", null).show();
                        }
                    }));
        }
        row("Home screen app", null, v -> openSystem(Settings.ACTION_HOME_SETTINGS));
        row("Android settings", "Wi-Fi, Bluetooth, brightness", v -> openSystem(Settings.ACTION_SETTINGS));

        section("Remote control");
        toggle("Remote control", null, "remote", true);
        String addr = RemoteServer.address();
        row(addr != null ? addr : "Not on Wi-Fi",
                "PIN: " + RemoteServer.pin(this), null);
        row("Change PIN", null, v -> confirm("Make a new PIN?",
                "Remote controls will need the new PIN.", () -> {
                    RemoteServer.newPin(this);
                    build();
                }));

        section("About");
        String version = "1";
        try { version = getPackageManager().getPackageInfo(getPackageName(), 0).versionName; } catch (Exception ignored) { }
        long free = Store.root().getParentFile() != null ? Store.root().getParentFile().getUsableSpace() : 0;
        row("WalkieTales " + version,
                String.format(Locale.ROOT, "%.1f GB free", free / 1e9), null);
        if (Kiosk.isOwner(this)) {
            row("Release kiosk control", "Only before uninstalling or reusing the phone",
                    v -> confirm("Release kiosk control?",
                            "The notification shade, Home and Recents will work again, and the lock can only be "
                                    + "restored with a computer (adb).", () -> {
                                Kiosk.release(this);
                                build();
                            }));
        }
    }

    /** Open a system screen. While locked, step out of the kiosk first; the player re-locks when it returns. */
    void openSystem(String action) {
        if (Kiosk.isLocked(this)) {
            Kiosk.steppedOut = true;
            Kiosk.unlock(this);
        }
        open(action);
    }

    // ------------------------------------------------------------------ actions

    void editName() {
        final android.widget.EditText in = new android.widget.EditText(this);
        in.setSingleLine(true);
        in.setInputType(android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_FLAG_CAP_WORDS);
        in.setText(prefs.getString("kid_name", ""));
        in.setSelection(in.getText().length());
        android.widget.FrameLayout box = new android.widget.FrameLayout(this);
        box.setPadding(dp(24), dp(8), dp(24), 0);
        box.addView(in);
        new AlertDialog.Builder(this, DIALOG)
                .setTitle("Child's name")
                .setView(box)
                .setPositiveButton("Save", (d, w) -> {
                    prefs.edit().putString("kid_name", in.getText().toString().trim()).apply();
                    build();
                })
                .setNegativeButton("Cancel", null)
                .show();
    }

    void timeRow(String title, String key, int def) {
        int mins = prefs.getInt(key, def);
        row(title, formatTime(mins), v -> new android.app.TimePickerDialog(this, DIALOG, (tp, hh, mm) -> {
            prefs.edit().putInt(key, hh * 60 + mm).apply();
            build();
        }, mins / 60, mins % 60, android.text.format.DateFormat.is24HourFormat(this)).show());
    }

    String formatTime(int mins) {
        java.util.Calendar c = java.util.Calendar.getInstance();
        c.set(java.util.Calendar.HOUR_OF_DAY, mins / 60);
        c.set(java.util.Calendar.MINUTE, mins % 60);
        return android.text.format.DateFormat.getTimeFormat(this).format(c.getTime());
    }

    void pickLinkTarget(List<String> folders) {
        final List<String> targets = new ArrayList<>(folders);
        for (String a : Store.ACTIONS) targets.add(a);
        String[] labels = new String[targets.size()];
        for (int i = 0; i < targets.size(); i++) {
            String tg = targets.get(i);
            labels[i] = Store.isAction(tg) ? "⚙  " + Store.label(tg) : tg;
        }
        new AlertDialog.Builder(this, DIALOG)
                .setTitle("What should the card do?")
                .setItems(labels, (d, w) -> {
                    startActivity(new Intent(this, MainActivity.class)
                            .putExtra("link", targets.get(w))
                            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP));
                    finish();
                })
                .setNegativeButton("Cancel", null)
                .show();
    }

    void showCards() {
        final Map<String, String> cards = Store.loadCards();
        if (cards.isEmpty()) {
            new AlertDialog.Builder(this, DIALOG).setTitle("No cards linked yet")
                    .setMessage("Use “Link a card” to set one up.").setPositiveButton("OK", null).show();
            return;
        }
        final List<String> ids = new ArrayList<>(cards.keySet());
        String[] items = new String[ids.size()];
        for (int i = 0; i < ids.size(); i++) items[i] = Store.label(cards.get(ids.get(i))) + "\ncard " + ids.get(i);
        new AlertDialog.Builder(this, DIALOG)
                .setTitle("Linked cards — tap to unlink")
                .setItems(items, (d, w) -> confirm("Unlink this card?",
                        "It was playing “" + Store.label(cards.get(ids.get(w))) + "”.", () -> {
                            cards.remove(ids.get(w));
                            Store.saveCards(cards);
                            build();
                        }))
                .setNeutralButton("Unlink all", (d, w) -> confirm("Unlink every card?",
                        "Cards will need linking again. No music is deleted.", () -> {
                            cards.clear();
                            Store.saveCards(cards);
                            build();
                        }))
                .setPositiveButton("Close", null)
                .show();
    }

    void folderOptions(String f) {
        final String[] keys = {"shuffle:" + f, "repeat:" + f, "resume:" + f};
        final boolean[] defs = {false, false, true};
        boolean[] checked = new boolean[keys.length];
        for (int i = 0; i < keys.length; i++) checked[i] = prefs.getBoolean(keys[i], defs[i]);
        AlertDialog d = new AlertDialog.Builder(this, DIALOG)
                .setTitle(f)
                .setMultiChoiceItems(new String[]{"Shuffle", "Repeat when finished", "Carry on where it stopped"},
                        checked, (dlg, w, on) -> prefs.edit().putBoolean(keys[w], on).apply())
                .setPositiveButton("Play now", (dlg, w) -> playNow(f))
                .setNeutralButton("Start over", (dlg, w) -> {
                    prefs.edit().remove("pos:" + f).apply();
                    build();
                })
                .setNegativeButton("Close", null)
                .create();
        d.setOnDismissListener(x -> build());
        d.show();
    }

    void playNow(String target) {
        startActivity(new Intent(this, MainActivity.class)
                .putExtra("folder", target)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP));
        finish();
    }

    void open(String action) {
        try {
            startActivity(new Intent(action));
        } catch (Exception e) {
            new AlertDialog.Builder(this, DIALOG).setMessage("That screen isn't available right now.")
                    .setPositiveButton("OK", null).show();
        }
    }

    void confirm(String title, String msg, Runnable yes) {
        new AlertDialog.Builder(this, DIALOG).setTitle(title).setMessage(msg)
                .setPositiveButton("Yes", (d, w) -> yes.run())
                .setNegativeButton("Cancel", null)
                .show();
    }

    String folderSummary(String f, Map<String, String> cards) {
        int n = Store.listTracks(f).size();
        int c = Store.cardsFor(cards, f);
        StringBuilder sb = new StringBuilder();
        if (Store.isLiveOnly(f)) sb.append(n == 1 ? "live radio" : n + " radio stations");
        else sb.append(n).append(n == 1 ? " track" : " tracks");
        sb.append("  ·  ").append(c == 0 ? "no card" : c == 1 ? "1 card" : c + " cards");
        if (prefs.getBoolean("shuffle:" + f, false)) sb.append("  ·  shuffle");
        if (prefs.getBoolean("repeat:" + f, false)) sb.append("  ·  repeat");
        if (!prefs.getBoolean("resume:" + f, true)) sb.append("  ·  always from the start");
        if (new File(Store.root(), f).isDirectory() && Ui.loadCover(new File(Store.root(), f)) == null) sb.append("  ·  no cover");
        return sb.toString();
    }

    void lockToggle() {
        boolean owner = Kiosk.isOwner(this);
        Switch sw = toggle("Lock to this app", null, "kiosk_lock", owner);
        sw.setChecked(Kiosk.wanted(this) || Kiosk.isLocked(this));
        sw.setOnCheckedChangeListener((b, on) -> {
            prefs.edit().putBoolean("kiosk_lock", on).apply();
            if (on) Kiosk.lock(this);
            else Kiosk.unlock(this);
        });
    }

    // ------------------------------------------------------------------ row builders

    void section(String name) {
        TextView t = Ui.text(this, name.toUpperCase(Locale.ROOT), 13, ACCENT, true);
        t.setLetterSpacing(0.12f);
        t.setPadding(dp(20), dp(26), dp(20), dp(6));
        list.addView(t);
    }

    LinearLayout rowShell(String title, String sub) {
        LinearLayout row = new LinearLayout(this);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(dp(20), dp(13), dp(20), dp(13));
        row.setMinimumHeight(dp(56));
        LinearLayout texts = new LinearLayout(this);
        texts.setOrientation(LinearLayout.VERTICAL);
        texts.addView(Ui.text(this, title, 17, 0xFFFFFFFF, false));
        if (sub != null) {
            TextView s = Ui.text(this, sub, 14, 0x99FFFFFF, false);
            s.setTag("sub");
            s.setPadding(0, dp(2), 0, 0);
            texts.addView(s);
        }
        row.addView(texts, new LinearLayout.LayoutParams(0, -2, 1f));
        list.addView(row, new LinearLayout.LayoutParams(-1, -2));
        return row;
    }

    void row(String title, String sub, View.OnClickListener click) {
        LinearLayout r = rowShell(title, sub);
        if (click != null) {
            TypedValue tv = new TypedValue();
            getTheme().resolveAttribute(android.R.attr.selectableItemBackground, tv, true);
            r.setBackgroundResource(tv.resourceId);
            r.setOnClickListener(click);
        }
    }

    Switch toggle(String title, String sub, String key, boolean def) {
        LinearLayout r = rowShell(title, sub);
        Switch sw = new Switch(this);
        sw.setChecked(prefs.getBoolean(key, def));
        sw.setOnCheckedChangeListener((b, on) -> prefs.edit().putBoolean(key, on).apply());
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, -2);
        lp.leftMargin = dp(12);
        r.addView(sw, lp);
        r.setOnClickListener(v -> sw.toggle());
        return sw;
    }

    void seek(String title, String key, int min, int max, int def) {
        LinearLayout r = rowShell(title, null);
        r.setOrientation(LinearLayout.VERTICAL);
        r.setGravity(Gravity.START);
        // rowShell sized the title column for a horizontal row (width 0 + weight); make it full width here.
        r.getChildAt(0).setLayoutParams(new LinearLayout.LayoutParams(-1, -2));
        final TextView value = Ui.text(this, prefs.getInt(key, def) + "%", 14, 0x99FFFFFF, false);
        r.addView(value);
        SeekBar sb = new SeekBar(this);
        sb.setMax((max - min) / 5);
        sb.setProgress((prefs.getInt(key, def) - min) / 5);
        sb.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override public void onProgressChanged(SeekBar s, int p, boolean user) {
                int v = min + p * 5;
                value.setText(v + "%");
                prefs.edit().putInt(key, v).apply();
            }
            @Override public void onStartTrackingTouch(SeekBar s) { }
            @Override public void onStopTrackingTouch(SeekBar s) { }
        });
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
        lp.topMargin = dp(6);
        r.addView(sb, lp);
    }

    void cycle(String title, String key, int[] values, String[] labels, int def) {
        int cur = prefs.getInt(key, def);
        int idx = 0;
        for (int i = 0; i < values.length; i++) if (values[i] == cur) idx = i;
        final int[] at = {idx};
        LinearLayout r = rowShell(title, labels[idx]);
        TypedValue tv = new TypedValue();
        getTheme().resolveAttribute(android.R.attr.selectableItemBackground, tv, true);
        r.setBackgroundResource(tv.resourceId);
        final TextView sub = (TextView) r.findViewWithTag("sub");
        r.setOnClickListener(v -> {
            at[0] = (at[0] + 1) % values.length;
            prefs.edit().putInt(key, values[at[0]]).apply();
            sub.setText(labels[at[0]]);
        });
    }

    int dp(float v) {
        return Ui.dp(this, v);
    }
}
