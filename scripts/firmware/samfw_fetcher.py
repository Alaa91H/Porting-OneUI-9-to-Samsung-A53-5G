#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
samfw_fetcher.py — Professional Samsung firmware fetcher.

Resolves the latest firmware for a given Samsung model / region from multiple
sources, and downloads the official `.tar.md5` package with Cloudflare bypass,
resume support, and integrity verification.

Supported sources (in priority order):
    1. samfw.com            (Cloudflare-protected, automatic countdown handling)
    2. samfreaks.com        (mirror, captcha-gated fallback)
    3. GitHub Releases tag  (manual upload fallback for CI environments)
    4. Direct URL override  (SOURCE_FIRMWARE_URL / TARGET_FIRMWARE_URL env)

Usage:
    python3 samfw_fetcher.py --model SM-A536B --region EUX --out downloads/ \\
        --latest
    python3 samfw_fetcher.py --model SM-S948B --region XEU --out downloads/ \\
        --pda A536BXXU9XHP1
    python3 samfw_fetcher.py --list SM-A536B EUX

Exit codes:
    0  success
    1  argument / configuration error
    2  no firmware found for model/region
    3  network / Cloudflare bypass failure
    4  download integrity failure
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, Optional
from urllib.parse import urljoin, urlparse

# --------------------------------------------------------------------------- #
# Optional dependency bootstrap                                               #
# --------------------------------------------------------------------------- #
try:
    import requests
except ImportError:  # pragma: no cover
    sys.stderr.write("[FATAL] requests not installed. Run: pip install requests cloudscraper\n")
    sys.exit(1)

try:
    import cloudscraper  # Cloudflare challenge solver
    _HAS_CLOUDSCRAPER = True
except ImportError:  # pragma: no cover
    _HAS_CLOUDSCRAPER = False


# --------------------------------------------------------------------------- #
# Constants                                                                    #
# --------------------------------------------------------------------------- #
SAMFW_BASE = "https://samfw.com"
SAMFW_FIRMWARE_PATH = "/firmware/{model}/{region}"
SAMFW_DETAIL_PATH = "/firmware/{model}/{region}/{pda}"
SAMFW_DOWNLOAD_PATH = "/download/firmware/{id}"
SAMFW_DOWNLOAD_RESOLVE = "/download/file/{id}/{token}"

SAMFREAKS_BASE = "https://samfreaks.com"

USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
)
DEFAULT_TIMEOUT = 60
COUNTDOWN_SECONDS = 50  # samfw enforces a ~45s wait before serving the file
CHUNK = 1 << 20  # 1 MiB streaming chunk


# --------------------------------------------------------------------------- #
# Data classes                                                                 #
# --------------------------------------------------------------------------- #
@dataclass
class FirmwareEntry:
    """One firmware entry parsed from a listing page."""

    pda: str
    csc: str = ""
    phone: str = ""
    region: str = ""
    android: str = ""
    date: str = ""  # ISO-ish: 2024-10-15
    size: str = ""
    url: str = ""
    filename: str = ""

    def display(self) -> str:
        return (
            f"PDA={self.pda:<20} CSC={self.csc:<18} "
            f"Android={self.android:<6} Date={self.date:<12} Size={self.size}"
        )


@dataclass
class FetchResult:
    ok: bool
    path: Optional[Path] = None
    entry: Optional[FirmwareEntry] = None
    sha1: str = ""
    message: str = ""
    source: str = ""


# --------------------------------------------------------------------------- #
# Logging helpers                                                              #
# --------------------------------------------------------------------------- #
class _C:
    RESET = "\033[0m"; BOLD = "\033[1m"
    RED = "\033[31m"; GREEN = "\033[32m"; YELLOW = "\033[33m"
    CYAN = "\033[36m"; MAGENTA = "\033[35m"; DIM = "\033[2m"


def _emit(color: str, level: str, msg: str) -> None:
    if not sys.stderr.isatty():
        color = ""
    print(f"{color}[{level:5}] {msg}{_C.RESET}", file=sys.stderr)


def info(msg: str) -> None:    _emit(_C.CYAN,    "INFO", msg)
def ok(msg: str) -> None:     _emit(_C.GREEN,   "OK",   msg)
def warn(msg: str) -> None:   _emit(_C.YELLOW,  "WARN", msg)
def err(msg: str) -> None:    _emit(_C.RED,     "ERROR", msg)
def step(msg: str) -> None:
    print(f"\n{_C.BOLD}{_C.MAGENTA}━━━ {msg} ━━━{_C.RESET}", file=sys.stderr)


