package app.cardplayer;

import java.io.File;

/** One playable item: a local audio file, or a live internet stream (radio station). */
final class Track {
    final String source;  // file path or http(s) URL
    final String name;    // what kids see
    final boolean live;   // internet stream: no duration, no seeking, no resume position

    private Track(String source, String name, boolean live) {
        this.source = source;
        this.name = name;
        this.live = live;
    }

    static Track file(File f) {
        return new Track(f.getAbsolutePath(), Store.cleanName(f), false);
    }

    static Track stream(String url, String name) {
        return new Track(url, name, true);
    }
}
