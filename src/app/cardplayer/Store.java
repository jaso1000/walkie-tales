package app.cardplayer;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Environment;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.io.Reader;
import java.io.Writer;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Properties;
import java.util.TreeMap;

/** Music library, card links and settings storage. */
final class Store {
    private Store() { }

    static final String[] AUDIO_EXT = {".mp3", ".m4a", ".m4b", ".aac", ".ogg", ".opus", ".flac", ".wav"};

    // Special card targets (anything not starting with '@' is a folder name)
    static final String ALL = "@all";
    static final String PAUSE = "@pause";
    static final String NEXT = "@next";
    static final String SLEEP = "@sleep";
    static final String VOL_UP = "@volup";
    static final String VOL_DOWN = "@voldown";
    static final String[] ACTIONS = {ALL, PAUSE, NEXT, SLEEP, VOL_UP, VOL_DOWN};

    // ------------------------------------------------------------ settings (shared by the settings screen and the remote API)

    /** Every grown-up setting with its default. The type of the default is the type of the setting. */
    static final Map<String, Object> SETTINGS = new java.util.LinkedHashMap<>();

    static {
        SETTINGS.put("kid_name", "");
        SETTINGS.put("max_volume", 70);
        SETTINGS.put("show_volume", true);
        SETTINGS.put("fade_in", true);
        SETTINGS.put("announce", false);
        SETTINGS.put("quiet", false);
        SETTINGS.put("quiet_start", 19 * 60);
        SETTINGS.put("quiet_end", 7 * 60);
        SETTINGS.put("quiet_volume", 40);
        SETTINGS.put("cards", true);
        SETTINGS.put("browse", true);
        SETTINGS.put("track_list", true);
        SETTINGS.put("rest_mode", false);
        SETTINGS.put("dim_after", 90);
        SETTINGS.put("screen_on", 0);
        SETTINGS.put("night_light", false);
        SETTINGS.put("night_clock", true);
        SETTINGS.put("show_status", true);
        SETTINGS.put("gate", true);
        SETTINGS.put("remote", true);
    }

    static org.json.JSONObject settingsJson(SharedPreferences p) throws org.json.JSONException {
        org.json.JSONObject o = new org.json.JSONObject();
        for (Map.Entry<String, Object> e : SETTINGS.entrySet()) {
            Object d = e.getValue();
            if (d instanceof Boolean) o.put(e.getKey(), p.getBoolean(e.getKey(), (Boolean) d));
            else if (d instanceof Integer) o.put(e.getKey(), p.getInt(e.getKey(), (Integer) d));
            else o.put(e.getKey(), p.getString(e.getKey(), (String) d));
        }
        return o;
    }

    /** Apply the known keys of {@code in}, coercing types and clamping ranges. Unknown keys are ignored. */
    static void applySettings(SharedPreferences p, org.json.JSONObject in) {
        SharedPreferences.Editor ed = p.edit();
        for (Map.Entry<String, Object> e : SETTINGS.entrySet()) {
            String k = e.getKey();
            if (!in.has(k)) continue;
            Object d = e.getValue();
            if (d instanceof Boolean) {
                ed.putBoolean(k, in.optBoolean(k, (Boolean) d));
            } else if (d instanceof Integer) {
                int v = in.optInt(k, (Integer) d);
                switch (k) {
                    case "max_volume": case "quiet_volume": v = Math.max(10, Math.min(100, v)); break;
                    case "quiet_start": case "quiet_end": v = Math.max(0, Math.min(24 * 60 - 1, v)); break;
                    case "dim_after": v = Math.max(0, Math.min(3600, v)); break;
                    case "screen_on": v = v == 1 ? 1 : 0; break;
                    default: break;
                }
                ed.putInt(k, v);
            } else {
                String s = in.optString(k, (String) d).trim();
                ed.putString(k, s.length() > 40 ? s.substring(0, 40) : s);
            }
        }
        ed.apply();
    }

    static File root() {
        return new File(Environment.getExternalStorageDirectory(), "Music/Cards");
    }

    /** Card links live next to the music so they survive reinstalling the app. */
    static File cardsFile() {
        return new File(root(), "cards.txt");
    }

    static SharedPreferences prefs(Context c) {
        return c.getSharedPreferences("cards", Context.MODE_PRIVATE);
    }