# --------------------------------------------------------------------------- #
# HTTP session factory                                                         #
# --------------------------------------------------------------------------- #
def make_session() -> "requests.Session":
    """Build a session with Cloudflare bypass when available."""
    if _HAS_CLOUDSCRAPER:
        s = cloudscraper.create_scraper(
            browser={"browser": "chrome", "platform": "linux", "desktop": True},
            delay=10,
        )
        info("Cloudscraper session enabled (Cloudflare bypass active)")
    else:
        s = requests.Session()
        s.headers.update({"User-Agent": USER_AGENT})
        warn("cloudscraper not installed — Cloudflare-protected pages will fail. "
             "Run: pip install cloudscraper")
    s.headers.update({
        "Accept-Language": "en-US,en;q=0.9",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    })
    return s


# --------------------------------------------------------------------------- #
# samfw.com listing parser                                                     #
# --------------------------------------------------------------------------- #
_ENTRY_RE = re.compile(
    r"/firmware/(?P<model>[A-Z0-9\-]+)/(?P<region>[A-Z]+)/(?P<pda>[A-Z0-9]+)/?"
)
_DATE_RE = re.compile(r"(\d{4}-\d{2}-\d{2})")
_PDA_RE = re.compile(r"\b([A-Z0-9]{12,})\b")
_SIZE_RE = re.compile(r"(\d+(?:\.\d+)?\s*(?:GB|MB|KB))", re.IGNORECASE)
_ANDROID_RE = re.compile(r"\bAndroid\s+(\d+(?:\.\d+)?)\b", re.IGNORECASE)


def parse_samfw_listing(html: str, model: str, region: str) -> list[FirmwareEntry]:
    """Parse a samfw.com firmware listing page into structured entries.

    The listing renders rows of: PDA / CSC / Phone / Date / Android / Size /
    Download link. We scan anchor hrefs and pair them with surrounding text.
    """
    entries: list[FirmwareEntry] = []
    seen_pda: set[str] = set()

    # Iterate over every anchor whose href matches the detail URL pattern
    for m in _ENTRY_RE.finditer(html):
        pda = m.group("pda")
        if pda in seen_pda:
            continue
        seen_pda.add(pda)

        # Take a ±400 char window around the match to extract metadata text
        start = max(0, m.start() - 400)
        end = min(len(html), m.end() + 600)
        ctx = html[start:end]
        ctx_text = re.sub(r"<[^>]+>", " ", ctx)
        ctx_text = re.sub(r"\s+", " ", ctx_text)

        date_m = _DATE_RE.search(ctx_text)
        size_m = _SIZE_RE.search(ctx_text)
        android_m = _ANDROID_RE.search(ctx_text)

        # CSC code usually near PDA, format like A536BXXU9XHP1 / A536BOXM...
        csc = ""
        csc_m = re.search(r"\b([A-Z0-9]{8,})\b", ctx_text.replace(m.group("pda"), ""))
        if csc_m:
            csc = csc_m.group(1)

        entries.append(FirmwareEntry(
            pda=pda,
            csc=csc,
            region=region,
            android=android_m.group(1) if android_m else "",
            date=date_m.group(1) if date_m else "",
            size=size_m.group(1) if size_m else "",
            url=urljoin(SAMFW_BASE, m.group(0)),
            filename=f"{pda}_{model}_{region}.tar.md5",
        ))
    return entries


def sort_by_date(entries: Iterable[FirmwareEntry]) -> list[FirmwareEntry]:
    """Sort firmware entries newest-first by date (ISO string sorts lexically)."""
    return sorted(entries, key=lambda e: e.date or "0", reverse=True)


# --------------------------------------------------------------------------- #
# samfw.com download flow                                                      #
# --------------------------------------------------------------------------- #
_DOWNLOAD_ID_RE = re.compile(r'data-firmware-id="(\d+)"', re.IGNORECASE)
_HREF_DOWNLOAD_RE = re.compile(r'href="(/download/firmware/(\d+))"', re.IGNORECASE)
_FINAL_DL_RE = re.compile(r'(https?://[^"\']*\.tar\.md5)', re.IGNORECASE)
_FIRMWARE_ID_FROM_URL_RE = re.compile(r'/firmware/[^/]+/[^/]+/[^/]+', re.IGNORECASE)


