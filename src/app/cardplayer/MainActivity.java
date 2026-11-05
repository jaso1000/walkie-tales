package app.cardplayer;

import android.animation.ObjectAnimator;
import android.animation.ValueAnimator;
import android.app.Activity;
import android.app.ActivityManager;
import android.app.AlertDialog;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.content.res.ColorStateList;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.Outline;
import android.graphics.drawable.GradientDrawable;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.media.MediaMetadataRetriever;
import android.media.MediaPlayer;
import android.net.Uri;
import android.nfc.NfcAdapter;
import android.nfc.Tag;
import android.nfc.tech.IsoDep;
import android.nfc.tech.MifareUltralight;
import android.nfc.tech.NfcA;
import android.nfc.tech.NfcB;
import android.nfc.tech.NfcF;
import android.nfc.tech.NfcV;
import android.nfc.tech.TagTechnology;
import android.os.BatteryManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.os.SystemClock;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.provider.Settings;
import android.speech.tts.TextToSpeech;
import android.speech.tts.UtteranceProgressListener;
import android.text.InputType;
import android.view.GestureDetector;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewOutlineProvider;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.WindowManager;
import android.view.animation.AccelerateDecelerateInterpolator;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.ImageButton;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.SeekBar;
import android.widget.TextClock;
import android.widget.TextView;
import android.window.OnBackInvokedDispatcher;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.util.ArrayList;
import java.util.Calendar;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Random;
import java.util.TreeMap;

/**
 * WalkieTales: tap an NFC card on the phone to play a folder of audio.
 *
 * Music lives in /sdcard/Music/Cards/<folder>/... (one folder per card).
 * Grown-ups press and hold ⋮ (top-right) for settings.
 */
public class MainActivity extends Activity implements NfcAdapter.ReaderCallback {

    static final int DIALOG_THEME = android.R.style.Theme_DeviceDefault_Dialog_Alert;
    static final int DEFAULT_ACCENT = 0xFF6C4CF1;
    static final int[] SLEEP_MINUTES = {0, 15, 30, 45, 60};
    static boolean lockTried;

    final Handler h = new Handler(Looper.getMainLooper());
    SharedPreferences prefs;
    NfcAdapter nfc;
    AudioManager audio;
    AudioFocusRequest focusRequest;

    Map<String, String> cards = new TreeMap<>();
    long cardsStamp = -1;

    MediaPlayer mp;
    String folder;              // folder name, Store.ALL, or null when idle
    String folderCard;          // card that started the current folder
    List<Track> tracks = new ArrayList<>();
    boolean preparing, wantPlay; // a live stream is connecting
    int prepToken;
    int index;
    int ticks, bedtimeTicks;
    int accent = DEFAULT_ACCENT;

    String linkTarget;
    String lastTag;
    long lastTagAt;
    volatile int watchToken;

    int sleepIdx;
    long sleepAt;

    boolean dimmed, swallowTouch, askedForFiles, receiversOn, charging;
    int batteryPct = -1;
    RemoteServer server;
    android.media.session.MediaSession session;
    TextToSpeech tts;
    boolean ttsReady;
    EqView eq;
    TextClock nightClock;
    int shownVolume = -1;
    ValueAnimator fade;
    ObjectAnimator breathe;

    FrameLayout rootView, browser;
    LinearLayout grid;
    boolean browsing;
    int browseBuild;
    View nightView, statusGroup, volumeRow, browseBtn, blackout, chipsRow;
    GradientDrawable backdrop;
    ImageView art, moon;
    TextView title, subtitle, status, timePos, timeDur, battery, sleepText, tracksText;
    LinearLayout tracksBtn;
    SeekBar seek;
    boolean scrubbing;
    ImageButton prevBtn, playBtn, nextBtn;
    LinearLayout dots;

    // "Screen off" from the remote: black, touch-proof, and switched off for real where Android allows.
    boolean screenLocked;
    PowerManager.WakeLock lockWake;
    android.net.wifi.WifiManager.WifiLock wifiLock;

