package app.cardplayer;

import android.content.Context;
import android.content.SharedPreferences;
import android.graphics.Bitmap;
import android.os.Handler;
import android.os.Looper;

import org.json.JSONObject;

import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Collections;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;

/**
 * A tiny HTTP server so a phone (or the Docker companion) on the same Wi-Fi can control the player.
 *
 * Every /api/ request needs the PIN, sent as an "X-Pin" header or "?pin=" query parameter.
 * Commands run on the main thread through {@link Api}; covers and uploads are handled here.
 */
final class RemoteServer {

    static final int PORT = 8080;
    static final long MAX_UPLOAD = 1024L * 1024 * 1024; // 1 GB per file

    interface Api {
        JSONObject call(String method, String path, Map<String, String> query, JSONObject body) throws Exception;
    }

    private final Context ctx;
    private final Api api;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService pool = Executors.newFixedThreadPool(4);
    private volatile ServerSocket socket;
    private volatile boolean running;

    RemoteServer(Context ctx, Api api) {
        this.ctx = ctx.getApplicationContext();
        this.api = api;
    }

    // ------------------------------------------------------------ PIN + address

    static String pin(Context c) {
        SharedPreferences p = Store.prefs(c);
        String pin = p.getString("remote_pin", null);
        if (pin == null) pin = newPin(c);
        return pin;
    }

    static String newPin(Context c) {
        String pin = String.format(Locale.ROOT, "%06d", new SecureRandom().nextInt(1_000_000));
        Store.prefs(c).edit().putString("remote_pin", pin).apply();
        return pin;
    }

