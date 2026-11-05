# Walkie Tales

*Tap a card, hear a story.* A homemade, card-based audio player for the Walker kids.

Walkie Tales turns an old Android phone into a kids' card-based audio player: tap an NFC card on the back of the phone and it plays a folder of music or stories. Built for a Nexus 5 running LineageOS 23.2 (Android 16), and works on any NFC Android phone with Android 8 or newer.

The app is native Android in plain Java, using only the framework (no AndroidX, Gradle or Flutter). It's about 100 KB and runs fine on 32-bit phones.

## Features

**For kids**
- Tap a card to play its folder. Tap again to pause. Each folder carries on where it stopped.
- Optional *Toniebox mode*: plays while the card rests on the phone and pauses when it's lifted.
- Big play/pause/skip buttons. Swipe the cover to skip, hold ⏮ to start over, and tap the track name for a track list.
- Browse without cards: a grid of covers with "Now playing" and "Track 3 of 12". Grown-ups can turn it off.
- Volume buttons with a dot meter, a sleep timer (moon button) and a friendly greeting ("Good morning, Sam!").
- The look follows the cover art. There's an equalizer animation, crossfades, a night-light glow with a bedside clock, and screen dimming.
- Bluetooth/headset play, pause and skip buttons work.

**For grown-ups** (press and hold ⋮, then answer a quick sum)
- Link cards to folders or to actions: Shuffle everything, Pause, Skip, Sleep timer, Volume up/down.
- Per-folder shuffle, repeat and resume settings.
- Maximum volume, quiet hours (a lower limit overnight), fade-in, and spoken titles (text-to-speech).
- Dimming, keep-screen-on, night light and clock, and the grown-up check.
- Kiosk lock: as device owner it blocks the notification shade, Home and Recents. "Android settings" steps out of the lock and it locks again when you return to the player.
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

Supported formats are MP3, M4A/M4B, AAC, OGG, Opus, FLAC and WAV. Subfolders are included, sorted naturally. Card links are stored in `Music/Cards/cards.txt`, so they survive reinstalling the app.

## Remote control and Docker companion

The player runs a small PIN-protected web server on port 8080. Open the address shown in *Grown-up settings → Remote control* on your phone (same Wi-Fi) and you get a remote with:
- now playing and playback controls
- volume and the sleep timer
- a library you can tap to play, plus music upload
- card linking
- all settings
- messages to the screen

[`companion/`](companion/) packages the same page as a Docker container for a home server. See [companion/README.md](companion/README.md).

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
- **Windows:** fastboot needs Google's USB driver (`android_winusb.inf`).

## Project layout

```
AndroidManifest.xml
build.sh
res/                         icons, theme, device-admin policy
src/app/cardplayer/
  MainActivity.java          player screen, NFC, playback, kiosk, remote API handlers
  SettingsActivity.java      grown-up settings
  RemoteServer.java          tiny HTTP server for the remote
  Store.java                 library, card links, settings registry
  Kiosk.java                 lock-task / device-owner kiosk
  Ui.java, EqView.java       drawing helpers
  AdminReceiver.java         device-admin receiver
companion/                   web remote (shared page) + Docker container
```
