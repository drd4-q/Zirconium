#!/usr/bin/env python3
"""Download real third-party applications to exercise the kernel ABIs.

Linux binaries must be STATIC musl builds — the kernel has no dynamic loader.
Windows entries are ordinary console PEs driven through the INT 0x81 thunks.
Everything lands in samples/apps/ and tools/create_test_disk.py copies it onto
disk.img. Each download is independent: failures warn but never abort.
"""
import io
import json
import os
import re
import ssl
import sys
import tarfile
import urllib.error
import urllib.request
import zipfile

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
APPS_DIR = os.path.join(REPO_ROOT, "samples", "apps")
UA = {"User-Agent": "Mozilla/5.0 zirconium-fetch/1.0"}


def http_get(url, timeout=180):
    req = urllib.request.Request(url, headers=UA)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read()
    except (urllib.error.URLError, ssl.SSLError) as e:
        print(f"    retrying {url} without TLS verification ({e})")
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
            return r.read()


def github_latest_asset(repo, pattern):
    """Return the browser_download_url of the newest release asset matching."""
    api = f"https://api.github.com/repos/{repo}/releases/latest"
    data = json.loads(http_get(api, timeout=60))
    for asset in data.get("assets", []):
        if re.search(pattern, asset.get("name", "")):
            return asset["name"], asset["browser_download_url"]
    raise RuntimeError(f"{repo}: no release asset matches {pattern!r}")


def save(name, data):
    path = os.path.join(APPS_DIR, name)
    with open(path, "wb") as f:
        f.write(data)
    print(f"[FETCH] {name:<12} {len(data):>10,} bytes")


def extract_member(blob, member_regex, out_name):
    """Pull one file out of a tar.gz/zip archive blob by member-name regex."""
    if blob[:2] == b"PK":
        with zipfile.ZipFile(io.BytesIO(blob)) as z:
            for info in z.infolist():
                if re.search(member_regex, info.filename) and not info.is_dir():
                    save(out_name, z.read(info))
                    return True
    else:
        with tarfile.open(fileobj=io.BytesIO(blob), mode="r:*") as t:
            for info in t.getmembers():
                if info.isfile() and re.search(member_regex, info.name):
                    save(out_name, t.extractfile(info).read())
                    return True
    raise RuntimeError(f"member matching {member_regex!r} not found in archive")


def want(name):
    return not os.path.exists(os.path.join(APPS_DIR, name))


def fetch_fastfetch():
    if not want("fastfetch"):
        return print("[SKIP ] fastfetch already present")
    _, url = github_latest_asset(
        "fastfetch-cli/fastfetch", r"^fastfetch-linux-amd64\.tar\.gz$")
    extract_member(http_get(url), r"(^|/)bin/fastfetch$", "fastfetch")


def fetch_btop():
    if not want("btop"):
        return print("[SKIP ] btop already present")
    _, url = github_latest_asset(
        "aristocratos/btop", r"^btop-x86_64-unknown-linux-musl\.tar\.gz$")
    extract_member(http_get(url), r"(^|/)bin/btop$", "btop")


def fetch_coreutils():
    if not want("coreutils"):
        return print("[SKIP ] coreutils already present")
    _, url = github_latest_asset(
        "uutils/coreutils", r"^coreutils-[0-9.]+-x86_64-unknown-linux-musl\.tar\.gz$")
    extract_member(http_get(url), r"(^|/)coreutils$", "coreutils")


def fetch_neofetch():
    if not want("neofetch"):
        return print("[SKIP ] neofetch already present")
    save("neofetch", http_get(
        "https://raw.githubusercontent.com/dylanaraps/neofetch/master/neofetch"))


def fetch_7zr():
    if not want("7zr.exe"):
        return print("[SKIP ] 7zr.exe already present")
    save("7zr.exe", http_get("https://www.7-zip.org/a/7zr.exe"))


def fetch_jq():
    if not want("jq.exe"):
        return print("[SKIP ] jq.exe already present")
    _, url = github_latest_asset("jqlang/jq", r"^jq-windows-amd64\.exe$")
    save("jq.exe", http_get(url))


def fetch_rg():
    if not want("rg.exe"):
        return print("[SKIP ] rg.exe already present")
    _, url = github_latest_asset(
        "BurntSushi/ripgrep", r"x86_64-pc-windows-msvc\.zip$")
    extract_member(http_get(url), r"(^|/)rg\.exe$", "rg.exe")


def fetch_curl():
    if not want("curl.exe"):
        return print("[SKIP ] curl.exe already present")
    page = http_get("https://curl.se/windows/", timeout=60).decode("utf-8", "ignore")
    match = re.search(r'(dl-[0-9._]+/curl-[0-9._]+-win64-mingw\.zip)', page)
    if not match:
        raise RuntimeError("curl.se/windows: no win64-mingw link found")
    extract_member(http_get(f"https://curl.se/windows/{match.group(1)}"),
                   r"(^|/)bin/curl\.exe$", "curl.exe")


def main():
    os.makedirs(APPS_DIR, exist_ok=True)
    jobs = [
        ("fastfetch (musl static)", fetch_fastfetch),
        ("btop (musl static)", fetch_btop),
        ("coreutils (musl multicall)", fetch_coreutils),
        ("neofetch (shell script)", fetch_neofetch),
        ("7zr.exe (console PE)", fetch_7zr),
        ("jq.exe (console PE)", fetch_jq),
        ("rg.exe (console PE)", fetch_rg),
        ("curl.exe (console PE)", fetch_curl),
    ]
    failed = []
    for label, job in jobs:
        print(f"[FETCH] === {label} ===")
        try:
            job()
        except Exception as e:
            print(f"[WARN ] {label}: {e}")
            failed.append(label)

    present = sorted(os.listdir(APPS_DIR))
    print(f"\n[FETCH] done. samples/apps contents: {present}")
    if failed:
        print(f"[FETCH] FAILED items: {failed}")
        sys.exit(1)


if __name__ == "__main__":
    main()
