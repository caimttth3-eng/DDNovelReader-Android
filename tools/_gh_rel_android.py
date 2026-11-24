# -*- coding: utf-8 -*-
"""安卓仓库 Release 操作（复用 PC 的 token；API 一律 requests + 代理 1001）。

用法：
  python _gh_rel_android.py list
  python _gh_rel_android.py create <tag> <title> <body_file>
  python _gh_rel_android.py upload <release_id> <file> [<file> ...]
  python _gh_rel_android.py assets <release_id>
  python _gh_rel_android.py update-body <release_id> <body_file>
"""
import io
import json
import os
import sys

import requests

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")

OWNER, REPO = "caimttth3-eng", "DDNovelReader-Android"
API = "https://api.github.com"
PROXY = os.environ.get("DD_PROXY", "http://127.0.0.1:1001")
PROXIES = {"http": PROXY, "https": PROXY}
TOKEN_FILE = os.environ.get(
    "DD_TOKEN_FILE", r"C:\Users\lyuga\Doubao\chats\2026-08-27\new-chat-1\_gh_token.txt")


def token():
    with io.open(TOKEN_FILE, encoding="utf-8") as f:
        return f.read().strip()


def headers(extra=None):
    h = {"Authorization": "token " + token(), "User-Agent": "dd-rel-android",
         "Accept": "application/vnd.github+json"}
    if extra:
        h.update(extra)
    return h


def api(method, path, **kw):
    r = requests.request(method, API + path, headers=headers(kw.pop("extra", None)),
                         proxies=PROXIES, timeout=60, **kw)
    r.raise_for_status()
    return r.json() if r.content else {}


def main():
    cmd = sys.argv[1]
    if cmd == "list":
        for rel in api("GET", "/repos/%s/%s/releases" % (OWNER, REPO)):
            print(rel["id"], rel["tag_name"], rel["name"], "assets=%d" % len(rel["assets"]))
    elif cmd == "create":
        tag, title, body_file = sys.argv[2], sys.argv[3], sys.argv[4]
        body = io.open(body_file, encoding="utf-8").read()
        rel = api("POST", "/repos/%s/%s/releases" % (OWNER, REPO),
                  json={"tag_name": tag, "name": title, "body": body, "draft": False})
        print("created", rel["id"], rel["html_url"])
    elif cmd == "upload":
        rid = sys.argv[2]
        for path in sys.argv[3:]:
            name = os.path.basename(path)
            url = ("https://uploads.github.com/repos/%s/%s/releases/%s/assets?name=%s"
                   % (OWNER, REPO, rid, name))
            with io.open(path, "rb") as f:
                r = requests.post(url, headers=headers({"Content-Type": "application/octet-stream"}),
                                  data=f, proxies=PROXIES, timeout=1800)
            r.raise_for_status()
            print("uploaded", name, r.json()["state"], r.json()["size"])
    elif cmd == "assets":
        rid = sys.argv[2]
        for a in api("GET", "/repos/%s/%s/releases/%s/assets" % (OWNER, REPO, rid)):
            print(a["name"], a["state"], a["size"])
    elif cmd == "update-body":
        rid = sys.argv[2]
        body = io.open(sys.argv[3], encoding="utf-8").read()
        print(api("PATCH", "/repos/%s/%s/releases/%s" % (OWNER, REPO, rid),
                  json={"body": body}).get("html_url"))
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
