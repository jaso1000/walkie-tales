# Card Player Remote

A web remote for the Card Player kids' music player. Use it from any phone or computer on your Wi-Fi.

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
- **Library:** tap a folder to play it, and upload music or `cover.jpg` into new or existing folders.
- **Cards:** link a card to a folder or action (then tap the card on the player), and unlink cards.
- **Settings:** child's name, max volume, quiet hours, fade-in, spoken titles, browsing, track list, Toniebox mode,
  dimming, keep-screen-on, night light and clock, grown-up check.

## Security

The player only accepts commands that carry its 6-digit PIN. You can change the PIN on the player.
It's designed for a home network. Don't expose port 8080 (player) or 8090 (container) to the internet.