    // ================================================================ lifecycle

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        prefs = Store.prefs(this);
        audio = (AudioManager) getSystemService(AUDIO_SERVICE);
        nfc = NfcAdapter.getDefaultAdapter(this);

        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(true);
            setTurnScreenOn(true);
        }
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        buildUi();
        setContentView(rootView);
        hideSystemBars();

        if (Build.VERSION.SDK_INT >= 33) {
            // Kiosk: the back gesture does nothing on the player.
            getOnBackInvokedDispatcher().registerOnBackInvokedCallback(
                    OnBackInvokedDispatcher.PRIORITY_DEFAULT, () -> { if (sheetOpen) closeTrackList(); else if (browsing) closeBrowser(); });
        }

        Kiosk.restoreTimeout(this); // in case the app restarted while the screen was switched off
        showIdle();
        restoreLast();
        handleIntent(getIntent());
        server = new RemoteServer(this, this::remote);
        syncRemote();
        initMediaSession();
        watchNetwork();
        h.postDelayed(() -> findCovers(false), 15_000); // give Wi-Fi a moment after boot
    }

    // ================================================================ automatic covers

    long lastCoverRun;

    void findCovers(boolean force) {
        lastCoverRun = SystemClock.elapsedRealtime();
        ArtFinder.runAsync(this, force, this::coversChanged);
    }

    /** New pictures arrived: refresh the player and the browse grid. */
    void coversChanged() {
        if (folder != null && !Store.ALL.equals(folder)) applyTheme(folder);
        if (browsing) openBrowser();
    }

    // ================================================================ Bluetooth / headset buttons

    /** Lets play/pause/skip buttons on Bluetooth speakers, headphones and media remotes control the player. */
    void initMediaSession() {
        session = new android.media.session.MediaSession(this, "WalkieTales");
        session.setCallback(new android.media.session.MediaSession.Callback() {
            @Override public void onPlay() {
                wake();
                if (mp == null) togglePlay();
                else if (preparing || !mp.isPlaying()) play();
            }
            @Override public void onPause() { pause(); }
            @Override public void onStop() { pause(); }
            @Override public void onSkipToNext() { wake(); next(); }
            @Override public void onSkipToPrevious() { wake(); prev(); }
        }, h);
        session.setActive(true);
        updateMediaSession();
    }

    void updateMediaSession() {
        if (session == null) return;
        boolean playing = ready() && mp.isPlaying();
        long pos = 0;
        try { if (ready() && !isLive()) pos = mp.getCurrentPosition(); } catch (Exception ignored) { }
        session.setPlaybackState(new android.media.session.PlaybackState.Builder()
                .setActions(android.media.session.PlaybackState.ACTION_PLAY
                        | android.media.session.PlaybackState.ACTION_PAUSE
                        | android.media.session.PlaybackState.ACTION_PLAY_PAUSE
                        | android.media.session.PlaybackState.ACTION_STOP
                        | android.media.session.PlaybackState.ACTION_SKIP_TO_NEXT
                        | android.media.session.PlaybackState.ACTION_SKIP_TO_PREVIOUS)
                .setState(playing ? android.media.session.PlaybackState.STATE_PLAYING
                        : android.media.session.PlaybackState.STATE_PAUSED, pos, playing ? 1f : 0f)
                .build());
        if (folder != null && !tracks.isEmpty()) {
            android.media.MediaMetadata.Builder md = new android.media.MediaMetadata.Builder()
                    .putString(android.media.MediaMetadata.METADATA_KEY_TITLE, tracks.get(index).name)
                    .putString(android.media.MediaMetadata.METADATA_KEY_ALBUM, Store.ALL.equals(folder) ? "Everything" : folder)
                    .putString(android.media.MediaMetadata.METADATA_KEY_ARTIST, "WalkieTales")
                    .putLong(android.media.MediaMetadata.METADATA_KEY_TRACK_NUMBER, index + 1)
                    .putLong(android.media.MediaMetadata.METADATA_KEY_NUM_TRACKS, tracks.size());
            try { if (ready() && !isLive()) md.putLong(android.media.MediaMetadata.METADATA_KEY_DURATION, mp.getDuration()); } catch (Exception ignored) { }
            session.setMetadata(md.build());
        }
    }

    // ================================================================ internet (radio needs it)

    boolean online() {
        try {
            android.net.ConnectivityManager cm = (android.net.ConnectivityManager) getSystemService(CONNECTIVITY_SERVICE);
            android.net.NetworkCapabilities nc = cm.getNetworkCapabilities(cm.getActiveNetwork());
            return nc != null && nc.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET);
        } catch (Exception e) {
            return true; // can't tell: don't hide anything
        }
    }

    /** Wi-Fi came or went: refresh the library so radio stations appear / disappear. */
    void watchNetwork() {
        try {
            android.net.ConnectivityManager cm = (android.net.ConnectivityManager) getSystemService(CONNECTIVITY_SERVICE);
            cm.registerDefaultNetworkCallback(new android.net.ConnectivityManager.NetworkCallback() {
                @Override public void onAvailable(android.net.Network n) { h.postDelayed(MainActivity.this::networkChanged, 500); }
                @Override public void onLost(android.net.Network n) { h.postDelayed(MainActivity.this::networkChanged, 500); }
            });
        } catch (Exception ignored) { }
    }

    void networkChanged() {
        if (browsing) openBrowser();
    }

    void syncRemote() {
        boolean want = prefs.getBoolean("remote", true);
        if (want && !server.isRunning()) server.start();
        else if (!want && server.isRunning()) server.stop();
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        handleIntent(intent);
    }

    /**
     * Extras: "folder" plays a folder (also usable from adb:
     * adb shell am start -n app.cardplayer/.MainActivity -e folder "Name");
     * "link" waits for a card to link to that folder/action.
     */
    void handleIntent(Intent i) {
        if (i == null) return;
        String f = i.getStringExtra("folder");
        String link = i.getStringExtra("link");
        i.removeExtra("folder");
        i.removeExtra("link");
        if (f != null && (Store.ALL.equals(f) || new File(Store.root(), f).isDirectory())) {
            savePosition();
            folderCard = null;
            openFolder(f, true);
        }
        if (link != null) {
            linkTarget = link;
            flash("Now tap a card to link it to “" + Store.label(link) + "”", 30000);
            h.removeCallbacks(cancelLink);
            h.postDelayed(cancelLink, 30000);
        }
    }

    @Override
    @SuppressWarnings("deprecation")
    public void onBackPressed() {
        if (sheetOpen) closeTrackList(); else if (browsing) closeBrowser(); // otherwise kiosk: ignore
    }

    @Override
    protected void onResume() {
        super.onResume();
        reloadCards();
        applySettings();
        hideSystemBars();
        wake();
        if (Build.VERSION.SDK_INT >= 30 && !Environment.isExternalStorageManager()) {
            flash("WalkieTales needs access to the Music folder", 8000);
            if (!askedForFiles) {
                askedForFiles = true;
                try {
                    startActivity(new Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                            Uri.parse("package:" + getPackageName())));
                } catch (Exception ignored) { }
            }
        }
        enableReader();
        if (!receiversOn) {
            register(batteryReceiver, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
            register(noisyReceiver, new IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY));
            register(screenReceiver, new IntentFilter(Intent.ACTION_SCREEN_ON));
            receiversOn = true;
        }
        maybeLockTask();
        if (lastCoverRun > 0 && SystemClock.elapsedRealtime() - lastCoverRun > 30 * 60_000L) findCovers(false);
        if (server != null) syncRemote();
        h.post(ticker);
    }

    // ================================================================ remote control API (see RemoteServer)

    JSONObject remote(String method, String path, Map<String, String> q, JSONObject b) throws Exception {
        boolean post = method.equals("POST");
        switch (path) {
            case "/api/status": return status();
            case "/api/library": return library();
            case "/api/cards": return cardsJson();
            case "/api/settings":
                if (post) {
                    Store.applySettings(prefs, b);
                    applySettings();
                    syncRemote();
                }
                return new JSONObject().put("settings", Store.settingsJson(prefs));
            default: break;
        }
        if (!post) return null;
        wake(); // does nothing while the screen is switched off from the remote
        switch (path) {
            case "/api/play": {
                String f = b.optString("folder");
                if (!Store.ALL.equals(f) && (RemoteServer.safeFolder(f) == null || !new File(Store.root(), f).isDirectory())) {
                    throw new IllegalArgumentException("No folder called " + f);
                }
                savePosition();
                folderCard = null;
                openFolder(f, true);
                break;
            }
            case "/api/toggle": togglePlay(); break;
            case "/api/pause": pause(); break;
            case "/api/resume": if (ready() && !mp.isPlaying()) play(); else if (mp == null) togglePlay(); break;
            case "/api/next": next(); break;
            case "/api/prev": prev(); break;
            case "/api/restart": restartFolder(); break;
            case "/api/stop": stopAll(); break;
            case "/api/track": {
                int i = b.getInt("index");
                if (folder == null || i < 0 || i >= tracks.size()) throw new IllegalArgumentException("No such track");
                startTrack(i, 0, true, 0);
                break;
            }
            case "/api/seek": if (ready() && !isLive()) { mp.seekTo(Math.max(0, b.getInt("ms"))); updateUi(); } break;
            case "/api/volume": {
                if (b.has("level")) {
                    int v = Math.max(0, Math.min(capSteps(), b.getInt("level")));
                    audio.setStreamVolume(AudioManager.STREAM_MUSIC, v, 0);
                } else {
                    changeVolume(b.optInt("delta", 0));
                }
                shownVolume = -1;
                renderVolume();
                break;
            }
            case "/api/sleep": setSleep(b.optInt("minutes", 0)); break;
            case "/api/screen": setScreenLocked(b.optBoolean("off", !screenLocked)); break;
            case "/api/message": {
                String t = b.optString("text").trim();
                if (t.length() > 120) t = t.substring(0, 120);
                if (!t.isEmpty()) {
                    flash(t, 20_000);
                    buzz();
                    if (prefs.getBoolean("announce", false) && tts != null && ttsReady) {
                        tts.speak(t, TextToSpeech.QUEUE_FLUSH, null, "msg");
                    }
                }
                break;
            }
            case "/api/cards/link": {
                String t = b.getString("target");
                boolean ok = Store.isAction(t) ? java.util.Arrays.asList(Store.ACTIONS).contains(t)
                        : new File(Store.root(), t).isDirectory();
                if (!ok) throw new IllegalArgumentException("Unknown target");
                linkTarget = t;
                flash("Now tap a card to link it to “" + Store.label(t) + "”", 30000);
                h.removeCallbacks(cancelLink);
                h.postDelayed(cancelLink, 30000);
                break;
            }
            case "/api/covers/find": {
                findCovers(b.optBoolean("force", true));
                return new JSONObject().put("started", true);
            }
            case "/api/covers/remove": { // "wrong cover": delete it and never fetch one for this folder again
                String f = b.getString("folder");
                if (RemoteServer.safeFolder(f) == null) throw new IllegalArgumentException("Bad folder");
                ArtFinder.reject(this, f);
                coversChanged();
                break;
            }
            case "/api/station": {
                String name = b.optString("name").trim(), url = b.optString("url").trim();
                String fold = b.optString("folder").trim();
                if (name.isEmpty()) throw new IllegalArgumentException("Give the station a name");
                if (!Store.isUrl(url) || url.length() > 1000) throw new IllegalArgumentException("The stream address must start with http:// or https://");
                if (name.length() > 60) name = name.substring(0, 60);
                File dir = RemoteServer.safeFolder(fold.isEmpty() ? name.replaceAll("[\\\\/]", "") : fold);
                if (dir == null) throw new IllegalArgumentException("Bad folder name");
                Store.addStation(dir, name, url);
                findCovers(false); // look for the station's logo
                flash("New radio station: " + name, 4000);
                if (browsing) openBrowser();
                break;
            }
            case "/api/cards/cancel": linkTarget = null; h.removeCallbacks(cancelLink); flash("Linking cancelled", 2000); break;
            case "/api/cards/unlink": {
                cards.remove(b.getString("id"));
                Store.saveCards(cards);
                cardsStamp = Store.cardsFile().lastModified();
                break;
            }
            default: return null;
        }
        return status();
    }

    JSONObject status() throws Exception {
        JSONObject s = new JSONObject();
        String version = "";
        try { version = getPackageManager().getPackageInfo(getPackageName(), 0).versionName; } catch (Exception ignored) { }
        s.put("version", version);
        s.put("name", prefs.getString("kid_name", ""));
        boolean have = folder != null && !tracks.isEmpty();
        s.put("folder", have ? folder : JSONObject.NULL);
        s.put("title", have ? (Store.ALL.equals(folder) ? "Everything" : folder) : JSONObject.NULL);
        s.put("playing", ready() && mp.isPlaying());
        if (have) {
            s.put("track", tracks.get(index).name);
            s.put("trackIndex", index);
            s.put("trackCount", tracks.size());
            JSONArray names = new JSONArray();
            for (Track t : tracks) names.put(t.name);
            s.put("tracks", names);
        }
        s.put("live", isLive());
        s.put("connecting", preparing);
        if (ready() && !isLive()) {
            try {
                s.put("position", mp.getCurrentPosition());
                s.put("duration", mp.getDuration());
            } catch (Exception ignored) { }
        }
        JSONObject vol = new JSONObject();
        vol.put("level", audio.getStreamVolume(AudioManager.STREAM_MUSIC));
        vol.put("cap", capSteps());
        vol.put("max", audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC));
        vol.put("quiet", quietNow());
        s.put("volume", vol);
        long left = sleepAt > 0 ? Math.max(0, sleepAt - SystemClock.elapsedRealtime()) : 0;
        s.put("sleepMinutesLeft", sleepAt > 0 ? (left + 59_999) / 60_000 : 0);
        s.put("battery", batteryPct);
        s.put("charging", charging);
        s.put("linking", linkTarget == null ? JSONObject.NULL : Store.label(linkTarget));
        s.put("accent", String.format(Locale.ROOT, "#%06X", accent & 0xFFFFFF));
        s.put("message", status.getText().toString());
        s.put("locked", Kiosk.isLocked(this));
        s.put("nfc", nfcState);
        s.put("screenOff", screenLocked);
        s.put("bedtime", bedtimeNow());
        s.put("dark", blackout.getVisibility() == View.VISIBLE);
        return s;
    }

    JSONObject library() throws Exception {
        JSONArray arr = new JSONArray();
        for (String f : Store.folders()) {
            JSONObject o = new JSONObject();
            o.put("name", f);
            o.put("tracks", Store.listTracks(f).size());
            o.put("live", Store.isLiveOnly(f));
            o.put("autoCover", ArtFinder.hasAuto(f));
            o.put("cards", Store.cardsFor(cards, f));
            o.put("info", tileInfo(f));
            o.put("color", String.format(Locale.ROOT, "#%06X", Ui.colorFor(f) & 0xFFFFFF));
            o.put("shuffle", prefs.getBoolean("shuffle:" + f, false));
            o.put("repeat", prefs.getBoolean("repeat:" + f, false));
            arr.put(o);
        }
        JSONArray acts = new JSONArray();
        for (String a : Store.ACTIONS) acts.put(new JSONObject().put("target", a).put("label", Store.label(a)));
        long free = Store.root().getParentFile() != null ? Store.root().getParentFile().getUsableSpace() : 0;
        return new JSONObject().put("folders", arr).put("actions", acts).put("freeBytes", free);
    }

    JSONObject cardsJson() throws Exception {
        reloadCards();
        JSONArray arr = new JSONArray();
        for (Map.Entry<String, String> e : cards.entrySet()) {
            arr.put(new JSONObject().put("id", e.getKey()).put("target", e.getValue()).put("label", Store.label(e.getValue())));
        }
        return new JSONObject().put("cards", arr).put("linking", linkTarget == null ? JSONObject.NULL : Store.label(linkTarget));
    }

    void setSleep(int minutes) {
        int m = Math.max(0, Math.min(240, minutes));
        sleepAt = m == 0 ? 0 : SystemClock.elapsedRealtime() + m * 60_000L;
        sleepIdx = 0;
        for (int i = 0; i < SLEEP_MINUTES.length; i++) if (SLEEP_MINUTES[i] == m) sleepIdx = i;
        if (m == 0) setPlayerVolume(1f);
        flash(m == 0 ? "Sleep timer off" : "Music stops in " + m + " minutes", 2500);
        renderSleep();
    }

    /** Stop playback and go back to the "Tap a card" screen. */
    void stopAll() {
        savePosition();
        releasePlayer();
        folder = null;
        folderCard = null;
        tracks = new ArrayList<>();
        accent = DEFAULT_ACCENT;
        backdrop.setColors(new int[]{Ui.shade(DEFAULT_ACCENT, 0.35f), 0xFF0B0B10});
        Ui.roundBg(playBtn).setColor(DEFAULT_ACCENT);
        shownVolume = -1;
        renderVolume();
        showIdle();
        updateKeepOn();
    }

    @Override
    protected void onPause() {
        super.onPause();
        if (nfc != null) {
            try { nfc.disableReaderMode(this); } catch (Exception ignored) { }
        }
        watchToken++;
        savePosition();
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        h.removeCallbacksAndMessages(null);
        if (receiversOn) {
            try { unregisterReceiver(batteryReceiver); } catch (Exception ignored) { }
            try { unregisterReceiver(noisyReceiver); } catch (Exception ignored) { }
            try { unregisterReceiver(screenReceiver); } catch (Exception ignored) { }
        }
        releaseLockHolds();
        savePosition();
        releasePlayer();
        if (tts != null) tts.shutdown();
        if (server != null) server.stop();
        if (session != null) session.release();
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) hideSystemBars();
    }

    @Override
    public boolean dispatchTouchEvent(MotionEvent ev) {
        // When the screen is dimmed, the first touch only wakes it (so a sleepy tap can't press a button).
        int a = ev.getActionMasked();
        if (screenLocked) { // switched off from the remote: touches do nothing, and the screen goes back off
            if (a == MotionEvent.ACTION_DOWN) scheduleScreenOff(800);
            return true;
        }
        if (a == MotionEvent.ACTION_DOWN && dimmed) {
            wake();
            swallowTouch = true;
            return true;
        }
        if (swallowTouch) {
            if (a == MotionEvent.ACTION_UP || a == MotionEvent.ACTION_CANCEL) swallowTouch = false;
            return true;
        }
        wake();
        return super.dispatchTouchEvent(ev);
    }

    @Override
    public boolean onKeyDown(int keyCode, KeyEvent e) {
        if (screenLocked && (keyCode == KeyEvent.KEYCODE_VOLUME_UP || keyCode == KeyEvent.KEYCODE_VOLUME_DOWN)) {
            scheduleScreenOff(800);
            return true;
        }
        if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) { changeVolume(1); return true; }
        if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) { changeVolume(-1); return true; }
        // Media buttons (Bluetooth remotes / headsets) even before Android has picked a media session.
        switch (keyCode) {
            case KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE:
            case KeyEvent.KEYCODE_HEADSETHOOK: wake(); togglePlay(); return true;
            case KeyEvent.KEYCODE_MEDIA_PLAY: wake(); if (preparing) play(); else if (mp == null || !mp.isPlaying()) togglePlay(); return true;
            case KeyEvent.KEYCODE_MEDIA_PAUSE:
            case KeyEvent.KEYCODE_MEDIA_STOP: pause(); return true;
            case KeyEvent.KEYCODE_MEDIA_NEXT: wake(); next(); return true;
            case KeyEvent.KEYCODE_MEDIA_PREVIOUS: wake(); prev(); return true;
            default: break;
        }
        return super.onKeyDown(keyCode, e);
    }

    void register(BroadcastReceiver r, IntentFilter f) {
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(r, f, Context.RECEIVER_NOT_EXPORTED);
        else registerReceiver(r, f);
    }

    void reloadCards() {
        long stamp = Store.cardsFile().lastModified();
        if (stamp != cardsStamp) {
            cards = Store.loadCards();
            cardsStamp = stamp;
        }
    }

    void applySettings() {
        volumeRow.setVisibility(prefs.getBoolean("show_volume", true) ? View.VISIBLE : View.GONE);
        statusGroup.setVisibility(prefs.getBoolean("show_status", true) ? View.VISIBLE : View.GONE);
        boolean canBrowse = canBrowse();
        browseBtn.setVisibility(canBrowse ? View.VISIBLE : View.GONE);
        renderTracksBtn();
        if (!canBrowse && browsing) closeBrowser();
        if (Kiosk.isOwner(this) && Kiosk.isLocked(this)) Kiosk.applyFeatures(this); // power menu on/off
        if (!screenLocked) {
            Kiosk.setTimeout(this, prefs.getInt("screen_timeout", 60));
            Kiosk.setStayOnWhileCharging(this, false); // charging alone shouldn't keep the screen on
        }
        if (browsing) openBrowser(); // refresh in case folders changed
        enableReader(); // cards may have been switched on/off
        nightClock.setVisibility(prefs.getBoolean("night_clock", true) ? View.VISIBLE : View.GONE);
        if (prefs.getBoolean("announce", false) && tts == null) initTts();
        if (folder == null) showIdle(); // refresh greeting / name
        else updateUi();
        updateKeepOn();
        enforceVolumeCap();
        shownVolume = -1;
        renderVolume();
    }

    /**
     * Keep the screen (and so the card reader) awake while charging, or also while playing / always if chosen.
     * Otherwise it times out after "screen_timeout" and the music carries on with the screen off.
     */
    void updateKeepOn() {
        int mode = prefs.getInt("screen_on", 0); // 0 never (sleeps after the timeout), 1 always, 2 while playing
        // Cards need the screen on for the reader: then it stays on while charging, and through the bedtime black screen.
        boolean on = !screenLocked && (mode == 1 || (mode == 2 && ready() && mp.isPlaying())
                || (cardsOn() && (charging || bedtimeDarkOn())));
        if (on) getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        else getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    }

    // ================================================================ speaking titles

    void initTts() {
        tts = new TextToSpeech(getApplicationContext(), status -> {
            ttsReady = status == TextToSpeech.SUCCESS;
            if (ttsReady) tts.setSpeechRate(0.9f);
        });
    }

    /** Say the title out loud (if enabled), then run {@code then}. */
    void announce(String text, Runnable then) {
        if (!prefs.getBoolean("announce", false) || tts == null || !ttsReady) {
            then.run();
            return;
        }
        final boolean[] done = {false};
        final Runnable once = () -> {
            if (!done[0]) {
                done[0] = true;
                then.run();
            }
        };
        tts.setOnUtteranceProgressListener(new UtteranceProgressListener() {
            @Override public void onStart(String id) { }
            @Override public void onDone(String id) { h.post(once); }
            @Override public void onError(String id) { h.post(once); }
        });
        Bundle p = new Bundle();
        p.putInt(TextToSpeech.Engine.KEY_PARAM_STREAM, AudioManager.STREAM_MUSIC);
        if (tts.speak(text, TextToSpeech.QUEUE_FLUSH, p, "title") != TextToSpeech.SUCCESS) {
            once.run();
            return;
        }
        h.postDelayed(once, 6000); // never get stuck waiting
    }

    void maybeLockTask() {
        // Coming back to the player after a grown-up visited Android settings: lock again.
        Kiosk.steppedOut = false;
        if (!Kiosk.wanted(this)) return;
        if (Kiosk.isOwner(this)) {
            Kiosk.lock(this); // device owner: silent, total lock (no notification shade)
        } else if (!lockTried) {
            lockTried = true; // plain app pinning asks for confirmation, so only try once
            Kiosk.lock(this);
        }
    }

    // ================================================================ NFC

    boolean cardsOn() {
        return prefs.getBoolean("cards", true);
    }

    /** Browsing is always available when cards are off, otherwise there'd be no way to pick anything. */
    boolean canBrowse() {
        return prefs.getBoolean("browse", true) || !cardsOn();
    }

    void enableReader() {
        if (!cardsOn()) {
            if (nfc != null) {
                try { nfc.disableReaderMode(this); } catch (Exception ignored) { }
            }
            nfcState = "cards off";
            return;
        }
        if (nfc == null) { flash("This phone has no NFC", 8000); return; }
        if (!nfc.isEnabled()) flash("Turn on NFC in Settings", 8000);
        Bundle opts = new Bundle();
        opts.putInt(NfcAdapter.EXTRA_READER_PRESENCE_CHECK_DELAY, 1000);
        try {
            nfc.enableReaderMode(this, this,
                    NfcAdapter.FLAG_READER_NFC_A | NfcAdapter.FLAG_READER_NFC_B
                            | NfcAdapter.FLAG_READER_NFC_F | NfcAdapter.FLAG_READER_NFC_V
                            | NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK,
                    opts);
            nfcState = nfc.isEnabled() ? "reader on" : "NFC off";
            android.util.Log.i("WalkieTales", "NFC reader mode enabled (adapter enabled=" + nfc.isEnabled() + ")");
        } catch (Exception e) {
            nfcState = "reader failed: " + e;
            android.util.Log.e("WalkieTales", "enableReaderMode failed", e);
        }
    }

    String nfcState = "not started";

    @Override
    public void onTagDiscovered(Tag tag) {
        final String id = hex(tag.getId());
        android.util.Log.i("WalkieTales", "Tag discovered id=" + id + " tech=" + java.util.Arrays.toString(tag.getTechList()));
        nfcState = "last card " + id;
        h.post(() -> onCard(id, tag));
    }

    void onCard(String id, Tag tag) {
        long now = SystemClock.elapsedRealtime();
        boolean bounce = id.equals(lastTag) && now - lastTagAt < 1500;
        lastTag = id;
        lastTagAt = now;
        if (bounce) return;
        wake();
        buzz();

        if (linkTarget != null) {
            String was = cards.get(id);
            cards.put(id, linkTarget);
            boolean ok = Store.saveCards(cards);
            cardsStamp = Store.cardsFile().lastModified();
            flash(ok ? "✓ Card linked to “" + Store.label(linkTarget) + "”"
                    + (was != null && !was.equals(linkTarget) ? " (was “" + Store.label(was) + "”)" : "")
                    : "Couldn't save the card link", 5000);
            linkTarget = null;
            h.removeCallbacks(cancelLink);
            pop();
            return;
        }

        String target = cards.get(id);
        if (target == null) {
            flash("This card isn't set up yet", 4000);
            shake();
            return;
        }
        if (Store.isAction(target) && !Store.ALL.equals(target)) {
            pop();
            doAction(target);
            return;
        }
        if (!Store.ALL.equals(target) && !new File(Store.root(), target).isDirectory()) {
            flash("Can't find the “" + target + "” folder", 4000);
            shake();
            return;
        }

        boolean rest = prefs.getBoolean("rest_mode", false);
        if (rest) watchPresence(tag, id);
        pop();

        if (target.equals(folder) && mp != null) {
            folderCard = id;
            if (rest) {
                if (preparing || !mp.isPlaying()) play();
            } else {
                togglePlay();
            }
            return;
        }
        savePosition();
        folderCard = id;
        openFolder(target, true);
    }

    void doAction(String a) {
        switch (a) {
            case Store.PAUSE:
                if (ready() && mp.isPlaying()) pause();
                else flash("Paused", 1500);
                break;
            case Store.NEXT: next(); break;
            case Store.SLEEP: cycleSleep(); break;
            case Store.VOL_UP: changeVolume(1); break;
            case Store.VOL_DOWN: changeVolume(-1); break;
            default: break;
        }
    }

    /** "Rest" mode: keep pinging the card; when it is lifted off the phone, pause. */
    void watchPresence(Tag tag, String id) {
        final int token = ++watchToken;
        final TagTechnology t = techFor(tag);
        if (t == null) return;
        new Thread(() -> {
            try {
                while (token == watchToken) {
                    t.connect();
                    t.close();
                    Thread.sleep(400);
                }
            } catch (Exception e) {
                if (token == watchToken) h.post(() -> onCardRemoved(id));
            } finally {
                try { t.close(); } catch (Exception ignored) { }
            }
        }, "card-presence").start();
    }

    void onCardRemoved(String id) {
        lastTag = null; // allow putting the same card straight back
        if (prefs.getBoolean("rest_mode", false) && id.equals(folderCard) && ready() && mp.isPlaying()) {
            pause();
            flash("Put the card back to keep listening", 4000);
        }
    }

    static TagTechnology techFor(Tag tag) {
        for (String s : tag.getTechList()) {
            if (s.equals(NfcA.class.getName())) return NfcA.get(tag);
            if (s.equals(NfcB.class.getName())) return NfcB.get(tag);
            if (s.equals(NfcF.class.getName())) return NfcF.get(tag);
            if (s.equals(NfcV.class.getName())) return NfcV.get(tag);
            if (s.equals(IsoDep.class.getName())) return IsoDep.get(tag);
            if (s.equals(MifareUltralight.class.getName())) return MifareUltralight.get(tag);
        }
        return null;
    }

    final Runnable cancelLink = () -> {
        if (linkTarget != null) {
            linkTarget = null;
            flash("Linking cancelled", 2500);
        }
    };

    // ================================================================ playback

    void restoreLast() {
        String last = prefs.getString("last", null);
        if (last != null && !Store.ALL.equals(last) && new File(Store.root(), last).isDirectory()) {
            openFolder(last, false);
        }
    }

    void openFolder(String f, boolean play) {
        boolean all = Store.ALL.equals(f);
        List<Track> list;
        if (all) {
            list = new ArrayList<>();
            for (String d : Store.folders()) for (Track t : Store.listTracks(d)) if (!t.live) list.add(t); // no radio in "Everything"
        } else {
            list = Store.listTracks(f);
        }
        if (list.isEmpty()) {
            flash(all ? "There's no music on the phone yet" : "No music in “" + f + "” yet", 4000);
            return;
        }
        boolean shuffle = all || prefs.getBoolean("shuffle:" + f, false);
        boolean resume = !shuffle && prefs.getBoolean("resume:" + f, true);
        if (shuffle) Collections.shuffle(list, new Random());

        folder = f;
        tracks = list;
        int i = 0, pos = 0;
        if (resume) {
            String[] saved = prefs.getString("pos:" + f, "0:0").split(":");
            try {
                i = Integer.parseInt(saved[0]);
                pos = Integer.parseInt(saved[1]);
            } catch (Exception ignored) { }
            if (i < 0 || i >= list.size()) { i = 0; pos = 0; }
        }
        prefs.edit().putString("last", f).apply();
        applyTheme(f);
        if (!play && list.get(i).live) {
            // Restoring a radio folder (e.g. after a restart): don't connect until play is pressed.
            releasePlayer();
            index = i;
            updateUi();
            return;
        }
        if (play && prefs.getBoolean("announce", false)) {
            startTrack(i, pos, false, 0);
            final List<Track> mine = tracks;
            announce(all ? "Everything" : f, () -> { if (tracks == mine) play(); });
        } else {
            startTrack(i, pos, play, 0);
        }
    }

    void startTrack(int i, int posMs, boolean play, int failures) {
        releasePlayer();
        index = i;
        if (tracks.get(i).live) {
            startStream(i, play);
            return;
        }
        MediaPlayer m = new MediaPlayer();
        try {
            m.setAudioAttributes(attrs());
            m.setWakeMode(getApplicationContext(), PowerManager.PARTIAL_WAKE_LOCK);
            m.setDataSource(tracks.get(i).source);
            m.prepare();
            if (posMs > 0 && posMs < m.getDuration() - 2000) m.seekTo(posMs);
        } catch (Exception e) {
            m.release();
            if (failures + 1 < tracks.size()) {
                startTrack((i + 1) % tracks.size(), 0, play, failures + 1);
            } else {
                flash("Couldn't play anything here", 5000);
                updateUi();
            }
            return;
        }
        m.setOnCompletionListener(x -> onTrackDone());
        mp = m;
        if (play) play(); else updateUi();
    }

    // ---------------------------------------------------------------- live streams (radio)

    boolean isLive() {
        return folder != null && !tracks.isEmpty() && index < tracks.size() && tracks.get(index).live;
    }

    /** Player exists and isn't still connecting: safe to ask it for position/duration. */
    boolean ready() {
        return mp != null && !preparing;
    }

    /** Connect to an internet stream without blocking the screen; plays when ready (if asked to). */
    void startStream(int i, boolean play) {
        final Track t = tracks.get(i);
        final int token = ++prepToken;
        preparing = true;
        wantPlay = play;
        flash("Connecting to “" + t.name + "”…", 20000);
        updateUi();
        new Thread(() -> {
            final String url = Store.resolveStream(t.source); // follows .pls/.m3u "listen live" links
            h.post(() -> {
                if (token != prepToken) return; // something else was picked meanwhile
                MediaPlayer m = new MediaPlayer();
                try {
                    m.setAudioAttributes(attrs());
                    m.setWakeMode(getApplicationContext(), PowerManager.PARTIAL_WAKE_LOCK);
                    m.setDataSource(url);
                } catch (Exception e) {
                    m.release();
                    streamFailed(t, token);
                    return;
                }
                m.setOnPreparedListener(x -> {
                    if (token != prepToken || mp != x) return;
                    preparing = false;
                    flash("", 1);
                    if (wantPlay) play(); else updateUi();
                    wantPlay = false;
                });
                m.setOnErrorListener((x, what, extra) -> {
                    if (mp == x) streamFailed(t, token);
                    return true;
                });
                m.setOnCompletionListener(x -> { // the station dropped the connection
                    if (mp != x) return;
                    releasePlayer();
                    flash("“" + t.name + "” stopped. Press play to reconnect", 10000);
                    updateUi();
                });
                mp = m;
                m.prepareAsync();
            });
        }, "stream-connect").start();
    }

    void streamFailed(Track t, int token) {
        if (token != prepToken) return;
        preparing = false;
        wantPlay = false;
        releasePlayer();
        flash("Can't reach “" + t.name + "” right now", 8000);
        updateUi();
    }

    boolean repeats() {
        return Store.ALL.equals(folder) || prefs.getBoolean("repeat:" + folder, false);
    }

    void onTrackDone() {
        if (index + 1 < tracks.size()) {
            startTrack(index + 1, 0, true, 0);
        } else if (repeats()) {
            if (Store.ALL.equals(folder) || prefs.getBoolean("shuffle:" + folder, false)) Collections.shuffle(tracks);
            startTrack(0, 0, true, 0);
        } else {
            prefs.edit().putString("pos:" + folder, "0:0").apply();
            startTrack(0, 0, false, 0);
            flash("The end ★", 5000);
        }
    }

    void play() {
        if (mp == null) return;
        if (preparing) { // still connecting to a station: start as soon as it's ready
            wantPlay = true;
            updateUi();
            return;
        }
        if (focusRequest == null) {
            focusRequest = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(attrs())
                    .setOnAudioFocusChangeListener(c -> {
                        if (c == AudioManager.AUDIOFOCUS_LOSS || c == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) h.post(this::pause);
                    })
                    .build();
        }
        audio.requestAudioFocus(focusRequest);
        enforceVolumeCap();
        if (fade != null) fade.cancel();
        if (prefs.getBoolean("fade_in", true)) {
            setPlayerVolume(0f);
            mp.start();
            fade = ValueAnimator.ofFloat(0f, 1f);
            fade.setDuration(1200);
            fade.addUpdateListener(an -> setPlayerVolume((float) an.getAnimatedValue()));
            fade.start();
        } else {
            setPlayerVolume(1f);
            mp.start();
        }
        updateUi();
    }

    void setPlayerVolume(float v) {
        if (!ready()) return; // not allowed while a station is still connecting
        try { mp.setVolume(v, v); } catch (Exception ignored) { }
    }

    void pause() {
        if (fade != null) fade.cancel();
        wantPlay = false;
        try { if (ready() && mp.isPlaying()) mp.pause(); } catch (Exception ignored) { }
        savePosition();
        updateUi();
    }

    void togglePlay() {
        if (preparing) { // tapping while a station connects cancels/restores the auto-start
            if (wantPlay) pause(); else play();
            return;
        }
        if (mp == null) {
            if (isLive()) startTrack(index, 0, true, 0); // reconnect to the station
            else if (folder != null) openFolder(folder, true);
            else if (canBrowse()) openBrowser();
            else flash("Tap a card on the back of the phone", 3000);
        } else if (mp.isPlaying()) {
            pause();
        } else {
            play();
        }
    }

    void prev() {
        if (isLive()) { // previous station
            if (index > 0) startTrack(index - 1, 0, true, 0);
            else if (tracks.size() > 1) startTrack(tracks.size() - 1, 0, true, 0);
            return;
        }
        if (!ready()) return;
        boolean playing = mp.isPlaying();
        if (mp.getCurrentPosition() > 3000 || index == 0) {
            mp.seekTo(0);
            updateUi();
        } else {
            startTrack(index - 1, 0, playing, 0);
        }
    }

    void next() {
        if (isLive()) { // next station (wraps around)
            if (tracks.size() > 1) startTrack((index + 1) % tracks.size(), 0, true, 0);
            else flash("That's the only station here", 2500);
            return;
        }
        if (mp == null) {
            flash("Nothing is playing", 1500);
            return;
        }
        if (index + 1 < tracks.size()) startTrack(index + 1, 0, true, 0);
        else if (repeats()) startTrack(0, 0, true, 0);
        else flash("That's the last one", 2500);
    }

    void restartFolder() {
        if (folder == null) return;
        startTrack(0, 0, true, 0);
        flash("Back to the beginning", 2500);
    }

    void savePosition() {
        if (folder == null || mp == null || Store.ALL.equals(folder)) return;
        if (prefs.getBoolean("shuffle:" + folder, false)) return;
        try {
            int pos = isLive() || !ready() ? 0 : mp.getCurrentPosition(); // stations: just remember which one
            prefs.edit().putString("pos:" + folder, index + ":" + pos).apply();
        } catch (Exception ignored) { }
    }

    void releasePlayer() {
        prepToken++; // cancels any station that's still connecting
        preparing = false;
        if (mp != null) {
            try { mp.release(); } catch (Exception ignored) { }
            mp = null;
        }
    }

    static AudioAttributes attrs() {
        return new AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                .build();
    }

    final Runnable ticker = new Runnable() {
        @Override public void run() {
            h.removeCallbacks(this);
            if (isLive()) {
                setSeekable(false);
                seek.setMax(1);
                seek.setProgress(ready() ? 1 : 0); // full bar = on air
                timePos.setText(preparing ? "Connecting…" : ready() && mp.isPlaying() ? "●  LIVE" : "LIVE");
                timeDur.setText("");
            } else if (ready()) {
                setSeekable(true);
                try {
                    int dur = mp.getDuration(), cur = mp.getCurrentPosition();
                    if (!scrubbing) {
                        seek.setMax(Math.max(dur, 1));
                        seek.setProgress(cur);
                        timePos.setText(fmt(cur));
                    }
                    timeDur.setText(fmt(dur));
                    if (mp.isPlaying() && ++ticks % 20 == 0) savePosition();
                } catch (Exception ignored) { }
            } else {
                setSeekable(false);
            }
            if (++bedtimeTicks % 20 == 0) checkBedtime();
            tickSleep();
            enforceVolumeCap();
            renderVolume();
            h.postDelayed(this, 500);
        }
    };

    // ================================================================ sleep timer

    void cycleSleep() {
        sleepIdx = (sleepIdx + 1) % SLEEP_MINUTES.length;
        int m = SLEEP_MINUTES[sleepIdx];
        sleepAt = m == 0 ? 0 : SystemClock.elapsedRealtime() + m * 60_000L;
        if (m == 0) setPlayerVolume(1f);
        flash(m == 0 ? "Sleep timer off" : "Music stops in " + m + " minutes", 2500);
        renderSleep();
    }

    void tickSleep() {
        if (sleepAt > 0) {
            long left = sleepAt - SystemClock.elapsedRealtime();
            if (left <= 0) {
                sleepAt = 0;
                sleepIdx = 0;
                pause();
                setPlayerVolume(1f);
                flash("Goodnight", 6000);
                h.postDelayed(dim, 4000);
            } else if (left < 15_000 && ready() && mp.isPlaying() && (fade == null || !fade.isRunning())) {
                setPlayerVolume(left / 15_000f);
            }
        }
        renderSleep();
    }

    void renderSleep() {
        if (sleepAt > 0) {
            long left = Math.max(0, sleepAt - SystemClock.elapsedRealtime());
            sleepText.setText(((left + 59_999) / 60_000) + "m");
            moon.setColorFilter(0xFFFFD54F);
            moon.setAlpha(1f);
        } else {
            sleepText.setText("");
            moon.clearColorFilter();
            moon.setAlpha(0.5f);
        }
    }

    // ================================================================ volume

    int capSteps() {
        int max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC);
        int pct = prefs.getInt("max_volume", 70);
        if (quietNow()) pct = Math.min(pct, prefs.getInt("quiet_volume", 40));
        return Math.max(1, Math.round(max * pct / 100f));
    }

    /** Quiet hours: a lower volume limit overnight (e.g. 7pm–7am). */
    boolean quietNow() {
        return prefs.getBoolean("quiet", false) && bedtimeNow();
    }

    /** Bedtime: between the quiet-hours start and end times (used by the volume limit and the screen-off option). */
    boolean bedtimeNow() {
        Calendar c = Calendar.getInstance();
        int m = c.get(Calendar.HOUR_OF_DAY) * 60 + c.get(Calendar.MINUTE);
        int s = prefs.getInt("quiet_start", 19 * 60), e = prefs.getInt("quiet_end", 7 * 60);
        return s <= e ? (m >= s && m < e) : (m >= s || m < e);
    }

    void enforceVolumeCap() {
        int cap = capSteps();
        if (audio.getStreamVolume(AudioManager.STREAM_MUSIC) > cap) {
            audio.setStreamVolume(AudioManager.STREAM_MUSIC, cap, 0);
        }
    }

    void changeVolume(int d) {
        int cap = capSteps();
        int cur = audio.getStreamVolume(AudioManager.STREAM_MUSIC);
        int v = Math.max(0, Math.min(cap, cur + d));
        audio.setStreamVolume(AudioManager.STREAM_MUSIC, v, 0);
        if (d > 0 && cur >= cap) flash("That's as loud as it goes", 1500);
        if (v == 0) flash("Volume is off", 1500);
        wake();
        renderVolume();
    }

    void renderVolume() {
        int cap = capSteps();
        int cur = Math.min(audio.getStreamVolume(AudioManager.STREAM_MUSIC), cap);
        // Show at most 10 dots; each dot can stand for more than one volume step.
        int segs = Math.min(cap, 10);
        int lit = cur == 0 ? 0 : Math.max(1, Math.round(cur * segs / (float) cap));
        int key = segs * 100_000 + lit * 1000 + (accent & 0xFFF);
        if (key == shownVolume) return;
        shownVolume = key;
        if (dots.getChildCount() != segs) {
            dots.removeAllViews();
            int avail = getResources().getDisplayMetrics().widthPixels - dp(2 * 22 + 2 * 52 + 24);
            int slot = Math.min(dp(22), avail / segs);
            int size = Math.max(dp(6), Math.round(slot * 0.6f));
            for (int i = 0; i < segs; i++) {
                View d = new View(this);
                GradientDrawable g = new GradientDrawable();
                g.setShape(GradientDrawable.OVAL);
                d.setBackground(g);
                LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(size, size);
                lp.leftMargin = lp.rightMargin = (slot - size) / 2;
                dots.addView(d, lp);
            }
        }
        for (int i = 0; i < segs; i++) {
            ((GradientDrawable) dots.getChildAt(i).getBackground()).setColor(i < lit ? Ui.tint(accent, 0.2f) : 0x2EFFFFFF);
        }
    }

    // ================================================================ grown-up gate

    void openSettings() {
        if (!prefs.getBoolean("gate", true)) {
            startActivity(new Intent(this, SettingsActivity.class));
            return;
        }
        Random r = new Random();
        // Two-digit addition: quick for grown-ups, still beyond small children.
        final int a = 11 + r.nextInt(39), b = 11 + r.nextInt(39);
        final EditText in = new EditText(this);
        in.setInputType(InputType.TYPE_CLASS_NUMBER);
        in.setTextSize(26);
        in.setGravity(Gravity.CENTER);
        FrameLayout box = new FrameLayout(this);
        box.setPadding(dp(24), dp(8), dp(24), 0);
        box.addView(in);
        AlertDialog d = new AlertDialog.Builder(this, DIALOG_THEME)
                .setTitle("Grown-ups only")
                .setMessage("What is " + a + " + " + b + "?")
                .setView(box)
                .setPositiveButton("OK", (x, w) -> {
                    if (in.getText().toString().trim().equals(String.valueOf(a + b))) {
                        startActivity(new Intent(this, SettingsActivity.class));
                    } else {
                        flash("Not quite!", 2000);
                        shake();
                    }
                })
                .setNegativeButton("Cancel", null)
                .create();
        d.getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_VISIBLE);
        d.show();
        in.requestFocus();
    }

    // ================================================================ UI

    void buildUi() {
        rootView = new FrameLayout(this);
        backdrop = new GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM,
                new int[]{Ui.shade(DEFAULT_ACCENT, 0.35f), 0xFF0B0B10});
        rootView.setBackground(backdrop);

        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        col.setGravity(Gravity.CENTER_HORIZONTAL);
        col.setPadding(dp(22), dp(10), dp(22), dp(18));
        col.setClipToPadding(false); // the scrub dot reaches into the side margins at the start/end of a track
        col.setClipChildren(false);
        rootView.addView(col, new FrameLayout.LayoutParams(-1, -1));

        // ---- top bar: clock · battery ........ sleep timer · settings cog
        LinearLayout top = new LinearLayout(this);
        top.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout sg = new LinearLayout(this);
        sg.setGravity(Gravity.CENTER_VERTICAL);
        TextClock clock = new TextClock(this);
        clock.setTextSize(17);
        clock.setTextColor(0xD9FFFFFF);
        clock.setTypeface(android.graphics.Typeface.create("sans-serif-medium", android.graphics.Typeface.NORMAL));
        sg.addView(clock);
        battery = Ui.text(this, "", 14, 0x99FFFFFF, false);
        battery.setPadding(dp(12), 0, 0, 0);
        sg.addView(battery);
        statusGroup = sg;
        top.addView(sg);
        top.addView(new View(this), new LinearLayout.LayoutParams(0, 1, 1f));
        sleepText = Ui.text(this, "", 14, 0xFFFFD54F, true);
        sleepText.setPadding(dp(6), 0, 0, 0);
        top.addView(sleepText);
        moon = new ImageView(this);
        moon.setImageResource(R.drawable.ic_moon);
        moon.setPadding(dp(11), dp(11), dp(11), dp(11));
        moon.setContentDescription("Sleep timer");
        moon.setOnClickListener(v -> cycleSleep());
        top.addView(moon, new LinearLayout.LayoutParams(dp(46), dp(46)));
        ImageView cog = new ImageView(this);
        cog.setImageResource(R.drawable.ic_settings);
        cog.setAlpha(0.55f);
        cog.setPadding(dp(11), dp(11), dp(11), dp(11));
        cog.setContentDescription("Grown-up settings (press and hold)");
        cog.setOnClickListener(v -> flash("Grown-ups: press and hold ⚙", 2000));
        cog.setOnLongClickListener(v -> { openSettings(); return true; });
        top.addView(cog, new LinearLayout.LayoutParams(dp(46), dp(46)));
        col.addView(top, new LinearLayout.LayoutParams(-1, dp(46)));

        // ---- artwork: lives in a box that takes all leftover height, and stays square inside it,
        // so the controls below always fit whatever the screen size.
        FrameLayout artBox = new FrameLayout(this) {
            @Override protected void onSizeChanged(int w, int hgt, int ow, int oh) {
                super.onSizeChanged(w, hgt, ow, oh);
                int s = Math.max(dp(120), Math.min(Math.min(w - dp(16), hgt - dp(16)), dp(340)));
                FrameLayout.LayoutParams lp = (FrameLayout.LayoutParams) art.getLayoutParams();
                if (lp.width != s) {
                    lp.width = s;
                    lp.height = s;
                    post(() -> art.setLayoutParams(lp));
                }
            }
        };
        col.addView(artBox, new LinearLayout.LayoutParams(-1, 0, 1f));
        art = new ImageView(this);
        art.setScaleType(ImageView.ScaleType.CENTER_CROP);
        art.setOutlineProvider(new ViewOutlineProvider() {
            @Override public void getOutline(View v, Outline o) {
                o.setRoundRect(0, 0, v.getWidth(), v.getHeight(), dp(28));
            }
        });
        art.setClipToOutline(true);
        art.setElevation(dp(18));
        // Tap the cover to play/pause; swipe it left/right to skip, up for the track list.
        final GestureDetector gd = new GestureDetector(this, new GestureDetector.SimpleOnGestureListener() {
            @Override public boolean onDown(MotionEvent e) { return true; }
            @Override public boolean onSingleTapUp(MotionEvent e) {
                togglePlay();
                return true;
            }
            @Override public boolean onFling(MotionEvent a, MotionEvent b, float vx, float vy) {
                if (a == null) return false;
                float dx = b.getX() - a.getX(), dy = b.getY() - a.getY();
                if (mp != null && Math.abs(dx) > dp(50) && Math.abs(vx) > Math.abs(vy)) {
                    nudge(dx < 0);
                    if (dx < 0) next(); else prev();
                    return true;
                }
                if (dy < -dp(60) && Math.abs(vy) > Math.abs(vx)) {
                    showTrackList();
                    return true;
                }
                return false;
            }
        });
        art.setOnTouchListener((v, e) -> gd.onTouchEvent(e));
        art.setContentDescription("Cover. Tap to play or pause, swipe sideways to skip, swipe up for the tracks");
        int size = dp(240); // replaced with the real size once the box is measured
        artBox.addView(art, new FrameLayout.LayoutParams(size, size, Gravity.CENTER));
        breathe = ObjectAnimator.ofFloat(art, "scaleX", 1f, 1.035f);
        breathe.setDuration(2200);
        breathe.setRepeatMode(ValueAnimator.REVERSE);
        breathe.setRepeatCount(ValueAnimator.INFINITE);
        breathe.setInterpolator(new AccelerateDecelerateInterpolator());
        breathe.addUpdateListener(an -> art.setScaleY((float) an.getAnimatedValue()));

        // messages float over the bottom of the cover instead of taking up a row of their own
        status = Ui.text(this, "", 15, 0xFFFFE082, true);
        status.setGravity(Gravity.CENTER);
        status.setPadding(dp(16), dp(9), dp(16), dp(9));
        status.setMaxLines(3);
        GradientDrawable sb = new GradientDrawable();
        sb.setCornerRadius(dp(18));
        sb.setColor(0xD9101016);
        status.setBackground(sb);
        status.setElevation(dp(24));
        status.setVisibility(View.GONE);
        FrameLayout.LayoutParams stl = new FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
        stl.bottomMargin = dp(14);
        stl.leftMargin = stl.rightMargin = dp(18);
        artBox.addView(status, stl);

        // ---- folder name (shrinks to fit one line) and the track playing
        title = Ui.text(this, "", 26, Color.WHITE, true);
        title.setGravity(Gravity.CENTER);
        title.setMaxLines(1);
        title.setAutoSizeTextTypeUniformWithConfiguration(17, 26, 1, android.util.TypedValue.COMPLEX_UNIT_SP);
        LinearLayout.LayoutParams tl = new LinearLayout.LayoutParams(-1, dp(38));
        tl.topMargin = dp(12);
        col.addView(title, tl);

        LinearLayout subRow = new LinearLayout(this);
        subRow.setGravity(Gravity.CENTER);
        eq = new EqView(this);
        LinearLayout.LayoutParams el = new LinearLayout.LayoutParams(dp(20), dp(14));
        el.rightMargin = dp(10);
        subRow.addView(eq, el);
        subtitle = Ui.text(this, "", 17, 0xC7FFFFFF, false);
        subtitle.setSingleLine(true);
        subtitle.setEllipsize(TextUtils.TruncateAt.END);
        subtitle.setMaxWidth(getResources().getDisplayMetrics().widthPixels - dp(90));
        subRow.addView(subtitle);
        LinearLayout.LayoutParams sl = new LinearLayout.LayoutParams(-1, -2);
        sl.topMargin = dp(2);
        col.addView(subRow, sl);

        // ---- scrub bar: drag the dot to move through the track
        seek = new SeekBar(this);
        GradientDrawable trackBg = new GradientDrawable();
        trackBg.setCornerRadius(dp(4));
        trackBg.setColor(0x33FFFFFF);
        GradientDrawable trackFg = new GradientDrawable();
        trackFg.setCornerRadius(dp(4));
        trackFg.setColor(Color.WHITE);
        android.graphics.drawable.LayerDrawable bar = new android.graphics.drawable.LayerDrawable(new android.graphics.drawable.Drawable[]{
                trackBg, new android.graphics.drawable.ClipDrawable(trackFg, Gravity.START, android.graphics.drawable.ClipDrawable.HORIZONTAL)});
        bar.setId(0, android.R.id.background);
        bar.setId(1, android.R.id.progress);
        seek.setProgressDrawable(bar);
        seek.setMinHeight(dp(8));
        seek.setMaxHeight(dp(8));
        GradientDrawable thumb = new GradientDrawable();
        thumb.setShape(GradientDrawable.OVAL);
        thumb.setColor(Color.WHITE);
        thumb.setSize(dp(26), dp(26));
        seek.setThumb(thumb);
        seek.setSplitTrack(false);
        seek.setPadding(dp(14), 0, dp(14), 0);
        seek.setContentDescription("Position in the track");
        seek.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override public void onProgressChanged(SeekBar s, int p, boolean user) {
                if (user) timePos.setText(fmt(p));
            }
            @Override public void onStartTrackingTouch(SeekBar s) {
                scrubbing = true;
                s.animate().scaleY(1.15f).setDuration(120).start();
            }
            @Override public void onStopTrackingTouch(SeekBar s) {
                scrubbing = false;
                s.animate().scaleY(1f).setDuration(160).start();
                if (ready() && !isLive()) {
                    try {
                        mp.seekTo(s.getProgress());
                        savePosition();
                    } catch (Exception ignored) { }
                }
                updateUi();
            }
        });
        LinearLayout.LayoutParams skl = new LinearLayout.LayoutParams(-1, dp(40));
        skl.topMargin = dp(10);
        skl.leftMargin = skl.rightMargin = -dp(14); // let the dot reach the edges of the column
        col.addView(seek, skl);
        LinearLayout times = new LinearLayout(this);
        timePos = Ui.text(this, "", 13, 0x99FFFFFF, false);
        timeDur = Ui.text(this, "", 13, 0x99FFFFFF, false);
        times.addView(timePos, new LinearLayout.LayoutParams(0, -2, 1f));
        times.addView(timeDur);
        col.addView(times, new LinearLayout.LayoutParams(-1, -2));

        // ---- transport
        LinearLayout controls = new LinearLayout(this);
        controls.setGravity(Gravity.CENTER);
        prevBtn = Ui.roundButton(this, R.drawable.ic_prev, 0x26FFFFFF, 18);
        playBtn = Ui.roundButton(this, R.drawable.ic_play, DEFAULT_ACCENT, 22);
        nextBtn = Ui.roundButton(this, R.drawable.ic_next, 0x26FFFFFF, 18);
        prevBtn.setContentDescription("Previous track");
        playBtn.setContentDescription("Play or pause");
        nextBtn.setContentDescription("Next track");
        prevBtn.setOnClickListener(v -> prev());
        prevBtn.setOnLongClickListener(v -> { restartFolder(); return true; });
        playBtn.setOnClickListener(v -> togglePlay());
        nextBtn.setOnClickListener(v -> next());
        controls.addView(prevBtn, sized(68, 0));
        controls.addView(playBtn, sized(92, 30));
        controls.addView(nextBtn, sized(68, 0));
        LinearLayout.LayoutParams cl = new LinearLayout.LayoutParams(-1, -2);
        cl.topMargin = dp(8);
        col.addView(controls, cl);

        // ---- volume: [-] ● ● ● ○ ○ [+]
        LinearLayout vr = new LinearLayout(this);
        vr.setGravity(Gravity.CENTER);
        ImageButton down = Ui.roundButton(this, R.drawable.ic_vol_down, 0x1AFFFFFF, 12);
        ImageButton up = Ui.roundButton(this, R.drawable.ic_vol_up, 0x1AFFFFFF, 12);
        down.setElevation(0);
        up.setElevation(0);
        down.setContentDescription("Quieter");
        up.setContentDescription("Louder");
        down.setOnClickListener(v -> changeVolume(-1));
        up.setOnClickListener(v -> changeVolume(1));
        dots = new LinearLayout(this);
        dots.setGravity(Gravity.CENTER);
        vr.addView(down, sized(48, 0));
        LinearLayout.LayoutParams dl = new LinearLayout.LayoutParams(-2, -2);
        dl.leftMargin = dl.rightMargin = dp(12);
        vr.addView(dots, dl);
        vr.addView(up, sized(48, 0));
        volumeRow = vr;
        LinearLayout.LayoutParams vl = new LinearLayout.LayoutParams(-1, -2);
        vl.topMargin = dp(12);
        col.addView(vr, vl);

        // ---- two big buttons: pick something else / see every track
        LinearLayout chips = new LinearLayout(this);
        browseBtn = chip(R.drawable.ic_grid, "Library", null);
        browseBtn.setOnClickListener(v -> openBrowser());
        tracksText = Ui.text(this, "Tracks", 17, Color.WHITE, true);
        tracksBtn = chip(R.drawable.ic_queue, null, tracksText);
        tracksBtn.setOnClickListener(v -> showTrackList());
        LinearLayout.LayoutParams c1 = new LinearLayout.LayoutParams(0, dp(54), 1f);
        LinearLayout.LayoutParams c2 = new LinearLayout.LayoutParams(0, dp(54), 1f);
        c2.leftMargin = dp(12);
        chips.addView(browseBtn, c1);
        chips.addView(tracksBtn, c2);
        chipsRow = chips;
        LinearLayout.LayoutParams chl = new LinearLayout.LayoutParams(-1, -2);
        chl.topMargin = dp(16);
        col.addView(chips, chl);

        // ---- library browser overlay (lets kids pick without a card; can be turned off in settings)
        browser = new FrameLayout(this);
        browser.setBackgroundColor(0xFF0B0B10);
        browser.setVisibility(View.GONE);
        browser.setClickable(true); // don't let taps fall through to the player
        LinearLayout bcol = new LinearLayout(this);
        bcol.setOrientation(LinearLayout.VERTICAL);
        bcol.setPadding(dp(20), dp(16), dp(20), 0);
        LinearLayout bhead = new LinearLayout(this);
        bhead.setGravity(Gravity.CENTER_VERTICAL);
        TextView btitle = Ui.text(this, "Pick something", 26, Color.WHITE, true);
        bhead.addView(btitle, new LinearLayout.LayoutParams(0, -2, 1f));
        ImageButton close = Ui.roundButton(this, R.drawable.ic_close, 0x26FFFFFF, 12);
        close.setElevation(0);
        close.setOnClickListener(v -> closeBrowser());
        bhead.addView(close, sized(48, 0));
        bcol.addView(bhead, new LinearLayout.LayoutParams(-1, dp(56)));
        android.widget.ScrollView scroll = new android.widget.ScrollView(this);
        scroll.setVerticalScrollBarEnabled(false);
        grid = new LinearLayout(this);
        grid.setOrientation(LinearLayout.VERTICAL);
        grid.setPadding(0, dp(8), 0, dp(24));
        scroll.addView(grid);
        bcol.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1f));
        browser.addView(bcol, new FrameLayout.LayoutParams(-1, -1));
        rootView.addView(browser, new FrameLayout.LayoutParams(-1, -1));

        // ---- night light overlay (shown instead of a dark screen when idle)
        GradientDrawable glow = new GradientDrawable();
        glow.setGradientType(GradientDrawable.RADIAL_GRADIENT);
        glow.setColors(new int[]{0xFFFFB86B, 0xFF8A4214, 0xFF140904});
        glow.setGradientRadius(dp(380));
        FrameLayout nv = new FrameLayout(this);
        nv.setBackground(glow);
        nv.setVisibility(View.GONE);
        nightClock = new TextClock(this);
        nightClock.setFormat12Hour("h:mm");
        nightClock.setFormat24Hour("H:mm");
        nightClock.setTextSize(76);
        nightClock.setTextColor(0x8CFFE6C2);
        nightClock.setTypeface(android.graphics.Typeface.create("sans-serif-light", android.graphics.Typeface.NORMAL));
        FrameLayout.LayoutParams ncl = new FrameLayout.LayoutParams(-2, -2, Gravity.CENTER_HORIZONTAL | Gravity.TOP);
        ncl.topMargin = dp(120);
        nv.addView(nightClock, ncl);
        nightView = nv;
        rootView.addView(nightView, new FrameLayout.LayoutParams(-1, -1));

        // ---- black screen: bedtime "screen off", and "screen off" from the remote
        blackout = new View(this);
        blackout.setBackgroundColor(Color.BLACK);
        blackout.setVisibility(View.GONE);
        rootView.addView(blackout, new FrameLayout.LayoutParams(-1, -1));
    }

    /** A big rounded button with an icon and a label, for the bottom row. */
    LinearLayout chip(int icon, String label, TextView labelView) {
        LinearLayout c = new LinearLayout(this);
        c.setGravity(Gravity.CENTER);
        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(dp(27));
        bg.setColor(0x24FFFFFF);
        c.setBackground(new android.graphics.drawable.RippleDrawable(ColorStateList.valueOf(0x40FFFFFF), bg, null));
        ImageView i = new ImageView(this);
        i.setImageResource(icon);
        i.setColorFilter(Color.WHITE);
        c.addView(i, new LinearLayout.LayoutParams(dp(24), dp(24)));
        TextView t = labelView != null ? labelView : Ui.text(this, label, 17, Color.WHITE, true);
        t.setPadding(dp(10), 0, 0, 0);
        t.setSingleLine(true);
        c.addView(t);
        c.setContentDescription(label != null ? label : "Tracks");
        return c;
    }

    void setSeekable(boolean on) {
        if (seek.isEnabled() == on) return;
        seek.setEnabled(on);
        seek.getThumb().mutate().setAlpha(on ? 255 : 0);
    }

    /** "Tracks · 3 of 9" button; hidden when there's nothing to choose from or the list is turned off. */
    void renderTracksBtn() {
        boolean allowed = prefs.getBoolean("track_list", true);
        boolean have = folder != null && tracks.size() > 1;
        tracksBtn.setVisibility(allowed ? View.VISIBLE : View.GONE);
        tracksBtn.setAlpha(have ? 1f : 0.4f);
        tracksBtn.setEnabled(have);
        if (have) tracksText.setText((isLive() ? "Stations  " : "Tracks  ") + (index + 1) + "/" + tracks.size());
        else tracksText.setText("Tracks");
        boolean both = allowed && browseBtn.getVisibility() == View.VISIBLE;
        ((LinearLayout.LayoutParams) tracksBtn.getLayoutParams()).leftMargin = both ? dp(12) : 0;
        chipsRow.setVisibility(allowed || browseBtn.getVisibility() == View.VISIBLE ? View.VISIBLE : View.GONE);
        chipsRow.requestLayout();
    }

    // ================================================================ browse without cards

    void openBrowser() {
        if (!canBrowse()) return;
        final int build = ++browseBuild;
        grid.removeAllViews();
        final List<String> items = new ArrayList<>();
        boolean online = online();
        for (String f : Store.folders()) {
            if (Store.listTracks(f).isEmpty()) continue;
            if (!online && Store.isLiveOnly(f)) continue; // no internet: radio stations can't play, so don't offer them
            items.add(f);
        }
        if (items.size() > 1) items.add(Store.ALL);

        if (items.isEmpty()) {
            TextView empty = Ui.text(this, "No music yet.\n\nGrown-ups: copy folders of music into Music/Cards/ on the phone.",
                    17, 0xB3FFFFFF, false);
            empty.setGravity(Gravity.CENTER);
            empty.setPadding(dp(16), dp(60), dp(16), 0);
            grid.addView(empty);
        }

        int gap = dp(16);
        int tile = (getResources().getDisplayMetrics().widthPixels - dp(40) - gap) / 2;
        final List<ImageView> arts = new ArrayList<>();
        LinearLayout row = null;
        for (int i = 0; i < items.size(); i++) {
            final String f = items.get(i);
            if (i % 2 == 0) {
                row = new LinearLayout(this);
                LinearLayout.LayoutParams rl = new LinearLayout.LayoutParams(-1, -2);
                rl.bottomMargin = dp(18);
                grid.addView(row, rl);
            }
            boolean all = Store.ALL.equals(f);
            int c = all ? 0xFFE0559A : Ui.colorFor(f);
            LinearLayout cell = new LinearLayout(this);
            cell.setOrientation(LinearLayout.VERTICAL);
            ImageView img = new ImageView(this);
            img.setScaleType(ImageView.ScaleType.CENTER_CROP);
            img.setImageBitmap(Ui.letterArt(all ? "★" : f.substring(0, 1).toUpperCase(Locale.ROOT), c));
            img.setOutlineProvider(new ViewOutlineProvider() {
                @Override public void getOutline(View v, Outline o) {
                    o.setRoundRect(0, 0, v.getWidth(), v.getHeight(), dp(20));
                }
            });
            img.setClipToOutline(true);
            img.setElevation(dp(8));
            cell.addView(img, new LinearLayout.LayoutParams(tile, tile));
            TextView name = Ui.text(this, all ? "Everything" : f, 16, Color.WHITE, true);
            name.setMaxLines(2);
            name.setEllipsize(TextUtils.TruncateAt.END);
            name.setPadding(dp(4), dp(8), dp(4), 0);
            if (f.equals(folder)) name.setTextColor(Ui.tint(c, 0.35f));
            cell.addView(name, new LinearLayout.LayoutParams(tile, -2));
            TextView info = Ui.text(this, tileInfo(f), 13, 0x8CFFFFFF, false);
            info.setPadding(dp(4), dp(2), dp(4), 0);
            cell.addView(info, new LinearLayout.LayoutParams(tile, -2));
            cell.setOnClickListener(v -> {
                closeBrowser();
                if (f.equals(folder) && mp != null) {
                    if (preparing || !mp.isPlaying()) play();
                } else {
                    savePosition();
                    folderCard = null;
                    openFolder(f, true);
                }
                pop();
            });
            LinearLayout.LayoutParams cl = new LinearLayout.LayoutParams(tile, -2);
            if (i % 2 == 0) cl.rightMargin = gap;
            row.addView(cell, cl);
            arts.add(all ? null : img);
        }

        // Load real cover art off the main thread.
        new Thread(() -> {
            for (int i = 0; i < items.size(); i++) {
                if (build != browseBuild) return;
                ImageView img = arts.get(i);
                if (img == null) continue;
                Bitmap cover = Ui.loadCover(new File(Store.root(), items.get(i)));
                if (cover != null) h.post(() -> { if (build == browseBuild) img.setImageBitmap(cover); });
            }
        }, "covers").start();

        if (!browsing) {
            browsing = true;
            browser.setAlpha(0f);
            browser.setTranslationY(dp(40));
            browser.setVisibility(View.VISIBLE);
            browser.animate().alpha(1f).translationY(0).setDuration(220).start();
        }
    }

    String tileInfo(String f) {
        if (f.equals(folder) && ready() && mp.isPlaying()) return "Now playing";
        if (Store.ALL.equals(f)) return "Shuffle it all";
        if (Store.isLiveOnly(f)) {
            int s = Store.listTracks(f).size();
            return s == 1 ? "Live radio" : s + " radio stations";
        }
        int n = Store.listTracks(f).size();
        int at = 0;
        try { at = Integer.parseInt(prefs.getString("pos:" + f, "0:0").split(":")[0]); } catch (Exception ignored) { }
        boolean resumes = prefs.getBoolean("resume:" + f, true) && !prefs.getBoolean("shuffle:" + f, false);
        if (resumes && at > 0 && at < n) return "Track " + (at + 1) + " of " + n;
        return n + (n == 1 ? " track" : " tracks");
    }

    void closeBrowser() {
        if (!browsing) return;
        browsing = false;
        browseBuild++;
        browser.animate().alpha(0f).translationY(dp(40)).setDuration(180)
                .withEndAction(() -> browser.setVisibility(View.GONE)).start();
    }

    LinearLayout.LayoutParams sized(int sizeDp, int sideMarginDp) {
        LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(dp(sizeDp), dp(sizeDp));
        p.leftMargin = p.rightMargin = dp(sideMarginDp);
        return p;
    }

    Bitmap idleArt;

    void showIdle() {
        if (idleArt == null) idleArt = Ui.letterArt("♪", DEFAULT_ACCENT);
        art.setImageBitmap(idleArt);
        String name = prefs.getString("kid_name", "").trim();
        boolean browse = canBrowse();
        if (!cardsOn()) {
            // Browse-only player (e.g. a phone without working NFC).
            title.setText(name.isEmpty() ? "Pick something!" : greeting() + ", " + name + "!");
            subtitle.setText("Press Library to choose");
        } else {
            title.setText(name.isEmpty() ? "Tap a card" : greeting() + ", " + name + "!");
            subtitle.setText(browse ? "Tap a card, or press Library" : "Hold a card against the back of the phone");
        }
        timePos.setText("");
        timeDur.setText("");
        seek.setProgress(0);
        setSeekable(false);
        renderTracksBtn();
        eq.setPlaying(false);
        eq.setVisibility(View.GONE);
        setControlsEnabled(false);
        setBreathing(true);
    }

    static String greeting() {
        int hr = Calendar.getInstance().get(Calendar.HOUR_OF_DAY);
        if (hr < 5 || hr >= 19) return "Sleep tight";
        if (hr < 12) return "Good morning";
        if (hr < 17) return "Good afternoon";
        return "Good evening";
    }

    // ================================================================ track list (bottom sheet)

    FrameLayout sheet;
    boolean sheetOpen;
    int sheetBuild;

    void showTrackList() {
        if (folder == null || tracks.isEmpty() || !prefs.getBoolean("track_list", true)) return;
        final int build = ++sheetBuild;
        final List<Track> list = tracks;
        final boolean all = Store.ALL.equals(folder);

        if (sheet != null) rootView.removeView(sheet);
        sheet = new FrameLayout(this);
        sheet.setBackgroundColor(0xB3000000); // dim the player behind
        sheet.setOnClickListener(v -> closeTrackList()); // tap outside to close

        LinearLayout panel = new LinearLayout(this);
        panel.setOrientation(LinearLayout.VERTICAL);
        panel.setClickable(true); // taps on the panel don't close it
        GradientDrawable pbg = new GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM,
                new int[]{Ui.shade(accent, 0.62f), 0xFF101016});
        float r = dp(28);
        pbg.setCornerRadii(new float[]{r, r, r, r, 0, 0, 0, 0});
        panel.setBackground(pbg);
        panel.setPadding(dp(18), dp(10), dp(18), dp(16));

        // grab handle
        View handle = new View(this);
        GradientDrawable hb = new GradientDrawable();
        hb.setColor(0x55FFFFFF);
        hb.setCornerRadius(dp(3));
        handle.setBackground(hb);
        LinearLayout.LayoutParams hl = new LinearLayout.LayoutParams(dp(44), dp(5));
        hl.gravity = Gravity.CENTER_HORIZONTAL;
        hl.bottomMargin = dp(14);
        panel.addView(handle, hl);

        // header: cover · title / count · close
        LinearLayout head = new LinearLayout(this);
        head.setGravity(Gravity.CENTER_VERTICAL);
        ImageView thumb = new ImageView(this);
        thumb.setScaleType(ImageView.ScaleType.CENTER_CROP);
        thumb.setImageDrawable(art.getDrawable());
        thumb.setOutlineProvider(new ViewOutlineProvider() {
            @Override public void getOutline(View v, Outline o) { o.setRoundRect(0, 0, v.getWidth(), v.getHeight(), dp(14)); }
        });
        thumb.setClipToOutline(true);
        head.addView(thumb, new LinearLayout.LayoutParams(dp(60), dp(60)));
        LinearLayout ht = new LinearLayout(this);
        ht.setOrientation(LinearLayout.VERTICAL);
        ht.setPadding(dp(14), 0, dp(8), 0);
        TextView hTitle = Ui.text(this, all ? "Everything" : folder, 21, Color.WHITE, true);
        hTitle.setSingleLine(true);
        hTitle.setEllipsize(TextUtils.TruncateAt.END);
        ht.addView(hTitle);
        boolean liveOnly = true;
        for (Track t : list) if (!t.live) { liveOnly = false; break; }
        int n = list.size();
        ht.addView(Ui.text(this, liveOnly ? (n == 1 ? "1 station" : n + " stations") : (n == 1 ? "1 track" : n + " tracks"),
                14, 0xA6FFFFFF, false));
        head.addView(ht, new LinearLayout.LayoutParams(0, -2, 1f));
        ImageButton close = Ui.roundButton(this, R.drawable.ic_close, 0x26FFFFFF, 12);
        close.setElevation(0);
        close.setContentDescription("Close");
        close.setOnClickListener(v -> closeTrackList());
        head.addView(close, new LinearLayout.LayoutParams(dp(46), dp(46)));
        LinearLayout.LayoutParams hdl = new LinearLayout.LayoutParams(-1, -2);
        hdl.bottomMargin = dp(12);
        panel.addView(head, hdl);

        // rows
        android.widget.ScrollView scroll = new android.widget.ScrollView(this);
        scroll.setVerticalScrollBarEnabled(false);
        LinearLayout rows = new LinearLayout(this);
        rows.setOrientation(LinearLayout.VERTICAL);
        scroll.addView(rows);
        final TextView[] lengths = new TextView[n];
        boolean playing = ready() && mp.isPlaying();
        int hi = Ui.tint(accent, 0.45f);
        for (int i = 0; i < n; i++) {
            final int w = i;
            Track t = list.get(i);
            boolean cur = i == index;
            LinearLayout row = new LinearLayout(this);
            row.setGravity(Gravity.CENTER_VERTICAL);
            row.setPadding(dp(10), dp(10), dp(12), dp(10));
            row.setMinimumHeight(dp(62));
            GradientDrawable rb = new GradientDrawable();
            rb.setCornerRadius(dp(16));
            rb.setColor(cur ? Ui.shade(accent, 0.25f) & 0x00FFFFFF | 0x8C000000 : 0x00000000);
            row.setBackground(new android.graphics.drawable.RippleDrawable(
                    ColorStateList.valueOf(0x33FFFFFF), rb, null));

            // left badge: track number, or dancing bars / play icon for the current one
            FrameLayout badge = new FrameLayout(this);
            GradientDrawable bb = new GradientDrawable();
            bb.setShape(GradientDrawable.OVAL);
            bb.setColor(cur ? accent : 0x1FFFFFFF);
            badge.setBackground(bb);
            if (cur && playing) {
                EqView e = new EqView(this);
                e.setColor(Color.WHITE);
                e.setPlaying(true);
                badge.addView(e, new FrameLayout.LayoutParams(dp(18), dp(14), Gravity.CENTER));
            } else if (cur) {
                ImageView pi = new ImageView(this);
                pi.setImageResource(R.drawable.ic_play);
                badge.addView(pi, new FrameLayout.LayoutParams(dp(20), dp(20), Gravity.CENTER));
            } else {
                TextView num = Ui.text(this, String.valueOf(i + 1), 15, 0xCCFFFFFF, true);
                num.setGravity(Gravity.CENTER);
                badge.addView(num, new FrameLayout.LayoutParams(-1, -1));
            }
            row.addView(badge, new LinearLayout.LayoutParams(dp(40), dp(40)));

            LinearLayout texts = new LinearLayout(this);
            texts.setOrientation(LinearLayout.VERTICAL);
            texts.setPadding(dp(14), 0, dp(8), 0);
            TextView name = Ui.text(this, t.name, 17, cur ? hi : Color.WHITE, cur);
            name.setMaxLines(2);
            name.setEllipsize(TextUtils.TruncateAt.END);
            texts.addView(name);
            row.addView(texts, new LinearLayout.LayoutParams(0, -2, 1f));

            if (t.live) {
                TextView live = Ui.text(this, "LIVE", 11, Color.WHITE, true);
                live.setLetterSpacing(0.12f);
                live.setPadding(dp(8), dp(3), dp(8), dp(3));
                GradientDrawable lb = new GradientDrawable();
                lb.setCornerRadius(dp(8));
                lb.setColor(0xFFE0455A);
                live.setBackground(lb);
                row.addView(live);
            } else {
                TextView len = Ui.text(this, "", 14, 0x8CFFFFFF, false);
                lengths[i] = len;
                row.addView(len);
            }
            row.setOnClickListener(v -> {
                closeTrackList();
                if (w == index && mp != null) { if (preparing || !mp.isPlaying()) play(); }
                else startTrack(w, 0, true, 0);
            });
            LinearLayout.LayoutParams rl = new LinearLayout.LayoutParams(-1, -2);
            rl.bottomMargin = dp(4);
            rows.addView(row, rl);
        }
        int maxH = Math.round(getResources().getDisplayMetrics().heightPixels * 0.62f);
        panel.addView(scroll, new LinearLayout.LayoutParams(-1, -2));
        scroll.getLayoutParams().height = Math.min(maxH, n * dp(66) + dp(8));

        sheet.addView(panel, new FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM));
        int at = rootView.indexOfChild(nightView);
        rootView.addView(sheet, at < 0 ? rootView.getChildCount() : at, new FrameLayout.LayoutParams(-1, -1));

        // slide up, then scroll the current track into view
        sheetOpen = true;
        sheet.setAlpha(0f);
        panel.setTranslationY(dp(260));
        sheet.animate().alpha(1f).setDuration(180).start();
        panel.animate().translationY(0).setDuration(260).setInterpolator(new android.view.animation.DecelerateInterpolator()).start();
        final int cur = index;
        scroll.post(() -> {
            View row = rows.getChildAt(cur);
            if (row != null) scroll.scrollTo(0, Math.max(0, row.getTop() - dp(66)));
        });

        // track lengths, read in the background
        new Thread(() -> {
            for (int i = 0; i < n && i < 400; i++) {
                if (build != sheetBuild) return;
                if (lengths[i] == null) continue;
                String d = "";
                MediaMetadataRetriever mr = new MediaMetadataRetriever();
                try {
                    mr.setDataSource(list.get(i).source);
                    String ms = mr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION);
                    if (ms != null) d = fmt(Integer.parseInt(ms));
                } catch (Exception ignored) {
                } finally {
                    try { mr.release(); } catch (Exception ignored) { }
                }
                final TextView tv = lengths[i];
                final String text = d;
                h.post(() -> { if (build == sheetBuild) tv.setText(text); });
            }
        }, "track-lengths").start();
    }

    void closeTrackList() {
        if (!sheetOpen || sheet == null) return;
        sheetOpen = false;
        sheetBuild++;
        final FrameLayout s = sheet;
        s.animate().alpha(0f).setDuration(160).withEndAction(() -> rootView.removeView(s)).start();
    }

    void nudge(boolean left) {
        art.animate().translationX(left ? -dp(36) : dp(36)).setDuration(90)
                .withEndAction(() -> art.animate().translationX(0).setDuration(180).start())
                .start();
    }

    /** Crossfade to a new cover. */
    void setArt(Bitmap b) {
        art.animate().cancel();
        art.animate().alpha(0.15f).setDuration(110).withEndAction(() -> {
            art.setImageBitmap(b);
            art.animate().alpha(1f).setDuration(240).start();
        }).start();
    }

    void updateUi() {
        if (folder == null || tracks.isEmpty()) {
            showIdle();
            return;
        }
        boolean all = Store.ALL.equals(folder);
        title.setText(all ? "Everything" : folder);
        String extra = "";
        if (!all && prefs.getBoolean("shuffle:" + folder, false)) extra += "  ·  shuffle";
        if (!all && prefs.getBoolean("repeat:" + folder, false)) extra += "  ·  repeat";
        String tn = tracks.get(index).name;
        boolean playingNow = ready() && mp.isPlaying();
        if (tn.equalsIgnoreCase(title.getText().toString())) tn = playingNow ? "Now playing" : "Tap ▶ to listen";
        subtitle.setText(tn + extra);
        renderTracksBtn();
        boolean playing = ready() && mp.isPlaying();
        setControlsEnabled(mp != null || isLive());
        setBreathing(!playing);
        eq.setVisibility(View.VISIBLE);
        eq.setColor(Ui.tint(accent, 0.3f));
        eq.setPlaying(playing);
        updateKeepOn();
        updateMediaSession();
        ticker.run();
    }

    void setControlsEnabled(boolean on) {
        float a = on ? 1f : 0.35f;
        prevBtn.setAlpha(a);
        nextBtn.setAlpha(a);
        playBtn.setAlpha(on ? 1f : 0.6f);
        playBtn.setImageResource(ready() && mp.isPlaying() ? R.drawable.ic_pause : R.drawable.ic_play);
    }

    void setBreathing(boolean on) {
        if (on && !breathe.isStarted()) {
            breathe.start();
        } else if (!on && breathe.isStarted()) {
            breathe.cancel();
            art.setScaleX(1f);
            art.setScaleY(1f);
        }
    }

    void applyTheme(String f) {
        boolean all = Store.ALL.equals(f);
        Bitmap cover = all ? null : Ui.loadCover(new File(Store.root(), f));
        accent = all ? 0xFFE0559A : Ui.colorFor(f);
        if (cover != null) accent = Ui.dominantColor(cover, accent); // theme follows the cover art
        backdrop.setColors(new int[]{Ui.shade(accent, 0.45f), 0xFF0B0B10});
        Ui.roundBg(playBtn).setColor(accent);
        setArt(cover != null ? cover
                : Ui.letterArt(all ? "★" : f.substring(0, 1).toUpperCase(Locale.ROOT), accent));
        shownVolume = -1;
        renderVolume();
    }

    void pop() {
        setBreathing(false);
        art.animate().scaleX(1.08f).scaleY(1.08f).setDuration(110)
                .withEndAction(() -> art.animate().scaleX(1f).scaleY(1f).setDuration(220).start())
                .start();
    }

    void shake() {
        ObjectAnimator.ofFloat(art, "translationX", 0, dp(14), -dp(14), dp(8), -dp(8), 0)
                .setDuration(420).start();
    }

    final Runnable clearStatus = () -> {
        status.setText("");
        status.animate().alpha(0f).setDuration(200).withEndAction(() -> {
            if (status.getText().length() == 0) status.setVisibility(View.GONE);
        }).start();
    };

    void flash(String msg, long ms) {
        status.setText(msg);
        status.animate().cancel();
        if (msg.isEmpty()) {
            status.setVisibility(View.GONE);
        } else {
            status.setAlpha(1f);
            status.setVisibility(View.VISIBLE);
        }
        h.removeCallbacks(clearStatus);
        h.postDelayed(clearStatus, ms);
    }

    void hideSystemBars() {
        if (Build.VERSION.SDK_INT >= 30) {
            WindowInsetsController c = getWindow().getInsetsController();
            if (c != null) {
                c.hide(WindowInsets.Type.systemBars());
                c.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
            }
        }
    }

    // ================================================================ dimming / night light

    /** "Screen off at bedtime" is switched on and it's bedtime now. */
    boolean bedtimeDarkOn() {
        return prefs.getBoolean("bedtime_dark", false) && bedtimeNow();
    }

    final Runnable dim = () -> {
        if (screenLocked) return;
        boolean dark = bedtimeDarkOn();
        boolean night = !dark && prefs.getBoolean("night_light", false);
        setBrightness(dark ? 0f : night ? 0.12f : 0.02f);
        showBlackout(dark);
        if (night && nightView.getVisibility() != View.VISIBLE) {
            nightView.setAlpha(0f);
            nightView.setVisibility(View.VISIBLE);
            nightView.animate().alpha(1f).setDuration(1500).start();
        } else if (!night) {
            nightView.setVisibility(View.GONE);
        }
        dimmed = true;
        updateKeepOn();
    };

    void setBrightness(float v) {
        WindowManager.LayoutParams lp = getWindow().getAttributes();
        lp.screenBrightness = v;
        getWindow().setAttributes(lp);
    }

    void showBlackout(boolean on) {
        if (on && blackout.getVisibility() != View.VISIBLE) {
            closeTrackList();
            blackout.setAlpha(0f);
            blackout.setVisibility(View.VISIBLE);
            blackout.animate().alpha(1f).setDuration(1200).start();
        } else if (!on && blackout.getVisibility() == View.VISIBLE) {
            blackout.animate().cancel();
            blackout.setVisibility(View.GONE);
        }
    }

    void wake() {
        if (screenLocked) return;
        if (dimmed) {
            setBrightness(WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE);
            nightView.animate().cancel();
            nightView.setVisibility(View.GONE);
            showBlackout(false);
            dimmed = false;
        }
        h.removeCallbacks(dim);
        int secs = prefs.getInt("dim_after", 90);
        if (bedtimeDarkOn()) secs = secs == 0 ? 30 : Math.min(secs, 30); // bedtime: back to black after 30 s
        if (secs > 0) h.postDelayed(dim, secs * 1000L);
    }

    /** Bedtime starts or ends while the screen is already dimmed: switch between black and the normal dim. */
    void checkBedtime() {
        if (screenLocked) return;
        boolean dark = bedtimeDarkOn();
        if (dimmed && dark != (blackout.getVisibility() == View.VISIBLE)) dim.run();
        else if (!dimmed && dark && !h.hasCallbacks(dim)) wake();
    }

    // ================================================================ screen off from the remote

    void setScreenLocked(boolean on) {
        if (on == screenLocked) return;
        if (on) {
            screenLocked = true;
            h.removeCallbacks(dim);
            closeTrackList();
            closeBrowser();
            setBrightness(0f);
            blackout.animate().cancel();
            blackout.setAlpha(1f);
            blackout.setVisibility(View.VISIBLE);
            nightView.setVisibility(View.GONE);
            dimmed = true;
            holdForRemote();
            scheduleScreenOff(1500);
        } else {
            screenLocked = false;
            h.removeCallbacks(screenOffNow);
            releaseLockHolds();
            Kiosk.restoreTimeout(this);
            Kiosk.setTimeout(this, prefs.getInt("screen_timeout", 60));
            turnScreenOn();
            wake();
        }
        updateKeepOn();
    }

    final Runnable screenOffNow = () -> {
        // Switch the display off; if Android won't allow that, let it time out after 5 s instead.
        if (screenLocked && !Kiosk.screenOff(this)) Kiosk.shortTimeout(this);
    };

    void scheduleScreenOff(long ms) {
        h.removeCallbacks(screenOffNow);
        h.postDelayed(screenOffNow, ms);
    }

    /** Keep Wi-Fi and the remote server alive while the screen is off, so the grown-up can switch it back on. */
    void holdForRemote() {
        try {
            if (lockWake == null) {
                lockWake = ((PowerManager) getSystemService(POWER_SERVICE)).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "WalkieTales:remote");
                lockWake.setReferenceCounted(false);
            }
            lockWake.acquire(24 * 3600_000L);
        } catch (Exception ignored) { }
        try {
            if (wifiLock == null) {
                android.net.wifi.WifiManager wm = (android.net.wifi.WifiManager) getApplicationContext().getSystemService(WIFI_SERVICE);
                @SuppressWarnings("deprecation")
                android.net.wifi.WifiManager.WifiLock wl = wm.createWifiLock(android.net.wifi.WifiManager.WIFI_MODE_FULL_HIGH_PERF, "WalkieTales:remote");
                wifiLock = wl;
                wifiLock.setReferenceCounted(false);
            }
            wifiLock.acquire();
        } catch (Exception ignored) { }
    }

    void releaseLockHolds() {
        try { if (lockWake != null && lockWake.isHeld()) lockWake.release(); } catch (Exception ignored) { }
        try { if (wifiLock != null && wifiLock.isHeld()) wifiLock.release(); } catch (Exception ignored) { }
    }

    @SuppressWarnings("deprecation")
    void turnScreenOn() {
        try {
            PowerManager.WakeLock w = ((PowerManager) getSystemService(POWER_SERVICE)).newWakeLock(
                    PowerManager.SCREEN_BRIGHT_WAKE_LOCK | PowerManager.ACQUIRE_CAUSES_WAKEUP, "WalkieTales:wake");
            w.acquire(3000);
        } catch (Exception ignored) { }
    }

    /** Someone pressed the power button while the screen is meant to be off: switch it straight back off. */
    final BroadcastReceiver screenReceiver = new BroadcastReceiver() {
        @Override public void onReceive(Context c, Intent i) {
            if (screenLocked) scheduleScreenOff(800);
        }
    };

    @SuppressWarnings("deprecation")
    void buzz() {
        try {
            Vibrator v = (Vibrator) getSystemService(VIBRATOR_SERVICE);
            if (v != null) v.vibrate(VibrationEffect.createOneShot(40, VibrationEffect.DEFAULT_AMPLITUDE));
        } catch (Exception ignored) { }
    }

    // ================================================================ receivers

    final BroadcastReceiver batteryReceiver = new BroadcastReceiver() {
        @Override public void onReceive(Context c, Intent i) {
            int level = i.getIntExtra(BatteryManager.EXTRA_LEVEL, -1);
            int scale = i.getIntExtra(BatteryManager.EXTRA_SCALE, 100);
            int st = i.getIntExtra(BatteryManager.EXTRA_STATUS, -1);
            int plugged = i.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0);
            charging = plugged != 0 || st == BatteryManager.BATTERY_STATUS_CHARGING || st == BatteryManager.BATTERY_STATUS_FULL;
            updateKeepOn();
            if (level < 0) return;
            int pct = Math.round(level * 100f / scale);
            batteryPct = pct;
            battery.setText(pct + "%" + (charging ? " · charging" : ""));
            battery.setTextColor(charging ? 0xCC8BE38B : pct <= 15 ? 0xFFFF7A7A : 0x99FFFFFF);
        }
    };

    /** Headphones unplugged / Bluetooth speaker disconnected: pause instead of blasting the phone speaker. */
    final BroadcastReceiver noisyReceiver = new BroadcastReceiver() {
        @Override public void onReceive(Context c, Intent i) {
            if (ready() && mp.isPlaying()) {
                pause();
                flash("Paused — speaker disconnected", 4000);
            }
        }
    };

    // ================================================================ helpers

    static String hex(byte[] id) {
        StringBuilder sb = new StringBuilder();
        for (byte x : id) sb.append(String.format(Locale.ROOT, "%02X", x));
        return sb.toString();
    }

    static String fmt(int ms) {
        int s = Math.max(ms, 0) / 1000;
        if (s >= 3600) return String.format(Locale.ROOT, "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60);
        return String.format(Locale.ROOT, "%d:%02d", s / 60, s % 60);
    }

    int dp(float v) {
        return Ui.dp(this, v);
    }
}