    /** e.g. "http://192.168.1.23:8080", or null when not on a network. */
    static String address() {
        try {
            for (NetworkInterface ni : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!ni.isUp() || ni.isLoopback()) continue;
                for (InetAddress a : Collections.list(ni.getInetAddresses())) {
                    if (a.isSiteLocalAddress() && a.getAddress().length == 4) {
                        return "http://" + a.getHostAddress() + ":" + PORT;
                    }
                }
            }
        } catch (Exception ignored) { }
        return null;
    }

    // ------------------------------------------------------------ lifecycle

    synchronized void start() {
        if (running) return;
        running = true;
        Thread t = new Thread(() -> {
            ServerSocket bound = null;
            // After an app update the old process can hold the port for a few seconds: keep retrying.
            for (int attempt = 0; attempt < 40 && running && bound == null; attempt++) {
                try {
                    ServerSocket s = new ServerSocket();
                    s.setReuseAddress(true);
                    s.bind(new java.net.InetSocketAddress(PORT));
                    bound = s;
                } catch (IOException e) {
                    try { Thread.sleep(1500); } catch (InterruptedException ie) { break; }
                }
            }
            if (bound == null) {
                running = false;
                android.util.Log.w("WalkieTales", "Remote server could not bind port " + PORT);
                return;
            }
            try (ServerSocket ss = bound) {
                socket = ss;
                android.util.Log.i("WalkieTales", "Remote server listening on " + PORT);
                while (running) {
                    Socket s = ss.accept();
                    pool.execute(() -> handle(s));
                }
            } catch (Exception e) {
                // closed by stop(), or port busy
                if (running) android.util.Log.w("WalkieTales", "Remote server stopped: " + e);
            } finally {
                running = false;
            }
        }, "remote-server");
        t.setDaemon(true);
        t.start();
    }

    synchronized void stop() {
        running = false;
        try { if (socket != null) socket.close(); } catch (IOException ignored) { }
        socket = null;
    }

    boolean isRunning() {
        return running;
    }

    // ------------------------------------------------------------ HTTP

    private void handle(Socket s) {
        try (Socket sock = s) {
            sock.setSoTimeout(20_000);
            final String who = sock.getInetAddress() != null ? sock.getInetAddress().getHostAddress() : "?";
            InputStream in = new BufferedInputStream(sock.getInputStream());
            OutputStream out = sock.getOutputStream();

            String request = readLine(in);
            if (request == null || request.isEmpty()) return;
            String[] parts = request.split(" ");
            if (parts.length < 2) { send(out, 400, "text/plain", bytes("Bad request")); return; }
            String method = parts[0].toUpperCase(Locale.ROOT);
            String target = parts[1];

            Map<String, String> headers = new HashMap<>();
            String line;
            while ((line = readLine(in)) != null && !line.isEmpty()) {
                int c = line.indexOf(':');
                if (c > 0) headers.put(line.substring(0, c).trim().toLowerCase(Locale.ROOT), line.substring(c + 1).trim());
            }
            long len = 0;
            try { len = Long.parseLong(headers.getOrDefault("content-length", "0")); } catch (NumberFormatException ignored) { }

            String path = target;
            Map<String, String> query = new HashMap<>();
            int qi = target.indexOf('?');
            if (qi >= 0) {
                path = target.substring(0, qi);
                for (String kv : target.substring(qi + 1).split("&")) {
                    if (kv.isEmpty()) continue;
                    int e = kv.indexOf('=');
                    String k = e < 0 ? kv : kv.substring(0, e);
                    String v = e < 0 ? "" : kv.substring(e + 1);
                    query.put(URLDecoder.decode(k, "UTF-8"), URLDecoder.decode(v, "UTF-8"));
                }
            }

            if (method.equals("OPTIONS")) { send(out, 204, "text/plain", new byte[0]); return; }

            // The control page itself (no PIN needed to load the page).
            if (method.equals("GET") && (path.equals("/") || path.equals("/index.html"))) {
                send(out, 200, "text/html; charset=utf-8", readAll(ctx.getAssets().open("web/index.html")));
                return;
            }
            if (!path.startsWith("/api/")) { send(out, 404, "text/plain", bytes("Not found")); return; }

            String given = headers.containsKey("x-pin") ? headers.get("x-pin") : query.get("pin");
            long wait = Guard.blockedFor(who);
            if (wait > 0) { // too many wrong PINs from here: make guessing all million PINs take months, not hours
                sendJson(out, 429, new JSONObject().put("error", "Too many wrong PINs. Try again in " + Math.max(1, wait / 1000) + " seconds"));
                return;
            }
            if (!Store.prefs(ctx).getBoolean("remote", true) || !pinMatches(given)) {
                if (given != null && !given.trim().isEmpty()) Guard.failed(who); // no PIN at all isn't a guess
                sendJson(out, 401, new JSONObject().put("error", "PIN required"));
                return;
            }
            Guard.ok(who);

            if (method.equals("GET") && path.equals("/api/cover")) {
                serveCover(out, query.get("folder"), query.containsKey("now"));
                return;
            }
            if (method.equals("GET") && path.equals("/api/file")) { // download one file (copy between players, fix formats)
                File dir = safeFolder(query.get("folder"));
                String name = safeName(query.get("name"));
                File f = dir == null || name == null ? null : new File(dir, name);
                if (f == null || !f.isFile()) { sendJson(out, 404, new JSONObject().put("error", "No such file")); return; }
                out.write(bytes("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: " + f.length()
                        + "\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"));
                try (java.io.FileInputStream fin = new java.io.FileInputStream(f)) {
                    byte[] buf = new byte[64 * 1024];
                    int n;
                    while ((n = fin.read(buf)) > 0) out.write(buf, 0, n);
                }
                out.flush();
                return;
            }
            if (method.equals("PUT") && path.equals("/api/upload")) {
                upload(in, out, query.get("folder"), query.get("name"), len);
                return;
            }
            if (method.equals("PUT") && path.equals("/api/update")) {
                receiveUpdate(in, out, len, query.containsKey("force"));
                return;
            }

            JSONObject body = new JSONObject();
            if (len > 0) {
                if (len > 1_000_000) { sendJson(out, 413, new JSONObject().put("error", "Too large")); return; }
                String text = new String(readExactly(in, (int) len), StandardCharsets.UTF_8);
                if (!text.trim().isEmpty()) body = new JSONObject(text);
            }
            final String m = method, p = path;
            final JSONObject b = body;
            FutureTask<JSONObject> task = new FutureTask<>(() -> api.call(m, p, query, b));
            main.post(task);
            JSONObject result;
            try {
                result = task.get(8, TimeUnit.SECONDS);
            } catch (Exception e) {
                Throwable cause = e.getCause() != null ? e.getCause() : e;
                sendJson(out, 400, new JSONObject().put("error", String.valueOf(cause.getMessage())));
                return;
            }
            if (result == null) sendJson(out, 404, new JSONObject().put("error", "Unknown command"));
            else sendJson(out, 200, result);
        } catch (Exception ignored) {
            // client went away
        }
    }

    /**
     * Wrong-PIN limit per address: 5 free tries, then a wait that doubles each time (30 s up to 1 hour).
     * A right PIN clears it. With this, trying every 6-digit PIN would take far longer than anyone would bother.
     */
    static final class Guard {
        private static final Map<String, long[]> FAILS = new HashMap<>(); // address -> {count, blockedUntil}

        static synchronized long blockedFor(String who) {
            long[] f = FAILS.get(who);
            long left = f == null ? 0 : f[1] - System.currentTimeMillis();
            return Math.max(0, left);
        }

        static synchronized void failed(String who) {
            long[] f = FAILS.computeIfAbsent(who, k -> new long[2]);
            f[0]++;
            if (f[0] >= 5) f[1] = System.currentTimeMillis() + Math.min(3_600_000L, 30_000L << Math.min(7, f[0] - 5));
            if (FAILS.size() > 500) FAILS.clear(); // never grows without bound
        }

        static synchronized void ok(String who) {
            FAILS.remove(who);
        }
    }

    private boolean pinMatches(String given) {
        if (given == null) return false;
        return MessageDigest.isEqual(bytes(given.trim()), bytes(pin(ctx)));
    }

    /** A folder's picture; with "now", the picture built into the track playing now (if it has one). */
    private void serveCover(OutputStream out, String folder, boolean now) throws Exception {
        File dir = safeFolder(folder);
        Bitmap b = null;
        if (now) {
            String src = MainActivity.nowSource;
            if (src != null && dir != null && src.startsWith(dir.getAbsolutePath() + File.separator)) b = Ui.embeddedArt(new File(src));
        }
        if (b == null) b = dir != null && dir.isDirectory() ? Ui.loadCover(dir) : null;
        if (b == null) { send(out, 404, "text/plain", bytes("No cover")); return; }
        ByteArrayOutputStream bo = new ByteArrayOutputStream();
        b.compress(Bitmap.CompressFormat.JPEG, 85, bo);
        send(out, 200, "image/jpeg", bo.toByteArray());
    }

    private void upload(InputStream in, OutputStream out, String folder, String name, long len) throws Exception {
        File dir = safeFolder(folder);
        String file = safeName(name);
        if (dir == null || file == null) { sendJson(out, 400, new JSONObject().put("error", "Bad folder or file name")); return; }
        if (len <= 0) { sendJson(out, 411, new JSONObject().put("error", "Content-Length required")); return; }
        if (len > MAX_UPLOAD) { sendJson(out, 413, new JSONObject().put("error", "File too large")); return; }
        if (!dir.isDirectory() && !dir.mkdirs()) { sendJson(out, 500, new JSONObject().put("error", "Can't create folder")); return; }
        File dest = new File(dir, file);
        File tmp = new File(dir, "." + file + ".part");
        try (FileOutputStream fo = new FileOutputStream(tmp)) {
            byte[] buf = new byte[64 * 1024];
            long left = len;
            while (left > 0) {
                int n = in.read(buf, 0, (int) Math.min(buf.length, left));
                if (n < 0) throw new IOException("Upload cut short");
                fo.write(buf, 0, n);
                left -= n;
            }
        } catch (IOException e) {
            tmp.delete();
            throw e;
        }
        if (dest.exists()) dest.delete();
        if (!tmp.renameTo(dest)) { sendJson(out, 500, new JSONObject().put("error", "Couldn't save file")); return; }
        sendJson(out, 200, new JSONObject().put("ok", true).put("folder", dir.getName()).put("name", file));
    }

    /** A new version of the app, sent from the remote. Waits for a listening child unless told otherwise. */
    private void receiveUpdate(InputStream in, OutputStream out, long len, boolean force) throws Exception {
        if (len <= 0 || len > 200_000_000L) { sendJson(out, 413, new JSONObject().put("error", "That isn't a WalkieTales update")); return; }
        File apk = new File(ctx.getCacheDir(), "update.apk");
        try (FileOutputStream fo = new FileOutputStream(apk)) {
            byte[] buf = new byte[64 * 1024];
            long left = len;
            while (left > 0) {
                int n = in.read(buf, 0, (int) Math.min(buf.length, left));
                if (n < 0) throw new IOException("Upload cut short");
                fo.write(buf, 0, n);
                left -= n;
            }
        }
        String problem = !Kiosk.isOwner(ctx) ? "Only a player set up as a kiosk can update by itself" : SelfUpdate.problem(ctx, apk);
        if (problem != null) {
            apk.delete();
            sendJson(out, 400, new JSONObject().put("error", problem));
            return;
        }
        if (!force) {
            FutureTask<JSONObject> task = new FutureTask<>(() -> api.call("GET", "/api/status", new HashMap<>(), new JSONObject()));
            main.post(task);
            if (task.get(8, TimeUnit.SECONDS).optBoolean("playing")) {
                apk.delete();
                sendJson(out, 409, new JSONObject().put("error", "Playing right now").put("playing", true));
                return;
            }
        }
        sendJson(out, 200, new JSONObject().put("ok", true).put("version", SelfUpdate.versionName(ctx, apk)));
        out.flush();
        SelfUpdate.install(ctx, apk);
    }

    /** A folder directly inside Music/Cards (no paths, no dot-names). */
    static File safeFolder(String name) {
        if (name == null) return null;
        String n = name.trim();
        if (n.isEmpty() || n.startsWith(".") || n.contains("/") || n.contains("\\") || n.length() > 120) return null;
        return new File(Store.root(), n);
    }

    static String safeName(String name) {
        if (name == null) return null;
        String n = name.trim();
        if (n.isEmpty() || n.startsWith(".") || n.contains("/") || n.contains("\\") || n.length() > 200) return null;
        return n;
    }

    // ------------------------------------------------------------ helpers

    private static void sendJson(OutputStream out, int code, JSONObject o) throws IOException {
        send(out, code, "application/json; charset=utf-8", bytes(o.toString()));
    }

    private static void send(OutputStream out, int code, String type, byte[] body) throws IOException {
        String head = "HTTP/1.1 " + code + " " + reason(code) + "\r\n"
                + "Content-Type: " + type + "\r\n"
                + "Content-Length: " + body.length + "\r\n"
                + "Cache-Control: no-store\r\n"
                + "X-Content-Type-Options: nosniff\r\n"
                + "X-Frame-Options: DENY\r\n"
                + "Referrer-Policy: no-referrer\r\n"
                + "Connection: close\r\n\r\n";
        out.write(bytes(head));
        out.write(body);
        out.flush();
    }

    private static String reason(int code) {
        switch (code) {
            case 200: return "OK";
            case 204: return "No Content";
            case 400: return "Bad Request";
            case 401: return "Unauthorized";
            case 404: return "Not Found";
            case 411: return "Length Required";
            case 413: return "Payload Too Large";
            case 429: return "Too Many Requests";
            default: return "Error";
        }
    }

    private static String readLine(InputStream in) throws IOException {
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        int c;
        while ((c = in.read()) != -1) {
            if (c == '\n') break;
            if (c != '\r') b.write(c);
            if (b.size() > 16_384) throw new IOException("Header too long");
        }
        if (c == -1 && b.size() == 0) return null;
        return b.toString("UTF-8");
    }

    private static byte[] readExactly(InputStream in, int n) throws IOException {
        byte[] buf = new byte[n];
        int off = 0;
        while (off < n) {
            int r = in.read(buf, off, n - off);
            if (r < 0) throw new IOException("Body cut short");
            off += r;
        }
        return buf;
    }

    private static byte[] readAll(InputStream in) throws IOException {
        try (InputStream i = in) {
            ByteArrayOutputStream b = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = i.read(buf)) > 0) b.write(buf, 0, n);
            return b.toByteArray();
        }
    }

    private static byte[] bytes(String s) {
        return s.getBytes(StandardCharsets.UTF_8);
    }
}
