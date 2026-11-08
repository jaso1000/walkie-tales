#!/usr/bin/env bash
# Slim down a WalkieTales player phone for speed and battery life.
#
#   bash tools/phone-tune.sh            # apply
#   bash tools/phone-tune.sh --undo     # re-enable everything this disabled, restore settings
#   bash tools/phone-tune.sh --dry-run  # show what would happen
#
# Everything is reversible: apps are *disabled* for the user (pm disable-user), never uninstalled.
# Packages that don't exist on the phone are skipped, so the same script works on any ROM build.
# Google text-to-speech is kept by default (it's the only voice for "Say the name out loud" on the
# Google build). Set KEEP_TTS=0 to disable it too.
set -uo pipefail
export MSYS_NO_PATHCONV=1

MODE=apply
case "${1:-}" in --undo) MODE=undo ;; --dry-run) MODE=dry ;; "") ;; *) echo "usage: $0 [--undo|--dry-run]"; exit 1 ;; esac

# Google services and Google apps (the GMS "Go" build). These are the biggest battery/RAM users:
# Play Services wakes the phone constantly to sync, check in and scan.
GOOGLE=(
  com.google.android.gms                      # Google Play Services
  com.google.android.gsf                      # Google Services Framework
  com.android.vending                         # Play Store
  com.google.android.partnersetup
  com.google.android.gms.supervision
  com.google.android.apps.wellbeing           # Digital Wellbeing
  com.google.android.googlequicksearchbox     # Google app
  com.google.android.apps.searchlite          # Google Go
  com.google.android.apps.assistant           # Assistant Go
  com.google.android.apps.photosgo            # Gallery Go
  com.google.android.apps.nbu.files           # Files by Google
  com.google.android.apps.youtube.mango       # YouTube Go
  com.google.android.youtube
  com.google.android.gm.lite                  # Gmail Go
  com.google.android.gm
  com.google.android.apps.mapslite            # Maps Go
  com.google.android.apps.maps
  com.android.chrome
  com.google.android.apps.messaging
  com.google.android.dialer
  com.google.android.contacts
  com.google.android.calendar
  com.google.android.apps.docs
  com.google.android.apps.photos
  com.google.android.feedback
  com.google.android.printservice.recommendation
  com.google.android.marvin.talkback
  com.google.android.apps.restore
  com.google.android.onetimeinitializer
  com.google.android.syncadapters.contacts
  com.google.android.syncadapters.calendar
  com.google.android.gms.location.history
  com.google.android.deskclock
  com.google.android.calculator
  com.google.android.apps.googlecamera.fishfood
  com.google.android.apps.safetyhub
  com.google.android.as.oss                   # Private Compute Services
  com.google.android.configupdater
  com.google.android.accessibility.switchaccess
  com.google.android.apps.messaging.lenovo_msm8916
  com.google.android.iwlan                    # Wi-Fi calling (no SIM)
  com.google.android.as                       # Android System Intelligence
  com.google.android.apps.tachyon             # Duo / Meet
  com.google.android.apps.turbo               # Device Health Services
  com.google.ar.core
  com.google.android.projection.gearhead      # Android Auto
  com.android.hotwordenrollment.okgoogle
  com.android.hotwordenrollment.xgoogle
)
[ "${KEEP_TTS:-1}" = "1" ] || GOOGLE+=(com.google.android.tts)

