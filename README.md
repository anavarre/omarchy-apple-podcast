# Apple Podcasts — Omarchy bar widget (proof of concept)

A bar icon that opens a panel with your latest Apple Podcasts episodes (or Up Next), and plays them.

> **Unofficial.** Apple has no API for a listener's library. This calls the private
> endpoints behind podcasts.apple.com (`/v1/me/library/latest-episodes`,
> `/v1/me/library/next-episodes` on `amp-api.podcasts.apple.com`) the way the web
> player does. It can break whenever Apple changes the site and may sit outside
> Apple's terms. Personal use only.

## Install

```sh
ln -s "$PWD" ~/.config/omarchy/plugins/omarchy-apple-podcasts
omarchy plugin enable anavarre.apple-podcasts
omarchy-shell shell rescanPlugins
omarchy bar move anavarre.apple-podcasts --section right
```

## Sign in

Apple offers third parties no sign-in, so the plugin borrows your web-player session:
open the panel, press **Open podcasts.apple.com**, sign in with your Apple Account
(2FA happens in the browser), then copy the `media-user-token` cookie value
(browser dev tools → Storage/Application → Cookies) and paste it into the panel.

The token is stored `0600` in `~/.config/omarchy/apple-podcasts/`. The web player's
developer token is read from its JavaScript at run time and cached until it expires.
`bin/podcasts-api` makes every request; the token never appears in argv.

## Playing

Click an episode to open the focused player: play/pause, skip back and forward
(15 s each by default; 10, 15, 30, 45, 60, 75 or 90 via the `skipBackSeconds` /
`skipForwardSeconds` settings, the lengths Apple's own clients offer), and a progress bar you can click
to jump. Keys: `Space` play/pause, `←`/`→` skip, `o` open the episode on Apple's site,
`s` stop, `Esc` back to the list. While something plays, the list shows a "Now
playing" row to get back to the player.

Audio comes from each episode's `assetUrl`, the publisher's own file, played by a
headless `mpv` that `bin/podcasts-player` drives over its IPC socket (in
`$XDG_RUNTIME_DIR`). It needs `mpv` and `socat`. mpv runs detached, so audio keeps
going if the shell reloads. Subscriber-only episodes with no `assetUrl` say so
instead of playing.

## Picking up where you left off

Your listening position is shared with Apple, so it follows you between the iPhone and
this computer. Starting an episode asks Apple where it was left (on any device) and
resumes there; episodes you finished or are in the last 10 s
of start from the top (any other position, however early, is kept). While you listen, the position is written back every 15 s and on
pause, stop, switching episode and end, so the phone resumes from here. Rows in the list
show "At 12:34" or "Played". Positions use `GET`/`PUT /v1/me/playback/positions/podcast-episodes`,
the calls the web player makes. The position is also saved on this computer the moment it is known (`positions/` in the store), and the newer of the two wins when you resume, so a slow or refused write to Apple, or switching episodes straight away, no longer sends you back to the top. If Apple can't be reached, the local copy is used.

## Status

`tests/run` covers the model, the API script (fixture server, including positions) and the player (real mpv, null
audio output). The episode list has been seen working against Apple's real API. The player's
QML (panel view, keys, clicks) has only been loaded by the shell, not exercised by a test.
