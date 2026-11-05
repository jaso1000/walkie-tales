package app.cardplayer;

import android.content.Context;
import android.content.SharedPreferences;
import android.graphics.BitmapFactory;
import android.media.MediaMetadataRetriever;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;

/**
 * Finds a picture for folders that don't have one, and saves it as "cover.auto.jpg".
 *
 * Music / audiobooks: Apple's keyless iTunes Search API, using the album/artist tags from the
 * first file if present, otherwise the folder name. Radio stations: radio-browser.info logos.
 * A result is only kept if its name genuinely matches; folders with no good match are retried
 * after a week. A cover a grown-up removes is never fetched again for that folder.
 */
final class ArtFinder {
    private ArtFinder() { }

    static final String AUTO_COVER = "cover.auto.jpg";
    static final long RETRY_MS = 7L * 24 * 3600 * 1000;
    private static final String UA = "WalkieTales/1.8 (kids audio player; github.com/jaso1000/walkie-tales)";
    private static final Set<String> STOP = new HashSet<>(Arrays.asList(
            "the", "a", "an", "and", "of", "to", "in", "on", "for", "with", "by", "ep", "unabridged", "abridged",
            "original", "score", "soundtrack", "edition", "deluxe", "remastered", "version", "vol", "volume",
            "includes", "song", "read", "along", "track", "audiobook", "radio", "fm", "am", "live"));

    private static volatile boolean running;

    /** Look for missing covers in the background. force = also retry folders that found nothing recently. */
    static void runAsync(Context ctx, boolean force, Runnable onChanged) {
        final Context c = ctx.getApplicationContext();
        if (running || !Store.prefs(c).getBoolean("find_art", true)) return;
        running = true;
        new Thread(() -> {
            try {
                boolean changed = false;
                for (String f : Store.folders()) {
                    if (!Store.prefs(c).getBoolean("find_art", true)) break;
                    if (findFor(c, f, force)) changed = true;
                }
                if (changed && onChanged != null) new android.os.Handler(android.os.Looper.getMainLooper()).post(onChanged);
            } finally {
                running = false;
            }
        }, "art-finder").start();
    }

    static boolean isRunning() {
        return running;
    }

    /** @return true if a new cover was saved. */
    static boolean findFor(Context c, String folder, boolean force) {
        SharedPreferences p = Store.prefs(c);
        String key = "art:" + folder;
        String state = p.getString(key, "");
        if (state.equals("off")) return false;
        File dir = new File(Store.root(), folder);
        if (!dir.isDirectory() || hasPicture(dir)) return false;
        if (!force && state.startsWith("none:")) {
            try {
                if (System.currentTimeMillis() - Long.parseLong(state.substring(5)) < RETRY_MS) return false;
            } catch (NumberFormatException ignored) { }
        }
        List<Track> tracks = Store.listTracks(folder);
        if (tracks.isEmpty()) return false;

        byte[] img = null;
        try {
            img = Store.isLiveOnly(folder) ? findStationLogo(tracks.get(0).name, folder) : findAlbumArt(folder, tracks);
        } catch (Exception ignored) { }

        if (img != null && looksLikeImage(img)) {
            try (FileOutputStream o = new FileOutputStream(new File(dir, AUTO_COVER))) {
                o.write(img);
                p.edit().putString(key, "found").apply();
                return true;
            } catch (Exception ignored) { }
        }
        p.edit().putString(key, "none:" + System.currentTimeMillis()).apply();
        return false;
    }

    /** Delete an auto-found cover and never look again for this folder. */
    static void reject(Context c, String folder) {
        new File(new File(Store.root(), folder), AUTO_COVER).delete();
        Store.prefs(c).edit().putString("art:" + folder, "off").apply();
    }

    /** Let a folder be searched again (after its cover was removed by mistake, for example). */
    static void reset(Context c, String folder) {
        Store.prefs(c).edit().remove("art:" + folder).apply();
    }

    static boolean hasAuto(String folder) {
        return new File(new File(Store.root(), folder), AUTO_COVER).isFile();
    }

    /** Any image file in the folder, or art embedded in the first music file. */
    static boolean hasPicture(File dir) {
        File[] files = dir.listFiles();
        if (files != null) {
            for (File f : files) {
                String n = f.getName().toLowerCase(Locale.ROOT);
                if (n.endsWith(".jpg") || n.endsWith(".jpeg") || n.endsWith(".png") || n.endsWith(".webp")) return true;
            }
        }
        List<File> audio = Store.listAudio(dir);
        if (audio.isEmpty()) return false;
        MediaMetadataRetriever r = new MediaMetadataRetriever();
        try {
            r.setDataSource(audio.get(0).getAbsolutePath());
            return r.getEmbeddedPicture() != null;
        } catch (Exception e) {
            return false;
        } finally {
            try { r.release(); } catch (Exception ignored) { }
        }
    }

    // ------------------------------------------------------------ music / audiobooks (iTunes)

