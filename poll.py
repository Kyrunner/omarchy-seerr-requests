#!/usr/bin/env python3
"""Poll Seerr for requests awaiting approval; emit one JSON line.

Invoked only by backend.sh, which supplies credentials through the environment
so the API key never lands in a process argument list (visible in `ps` to every
user on the box).

Two tiers, because the badge and the list have very different costs:

  /api/v1/request/count   tiny, always polled, and it is the whole badge
  /api/v1/request?...     fetched only when something is actually pending

A request object carries media.tmdbId but no title, so each pending item needs a
follow-up detail call. That is one extra call per *pending* item, not per request
in the database, and resolved titles are cached by tmdbId -- a request sitting
pending all day is resolved once rather than once per poll.
"""

import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

URL = os.environ.get("SEERR_URL", "").rstrip("/")
API_KEY = os.environ.get("SEERR_API_KEY", "")
WEB_BASE = os.environ.get("SEERR_WEB_BASE", URL).rstrip("/")
NOTIFY = os.environ.get("SEERR_NOTIFY") == "1"

STATE_DIR = os.path.join(
    os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
    "omarchy-seerr",
)
SEEN_FILE = os.path.join(STATE_DIR, "seen.json")
TITLES_FILE = os.path.join(STATE_DIR, "titles.json")

# Enough to cover any queue a person would still call a queue. Beyond this the
# count is still exact -- only the rendered list is capped, and `truncated` says so.
MAX_ITEMS = 50
POSTER_BASE = "https://image.tmdb.org/t/p/w185"


def die(msg):
    print(json.dumps({"ok": False, "error": msg, "pending": 0, "requests": []}))
    sys.exit(1)


def api(path):
    req = urllib.request.Request(
        URL + path,
        headers={"X-Api-Key": API_KEY, "Accept": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read().decode("utf-8"))


def api_or_die(path):
    """Only the calls the whole poll depends on go through here."""
    try:
        return api(path)
    except urllib.error.HTTPError as e:
        die("auth failed" if e.code in (401, 403) else "http %d" % e.code)
    except Exception:
        die("unreachable")


def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default


def save_json(path, data):
    """Write via a temp file so a crash mid-write cannot leave unparseable state
    that would re-notify the whole queue on the next run."""
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f)
        os.replace(tmp, path)
    except Exception:
        pass  # state is a convenience; losing it must never break the poll


def resolve_title(media_type, tmdb_id, titles):
    """Title/year/poster for one item, from cache when possible.

    Cached entries are treated as permanent: a film's title, year and poster
    path do not change, and a stale poster is a far smaller cost than a detail
    call per pending item per minute.
    """
    key = "%s:%s" % (media_type, tmdb_id)
    if key in titles:
        return titles[key]

    kind = "tv" if media_type == "tv" else "movie"
    try:
        d = api("/api/v1/%s/%d" % (kind, tmdb_id))
    except Exception:
        # A detail lookup that fails must not sink the whole poll -- the request
        # still needs approving, and the id is enough to act on.
        return {"title": "TMDB %s" % tmdb_id, "year": "", "poster": "", "resolved": False}

    date = d.get("releaseDate") or d.get("firstAirDate") or ""
    poster = d.get("posterPath") or ""
    entry = {
        "title": d.get("title") or d.get("name") or ("TMDB %s" % tmdb_id),
        "year": date[:4],
        "poster": (POSTER_BASE + poster) if poster else "",
        "resolved": True,
    }
    titles[key] = entry
    return entry


def season_label(seasons):
    """[{seasonNumber:2},{seasonNumber:3}] -> 'S2, S3'."""
    nums = sorted({s.get("seasonNumber") for s in seasons or [] if s.get("seasonNumber") is not None})
    if not nums:
        return ""
    return ", ".join("S%d" % n for n in nums)


def notify(items):
    for it in items:
        body = "%s requested %s" % (it["requested_by"], it["title"])
        if it["year"]:
            body += " (%s)" % it["year"]
        if it["seasons"]:
            body += " — %s" % it["seasons"]
        try:
            subprocess.run(
                ["notify-send", "-a", "Seerr", "-u", "normal", "Request needs approval", body],
                timeout=5,
                check=False,
            )
        except Exception:
            pass  # a missing notify-send must not break the poll


def main():
    if not URL or not API_KEY:
        die("not configured")

    counts = api_or_die("/api/v1/request/count")
    pending = int(counts.get("pending") or 0)

    if pending == 0:
        # Prune so a request approved elsewhere cannot re-notify if it somehow
        # returns to pending, and so the file tracks the queue rather than growing.
        save_json(SEEN_FILE, [])
        print(json.dumps({"ok": True, "pending": 0, "requests": [], "truncated": False}))
        return

    data = api_or_die("/api/v1/request?filter=pending&sort=added&take=%d" % MAX_ITEMS)
    results = data.get("results") or []

    titles = load_json(TITLES_FILE, {})
    titles_before = len(titles)
    out = []

    for r in results:
        media = r.get("media") or {}
        tmdb_id = media.get("tmdbId")
        media_type = media.get("mediaType") or r.get("type") or "movie"
        by = r.get("requestedBy") or {}

        if tmdb_id:
            info = resolve_title(media_type, int(tmdb_id), titles)
            web = "%s/%s/%s" % (WEB_BASE, "tv" if media_type == "tv" else "movie", tmdb_id)
        else:
            info = {"title": "Unknown item", "year": "", "poster": "", "resolved": False}
            web = "%s/requests" % WEB_BASE

        out.append({
            "id": r.get("id"),
            "type": media_type,
            "title": info["title"],
            "year": info["year"],
            "poster": info["poster"],
            "seasons": season_label(r.get("seasons")),
            "requested_by": by.get("displayName") or by.get("username") or "someone",
            "created_at": r.get("createdAt") or "",
            "web_url": web,
        })

    if len(titles) != titles_before:
        save_json(TITLES_FILE, titles)

    ids = [o["id"] for o in out]
    seen_raw = load_json(SEEN_FILE, None)

    if seen_raw is None:
        # First run: adopt the existing backlog silently. Toasting a queue that
        # has been sitting there for days is noise, not news.
        save_json(SEEN_FILE, ids)
    else:
        seen = set(seen_raw)
        fresh = [o for o in out if o["id"] not in seen]
        # The seen-set is always updated, even with notifications off, so turning
        # them on later announces what arrives next -- not the whole backlog.
        save_json(SEEN_FILE, ids)
        if fresh and NOTIFY:
            notify(fresh)

    print(json.dumps({
        "ok": True,
        "pending": pending,
        "requests": out,
        "truncated": pending > len(out),
    }))


if __name__ == "__main__":
    main()