# Phone/camera/media apps a kids' audio player never uses (LineageOS + AOSP names).
APPS=(
  org.lineageos.aperture        # Camera
  org.lineageos.glimpse         # Gallery
  org.lineageos.twelve          # Music player (competes for Bluetooth media buttons)
  org.lineageos.recorder
  org.lineageos.jelly           # Browser
  org.lineageos.etar            # Calendar
  org.lineageos.updater         # OTA checker (unofficial build: no OTAs anyway)
  org.lineageos.audiofx
  com.android.messaging
  com.android.dialer
  com.android.contacts
  com.android.calendar
  com.android.email
  com.android.gallery3d
  com.android.camera2
  com.android.music
  com.android.calculator2
  com.android.deskclock
  com.android.stk               # SIM toolkit
  com.android.bookmarkprovider
  com.android.printspooler
  com.android.wallpaper.livepicker
  com.android.egg               # Easter egg
  com.stevesoltys.seedvault     # Backups
  com.android.providers.partnerbookmarks
)
# Stock Samsung (One UI) extras: preloaded third-party apps, Bixby, edge panels, AR/stickers, DeX,
# Samsung cloud/pay/pass, and the phone/camera/media apps. Tested on a Galaxy S10 (Android 10).
SAMSUNG=(
  com.facebook.appmanager com.facebook.katana com.facebook.services com.facebook.system
  com.amazon.appmanager com.amazon.mShop.android.shopping
  com.microsoft.appmanager com.microsoft.skydrive flipboard.boxer.app com.hiya.star
  com.samsung.android.bixby.agent com.samsung.android.bixby.service com.samsung.android.bixby.wakeup
  com.samsung.android.bixbyvision.framework com.samsung.android.visionintelligence com.samsung.systemui.bixby2
  com.samsung.android.app.spage com.samsung.android.app.settings.bixby com.samsung.android.svoiceime
  com.samsung.android.app.routines com.samsung.android.app.tips com.samsung.android.app.reminder
  com.samsung.android.calendar com.samsung.android.messaging com.samsung.android.dialer
  com.samsung.android.contacts com.samsung.android.app.contacts
  com.sec.android.app.camera com.sec.android.gallery3d com.samsung.android.video
  com.sec.android.app.clockpackage com.sec.android.app.myfiles
  com.sec.android.app.samsungapps com.sec.android.widgetapp.samsungapps com.samsung.android.themestore
  com.samsung.android.game.gamehome com.samsung.android.game.gametools
  com.samsung.android.app.appsedge com.samsung.android.app.taskedge com.samsung.android.app.clipboardedge
  com.samsung.android.app.sbrowseredge com.samsung.android.app.cocktailbarservice
  com.samsung.android.ardrawing com.samsung.android.aremoji com.samsung.android.aremojieditor com.samsung.android.arzone
  com.samsung.android.app.camera.sticker.facearavatar.preload com.samsung.android.livestickers
  com.samsung.android.stickercenter com.sec.android.mimage.avatarstickers
  com.samsung.android.scloud com.samsung.android.mobileservice com.samsung.android.samsungpass
  com.samsung.android.samsungpassautofill com.samsung.android.spayfw com.samsung.android.fmm
  com.samsung.android.kidsinstaller com.samsung.android.app.watchmanagerstub com.samsung.android.drivelink.stub
  com.samsung.android.mateagent com.sec.android.easyMover.Agent com.samsung.android.smartswitchassistant
  com.samsung.android.app.sharelive com.samsung.android.allshare.service.mediashare
  com.samsung.android.allshare.service.fileshare com.samsung.android.smartmirroring
  com.samsung.android.mdx com.samsung.android.mdx.kit com.samsung.android.mdx.quickboard
  com.sec.android.app.dexonpc com.sec.android.app.desktoplauncher com.sec.android.desktopmode.uiservice
  com.samsung.desktopsystemui
  com.samsung.android.app.galaxyfinder com.samsung.android.rubin.app com.samsung.android.forest
  com.samsung.android.dynamiclock com.samsung.android.app.aodservice com.samsung.android.service.peoplestripe
  com.samsung.android.app.social com.samsung.android.hmt.vrsvc com.samsung.android.app.dressroom
  com.samsung.android.beaconmanager com.samsung.android.digitalkey
  com.samsung.android.app.ledbackcover com.sec.android.cover.ledcover
  com.samsung.storyservice com.sec.android.app.ve.vebgm com.sec.android.app.vepreload
  com.samsung.app.newtrim com.samsung.app.slowmotion com.samsung.app.highlightplayer
  com.sec.android.mimage.photoretouching com.samsung.android.app.motionpanoramaviewer
  com.samsung.android.app.interactivepanoramaviewer com.samsung.android.app.selfmotionpanoramaviewer
  com.samsung.android.app.dofviewer com.samsung.android.motionphoto.viewer com.sec.android.app.billing
  com.sec.android.widgetapp.webmanual com.sec.android.widgetapp.easymodecontactswidget
  com.sec.android.app.quicktool com.samsung.android.app.simplesharing
)
# Deliberately kept: Launcher3 (fallback home screen), Settings, SystemUI, NFC, Bluetooth,
# the keyboard (needed for the grown-up sum and PIN), DocumentsUI, WebView, Shell.
# On Samsung also: Knox/MDM services (device owner needs them), the Samsung keyboard (honeyboard),
# Device care (lool), media/storage providers, MTP, and the One UI launcher as a fallback home.

