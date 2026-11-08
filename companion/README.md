# WalkieTales Remote

A web remote for the WalkieTales kids' music player. Use it from any phone or computer on your Wi-Fi.

## Two ways to use it

**1. Straight from the player (nothing to install).**
On the player, press and hold ⋮ → answer the sum → **Remote control**. Open the address shown
(for example `http://192.168.1.50:8080`) in your phone's browser and enter the PIN.
Then use *Add to Home Screen* so it opens like an app.

**2. As a Docker container on your home server.**
This gives the remote a fixed address, and can keep the PIN on the server.

```bash
cd companion
# edit docker-compose.yml: set PLAYER_URL (and optionally PLAYER_PIN)
docker compose up -d --build
```

Then open `http://<server>:8090`.

Tip: give the player phone a fixed IP address (a DHCP reservation in your router) so `PLAYER_URL` doesn't change.

| Variable     | Meaning                                                        |
|--------------|----------------------------------------------------------------|
| `PLAYER_URL` | The player's address, e.g. `http://192.168.1.50:8080`           |
| `PLAYER_PIN` | Optional. If set, the page won't ask for the PIN               |
| `PORT`       | Port to listen on inside the container (default `8090`)        |

## What it can do

- **Now playing:** cover, track, progress (tap to seek), play/pause/next/previous (hold ⏮ to start over), stop.
- **Volume:** tap the dots or −/+. The player's volume limit still applies.
- **Sleep timer:** off, 15, 30, 45, 60 or 90 minutes.
- **Message:** send a short message to the player's screen.
- **Library:** tap a folder to play it, upload music or `cover.jpg` into new or existing folders, and delete a folder.
- **Cards:** link a card to a folder or action (then tap the card on the player), and unlink cards.
- **Settings:** child's name, max volume, quiet hours, fade-in, spoken titles, browsing, track list, Toniebox mode,
  dimming, keep-screen-on, night light and clock, grown-up check.

## Several players

The Docker companion can look after any number of players. Tap the player's name at the top of the page to switch,
add one by its address, or press **Find players on the Wi-Fi** (it checks port 8080 on the players' own network,
plus any `SCAN_SUBNETS`). Each device remembers each player's PIN separately. With more than one player, **Library → Add music** has an *Upload to* choice, and *Add a radio station* has an *Add to* choice, so the same files or station go to several players in one go (a player shows up there once this device knows its PIN). The list is kept in the
`walkie-tales-data` volume, and `PLAYERS="Riv=http://192.168.1.50:8080,Sam=http://192.168.1.51:8080"` can pre-fill it.
Only addresses on the home network (10.x, 172.16-31.x, 192.168.x or local host names) are accepted.

## Update players over the network

**Settings → About → Update players** sends the newest release from GitHub to every player that's online and whose PIN this device knows (set `UPDATE_REPO` to use another repository). A player that's playing is left alone until you press **Update anyway**. The player must be a device-owner kiosk on version 1.20 or newer, so earlier versions need one update by USB. It only installs a newer version signed with the same key as the app already on it.

To try a build before releasing it, put it in the data volume as `update/local.apk`, with its version number in `update/local.txt`. Delete both afterwards.

## Install it like an app

- **iPhone / iPad:** open the page in Safari → Share → **Add to Home Screen**. It opens full screen with the WalkieTales icon.
- **Android:** open it in Chrome → ⋮ → **Add to Home screen**. Over plain `http://` on your Wi-Fi, Chrome adds it as a
  shortcut with the icon. To have it open as a full-screen app with no address bar, serve the companion over
  `https://` (for example through a reverse proxy or a Cloudflare tunnel). Then Chrome offers **Install app**.

Icons are drawn by `tools/make-web-icons.py companion/web`.

## Security

The player only accepts commands that carry its 6-digit PIN. You can change the PIN on the player.
It's designed for a home network. Don't expose port 8080 (player) or 8090 (container) to the internet.
