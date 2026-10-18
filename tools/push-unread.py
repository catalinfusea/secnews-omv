#!/usr/bin/env python3
"""
push-unread.py - publish UNREAD entries from a Miniflux category or feed to ntfy.

Miniflux only pushes new entries to ntfy, at fetch time. This covers the case where you
want a push for entries that are already unread (e.g. after enabling the integration late).

Requires: Python 3 (stdlib only). Tested with Python 3.12 against ntfy 2.31.1 and a mock
Miniflux, and used with Python 3.11 against Miniflux 2.3.3 on OMV.

Secrets: from environment variables or prompted interactively (never on the command line):
  MINIFLUX_API_KEY  - Miniflux: Settings -> API Keys -> Create (NOT an ntfy tk_ token)
  NTFY_TOKEN        - ntfy token of the publisher user (write-only on the topic)
Optional: MINIFLUX_URL (default http://127.0.0.1:8180), NTFY_URL (default http://127.0.0.1:8190),
          NTFY_TOPIC (default secnews)

Examples (on the OMV host):
  ./push-unread.py --list-categories
  ./push-unread.py --category-id 2                 # dry run: list only
  ./push-unread.py --category-id 2 --send          # publish (max 10)
  ./push-unread.py --feed-id 3 --limit 5 --send --priority 5
"""
import argparse
import getpass
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

MAX_LIMIT = 50
TIMEOUT = 15


def env_or_prompt(name: str, prompt: str) -> str:
    val = os.environ.get(name, "").strip()
    if not val:
        val = getpass.getpass(prompt).strip()
    if not val:
        sys.exit(f"Missing {name}.")
    return val


def check_base_url(url: str, name: str) -> str:
    p = urllib.parse.urlparse(url)
    if p.scheme not in ("http", "https") or not p.netloc:
        sys.exit(f"{name} invalid: {url!r} (must be http:// or https://)")
    return url.rstrip("/")


def http_json(req: urllib.request.Request):
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        # don't print the response body (may contain details); status code only
        sys.exit(f"HTTP {e.code} from {req.full_url.split('?')[0]}")
    except urllib.error.URLError as e:
        sys.exit(f"Cannot connect to {req.full_url.split('?')[0]}: {e.reason}")


def miniflux_get(base: str, key: str, path: str, params=None):
    url = base + path + ("?" + urllib.parse.urlencode(params) if params else "")
    req = urllib.request.Request(url, headers={"X-Auth-Token": key})
    return http_json(req)


def clean(text: str, maxlen: int) -> str:
    text = "".join(ch for ch in (text or "") if ch == "\n" or ch >= " ").strip()
    return text if len(text) <= maxlen else text[: maxlen - 1] + "…"


def ntfy_publish(base: str, token: str, topic: str, title: str, msg: str, click: str, prio: int):
    body = {"topic": topic, "title": title, "message": msg, "priority": prio}
    if click.startswith(("http://", "https://")):
        body["click"] = click
    req = urllib.request.Request(
        base + "/",
        data=json.dumps(body).encode("utf-8"),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        method="POST",
    )
    return http_json(req)


def main():
    ap = argparse.ArgumentParser(description="Push unread Miniflux entries to ntfy")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--list-categories", action="store_true", help="list categories with their IDs")
    g.add_argument("--category-id", type=int)
    g.add_argument("--feed-id", type=int)
    ap.add_argument("--limit", type=int, default=10, help=f"max entries (1-{MAX_LIMIT}, default 10)")
    ap.add_argument("--priority", type=int, default=4, choices=range(1, 6), help="ntfy priority (default 4)")
    ap.add_argument("--send", action="store_true", help="actually publish (otherwise dry run)")
    a = ap.parse_args()

    if not 1 <= a.limit <= MAX_LIMIT:
        sys.exit(f"--limit must be between 1 and {MAX_LIMIT}")

    mf_url = check_base_url(os.environ.get("MINIFLUX_URL", "http://127.0.0.1:8180"), "MINIFLUX_URL")
    mf_key = env_or_prompt("MINIFLUX_API_KEY", "Miniflux API key: ")

    if a.list_categories:
        for c in miniflux_get(mf_url, mf_key, "/v1/categories"):
            print(f"{c['id']:>4}  {c['title']}")
        return

    params = {"status": "unread", "order": "published_at", "direction": "desc", "limit": a.limit}
    if a.category_id is not None:
        params["category_id"] = a.category_id
        data = miniflux_get(mf_url, mf_key, "/v1/entries", params)
    else:
        data = miniflux_get(mf_url, mf_key, f"/v1/feeds/{a.feed_id}/entries", params)

    entries = data.get("entries") or []
    print(f"Unread found: {data.get('total', len(entries))}, processing: {len(entries)}")
    if not entries:
        return

    if a.send:
        nt_url = check_base_url(os.environ.get("NTFY_URL", "http://127.0.0.1:8190"), "NTFY_URL")
        nt_tok = env_or_prompt("NTFY_TOKEN", "ntfy token (publisher user): ")
        topic = os.environ.get("NTFY_TOPIC", "secnews")

    # oldest first, so notifications arrive in chronological order
    for e in reversed(entries):
        feed = clean((e.get("feed") or {}).get("title", ""), 60)
        title = clean(e.get("title", ""), 200)
        url = e.get("url", "")
        print(f"- [{feed}] {title}")
        if a.send:
            ntfy_publish(nt_url, nt_tok, topic, clean(f"{feed}: {title}", 250), url or title, url, a.priority)
            time.sleep(0.5)  # stay under ntfy rate limits (burst 60, then 1 req / 5s)

    print("Sent." if a.send else "Dry run. Add --send to publish.")


if __name__ == "__main__":
    main()
