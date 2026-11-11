# WalkieTales setup guide

Everything beyond the [README](../README.md): installing and locking down players, adding music, building from source,
and notes for particular phones.

- [Android](#android)
- [iPhone](#iphone)
- [Music, covers and radio](#music-covers-and-radio)
- [The remote](#the-remote)
- [Building from source](#building-from-source)
- [Phone notes](#phone-notes)
- [How it's made](#how-its-made)

---

## Android

Works on Android 8 or newer, with or without Google. Any NFC phone can use cards; without NFC it's a browse-only player.

### Install

Download `WalkieTales.apk` from the [latest release](https://github.com/jaso1000/walkie-tales/releases/latest).
Releases are signed with this project's own key, so each one installs over the last.

For a proper kiosk player (no way out of the app), reset the phone, **skip adding any accounts**, turn on
*Developer options → USB debugging*, then from a computer:

```bash
adb install -r WalkieTales.apk
adb shell appops set app.cardplayer MANAGE_EXTERNAL_STORAGE allow       # read Music/Cards
adb shell cmd package set-home-activity app.cardplayer/.MainActivity    # make it the home screen
adb shell dpm set-device-owner app.cardplayer/.AdminReceiver            # full kiosk (needs no accounts on the phone)
```

On **Android 10 and older** (for example a stock Galaxy S10) there's no all-files access; grant storage instead of the
`appops` line:

```bash
adb shell pm grant app.cardplayer android.permission.READ_EXTERNAL_STORAGE
adb shell pm grant app.cardplayer android.permission.WRITE_EXTERNAL_STORAGE
```

On LineageOS, new apps have no network access: allow it in *App info → Wi-Fi data usage → Allow network access*, or the
remote won't work.

`tools/phone-tune.sh` then turns the phone into a quiet, long-lasting player: it disables unused apps and background
scanning, switches off the mobile radio (Wi-Fi and Bluetooth stay on), lets the screen sleep on the charger, and lets
the remote reach the player while the screen is off. `--undo` reverses it. With two phones connected, pick one with
`ANDROID_SERIAL=...`. Then `adb reboot`.

Give the phone a **DHCP reservation** in your router so its address never changes.

### What the kiosk does

As device owner, WalkieTales blocks the notification shade, Home and Recents, the lock screen, and (optionally) the
power-button menu. *Grown-up settings → Phone* has *Restart the phone* and *Android settings*, which steps out of the
lock and locks again when you come back.

**Undo the kiosk:** *Grown-up settings → About → Release kiosk control*. Do this before uninstalling.

### Updates

Updates come from this project's [GitHub releases](https://github.com/jaso1000/walkie-tales/releases), in two ways:

- **On the player:** *Grown-up settings → About → Check for updates*. It asks GitHub for the newest release, shows what's
  new, and installs it if you tap *Install*. Works on any Wi-Fi with internet, so a player away from home can update too.
  It only checks when you tap it.
- **From the Docker remote:** *Settings → About → Update players* sends the newest release to every player on your Wi-Fi.

Either way the player only installs it if it's WalkieTales, newer than what it has, and signed with the same key, so a
fake or tampered file is refused. The player must be a device-owner kiosk on 1.20 or newer (1.48 or newer for the
button).

---

## iPhone

The iPhone app runs on **iOS 15 to 17.0** (what TrollStore supports). No Mac, Apple developer account or jailbreak is
needed. There are no NFC cards on iPhone, since iOS only reads tags inside a scan pop-up.

### 1. Install TrollStore

Follow [TrollStore's own instructions](https://github.com/opa334/TrollStore) for your iOS version. On iOS 15–16 that's
usually **TrollRestore** from a computer, which replaces an unused app (such as Tips) with the TrollStore helper.
Afterwards, in TrollStore → *Settings* → **Install Persistence Helper** so apps keep working after a restart.

### 2. Get the app

The iPhone app is built by GitHub Actions: open the latest successful
[iOS build](https://github.com/jaso1000/walkie-tales/actions/workflows/ios.yml) and download the **WalkieTales-ipa**
artifact (you need to be signed in to GitHub), or build it yourself from `ios/`.

### 3. Install and update

- **First install:** get the `.ipa` onto the iPhone (AirDrop, a download, or iTunes File Sharing), open it and choose
  **Open in TrollStore → Install**.
- **Updates:** upload the new `.ipa` into a folder on the player from the remote (Library → ＋ Music, folder
  *App update*). On the iPhone: *Files → On My iPhone → WalkieTales → Cards → App update* → press and hold the file →
  *Share → TrollStore → Install*. Then delete the *App update* folder from the remote. Music, settings and the PIN are kept.

### 4. First run

Open WalkieTales and allow **Local Network** when asked, or the remote can't reach it. The address and PIN are in
*Grown-up settings → Remote control*. Give the iPhone a DHCP reservation in your router.

### 5. Lock it down

- **Guided Access** (the kiosk lock): *Settings → Accessibility → Guided Access → On*, set a **Guided Access passcode**
  the kids don't know, tick it under *Accessibility Shortcut*, and set *Display Auto-Lock* to 1 minute.
- **Screen Time** with its own passcode → *Content & Privacy Restrictions → On*:
  - *Allowed Apps*: turn every app off (this also removes Camera, Siri and Wallet from the lock screen).
    WalkieTales, Files and TrollStore aren't in that list, so updates still work.
  - *iTunes & App Store Purchases*: Installing Apps, Deleting Apps and In-app Purchases → Don't Allow.
  - *Passcode Changes* and *Account Changes* → Don't Allow.
  - *Content Restrictions → Siri → Web Search Content* → Don't Allow.
- **Spotlight:** *Settings → Siri & Search*: turn off all the Suggestions switches, and *Show App in Search* /
  *Show Content in Search* for every app.
- **Lock screen:** turn off *Emergency SOS → Call with 5 Presses* and *Call After Severe Crash* (an iPhone can call
  emergency services even without a SIM), remove the widgets, set notification previews to *Never*, turn off
  *Control Centre → Access Within Apps*, and switch off the passcode so waking it is one press of Home.
- **Radios:** in Control Centre turn on Airplane mode, then Wi-Fi and Bluetooth again.
- **Start the lock:** open WalkieTales → **triple-click Home** → *Options*: Side Button off, Volume Buttons on, Motion
  off, Keyboards off, Touch on, Time Limit off → **Start**. To get out: triple-click Home and enter the code.

### Things to know

- **iPhones can't play Ogg audio** (common in audiobook downloads, often named `.mp3`). The Docker remote converts an
  iPhone's copy to MP3 after every upload; for an older folder use *⋯ → Make it play on iPhone*.
- **While the iPhone is locked and nothing is playing, iOS pauses the app,** so the remote can't reach it until the screen
  is woken. While it plays, the remote works.
- Keep it on the charger with Auto-Lock on *Never* while uploading big folders, or the upload stops (the remote retries).
- If TrollStore apps ever stop opening after a restart, open the persistence helper → *Refresh App Registrations*.

---

## Music, covers and radio

### Folders

Put music in `Music/Cards/` (Android) or upload it from the remote, **one folder per album, book or card**:

```
Music/Cards/
  Gruffalo/
    cover.jpg        <- optional picture
    01 - Part one.mp3
    02 - Part two.mp3
  Bedtime Songs/
    ...
```

Formats: MP3, M4A/M4B, AAC, Ogg, Opus, FLAC (including 24-bit) and WAV. Subfolders are included, sorted naturally.
Card links are kept in `Music/Cards/cards.txt`, so they survive reinstalling the app.

Folders are sorted into **Music, Podcasts, Books and Radio** from their tags and names. You can change a folder's type
from the remote (*⋯ → Type*) or when uploading.

### Automatic covers

Folders without a picture get one automatically (*Library → Find missing covers online*, on by default), saved as
`cover.auto.jpg`:

- Music and audiobooks come from Apple's iTunes Search API, using the album/artist tags or the folder name. Radio station
  logos come from radio-browser.info.
- **Kid-safe matching:** a result is only kept if its name genuinely matches, nothing marked explicit is ever used, and
  a guess from a folder name alone only accepts children's and family results.
- A picture built into a music file is shown while that track plays. Your own `cover.jpg` (or any image) always wins.
- Wrong picture? Remove it from the remote's Library and it's never fetched again for that folder.

### Internet radio

A folder can hold radio stations: small `.m3u`, `.m3u8`, `.pls` or `.url` files with the stream address. The easiest
way is the remote's *Library → ＋ Radio*. The player shows **LIVE** instead of a progress bar, says so if a station can't
be reached, and hides stations while there's no internet. With several stations in a folder, ⏮/⏭ switch between them.

### Sleep sounds and messages

- *Sleep Sounds* (rain, ocean waves, white noise, heartbeat) are made on the player the first time it starts, and loop
  until stopped. They never count towards the daily listening limit. Delete the folder and it stays deleted.
- Voice messages, recorded on the remote or in *Grown-up settings → Messages*, are kept in the *Messages* folder, which gets its own envelope-and-heart picture.

---

## The remote

Each player serves its own remote on port **8480** (https on **8490**) (*Grown-up settings → Remote control* shows the address and PIN).
The Docker version looks after several players at once and adds uploads to all players, the all-players page, voice
message conversion, iPhone audio conversion and network updates. See [companion/README.md](../companion/README.md).

Security: every command needs the player's 6-digit PIN (you can make a new one on the player), and repeated wrong PINs
lock that address out for a while. It's built for a home network: don't expose ports 8480 or 8490 to the internet.

---

## Building from source

### Android

You need the Android SDK (build-tools 36, platform android-36), JDK 17 and Python 3. No Gradle.

```bash
bash build.sh          # -> WalkieTales.apk
```

`build.sh` expects the SDK at `/c/Android/sdk`; override it with `ANDROID_SDK=...`. The first build creates
`debug.keystore` to sign the app. **Keep a backup of it:** an update signed with a different key won't install over
the existing app. A copy you build yourself won't install over a release (uninstall first, after releasing kiosk control).

Testing without a card: `adb shell am start -n app.cardplayer/.MainActivity -e folder "Folder name"`.

### iPhone

`ios/` is a native UIKit app described by `ios/project.yml` ([XcodeGen](https://github.com/yonaskolb/XcodeGen)).
The [iOS workflow](../.github/workflows/ios.yml) builds a TrollStore-ready `.ipa` on macOS and runs a simulator test.

### Docker remote

`companion/` is a single Node.js file plus the web page. The [Docker workflow](../.github/workflows/docker-publish.yml)
publishes `ghcr.io/jaso1000/walkie-tales-remote` for amd64 and arm64; `docker compose up -d --build` in `companion/`
builds it locally instead.

---

## Phone notes

### Making another Android player: checklist

1. Unlock the bootloader, flash TWRP and a **no-Google** ROM if the phone needs one (see below). Skip adding a Google
   account during setup.
2. Turn on *Developer options → USB debugging*.
3. Run the install commands above (install, file access, home screen, device owner). Use the same `debug.keystore` as
   your other players so updates install everywhere.
4. *App info → Wi-Fi data usage → Allow network access* (LineageOS).
5. `bash tools/phone-tune.sh`, then `adb reboot`.
6. Give it a DHCP reservation and add music.

### Nexus 5 (hammerhead)

- **ROM:** unofficial LineageOS 23.2 by acroreiser (XDA). It needs TWRP `3.7.0_9-HH.R.17` and the `hh_repart_v_32gb`
  repartition script (or the 16 GB version).
- **Pick the no-Google ("vanilla") build** (`lineage-23.2-…-hammerhead-signed.zip`, not `…_gms_go_2gb…`): Play Services
  only costs battery and RAM. You lose the text-to-speech voice for *Say the name out loud*; install one separately if
  you want it.
- **Windows:** fastboot needs Google's USB driver (`android_winusb.inf`).

### Galaxy Note 3 (hlte, SM-N9005)

- **ROM:** unofficial LineageOS 21.0 by html6405 (Android 14), without Google apps. Needs TWRP 3.3 or newer.
- **Install:** format data, wipe system/cache/dalvik, flash the zip. First boot takes about 7 minutes.
- **Quirks:** `adb install` needs `--no-streaming`; `screencap` doesn't work (use `uiautomator dump`).
- **NFC:** the antenna is on the original Samsung battery (EB-B800BE with NFC). A replacement battery without it never
  sees a card.

### Galaxy S9 (starlte)

- Unofficial LineageOS 24.0 (Android 17), no Google. NFC cards work.

### Stock Samsung (e.g. Galaxy S10)

- No custom ROM needed: factory reset, skip every account, turn on USB debugging, then install as above.
- One UI turns Wi-Fi **and** Bluetooth off with airplane mode. `phone-tune.sh` turns Wi-Fi back on; switch Bluetooth on
  by hand once in *Android settings → Bluetooth*.

---

## How it's made

The Android app is plain Java using only the Android framework (no AndroidX, Gradle or Flutter), so it's tiny and runs
fine on old 32-bit phones. The iPhone app is native Swift and UIKit. The remote is one HTML page, shared by the players
and the Docker container.

```
AndroidManifest.xml, build.sh
res/                         icons, theme, device-admin policy
src/app/cardplayer/
  MainActivity.java          player screen, NFC, playback, kiosk, night light, remote API
  SettingsActivity.java      grown-up settings (with search)
  RemoteServer.java          the small PIN-protected web server for the remote
  Store.java                 library, categories, card links, radio playlists, settings
  SleepSounds.java           rain, ocean, white noise and heartbeat, made on the phone
  ArtFinder.java             automatic covers (iTunes / radio-browser.info)
  Kiosk.java                 lock-task / device-owner kiosk
  Track.java, Ui.java, ...   helpers
ios/                         the iPhone app (Swift)
companion/                   the remote page + Docker container (several players)
docs/                        this guide and the pictures for the README
tools/                       phone-tune.sh, make-web-icons.py
```
