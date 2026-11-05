# WalkieTales

*Tap a card, hear a story.* A homemade, card-based audio player for the Walker kids.

WalkieTales turns an old Android phone into a kids' card-based audio player: tap an NFC card on the back of the phone and it plays a folder of music or stories. Built for a Nexus 5 running LineageOS 23.2 (Android 16), and works on any NFC Android phone with Android 8 or newer.

The app is native Android in plain Java, using only the framework (no AndroidX, Gradle or Flutter). It's about 100 KB and runs fine on 32-bit phones.

## Features

**For kids**
- Tap a card to play its folder. Tap again to pause. Each folder carries on where it stopped.
- Optional *Toniebox mode*: plays while the card rests on the phone and pauses when it's lifted.
- Big play/pause/skip buttons and a scrub bar to drag through a track. Swipe the cover to skip, swipe up for the track list, hold ⏮ to start over.
- Two big buttons along the bottom: **Library** (a grid of covers, works without cards) and **Tracks** (every track in the folder). Grown-ups can hide either.
- Volume buttons with a dot meter, a sleep timer (moon button) and a friendly greeting ("Good morning, Sam!").
- The look follows the cover art. There's an equalizer animation, crossfades, and a night-light glow with a bedside clock.
- Bluetooth/headset play, pause and skip buttons work.

**For grown-ups** (press and hold the ⚙ cog, then answer a quick sum)
- Link cards to folders or to actions: Shuffle everything, Pause, Skip, Sleep timer, Volume up/down. Cards can be switched off for a browse-only player (handy on phones whose NFC doesn't work).
- Per-folder shuffle, repeat and resume settings.
- Maximum volume, fade-in, and spoken titles (text-to-speech).
- **Bedtime:** a lower volume limit overnight, and an optional black screen 30 s after the last touch.
- **Battery:** the screen sleeps after a set time (30 s to 5 min), even while playing or charging. Music carries on with the screen off.
- **Safety:** kiosk lock (as device owner it blocks the notification shade, Home and Recents), the power-button menu can be blocked so it can't be switched off, and *Restart the phone* is in settings. "Android settings" steps out of the lock and it locks again when you return.
- Radio stations are hidden from the Library while there's no internet.
- A remote control over Wi-Fi (see below).

## Music

Put music on the phone in `Music/Cards/`, one folder per card:

```
Music/Cards/
  Gruffalo/
    cover.jpg        <- optional picture
    01 - Part one.mp3
    02 - Part two.mp3
  Bedtime Songs/
    ...
```

Supported formats are MP3, M4A/M4B, AAC, OGG, Opus, FLAC (including 24-bit) and WAV. Subfolders are included, sorted naturally. Card links are stored in `Music/Cards/cards.txt`, so they survive reinstalling the app.

## Automatic covers

Folders without a picture get one automatically (setting: *Find missing covers online*, on by default). The result is saved as `cover.auto.jpg`:

- **Music and audiobooks:** Apple's keyless iTunes Search API. It searches with the album/artist tags from the files if they have them, otherwise the folder name.
- **Radio stations:** station logos from radio-browser.info.
- **Kid-safe matching:** a result is only kept if its name genuinely matches, nothing marked explicit is ever used, and a guess from a folder name alone only accepts children's/family results. (Without that rule, "Demo Songs" found a whiskey-bottle album.)
- **Each track's own picture while it plays:** if a music file has a picture built in (like a single's cover), the player and the remote show it during that track. The Library tile keeps the folder's picture.
- **Your own pictures win:** a `cover.jpg` (or any image) you add always takes precedence, and so does art embedded in the music files.
- **Wrong picture?** Tap that link under the folder in the remote's Library. It's removed and never fetched again for that folder. *Find missing covers* retries on demand. Otherwise folders with no match are retried weekly.
- Searching sends folder names (or album tags) to Apple and radio-browser.info.

## Internet radio

A folder can hold radio stations instead of (or as well as) music files. A station is a small playlist file with the stream address:

```
Music/Cards/Radio/
  cover.jpg
  Kids Radio.m3u      <- #EXTM3U / #EXTINF:-1,Kids Radio / https://example.com/stream.mp3
  Groove Salad.m3u
```

- `.m3u`, `.m3u8`, `.pls` and `.url` files are understood. A station's "listen live" link to a `.pls` or `.m3u` is followed automatically.
- StreamTheWorld links that name a numbered server (`12345.live.streamtheworld.com/…`) are switched to StreamTheWorld's official redirect, because those servers rotate.
- The easiest way to add one is the remote's *Library → Add a radio station*.
- A station folder works like any other folder: tap it in browse, link a card to it, sleep timer, volume limit. With several stations in a folder, ⏮/⏭ switch stations.
- The player shows **LIVE** instead of a progress bar, connects without freezing the screen, and says so if a station can't be reached or drops out (press play to reconnect).
- Stations are left out of "Everything" (shuffle), since a live stream never ends.
- Needs Wi-Fi, of course. Plain `http://` streams are allowed as well as `https://`.