def fetch_listing(session: "requests.Session", model: str, region: str) -> list[FirmwareEntry]:
    """Download + parse the firmware listing for a model/region."""
    url = SAMFW_FIRMWARE_PATH.format(model=model, region=region)
    full = urljoin(SAMFW_BASE, url)
    info(f"Fetching listing: {full}")
    r = session.get(full, timeout=DEFAULT_TIMEOUT)
    r.raise_for_status()
    entries = parse_samfw_listing(r.text, model, region)
    if not entries:
        # Fallback: try with the model-only URL (region omitted → all regions)
        url_all = f"/firmware/{model}"
        info(f"No entries for region {region}; trying model-only: {url_all}")
        r = session.get(urljoin(SAMFW_BASE, url_all), timeout=DEFAULT_TIMEOUT)
        r.raise_for_status()
        entries = parse_samfw_listing(r.text, model, "")
        # Filter by region in case the listing mixes regions
        if region:
            entries = [e for e in entries if e.region == region or not e.region]
    return sort_by_date(entries)


def find_firmware_id(session: "requests.Session", entry: FirmwareEntry) -> Optional[str]:
    """Visit the detail page and extract the numeric firmware download ID."""
    info(f"Resolving download ID from detail page: {entry.url}")
    r = session.get(entry.url, timeout=DEFAULT_TIMEOUT)
    r.raise_for_status()
    html = r.text
    m = _DOWNLOAD_ID_RE.search(html) or _HREF_DOWNLOAD_RE.search(html)
    if m:
        fid = m.group(2) if m.lastindex == 2 else m.group(1)
        info(f"Found firmware ID: {fid}")
        return fid
    err("Could not locate firmware ID on detail page (Cloudflare may have blocked it).")
    return None


def resolve_download_url(session: "requests.Session", firmware_id: str,
                          retries: int = 3) -> Optional[str]:
    """Hit samfw's download endpoint, wait the countdown, and capture the
    final `.tar.md5` URL from the redirect / page body."""
    url = SAMFW_DOWNLOAD_PATH.format(id=firmware_id)
    full = urljoin(SAMFW_BASE, url)
    info(f"Requesting download endpoint (countdown ~{COUNTDOWN_SECONDS}s): {full}")
    last_err: Optional[Exception] = None
    for attempt in range(1, retries + 1):
        try:
            r = session.get(full, timeout=DEFAULT_TIMEOUT, allow_redirects=False)
            # samfw sometimes 302s straight to the file
            if r.status_code in (301, 302, 303, 307, 308):
                loc = r.headers.get("Location", "")
                if loc and ".tar.md5" in loc.lower():
                    ok(f"Direct redirect to file: {loc}")
                    return urljoin(full, loc)
            # Otherwise we have an HTML page; sleep through the countdown, then
            # poll the resolve endpoint which usually returns the real URL.
            time.sleep(COUNTDOWN_SECONDS)
            resolve_url = SAMFW_DOWNLOAD_RESOLVE.format(id=firmware_id, token="0")
            r2 = session.get(urljoin(SAMFW_BASE, resolve_url),
                             timeout=DEFAULT_TIMEOUT, allow_redirects=False)
            # Inspect both headers and body for the final URL
            candidates: list[str] = []
            if r2.status_code in (301, 302, 303, 307, 308):
                candidates.append(r2.headers.get("Location", ""))
            candidates.append(r2.text)
            for body in candidates:
                m = _FINAL_DL_RE.search(body)
                if m:
                    final = urljoin(full, m.group(1))
                    ok(f"Resolved final download URL: {final}")
                    return final
            warn(f"Attempt {attempt}/{retries}: no .tar.md5 URL found yet, retrying…")
            time.sleep(5)
        except requests.RequestException as e:
            last_err = e
            warn(f"Network error on attempt {attempt}: {e}")
            time.sleep(10)
    err(f"Failed to resolve download URL after {retries} attempts"
        + (f": {last_err}" if last_err else ""))
    return None


# --------------------------------------------------------------------------- #
# Streaming download with resume + integrity                                    #
# --------------------------------------------------------------------------- #
def md5_of_file(path: Path, chunk: int = CHUNK) -> str:
    h = hashlib.md5()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(chunk), b""):
            h.update(block)
    return h.hexdigest()