    static boolean isAction(String target) {
        return target.startsWith("@");
    }

    static String label(String target) {
        switch (target) {
            case ALL: return "Shuffle everything";
            case PAUSE: return "Pause";
            case NEXT: return "Skip to next track";
            case SLEEP: return "Sleep timer";
            case VOL_UP: return "Volume up";
            case VOL_DOWN: return "Volume down";
            default: return target;
        }
    }

    // ------------------------------------------------------------ card links

    static Map<String, String> loadCards() {
        Map<String, String> m = new TreeMap<>();
        File f = cardsFile();
        if (!f.isFile()) return m;
        try (Reader r = new InputStreamReader(new FileInputStream(f), StandardCharsets.UTF_8)) {
            Properties p = new Properties();
            p.load(r);
            for (String k : p.stringPropertyNames()) m.put(k, p.getProperty(k));
        } catch (IOException ignored) { }
        return m;
    }

    static boolean saveCards(Map<String, String> m) {
        File f = cardsFile();
        File dir = f.getParentFile();
        if (dir != null) dir.mkdirs();
        Properties p = new Properties();
        p.putAll(m);
        try (Writer w = new OutputStreamWriter(new FileOutputStream(f), StandardCharsets.UTF_8)) {
            p.store(w, "Walkie Tales links: CARD_ID=Folder name (or @action)");
            return true;
        } catch (IOException e) {
            return false;
        }
    }

    static int cardsFor(Map<String, String> cards, String target) {
        int n = 0;
        for (String v : cards.values()) if (v.equals(target)) n++;
        return n;
    }

    // ------------------------------------------------------------ library

    static List<String> folders() {
        List<String> names = new ArrayList<>();
        File[] dirs = root().listFiles();
        if (dirs != null) {
            for (File d : dirs) if (d.isDirectory() && !d.getName().startsWith(".")) names.add(d.getName());
        }
        Collections.sort(names, Store::natCmp);
        return names;
    }

    static List<File> listAudio(String folder) {
        return listAudio(new File(root(), folder));
    }

    static List<File> listAudio(File dir) {
        List<File> out = new ArrayList<>();
        collect(dir, out);
        final int base = dir.getAbsolutePath().length();
        Collections.sort(out, (a, b) -> natCmp(a.getAbsolutePath().substring(base), b.getAbsolutePath().substring(base)));
        return out;
    }

    private static void collect(File dir, List<File> out) {
        File[] files = dir.listFiles();
        if (files == null) return;
        for (File f : files) {
            if (f.getName().startsWith(".")) continue;
            if (f.isDirectory()) {
                collect(f, out);
                continue;
            }
            String n = f.getName().toLowerCase(Locale.ROOT);
            for (String e : AUDIO_EXT) {
                if (n.endsWith(e)) {
                    out.add(f);
                    break;
                }
            }
        }
    }

    static String cleanName(File f) {
        String n = f.getName();
        int dot = n.lastIndexOf('.');
        if (dot > 0) n = n.substring(0, dot);
        String stripped = n.replaceFirst("^\\d+[\\s._-]*", "");
        if (!stripped.isEmpty()) n = stripped;
        return n.replace('_', ' ').trim();
    }

    /** Natural sort: "2 Song" before "10 Song", case-insensitive. */
    static int natCmp(String a, String b) {
        int i = 0, j = 0;
        while (i < a.length() && j < b.length()) {
            char ca = a.charAt(i), cb = b.charAt(j);
            if (Character.isDigit(ca) && Character.isDigit(cb)) {
                int si = i, sj = j;
                while (i < a.length() && Character.isDigit(a.charAt(i))) i++;
                while (j < b.length() && Character.isDigit(b.charAt(j))) j++;
                String na = a.substring(si, i).replaceFirst("^0+(?=.)", "");
                String nb = b.substring(sj, j).replaceFirst("^0+(?=.)", "");
                if (na.length() != nb.length()) return na.length() - nb.length();
                int c = na.compareTo(nb);
                if (c != 0) return c;
            } else {
                int c = Character.toLowerCase(ca) - Character.toLowerCase(cb);
                if (c != 0) return c;
                i++;
                j++;
            }
        }
        return (a.length() - i) - (b.length() - j);
    }
}
