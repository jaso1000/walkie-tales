#!/bin/bash
# Run WalkieTales in an iPhone simulator, load test music, drive it through the remote API and take screenshots.
# Used by the GitHub Actions iOS workflow (macOS runner). Output: ios/shots/*.png and ios/shots/report.txt
set -u
cd "$(dirname "$0")"
APP=simbuild/Build/Products/Release-iphonesimulator/WalkieTales.app
BID=app.cardplayer.ios
mkdir -p shots
R=shots/report.txt
: > $R
log() { echo "$*" | tee -a $R; }

# A small-screen iPhone, like the iPhone 7 (4.7-inch, 375x667 points)
DEV=$(xcrun simctl list devices available -j | python3 -c "
import json,sys
d=json.load(sys.stdin)['devices']
c=[x['udid'] for k,v in d.items() if 'iOS' in k for x in v if x['name'].startswith('iPhone SE')]
c=c or [x['udid'] for k,v in d.items() if 'iOS' in k for x in v if x['name'].startswith('iPhone')]
print(c[-1])")
log "simulator: $(xcrun simctl list devices | grep $DEV | head -1 | xargs)"
xcrun simctl boot "$DEV"
xcrun simctl bootstatus "$DEV" -b > /dev/null
xcrun simctl status_bar "$DEV" override --time "7:30" --batteryState charged --batteryLevel 100 2>/dev/null || true
xcrun simctl install "$DEV" "$APP"
xcrun simctl launch "$DEV" $BID > /dev/null
sleep 6
DATA=$(xcrun simctl get_app_container "$DEV" $BID data)
CARDS="$DATA/Documents/Cards"
log "app data: $DATA"

# test library: spoken "stories", a folder with a cover, and a radio station
mkdir -p "$CARDS/Bedtime Stories" "$CARDS/Dinosaur Songs" "$CARDS/Kids Radio"
say -o /tmp/a.aiff "Once upon a time, a little blue truck went for a drive in the countryside." && afconvert /tmp/a.aiff "$CARDS/Bedtime Stories/01 The Little Truck.m4a" -f m4af -d aac
say -o /tmp/b.aiff "The moon came up over the hill, and everyone said goodnight." && afconvert /tmp/b.aiff "$CARDS/Bedtime Stories/02 Goodnight Moon Hill.m4a" -f m4af -d aac
say -o /tmp/c.aiff "Stomp stomp stomp, the dinosaurs are dancing." && afconvert /tmp/c.aiff "$CARDS/Dinosaur Songs/Stomping Dinos.m4a" -f m4af -d aac
sips -s format jpeg ../companion/web/icon-512.png --out "$CARDS/Dinosaur Songs/cover.jpg" > /dev/null
printf '#EXTM3U\n#EXTINF:-1,Groove Salad\nhttps://ice1.somafm.com/groovesalad-128-mp3\n' > "$CARDS/Kids Radio/Groove Salad.m3u"

PIN=$(xcrun simctl spawn "$DEV" defaults read $BID remote_pin 2>/dev/null || true)
log "pin read: ${PIN:+yes}"
B=http://127.0.0.1:8080
api() { curl -s -m 10 -H "X-Pin: $PIN" -H "Content-Type: application/json" "$@"; }
shot() { sleep "${2:-2}"; xcrun simctl io "$DEV" screenshot "shots/$1.png" > /dev/null 2>&1; log "shot: $1"; }

log "--- remote page served: $(curl -s -m 5 -o /dev/null -w '%{http_code}' $B/)"
log "--- no PIN gives: $(curl -s -m 5 -o /dev/null -w '%{http_code}' $B/api/status)"
log "--- status: $(api $B/api/status | head -c 400)"
log "--- library: $(api $B/api/library | head -c 600)"
api -X POST -d '{"kid_name":"Riv"}' $B/api/settings > /dev/null
shot 1-idle 2
log "--- play: $(api -X POST -d '{"folder":"Bedtime Stories"}' $B/api/play | head -c 300)"
shot 2-playing-letter-cover 3
log "--- play folder with cover: $(api -X POST -d '{"folder":"Dinosaur Songs"}' $B/api/play | head -c 200)"
shot 3-playing-cover 3
api -X POST -d '{"folder":"Bedtime Stories"}' $B/api/play > /dev/null
api -X POST -d '{"minutes":30}' $B/api/sleep > /dev/null
api -X POST -d '{"text":"Dinner is ready!"}' $B/api/message > /dev/null
shot 4-message-and-sleep 2
api -X POST -d '{"show":"tracks"}' $B/api/ui > /dev/null
shot 5-tracks 2
api -X POST -d '{"show":"library"}' $B/api/ui > /dev/null
shot 6-library 3
api -X POST -d '{"show":"settings"}' $B/api/ui > /dev/null
shot 7-settings 2
api -X POST -d '{"show":"none"}' $B/api/ui > /dev/null
log "--- radio: $(api -X POST -d '{"folder":"Kids Radio"}' $B/api/play | head -c 200)"
shot 8-radio 8
log "--- radio status: $(api $B/api/status | python3 -c 'import json,sys; s=json.load(sys.stdin); print("live",s["live"],"connecting",s["connecting"],"playing",s["playing"],"msg",s["message"])')"
log "--- screen off: $(api -X POST -d '{"off":true}' $B/api/screen | python3 -c 'import json,sys; print(json.load(sys.stdin)["screenOff"])')"
shot 9-screen-off 1
api -X POST -d '{"off":false}' $B/api/screen > /dev/null
api -X POST -d '{"show_volume":false,"browse":false}' $B/api/settings > /dev/null
shot 10-volume-and-library-hidden 2
api -X POST -d '{"show_volume":true,"browse":true}' $B/api/settings > /dev/null
# upload over the remote, like the companion does
say -o /tmp/u.aiff "This song was uploaded from the remote." && afconvert /tmp/u.aiff /tmp/u.m4a -f m4af -d aac
log "--- upload: $(curl -s -m 20 -X PUT -H "X-Pin: $PIN" --data-binary @/tmp/u.m4a "$B/api/upload?folder=Uploaded&name=Remote%20Song.m4a")"
log "--- library after upload: $(api $B/api/library | python3 -c 'import json,sys; print([(f["name"],f["tracks"]) for f in json.load(sys.stdin)["folders"]])')"
log "--- cover endpoint: $(curl -s -m 10 -o /tmp/cv.jpg -w '%{http_code} %{content_type}' -H "X-Pin: $PIN" "$B/api/cover?folder=Dinosaur%20Songs")"
log "--- crashes: $(ls ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -ci walkie || echo 0)"
