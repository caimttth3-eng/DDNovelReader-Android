# -*- coding: utf-8 -*-
"""安卓仓库 Actions：runs / wait / artifacts / download。"""
import io, os, sys, time, zipfile
import requests

OWNER, REPO = "caimttth3-eng", "DDNovelReader-Android"
API = "https://api.github.com"
PROXIES = {"http": "http://127.0.0.1:1001", "https": "http://127.0.0.1:1001"}
TOKEN_FILE = r"C:\Users\lyuga\Doubao\chats\2026-08-27\new-chat-1\_gh_token.txt"


def headers():
    tok = io.open(TOKEN_FILE, encoding="utf-8").read().strip()
    return {"Authorization": "token " + tok, "User-Agent": "dd-ci-a",
            "Accept": "application/vnd.github+json"}


def get(path):
    r = requests.get(API + path, headers=headers(), proxies=PROXIES, timeout=40)
    r.raise_for_status()
    return r.json()


def runs():
    for run in get("/repos/%s/%s/actions/runs?per_page=5" % (OWNER, REPO)).get("workflow_runs") or []:
        print("run id=%s head=%s status=%s conclusion=%s created=%s" % (
            run["id"], run["head_sha"][:8], run["status"], run.get("conclusion"), run["created_at"]))


def wait(run_id):
    for _ in range(120):
        run = get("/repos/%s/%s/actions/runs/%s" % (OWNER, REPO, run_id))
        print(run["status"], run.get("conclusion"))
        if run["status"] == "completed":
            return 0 if run.get("conclusion") == "success" else 1
        time.sleep(15)
    return 1


def artifacts(run_id):
    for a in get("/repos/%s/%s/actions/runs/%s/artifacts" % (OWNER, REPO, run_id)).get("artifacts") or []:
        print("%s | id=%s | %.2f MB" % (a["name"], a["id"], a["size_in_bytes"] / 1048576.0))


def download(run_id, outdir):
    os.makedirs(outdir, exist_ok=True)
    for a in get("/repos/%s/%s/actions/runs/%s/artifacts" % (OWNER, REPO, run_id)).get("artifacts") or []:
        url = "%s/repos/%s/%s/actions/artifacts/%s/zip" % (API, OWNER, REPO, a["id"])
        r = requests.get(url, headers=headers(), proxies=PROXIES, timeout=120,
                         allow_redirects=False, stream=True)
        if r.status_code in (301, 302, 303, 307, 308):
            loc = r.headers["Location"]
            r.close()
            r = requests.get(loc, proxies=PROXIES, timeout=1800, stream=True)
        r.raise_for_status()
        zp = os.path.join(outdir, a["name"] + ".zip")
        with open(zp, "wb") as f:
            for c in r.iter_content(1 << 20):
                if c:
                    f.write(c)
        print("saved", zp, os.path.getsize(zp))
        with zipfile.ZipFile(zp) as z:
            z.extractall(os.path.join(outdir, "extracted"))
            print("extracted:", z.namelist())


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "runs":
        runs()
    elif cmd == "wait":
        sys.exit(wait(sys.argv[2]))
    elif cmd == "artifacts":
        artifacts(sys.argv[2])
    elif cmd == "download":
        download(sys.argv[2], sys.argv[3])