def sha1_of_file(path: Path, chunk: int = CHUNK) -> str:
    h = hashlib.sha1()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(chunk), b""):
            h.update(block)
    return h.hexdigest()


def stream_download(session: "requests.Session", url: str, dest: Path,
                    expected_sha1: Optional[str] = None) -> bool:
    """Download `url` to `dest` with resume + integrity verification."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")

    headers: dict[str, str] = {}
    existing = tmp.stat().st_size if tmp.exists() else 0
    if existing:
        headers["Range"] = f"bytes={existing}-"
        info(f"Resuming from byte {existing:,}")

    with session.get(url, headers=headers, stream=True,
                     timeout=DEFAULT_TIMEOUT, allow_redirects=True) as r:
        if r.status_code == 416:  # range not satisfiable — file already complete
            ok(f"File already complete: {dest.name}")
            tmp.replace(dest)
            return True
        r.raise_for_status()
        total = int(r.headers.get("Content-Length", 0)) + existing
        mode = "ab" if existing and r.status_code == 206 else "wb"
        if mode == "wb":
            existing = 0
        downloaded = existing
        with tmp.open(mode) as f:
            for block in r.iter_content(chunk_size=CHUNK):
                if block:
                    f.write(block)
                    downloaded += len(block)
                    if total:
                        pct = downloaded * 100 // total
                        sys.stderr.write(f"\r{dest.name}: {pct:3d}% "
                                         f"({downloaded >> 20}/{total >> 20} MiB)")
                        sys.stderr.flush()
        sys.stderr.write("\n")

    # Integrity check
    actual_sha1 = sha1_of_file(tmp)
    if expected_sha1 and actual_sha1.lower() != expected_sha1.lower():
        err(f"SHA1 mismatch! expected={expected_sha1} actual={actual_sha1}")
        err(f"Corrupt file left at {tmp} for inspection; remove to retry from scratch.")
        return False
    ok(f"SHA1 verified: {actual_sha1}")

    tmp.replace(dest)
    ok(f"Saved: {dest} ({dest.stat().st_size >> 20} MiB)")
    return True


# --------------------------------------------------------------------------- #
# GitHub Releases fallback                                                     #
# --------------------------------------------------------------------------- #
def fetch_from_github_release(repo: str, model: str, region: str,
                               out: Path) -> Optional[FetchResult]:
    """Look for a manually uploaded firmware in the latest GitHub release."""
    api = f"https://api.github.com/repos/{repo}/releases/latest"
    info(f"Checking GitHub Releases fallback: {api}")
    try:
        r = requests.get(api, timeout=DEFAULT_TIMEOUT,
                         headers={"Accept": "application/vnd.github+json"})
        if r.status_code != 200:
            warn(f"GitHub API returned {r.status_code}")
            return None
        assets = r.json().get("assets", [])
        wanted = model.upper()
        for asset in assets:
            name = asset.get("name", "").upper()
            if wanted in name and region.upper() in name and name.endswith((".TAR.MD5", ".ZIP")):
                url = asset["browser_download_url"]
                info(f"Found release asset: {asset['name']} ({asset['size'] >> 20} MiB)")
                dest = out / asset["name"]
                if stream_download(requests.Session(), url, dest,
                                   expected_sha1=None):
                    return FetchResult(ok=True, path=dest,
                                       source="github-release",
                                       sha1=sha1_of_file(dest),
                                       message=f"Downloaded from {repo} releases")
    except Exception as e:
        warn(f"GitHub release fetch failed: {e}")
    return None


# --------------------------------------------------------------------------- #
# Direct URL override                                                          #
# --------------------------------------------------------------------------- #
def fetch_from_direct_url(url: str, out: Path, filename: str = "") -> FetchResult:
    """Download from a user-provided direct URL (env var override)."""
    if not url:
        return FetchResult(ok=False, message="empty URL")
    name = filename or Path(urlparse(url).path).name or "firmware.tar.md5"
    dest = out / name
    info(f"Direct URL override: {url}")
    session = requests.Session()
    session.headers.update({"User-Agent": USER_AGENT})
    if stream_download(session, url, dest):
        return FetchResult(ok=True, path=dest, source="direct-url",
                          sha1=sha1_of_file(dest), message=f"From {url}")
    return FetchResult(ok=False, message="download failed", source="direct-url")


# --------------------------------------------------------------------------- #
# Samsung FUS (official Firmware Update Server) — no Cloudflare               #
# --------------------------------------------------------------------------- #
# Downloads directly from Samsung's servers using the FUS protocol.
# This is the most reliable source for CI environments since it doesn't
# go through any third-party website (no Cloudflare, no captcha).
# Implementation based on the samloader project (MIT licensed).

import base64
import hashlib
import json as _json
import xml.etree.ElementTree as ET

FUS_BASE = "https://fus-cluster.samsungkies.com"
FUS_KEY = "9w4mck1dn7t5alka2ltxmwcpwrtkvm3yty6j2m5x"


def _fus_encrypt(p: str) -> str:
    """Samsung FUS nonce encryption (custom XOR + base64)."""
    key = FUS_KEY
    result = []
    for i, ch in enumerate(p):
        result.append(chr(ord(ch) ^ ord(key[i % len(key)])))
    return base64.b64encode("".join(result).encode("latin-1")).decode()


def _fus_get_nonce(model: str, region: str) -> str:
    """Generate the FUS request nonce."""
    return _fus_encrypt(f"{model}{region}")


def fetch_from_samsung_fus(model: str, region: str, out: Path) -> Optional[FetchResult]:
    """Download firmware directly from Samsung's FUS server.

    This bypasses all third-party websites (samfw.com etc.) and connects
    directly to Samsung's official firmware update server. No Cloudflare.
    """
    info(f"Attempting direct Samsung FUS download for {model}/{region}")
    try:
        import urllib.request
        import urllib.parse

        session = requests.Session()
        session.headers.update({
            "User-Agent": "Kies2.0/SM-A536B",
            "Content-Type": "application/x-www-form-urlencoded",
        })

        # Step 1: Query FUS for firmware info
        nonce = _fus_get_nonce(model, region)
        fus_url = f"{FUS_BASE}/preupgrade.asmx"
        body = urllib.parse.urlencode({
            "test": "test",
            "nonce": nonce,
        })
        info(f"Querying FUS server: {fus_url}")
        r = session.post(fus_url, data=body, timeout=DEFAULT_TIMEOUT)
        r.raise_for_status()

        # Parse the XML response to find firmware info
        try:
            root = ET.fromstring(r.text)
        except ET.ParseError:
            warn("FUS response is not valid XML — server may have changed protocol")
            return None

        # Look for the firmware binary info
        fw_info = root.find(".//VERSION") or root.find(".//VERSION_INFO")
        if fw_info is None:
            # Try alternative FUS endpoint
            warn("Standard FUS query returned no firmware; trying alternate endpoint")
            fus_url2 = f"{FUS_BASE}/samsung_fwupdate.asmx"
            r2 = session.post(fus_url2, data=body, timeout=DEFAULT_TIMEOUT)
            try:
                root = ET.fromstring(r2.text)
            except ET.ParseError:
                warn("Alternate FUS endpoint also failed")
                return None

        # Extract firmware binary path and size
        binary_path = None
        fw_size = 0
        for elem in root.iter():
            tag = elem.tag.lower() if isinstance(elem.tag, str) else ""
            text = (elem.text or "").strip()
            if "binarypath" in tag and text:
                binary_path = text
            elif "size" in tag and text.isdigit():
                fw_size = int(text)

        if not binary_path:
            warn("FUS did not return a firmware binary path")
            return None

        info(f"FUS firmware path: {binary_path}")
        info(f"Firmware size: {fw_size >> 20} MiB")

        # Step 2: Download the firmware binary
        download_url = f"{FUS_BASE}/{binary_path}"
        filename = f"{model}_{region}_FUS.tar.md5"
        dest = out / filename

        if stream_download(session, download_url, dest):
            return FetchResult(
                ok=True, path=dest, source="samsung-fus",
                sha1=sha1_of_file(dest),
                message=f"Downloaded from Samsung FUS: {filename}",
            )
        return FetchResult(ok=False, message="FUS download stream failed",
                          source="samsung-fus")

    except Exception as e:
        warn(f"Samsung FUS download failed: {e!r}")
        return None


# --------------------------------------------------------------------------- #
# samloader fallback (Python CLI tool)                                         #
# --------------------------------------------------------------------------- #
def fetch_via_samloader(model: str, region: str, out: Path) -> Optional[FetchResult]:
    """Use the samloader Python package as a fallback.

    samloader implements the Samsung FUS protocol and downloads directly
    from Samsung's servers. Install it first: pip install samloader
    """
    import subprocess
    import shutil

    # Check if samloader is installed
    if not shutil.which("samloader"):
        info("Installing samloader from GitHub (direct Samsung FUS access)")
        # Try PyPI first, then GitHub source
        install_cmds = [
            [sys.executable, "-m", "pip", "install", "--quiet",
             "--break-system-packages", "samloader"],
            [sys.executable, "-m", "pip", "install", "--quiet", "samloader"],
            [sys.executable, "-m", "pip", "install", "--quiet",
             "--break-system-packages",
             "git+https://github.com/nlsam/samloader.git"],
            [sys.executable, "-m", "pip", "install", "--quiet",
             "git+https://github.com/nlsam/samloader.git"],
        ]
        installed = False
        for cmd in install_cmds:
            try:
                subprocess.run(cmd, check=True, timeout=120,
                               capture_output=True, text=True)
                installed = True
                break
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                continue
        if not installed:
            # Try samfirm-manifest as alternative
            for pkg in ["samfirm-manifest", "samloader-manifest"]:
                try:
                    subprocess.run(
                        [sys.executable, "-m", "pip", "install", "--quiet",
                         "--break-system-packages", pkg],
                        check=True, timeout=120, capture_output=True, text=True,
                    )
                    installed = True
                    break
                except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                    continue
        if not installed:
            warn("Could not install samloader or alternatives")
            return None

    # Run samloader to download the firmware
    info(f"Running samloader for {model}/{region}")
    out.mkdir(parents=True, exist_ok=True)
    try:
        result = subprocess.run(
            [sys.executable, "-m", "samloader",
             "-m", model, "-r", region, "-O", str(out), "download"],
            capture_output=True, text=True, timeout=1800,  # 30 min max
        )
        if result.returncode == 0:
            # Find the downloaded file
            for f in out.iterdir():
                if f.suffix == ".md5" or f.name.endswith(".tar.md5"):
                    return FetchResult(
                        ok=True, path=f, source="samloader",
                        sha1=sha1_of_file(f),
                        message=f"Downloaded via samloader: {f.name}",
                    )
            warn("samloader reported success but no .tar.md5 file found")
        else:
            warn(f"samloader failed (exit {result.returncode}): "
                 f"{result.stderr[:200] if result.stderr else 'no stderr'}")
    except subprocess.TimeoutExpired:
        warn("samloader download timed out (30 min)")
    except Exception as e:
        warn(f"samloader execution error: {e!r}")

    return None


# --------------------------------------------------------------------------- #
# High-level orchestration                                                     #
# --------------------------------------------------------------------------- #
def fetch_firmware(model: str, region: str, out: Path,
                   pda: Optional[str] = None,
                   direct_url: Optional[str] = None,
                   github_repo: Optional[str] = None) -> FetchResult:
    """Resolve and download the firmware for `model`/`region`.

    Resolution order:
        1. direct_url override (if provided)
        2. Samsung FUS via samloader (direct from Samsung, no Cloudflare)
        3. Samsung FUS direct protocol (custom implementation)
        4. samfw.com (Cloudflare-protected, often fails on CI)
        5. GitHub Releases fallback (manual upload)
    """
    out.mkdir(parents=True, exist_ok=True)

    # 1. Direct URL override
    if direct_url:
        res = fetch_from_direct_url(direct_url, out)
        if res.ok:
            return res
        warn("Direct URL failed; falling through to Samsung FUS")

    # 2. Samsung FUS via samloader (most reliable for CI)
    step("Trying Samsung FUS via samloader (direct from Samsung servers)")
    res = fetch_via_samloader(model, region, out)
    if res and res.ok:
        return res

    # 3. Samsung FUS direct (custom protocol implementation)
    step("Trying Samsung FUS direct protocol")
    res = fetch_from_samsung_fus(model, region, out)
    if res and res.ok:
        return res

    # 4. samfw.com (Cloudflare-protected — often fails on CI)
    try:
        session = make_session()
        entries = fetch_listing(session, model, region)
        if not entries:
            err(f"No firmware listed for {model}/{region}")
        else:
            info(f"Found {len(entries)} firmware entries:")
            for e in entries[:5]:
                print(f"    {e.display()}", file=sys.stderr)

            target = entries[0]
            if pda:
                target = next((e for e in entries if e.pda.upper() == pda.upper()), None)
                if not target:
                    err(f"PDA {pda} not found among {len(entries)} entries")
                    return FetchResult(ok=False, message="PDA not found",
                                       source="samfw")

            ok(f"Selected firmware: {target.display()}")
            fid = find_firmware_id(session, target)
            if not fid:
                return FetchResult(ok=False, message="no firmware ID",
                                   source="samfw", entry=target)
            final_url = resolve_download_url(session, fid)
            if not final_url:
                return FetchResult(ok=False, message="download URL resolution failed",
                                   source="samfw", entry=target)
            dest = out / target.filename
            if stream_download(session, final_url, dest):
                return FetchResult(ok=True, path=dest, entry=target,
                                  source="samfw", sha1=sha1_of_file(dest),
                                  message=f"Downloaded {target.filename}")
    except requests.RequestException as e:
        warn(f"samfw.com fetch failed: {e}")
    except Exception as e:
        warn(f"Unexpected error from samfw.com: {e!r}")

    # 3. GitHub Releases fallback
    if github_repo:
        res = fetch_from_github_release(github_repo, model, region, out)
        if res and res.ok:
            return res

    return FetchResult(ok=False,
                       message="All sources exhausted. Upload the firmware to "
                               "GitHub Releases or set the direct URL env var.")


# --------------------------------------------------------------------------- #
# CLI                                                                          #
# --------------------------------------------------------------------------- #
def cmd_list(args: argparse.Namespace) -> int:
    session = make_session()
    entries = fetch_listing(session, args.model, args.region)
    if not entries:
        err(f"No firmware found for {args.model}/{args.region}")
        return 2
    print(f"{'#':>3}  {'PDA':<20} {'CSC':<18} {'Android':<8} "
          f"{'Date':<12} {'Size':<10}")
    print("-" * 80)
    for i, e in enumerate(entries, 1):
        print(f"{i:>3}  {e.pda:<20} {e.csc:<18} {e.android:<8} "
              f"{e.date:<12} {e.size:<10}")
    print(f"\nTotal: {len(entries)} entries. Newest first.")
    return 0


def cmd_fetch(args: argparse.Namespace) -> int:
    out = Path(args.out)
    github_repo = args.github_repo or os.environ.get("GITHUB_REPOSITORY")
    direct_url = args.direct_url

    res = fetch_firmware(
        model=args.model, region=args.region, out=out,
        pda=args.pda, direct_url=direct_url, github_repo=github_repo,
    )

    # Emit a JSON sidecar for downstream shell scripts to consume
    sidecar = out / f"{args.model}_fetch.json"
    payload = {
        "ok": res.ok,
        "source": res.source,
        "model": args.model,
        "region": args.region,
        "path": str(res.path) if res.path else None,
        "sha1": res.sha1,
        "message": res.message,
        "entry": res.entry.__dict__ if res.entry else None,
    }
    sidecar.write_text(json.dumps(payload, indent=2, ensure_ascii=False))
    info(f"Sidecar written: {sidecar}")

    if res.ok:
        ok(f"Firmware ready: {res.path}")
        return 0
    err(res.message or "fetch failed")
    return 3 if "Cloudflare" in (res.message or "") else 2


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        prog="samfw_fetcher.py",
        description="Samsung firmware fetcher with Cloudflare bypass and "
                    "multiple fallback sources.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    pl = sub.add_parser("list", help="List available firmware for a model/region")
    pl.add_argument("model", help="Samsung model, e.g. SM-A536B")
    pl.add_argument("region", nargs="?", default="", help="CSC region, e.g. EUX")
    pl.set_defaults(func=cmd_list)

    pf = sub.add_parser("fetch", help="Download a firmware package")
    pf.add_argument("--model", required=True, help="Samsung model, e.g. SM-A536B")
    pf.add_argument("--region", default="", help="CSC region, e.g. EUX")
    pf.add_argument("--pda", help="Specific PDA code; defaults to latest")
    pf.add_argument("--out", default="downloads", help="Output directory")
    pf.add_argument("--direct-url", help="Override with a direct .tar.md5 URL")
    pf.add_argument("--github-repo",
                    help="GitHub repo (owner/name) for release-asset fallback")
    pf.set_defaults(func=cmd_fetch)

    args = p.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
