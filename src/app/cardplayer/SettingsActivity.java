package app.cardplayer;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.res.ColorStateList;
import android.graphics.Color;
import android.graphics.Insets;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.WindowInsets;
import android.widget.ImageView;
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

/**
 * Grown-up settings: a short menu of topics, each opening its own page.
 * The companion remote (companion/web/index.html) has the same menu: keep the two in step.
 */
public class SettingsActivity extends Activity {

    static final int BG = 0xFF101016;
    static final int PANEL = 0xFF1B1B26;
    static final int LINE = 0xFF2A2A38;
    static final int ACCENT = 0xFFB9A6FF;
    static final int STRONG = 0xFF6C4CF1;
    static final int MUTED = 0x99FFFFFF;
    static final int DANGER = 0xFFFF7A7A;
    static final int DIALOG = MainActivity.DIALOG_THEME;

    static final String MENU = "menu";

    SharedPreferences prefs;
    ScrollView scroll;
    LinearLayout list;
    LinearLayout group; // the rounded panel new rows go into
    String page = MENU;
    Object backCallback;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        prefs = Store.prefs(this);
        scroll = new ScrollView(this);
        scroll.setBackgroundColor(BG);
        list = new LinearLayout(this);
        list.setOrientation(LinearLayout.VERTICAL);
        list.setPadding(dp(16), 0, dp(16), dp(32));
        scroll.addView(list);
        if (Build.VERSION.SDK_INT >= 30) {
            scroll.setOnApplyWindowInsetsListener((v, ins) -> {
                Insets bars = ins.getInsets(WindowInsets.Type.systemBars());
                v.setPadding(0, bars.top, 0, bars.bottom);
                return ins;
            });
        }
        setContentView(scroll);
    }

    @Override
    protected void onResume() {
        super.onResume();
        build();
    }

    @Override
    public void onBackPressed() {
        if (!MENU.equals(page)) open(MENU);
        else super.onBackPressed();
    }

    /** Newer Android delivers Back through a callback; it only stays registered while inside a page. */
    void syncBack() {
        if (Build.VERSION.SDK_INT < 33) return;
        if (backCallback != null) {
            getOnBackInvokedDispatcher().unregisterOnBackInvokedCallback(
                    (android.window.OnBackInvokedCallback) backCallback);
            backCallback = null;
        }
        if (!MENU.equals(page)) {
            android.window.OnBackInvokedCallback cb = () -> open(MENU);
            getOnBackInvokedDispatcher().registerOnBackInvokedCallback(
                    android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT, cb);
            backCallback = cb;
        }
    }

    void open(String p) {
        page = p;
        build();
        scroll.scrollTo(0, 0);
    }

    void build() {
        list.removeAllViews();
        group = null;
        syncBack();
        switch (page) {
            case "library": buildLibrary(); break;
            case "cards": buildCards(); break;
            case "sound": buildSound(); break;
            case "bedtime": buildBedtime(); break;
            case "screen": buildScreen(); break;
            case "safety": buildSafety(); break;
            case "remote": buildRemote(); break;
            case "about": buildAbout(); break;
            default: buildMenu();
        }
    }

    // ------------------------------------------------------------------ the menu

    void buildMenu() {
        header("Grown-up settings", false);
        String kid = prefs.getString("kid_name", "").trim();
        int folders = Store.folders().size();
        int linked = Store.loadCards().size();

        panel(null);
        menuItem(R.drawable.ic_person, "Your child", kid.isEmpty() ? "Not set" : kid, v -> editName());
        panel(null);
        menuPage(R.drawable.ic_grid, "Library", folders + (folders == 1 ? " folder" : " folders"), "library");
        menuPage(R.drawable.ic_card, "Cards",
                prefs.getBoolean("cards", true) ? "On  ·  " + linked + " linked" : "Off", "cards");
        panel(null);
        menuPage(R.drawable.ic_vol_up, "Sound", "Maximum volume " + prefs.getInt("max_volume", 70) + "%", "sound");
        menuPage(R.drawable.ic_moon, "Bedtime",
                formatTime(prefs.getInt("quiet_start", 19 * 60)) + " to " + formatTime(prefs.getInt("quiet_end", 7 * 60)),
                "bedtime");
        menuPage(R.drawable.ic_phone, "Screen", screenSummary(), "screen");
        panel(null);
        menuPage(R.drawable.ic_shield, "Safety", !prefs.getBoolean("gate", true) ? "Grown-up check off"
                : Store.gatePin(prefs).isEmpty() ? "Grown-up sum on" : "Grown-up PIN on", "safety");
        menuPage(R.drawable.ic_wifi, "Remote control", prefs.getBoolean("remote", true) ? "On" : "Off", "remote");
        menuPage(R.drawable.ic_info, "About", "WalkieTales " + version(), "about");
    }

    String screenSummary() {
        int on = prefs.getInt("screen_on", 0);
        if (on == 1) return "Always on";
        String after = choiceLabel("screen_timeout", TIMEOUT_VALUES, TIMEOUT_LABELS, 60);
        return (on == 2 ? "On while playing, then off after " : "Off after ") + after;
    }

    // ------------------------------------------------------------------ the pages

    void buildLibrary() {
        header("Library", true);
        Map<String, String> cards = Store.loadCards();
        List<Store.FolderInfo> folders = Store.library();
        panel("Folders");
        if (folders.isEmpty()) row("No folders yet", "Add folders of music to Music/Cards", null);
        for (Store.FolderInfo i : folders) link(i.name, folderSummary(i, cards), v -> folderOptions(i.name));
        link("Shuffle everything", null, v -> playNow(Store.ALL));
        panel("Covers");
        toggle("Find missing covers online", null, "find_art", true);
        panel("On the player");
        toggle("Library button", null, "browse", true);
        toggle("Tracks button", null, "track_list", true);
    }

    void buildCards() {
        header("Cards", true);
        Map<String, String> cards = Store.loadCards();
        panel(null);
        toggle("Use NFC cards", null, "cards", true);
        toggle("Pause when the card is lifted off", null, "rest_mode", false);
        toggle("Keep the screen on for cards", "While charging and at bedtime, so a card works straight away. "
                + "Off: the screen sleeps as usual, and a card works after a tap wakes it.", "cards_awake", true);
        panel("Linked cards");
        link("Link a card", null, v -> pickLinkTarget(Store.folders()));
        link("Linked cards", cards.isEmpty() ? "None yet" : cards.size() + (cards.size() == 1 ? " card" : " cards"),
                v -> showCards());
    }

    void buildSound() {
        header("Sound", true);
        panel(null);
        seek("Maximum volume", "max_volume", 10, 100, 70);
        panel(null);
        toggle("Volume buttons on screen", null, "show_volume", true);
        toggle("Fade in", null, "fade_in", true);
        toggle("Say the name out loud", null, "announce", false);
        if (Headphones.hasBluetooth(this)) {
            panel("Headphones");
            toggle("Headphones button", "Switches Bluetooth on and off from the player", "headphones_button", true);
            link("Pair new headphones", "Opens Bluetooth settings", v -> openSystem(Settings.ACTION_BLUETOOTH_SETTINGS));
        }
    }

    void buildBedtime() {
        header("Bedtime", true);
        panel("Times");
        timeRow("Bedtime starts", "quiet_start", 19 * 60);
        timeRow("Bedtime ends", "quiet_end", 7 * 60);
        panel("During bedtime");
        toggle("Screen off at bedtime", "Goes black 30 seconds after the last touch", "bedtime_dark", false);
        toggle("Quieter at bedtime", null, "quiet", false);
        seek("Bedtime maximum volume", "quiet_volume", 10, 100, 40);
    }

    static final int[] DIM_VALUES = {30, 90, 300, 0};
    static final String[] DIM_LABELS = {"30 seconds", "90 seconds", "5 minutes", "Never"};
    static final int[] KEEP_VALUES = {0, 2, 1};
    static final String[] KEEP_LABELS = {"No", "While playing", "Always"};
    static final int[] TIMEOUT_VALUES = {30, 60, 120, 300};
    static final String[] TIMEOUT_LABELS = {"30 seconds", "1 minute", "2 minutes", "5 minutes"};

    void buildScreen() {
        header("Screen", true);
        panel("Sleeping");
        choice("Dim the screen after", "dim_after", DIM_VALUES, DIM_LABELS, 90);
        choice("Keep the screen on", "screen_on", KEEP_VALUES, KEEP_LABELS, 0);
        choice("Screen turns off after", "screen_timeout", TIMEOUT_VALUES, TIMEOUT_LABELS, 60);
        panel("Night light and clock");
        toggle("Night light", null, "night_light", false);
        toggle("Clock on the night light", null, "night_clock", true);
        toggle("Clock and battery", null, "show_status", true);
    }

    void buildSafety() {
        header("Safety", true);
        panel(null);
        toggle("Grown-up check before settings", Store.gatePin(prefs).isEmpty() ? "A quick sum" : "The grown-up PIN", "gate", true);
        valueRow("Grown-up PIN", Store.gatePin(prefs).isEmpty() ? "Not set" : "Set", v -> editGatePin());
        lockToggle();
        if (Kiosk.isOwner(this)) toggle("Power button can switch it off", null, "power_menu", true);
        panel("Phone");
        if (Kiosk.isOwner(this)) {
            link("Restart the phone", null,
                    v -> confirm("Restart the phone?", "It takes about a minute.", () -> {
                        if (!Kiosk.reboot(this)) {
                            new AlertDialog.Builder(this, DIALOG).setMessage("Android didn't allow the restart.")
                                    .setPositiveButton("OK", null).show();
                        }
                    }));
        }
        link("Home screen app", null, v -> openSystem(Settings.ACTION_HOME_SETTINGS));
        link("Android settings", "Wi-Fi, Bluetooth, brightness", v -> openSystem(Settings.ACTION_SETTINGS));
    }

    void buildRemote() {
        header("Remote control", true);
        panel(null);
        toggle("Remote control", null, "remote", true);
        panel("Connect");
        String addr = RemoteServer.address();
        row("Address", addr != null ? addr : "Not on Wi-Fi", null);
        row("PIN", RemoteServer.pin(this), null);
        link("Change PIN", null, v -> confirm("Make a new PIN?",
                "Remote controls will need the new PIN.", () -> {
                    RemoteServer.newPin(this);
                    build();
                }));
    }

    void buildAbout() {
        header("About", true);
        long free = Store.root().getParentFile() != null ? Store.root().getParentFile().getUsableSpace() : 0;
        panel(null);
        row("WalkieTales " + version(), String.format(Locale.ROOT, "%.1f GB free", free / 1e9), null);
        if (Kiosk.isOwner(this)) {
            panel(null);
            LinearLayout r = link("Release kiosk control", "Only before uninstalling or reusing the phone",
                    v -> confirm("Release kiosk control?",
                            "The notification shade, Home and Recents will work again, and the lock can only be "
                                    + "restored with a computer (adb).", () -> {
                                Kiosk.release(this);
                                build();
                            }));
            ((TextView) ((LinearLayout) r.getChildAt(0)).getChildAt(0)).setTextColor(DANGER);
        }
    }

    String version() {
        try {
            return getPackageManager().getPackageInfo(getPackageName(), 0).versionName;
        } catch (Exception e) {
            return "";
        }
    }

    /** Open a system screen. While locked, step out of the kiosk first; the player re-locks when it returns. */
    void openSystem(String action) {
        if (Kiosk.isLocked(this)) {
            Kiosk.steppedOut = true;
            Kiosk.unlock(this);
        }
        openAction(action);
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

    /** Set, change or remove the grown-up PIN: asked for instead of the sum before settings. */
    void editGatePin() {
        final android.widget.EditText a = new android.widget.EditText(this), b = new android.widget.EditText(this);
        for (android.widget.EditText e : new android.widget.EditText[]{a, b}) {
            e.setSingleLine(true);
            e.setInputType(android.text.InputType.TYPE_CLASS_NUMBER | android.text.InputType.TYPE_NUMBER_VARIATION_PASSWORD);
            e.setGravity(android.view.Gravity.CENTER);
            e.setTextSize(22);
        }
        a.setHint("New PIN (4 to 8 numbers)");
        b.setHint("Same PIN again");
        android.widget.LinearLayout box = new android.widget.LinearLayout(this);
        box.setOrientation(android.widget.LinearLayout.VERTICAL);
        box.setPadding(dp(24), dp(8), dp(24), 0);
        box.addView(a);
        box.addView(b);
        boolean has = !Store.gatePin(prefs).isEmpty();
        AlertDialog.Builder d = new AlertDialog.Builder(this, DIALOG)
                .setTitle("Grown-up PIN")
                .setMessage("Asked for instead of the sum before settings. If it's forgotten, it can be removed from the remote.")
                .setView(box)
                .setPositiveButton("Save", (x, w) -> {
                    String p = a.getText().toString().trim();
                    if (!p.matches("\\d{4,8}")) { toast("Use 4 to 8 numbers"); return; }
                    if (!p.equals(b.getText().toString().trim())) { toast("The two PINs don't match"); return; }
                    prefs.edit().putString("gate_pin", p).putBoolean("gate", true).apply();
                    toast("Grown-up PIN set");
                    build();
                })
                .setNegativeButton("Cancel", null);
        if (has) d.setNeutralButton("Remove", (x, w) -> {
            prefs.edit().remove("gate_pin").apply();
            toast("Back to the sum");
            build();
        });
        d.show();
        a.requestFocus();
    }

    void toast(String s) { android.widget.Toast.makeText(this, s, android.widget.Toast.LENGTH_SHORT).show(); }

    void timeRow(String title, String key, int def) {
        int mins = prefs.getInt(key, def);
        valueRow(title, formatTime(mins), v -> new android.app.TimePickerDialog(this, DIALOG, (tp, hh, mm) -> {
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

    void openAction(String action) {
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

    String folderSummary(Store.FolderInfo info, Map<String, String> cards) {
        String f = info.name;
        int n = info.tracks;
        int c = Store.cardsFor(cards, f);
        StringBuilder sb = new StringBuilder();
        if (info.live) sb.append(n == 1 ? "live radio" : n + " radio stations");
        else sb.append(n).append(n == 1 ? " track" : " tracks");
        sb.append("  ·  ").append(c == 0 ? "no card" : c == 1 ? "1 card" : c + " cards");
        if (prefs.getBoolean("shuffle:" + f, false)) sb.append("  ·  shuffle");
        if (prefs.getBoolean("repeat:" + f, false)) sb.append("  ·  repeat");
        if (!prefs.getBoolean("resume:" + f, true)) sb.append("  ·  always from the start");
        if (Ui.tile(this, info) == null) sb.append("  ·  no cover");
        return sb.toString();
    }

    void lockToggle() {
        boolean owner = Kiosk.isOwner(this);
        Switch sw = toggle("Lock to this app", null, "kiosk_lock", owner);
        sw.setOnCheckedChangeListener(null);
        sw.setChecked(Kiosk.wanted(this) || Kiosk.isLocked(this));
        sw.setOnCheckedChangeListener((b, on) -> {
            prefs.edit().putBoolean("kiosk_lock", on).apply();
            if (on) Kiosk.lock(this);
            else Kiosk.unlock(this);
        });
    }

    // ------------------------------------------------------------------ building blocks

    void header(String title, boolean back) {
        LinearLayout head = new LinearLayout(this);
        head.setGravity(Gravity.CENTER_VERTICAL);
        head.setPadding(0, dp(16), 0, dp(8));
        if (back) {
            ImageView arrow = icon(R.drawable.ic_back, 0xFFFFFFFF, 24);
            arrow.setPadding(dp(8), dp(10), dp(12), dp(10));
            ripple(arrow);
            arrow.setContentDescription("Back");
            arrow.setOnClickListener(v -> open(MENU));
            head.addView(arrow);
        }
        head.addView(Ui.text(this, title, back ? 22 : 26, 0xFFFFFFFF, true), new LinearLayout.LayoutParams(0, -2, 1f));
        if (!back) {
            TextView done = Ui.text(this, "Done", 17, ACCENT, true);
            done.setPadding(dp(14), dp(12), dp(4), dp(12));
            done.setOnClickListener(v -> finish());
            head.addView(done);
        }
        list.addView(head);
    }

    /** Start a new rounded group of rows, with an optional small heading. */
    void panel(String heading) {
        if (heading != null) {
            TextView t = Ui.text(this, heading, 14, ACCENT, true);
            t.setPadding(dp(6), dp(16), dp(6), dp(8));
            list.addView(t);
        }
        group = new LinearLayout(this);
        group.setOrientation(LinearLayout.VERTICAL);
        group.setClipToOutline(true);
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(PANEL);
        bg.setCornerRadius(dp(18));
        group.setBackground(bg);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
        lp.topMargin = heading != null ? 0 : dp(12);
        list.addView(group, lp);
    }

    LinearLayout rowShell(String title, String sub) {
        if (group.getChildCount() > 0) {
            View line = new View(this);
            line.setBackgroundColor(LINE);
            LinearLayout.LayoutParams l = new LinearLayout.LayoutParams(-1, Math.max(1, dp(1) / 2));
            l.leftMargin = dp(16);
            group.addView(line, l);
        }
        LinearLayout row = new LinearLayout(this);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(dp(16), dp(12), dp(14), dp(12));
        row.setMinimumHeight(dp(60));
        LinearLayout texts = new LinearLayout(this);
        texts.setOrientation(LinearLayout.VERTICAL);
        texts.addView(Ui.text(this, title, 17, 0xFFFFFFFF, false));
        if (sub != null) {
            TextView s = Ui.text(this, sub, 14, MUTED, false);
            s.setTag("sub");
            s.setPadding(0, dp(2), 0, 0);
            texts.addView(s);
        }
        row.addView(texts, new LinearLayout.LayoutParams(0, -2, 1f));
        group.addView(row, new LinearLayout.LayoutParams(-1, -2));
        return row;
    }

    /** A plain row; tappable when {@code click} is set. */
    LinearLayout row(String title, String sub, View.OnClickListener click) {
        LinearLayout r = rowShell(title, sub);
        if (click != null) {
            ripple(r);
            r.setOnClickListener(click);
        }
        return r;
    }

    /** A row that opens something: it ends with a chevron. */
    LinearLayout link(String title, String sub, View.OnClickListener click) {
        LinearLayout r = row(title, sub, click);
        r.addView(icon(R.drawable.ic_chevron, 0x66FFFFFF, 24));
        return r;
    }

    /** A row with its current value on the right. */
    void valueRow(String title, String value, View.OnClickListener click) {
        LinearLayout r = row(title, null, click);
        TextView v = Ui.text(this, value, 16, ACCENT, false);
        v.setPadding(dp(12), 0, dp(2), 0);
        r.addView(v);
        r.addView(icon(R.drawable.ic_chevron, 0x66FFFFFF, 24));
    }

    /** One of the main menu's topics: round icon, title, current state, chevron. */
    void menuItem(int iconRes, String title, String sub, View.OnClickListener click) {
        LinearLayout r = link(title, sub, click);
        ImageView badge = icon(iconRes, ACCENT, 24);
        badge.setPadding(dp(9), dp(9), dp(9), dp(9));
        GradientDrawable circle = new GradientDrawable();
        circle.setShape(GradientDrawable.OVAL);
        circle.setColor(Color.argb(0x38, 0x6C, 0x4C, 0xF1));
        badge.setBackground(circle);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(dp(42), dp(42));
        lp.rightMargin = dp(14);
        r.addView(badge, 0, lp);
    }

    void menuPage(int iconRes, String title, String sub, String target) {
        menuItem(iconRes, title, sub, v -> open(target));
    }

    Switch toggle(String title, String sub, String key, boolean def) {
        LinearLayout r = rowShell(title, sub);
        Switch sw = new Switch(this);
        sw.setChecked(prefs.getBoolean(key, def));
        sw.setThumbTintList(new ColorStateList(new int[][]{{android.R.attr.state_checked}, {}},
                new int[]{ACCENT, 0xFFC8C8D0}));
        sw.setTrackTintList(new ColorStateList(new int[][]{{android.R.attr.state_checked}, {}},
                new int[]{STRONG, 0xFF4A4A58}));
        sw.setOnCheckedChangeListener((b, on) -> prefs.edit().putBoolean(key, on).apply());
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, -2);
        lp.leftMargin = dp(12);
        r.addView(sw, lp);
        r.setOnClickListener(v -> sw.toggle());
        return sw;
    }

    void seek(String title, String key, int min, int max, int def) {
        LinearLayout r = rowShell(title, null);
        TextView value = Ui.text(this, prefs.getInt(key, def) + "%", 16, ACCENT, true);
        r.addView(value);
        SeekBar sb = new SeekBar(this);
        sb.setMax((max - min) / 5);
        sb.setProgress((prefs.getInt(key, def) - min) / 5);
        ColorStateList tint = ColorStateList.valueOf(ACCENT);
        sb.setProgressTintList(tint);
        sb.setThumbTintList(tint);
        sb.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override public void onProgressChanged(SeekBar s, int p, boolean user) {
                int v = min + p * 5;
                value.setText(v + "%");
                prefs.edit().putInt(key, v).apply();
            }
            @Override public void onStartTrackingTouch(SeekBar s) { }
            @Override public void onStopTrackingTouch(SeekBar s) { }
        });
        sb.setPadding(dp(20), 0, dp(20), dp(16));
        group.addView(sb, new LinearLayout.LayoutParams(-1, -2));
    }

    String choiceLabel(String key, int[] values, String[] labels, int def) {
        int cur = prefs.getInt(key, def);
        for (int i = 0; i < values.length; i++) if (values[i] == cur) return labels[i];
        return labels[0];
    }

    /** A row showing the current choice; tapping lists the options. */
    void choice(String title, String key, int[] values, String[] labels, int def) {
        valueRow(title, choiceLabel(key, values, labels, def), v -> {
            int cur = prefs.getInt(key, def), at = 0;
            for (int i = 0; i < values.length; i++) if (values[i] == cur) at = i;
            new AlertDialog.Builder(this, DIALOG)
                    .setTitle(title)
                    .setSingleChoiceItems(labels, at, (d, w) -> {
                        prefs.edit().putInt(key, values[w]).apply();
                        d.dismiss();
                        build();
                    })
                    .setNegativeButton("Cancel", null)
                    .show();
        });
    }

    ImageView icon(int res, int color, int sizeDp) {
        ImageView i = new ImageView(this);
        i.setImageResource(res);
        i.setColorFilter(color);
        i.setLayoutParams(new LinearLayout.LayoutParams(-2, -2));
        i.setMinimumWidth(dp(sizeDp));
        i.setMinimumHeight(dp(sizeDp));
        return i;
    }

    void ripple(View v) {
        TypedValue tv = new TypedValue();
        getTheme().resolveAttribute(android.R.attr.selectableItemBackground, tv, true);
        v.setBackgroundResource(tv.resourceId);
    }

    int dp(float v) {
        return Ui.dp(this, v);
    }
}