    static byte[] findAlbumArt(String folder, List<Track> tracks) throws Exception {
        String album = null, artist = null;
        for (Track t : tracks) {
            if (t.live) continue;
            MediaMetadataRetriever r = new MediaMetadataRetriever();
            try {
                r.setDataSource(t.source);
                album = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ALBUM);
                artist = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ALBUMARTIST);
                if (artist == null) artist = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ARTIST);
            } catch (Exception ignored) {
            } finally {
                try { r.release(); } catch (Exception ignored) { }
            }
            break;
        }
        boolean fromTags = album != null && !album.trim().isEmpty();
        boolean hasArtist = artist != null && !artist.trim().isEmpty();
        String title = fromTags ? album.trim() : folder;
        String query = hasArtist ? title + " " + artist.trim() : title;

        String best = null;
        double bestScore = 0;
        for (String kind : new String[]{"media=audiobook", "media=music&entity=album"}) {
            JSONObject res = new JSONObject(get("https://itunes.apple.com/search?term="
                    + URLEncoder.encode(query, "UTF-8") + "&" + kind + "&limit=10&explicit=No", 8000));
            JSONArray arr = res.optJSONArray("results");
            if (arr == null) continue;
            for (int i = 0; i < arr.length(); i++) {
                JSONObject o = arr.getJSONObject(i);
                String name = o.optString("collectionName", o.optString("trackName", ""));
                String art = o.optString("artworkUrl100", "");
                if (art.isEmpty()) continue;
                // Kids' player: never anything explicit.
                if ("explicit".equalsIgnoreCase(o.optString("collectionExplicitness"))
                        || "explicit".equalsIgnoreCase(o.optString("contentAdvisoryRating"))) continue;
                // Guessing from a folder name alone is risky ("Demo Songs" found a whiskey album), so then only
                // children's/family results count. With real album tags from the files, any genre is fine.
                if (!fromTags && !kidsGenre(o.optString("primaryGenreName"))) continue;
                double s = score(title, name);
                if (hasArtist && fromTags) s = s * 0.8 + 0.2 * score(artist, o.optString("artistName", ""));
                if (s > bestScore) {
                    bestScore = s;
                    best = art;
                }
            }
        }
        if (best == null || bestScore < 0.6) return null;
        return download(best.replace("100x100bb", "600x600bb"));
    }

    // ------------------------------------------------------------ radio logos (radio-browser.info)

    static byte[] findStationLogo(String station, String folder) throws Exception {
        for (String name : new String[]{station, folder}) {
            JSONArray arr = new JSONArray(get("https://all.api.radio-browser.info/json/stations/byname/"
                    + URLEncoder.encode(name, "UTF-8").replace("+", "%20") + "?limit=10&hidebroken=true&order=votes&reverse=true", 8000));
            String best = null;
            double bestScore = 0;
            for (int i = 0; i < arr.length(); i++) {
                JSONObject s = arr.getJSONObject(i);
                String fav = s.optString("favicon", "");
                if (!Store.isUrl(fav)) continue;
                double sc = score(name, s.optString("name", ""));
                if (sc > bestScore) {
                    bestScore = sc;
                    best = fav;
                }
            }
            if (best != null && bestScore >= 0.6) {
                byte[] img = download(best);
                if (img != null && looksLikeImage(img)) return img;
            }
        }
        return null;
    }

    // ------------------------------------------------------------ helpers

    static boolean kidsGenre(String genre) {
        String g = genre == null ? "" : genre.toLowerCase(Locale.ROOT);
        return g.contains("child") || g.contains("kid") || g.contains("famil") || g.contains("young")
                || g.contains("lullab") || g.contains("nursery");
    }

    /** How well a search result's name matches what we searched for (0..1). */
    static double score(String wanted, String found) {
        Set<String> w = words(wanted), f = words(found);
        if (w.isEmpty() || f.isEmpty()) return 0;
        int hit = 0;
        for (String x : w) if (f.contains(x)) hit++;
        double recall = hit / (double) w.size();     // how much of what we wanted is in the result
        double precision = hit / (double) f.size();  // how little extra stuff the result has
        return recall * 0.75 + precision * 0.25;
    }

    static Set<String> words(String s) {
        Set<String> out = new HashSet<>();
        for (String t : s.toLowerCase(Locale.ROOT).replaceAll("\\(.*?\\)|\\[.*?]", " ").split("[^\\p{L}\\p{N}]+")) {
            if (t.length() > 1 && !STOP.contains(t)) out.add(t.endsWith("s") && t.length() > 3 ? t.substring(0, t.length() - 1) : t);
        }
        return out;
    }

    static boolean looksLikeImage(byte[] b) {
        BitmapFactory.Options o = new BitmapFactory.Options();
        o.inJustDecodeBounds = true;
        BitmapFactory.decodeByteArray(b, 0, b.length, o);
        return o.outWidth >= 48 && o.outHeight >= 48;
    }

    static String get(String url, int timeout) throws Exception {
        byte[] b = fetch(url, timeout, 512 * 1024);
        return b == null ? "" : new String(b, StandardCharsets.UTF_8);
    }

    static byte[] download(String url) {
        try {
            return fetch(url, 10000, 3 * 1024 * 1024);
        } catch (Exception e) {
            return null;
        }
    }

    static byte[] fetch(String url, int timeout, int max) throws Exception {
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        try {
            c.setConnectTimeout(timeout);
            c.setReadTimeout(timeout);
            c.setInstanceFollowRedirects(true);
            c.setRequestProperty("User-Agent", UA);
            if (c.getResponseCode() / 100 != 2) return null;
            try (InputStream in = c.getInputStream()) {
                ByteArrayOutputStream bo = new ByteArrayOutputStream();
                byte[] buf = new byte[16 * 1024];
                int n;
                while ((n = in.read(buf)) > 0) {
                    bo.write(buf, 0, n);
                    if (bo.size() > max) return null;
                }
                return bo.toByteArray();
            }
        } finally {
            c.disconnect();
        }
    }
}
