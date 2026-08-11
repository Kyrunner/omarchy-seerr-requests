# ky.seerr-requests — design

Bar widget that surfaces Jellyseerr requests awaiting approval, notifies when a
new one arrives, and approves or declines them in place.

Verified against Jellyseerr **3.4.1** on 2026-08-11.

## Why a bar widget and not a service

The request is "tell me when something needs approval." Approval is an *action*,
so a notification with no surface to act on just starts a hunt for a browser tab.
A `bar-widget` is mounted at shell startup and runs its timer continuously — the
same way `ky.jellyfin-nowplaying` polls every 10s — so it fires the notification
*and* owns a place to act. A `service` plugin would add nothing and remove the UI.

## Structure

Mirrors `ky.jellyfin-nowplaying`: one shell script owns all Jellyseerr I/O, the
QML renders whatever the script prints. The script can be run and diffed over
SSH; the widget can only be checked by eye on the owner's screen.

```
manifest.json     bar-widget declaration + settings schema
backend.sh        the ONLY thing that talks to Jellyseerr
Panel.qml         bar item + popup
README.md         setup and behavior
```

## Config

`~/.config/omarchy-seerr/config.json`, overridable via `$OMARCHY_SEERR_CONFIG`:

```json
{
  "url": "http://192.168.1.10:5055",
  "api_key": "...",
  "web_base": "https://seerr.example.com"
}
```

`url` is the LAN API path used for polling. `web_base` is only used to build
browser links, so a click lands somewhere reachable away from home instead of a
LAN address. Falls back to `url` when unset — same split as the Jellyfin plugin.

Auth is the `X-Api-Key` header, not Jellyfin's `MediaBrowser Token=` scheme.

## Polling: two tiers

`GET /api/v1/request/count` returns counts only:

```json
{"total":141,"pending":2,"approved":48,"declined":1,...}
```

That is the whole badge. It runs on the interval timer (default 60s) and is one
small request. The expensive path — the full pending list plus per-title
resolution — runs only when `pending > 0` or the popup is open.

### The N+1, and why it is bounded

A Jellyseerr request object carries `media.tmdbId` but **no title**:

```json
{"id":140,"status":1,"type":"movie","createdAt":"2026-08-09T13:38:48.000Z",
 "media":{"tmdbId":329556,"mediaType":"movie"},"requestedBy":{"displayName":"chris"}}
```

Titles and posters need a follow-up `GET /api/v1/movie/{tmdbId}` or
`/api/v1/tv/{tmdbId}` each, returning `title`/`name`, `releaseDate`,
`posterPath`. That is one extra call per *pending* item, not per request in the
database — 2 today, and a queue large enough to matter is a queue you would have
already cleared.

`backend.sh` caches resolved titles by tmdbId in
`~/.local/state/omarchy-seerr/titles.json`, so a request sitting pending for a
day is resolved once rather than 1,440 times. Cache entries are immutable
(a film's title and year do not change) and keyed `<mediaType>:<tmdbId>`.

## Notifications

New pending request IDs fire one `notify-send`:

> **Seerr request** — chris requested *Landmine Goes Click* (2015)

Seen IDs persist to `~/.local/state/omarchy-seerr/seen.json`. Without that, every
shell restart re-toasts every pending request — the behavior that gets a plugin
uninstalled. IDs are pruned from `seen.json` once they leave the pending set, so
the file tracks the queue rather than growing without bound.

First run after install seeds `seen.json` silently instead of toasting the
existing backlog.

## Bar states

| State | Bar shows |
|-------|-----------|
| 0 pending | hidden (configurable: dimmed logo, no badge) |
| n pending | logo + accent-coloured badge with the count, `99+` above 99 |
| not configured | dimmed logo + red `!` badge, popup explains where the config goes |
| unreachable / auth failed | dimmed logo + red `!` badge, popup names which |

Failure must not render as "no requests." A dead API key looking identical to a
quiet queue is the failure mode that matters here — it fails silently and stays
failed. So a fault changes *both* the colour and the glyph, and keeps its width
in the bar rather than collapsing to zero the way an empty queue does.

### Why a badge and not text beside the icon

`BarIconButton` hides its glyph `Text` whenever `iconComponent` is non-null
(`BarIconButton.qml:32`), and the button is a fixed square slot
(`fixedWidth: slotSize`). There is no room beside the logo, so the count rides on
top of it.

### Theme colours

The `bar` object handed to a widget carries `foreground`, `urgent` and
`fontFamily`, but **not** `background` or `accent`. Reading those off it yields
`undefined`, which QML assigns as black and reports only as a runtime warning —
a widget that looks broken with nothing in the log to explain it. Both come from
the `Color` singleton instead.

## Approve / decline

`backend.sh approve <id>` and `backend.sh decline <id>` POST to
`/api/v1/request/<id>/approve|decline`, then the panel re-polls.

The row shows a spinner during the call and surfaces the error inline on
failure. It does not optimistically remove the row — an approve that silently
failed is worse than a slow one, because the requester is left waiting on a
queue you believe you cleared.

## Settings schema

| Key | Type | Default | Range |
|-----|------|---------|-------|
| `refreshIntervalSec` | integer | 60 | 15–600 |
| `notifyOnNew` | boolean | true | |
| `hideWhenEmpty` | boolean | true | |

## Out of scope

- Browsing non-pending requests — that is what the Seerr web UI is for.
- Issues, users, and settings surfaces.
- Creating requests. This approves what others ask for; it is not a discovery UI.