## Remote control and Docker companion

The player runs a small PIN-protected web server on port 8080. Open the address shown in *Grown-up settings → Remote control* on your phone (same Wi-Fi) and you get a remote with:
- now playing, playback controls and the track list
- volume, maximum volume and the sleep timer
- **turn the screen off**: black, taps ignored, and it switches itself back off if the power button wakes it
- a library you can tap to play, plus music upload and adding radio stations
- card linking
- all settings
- messages to the screen

[`companion/`](companion/) packages the same page as a Docker container for a home server, with extras: it handles **several players** (switch by tapping the name at the top, or let it find them on the Wi-Fi), and it can be added to a phone's home screen as an app with its own icon. See [companion/README.md](companion/README.md).

## Download

Each [release](https://github.com/jaso1000/walkie-tales/releases) has a ready-built `WalkieTales.apk`. It's signed with this project's own key, so a later release installs over an earlier one. A copy you build yourself is signed with your own key and won't install over a release (uninstall first, after releasing kiosk control).

## Build

You need the Android SDK (build-tools 36, platform android-36), JDK 17 and Python 3. Gradle isn't needed.

```bash
bash build.sh          # -> WalkieTales.apk
```

`build.sh` expects the SDK at `/c/Android/sdk`; override it with `ANDROID_SDK=...`. On the first build it creates `debug.keystore` to sign the app. **Keep a backup of that file.** An update signed with a different key won't install over the existing app.

## Install on the phone

```bash
adb install -r WalkieTales.apk
adb shell appops set app.cardplayer MANAGE_EXTERNAL_STORAGE allow       # read Music/Cards
adb shell cmd package set-home-activity app.cardplayer/.MainActivity    # make it the home screen
adb shell dpm set-device-owner app.cardplayer/.AdminReceiver            # full kiosk (needs no accounts on the phone)
```

On LineageOS, new apps have no network access. Enable it in *App info → Wi-Fi data usage → Allow network access*, or the remote won't work.

**Undo the kiosk:** *Grown-up settings → About → Release kiosk control*. Do this before uninstalling.

Handy for testing without a card: `adb shell am start -n app.cardplayer/.MainActivity -e folder "Folder name"`.

## Phone setup notes (Nexus 5 / hammerhead)

- **ROM:** unofficial LineageOS 23.2 by acroreiser (XDA). It needs TWRP `3.7.0_9-HH.R.17` and the `hh_repart_v_32gb` repartition script (or the 16 GB version).
- **Pick the no-Google ("vanilla") build** (`lineage-23.2-…-hammerhead-signed.zip`, not `…_gms_go_2gb…`). WalkieTales doesn't use any Google services. The first player was flashed with the Google build, and Play Services only costs battery and RAM. The one thing you lose is a text-to-speech voice for "Say the name out loud". Install one separately if you want that feature.
- **Windows:** fastboot needs Google's USB driver (`android_winusb.inf`).

### Making another player: checklist

1. Unlock the bootloader, then flash TWRP, repartition and sideload the **vanilla** ROM (see above). Skip adding a Google account during setup.
2. Turn on Developer options → USB debugging.
3. `bash build.sh`, then run the install commands above (install, file access, home screen, device owner). Use the same `debug.keystore` so updates install over every player.
4. App info → Wi-Fi data usage → **Allow network access** (LineageOS blocks new apps by default).
5. `bash tools/phone-tune.sh` disables unused apps and background scanning, lets the screen sleep on the charger, and lets the remote reach the player while its screen is off (`--undo` reverses it). Then `adb reboot`.
6. Give the phone a DHCP reservation in the router and copy music into `Music/Cards/`.

## Project layout

```
AndroidManifest.xml
build.sh
res/                         icons, theme, device-admin policy
src/app/cardplayer/
  MainActivity.java          player screen, NFC, playback, kiosk, remote API handlers
  SettingsActivity.java      grown-up settings
  RemoteServer.java          tiny HTTP server for the remote
  Store.java                 library, card links, radio playlists, settings registry
  Track.java                 a music file or a live stream
  ArtFinder.java             automatic covers (iTunes / radio-browser.info)
  Kiosk.java                 lock-task / device-owner kiosk
  Ui.java, EqView.java       drawing helpers
  AdminReceiver.java         device-admin receiver
companion/                   web remote (shared page) + Docker container (several players, app icons)
tools/                       phone-tune.sh (battery/speed), make-web-icons.py
```