adb_() { adb shell "$@" 2>/dev/null | tr -d '\r'; }
have() { adb_ pm path "$1" | grep -q '^package:'; }

adb get-state >/dev/null 2>&1 || { echo "No phone connected over adb."; exit 1; }
echo "Phone: $(adb_ getprop ro.product.model) / $(adb_ getprop ro.lineage.version)"

n=0
for p in "${GOOGLE[@]}" "${APPS[@]}" "${SAMSUNG[@]}"; do
  have "$p" || continue
  n=$((n + 1))
  case $MODE in
    dry)   echo "would toggle $p" ;;
    apply) printf '%-48s %s\n' "$p" "$(adb_ pm disable-user --user 0 "$p" | tail -1)" ;;
    undo)  printf '%-48s %s\n' "$p" "$(adb_ pm enable --user 0 "$p" | tail -1)" ;;
  esac
done
echo "$n packages ${MODE}"

[ "$MODE" = dry ] && exit 0

if [ "$MODE" = apply ]; then
  adb_ settings put global window_animation_scale 0.5      # snappier screens...
  adb_ settings put global transition_animation_scale 0.5
  adb_ settings put global animator_duration_scale 1        # ...but keep the app's own animations normal
  adb_ settings put global wifi_scan_always_enabled 0      # no background Wi-Fi scanning
  adb_ settings put global ble_scan_always_enabled 0       # no background Bluetooth scanning
  adb_ settings put secure location_mode 0                 # location off
  adb_ settings put global mobile_data 0                   # no SIM needed
  adb_ settings put global airplane_mode_radios cell       # airplane mode turns off only the mobile radio...
  adb_ cmd connectivity airplane-mode enable               # ...so it stops searching for a signal (Wi-Fi and Bluetooth stay on)
  adb_ svc wifi enable                                     # Samsung ignores airplane_mode_radios and turns Wi-Fi off: back on (it's remembered)
  adb_ settings put global stay_on_while_plugged_in 0      # screen sleeps even on the charger (the app keeps it on when needed)
  adb_ settings put system screen_brightness_mode 1        # adaptive brightness
  adb_ settings put system screen_off_timeout 60000        # 1 min when on battery and idle
  adb_ settings put global auto_sync 0 2>/dev/null
  adb_ cmd deviceidle whitelist +app.cardplayer >/dev/null  # let the remote reach it while the screen is off
  adb_ settings put global adaptive_battery_management_enabled 0 2>/dev/null  # Samsung/Pixel: don't put the player to sleep
  adb_ settings put system aod_mode 0 2>/dev/null                              # Samsung: Always On Display off
  echo "Settings tuned. Reboot the phone to free the memory: adb reboot"
else
  adb_ settings put global window_animation_scale 1
  adb_ settings put global transition_animation_scale 1
  adb_ settings put global wifi_scan_always_enabled 1
  adb_ settings put secure location_mode 3
  adb_ cmd connectivity airplane-mode disable
  adb_ settings put global airplane_mode_radios cell,bluetooth,uwb,wifi,wimax
  adb_ cmd deviceidle whitelist -app.cardplayer >/dev/null
  echo "Settings restored."
fi
