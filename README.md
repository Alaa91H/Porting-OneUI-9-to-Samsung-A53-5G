# One UI 9 Port — Samsung Galaxy S26 Ultra → Galaxy A53 5G

A complete, reproducible pipeline that ports **One UI 9** (built on Android 16)
from the **Samsung Galaxy S26 Ultra** (`SM-S948B`) to the **Samsung Galaxy A53
5G** (`SM-A536B`, codename `a53x`), with a configurable debloat stage that
removes pre-installed bloatware and carrier/OEM cruft.

The pipeline runs end-to-end on **GitHub Actions** (no local toolchain
required) and produces two flashable artefacts:

| Artefact | Format | Flash via |
|---|---|---|
| `OneUI9_a53x_Port_<build>.tar.md5` | Samsung Odin package (AP slot) | Odin / Heimdall |
| `OneUI9_a53x_Port_<build>.zip` | Recovery-flashable zip (edify v3) | TWRP / OrangeFox / stock recovery |

> [!IMPORTANT]
> Cross-device ROM porting is **unofficial and risky**. It can brick your
> device, void the warranty (Knox eFuse trip), and disable Samsung Pay / Secure
> Folder / Samsung Pass. This project is provided for educational and research
> purposes only. **Back up everything** before flashing, and proceed entirely at
> your own risk.

---

## Table of Contents

1. [How the Port Works](#how-the-port-works)
2. [Repository Layout](#repository-layout)
3. [Prerequisites](#prerequisites)
4. [Quick Start — GitHub Actions](#quick-start--github-actions)
5. [Quick Start — Local Build](#quick-start--local-build)
6. [Firmware Acquisition](#firmware-acquisition)
7. [Device Configuration](#device-configuration)
8. [Debloat Levels](#debloat-levels)
9. [Flashing the Result](#flashing-the-result)
10. [Verification & Post-flash Checks](#verification--post-flash-checks)
11. [Troubleshooting](#troubleshooting)
12. [Known Technical Limitations](#known-technical-limitations)
13. [Contributing](#contributing)
14. [Disclaimer](#disclaimer)

---

## How the Port Works

One UI 9 ships on the S26 Ultra as a `super.img` containing dynamic
partitions: `system`, `vendor`, `product`, `odm`, `system_ext`,
`vendor_dlkm`. The target A53 5G (`a53x`, Exynos 1280) is also a Virtual A/B
device with dynamic partitions, which makes a Treble-compatible port feasible.

### Porting strategy — Full ROM Port

| Component | From S26 Ultra (source) | From A53 5G (target) | Action |
|---|:---:|:---:|---|
| `system/framework` | ✅ | — | Replaced (One UI 9 framework + services) |
| `system/app`, `system/priv-app` | ✅ | merged | One UI 9 system apps copied over |
| `product/app`, `product/priv-app` | ✅ | replaced | One UI product apps |
| `system_ext` | ✅ | replaced | System extensions |
| `vendor` | — | ✅ | **Kept from target** (Exynos 1280 HALs) |
| `odm` | — | ✅ | **Kept from target** (OEM customisations) |
| `boot` / `init_boot` | — | ✅ | **Kept + patched** (forceencrypt / verity off) |
| `vendor_boot` | — | ✅ | Kept (ramdisk + device tree) |
| `dtbo` | — | ✅ | Kept (device tree overlay) |
| `modem` (CP) | — | ✅ | Kept (Exynos 1280 baseband) |
| `build.prop` | ✅ merged | ✅ merged | Patched to report One UI 9 on `a53x` |

The kernel, vendor, modem and device tree all stay on the A53 5G originals to
preserve hardware compatibility. Only the One UI layer (framework + system /
product apps + build props) is overlaid from the S26 Ultra.

### Pipeline stages

```
00_setup.sh            Install build tools (simg2img, erofs-utils, lpmake, …)
01_download_firmware   Resolve + download both firmware packages (samfw.com)
02_extract_firmware    Unpack .tar.md5 → split super.img into partitions
03_port_framework      Overlay One UI 9 framework & apps onto target system
04_debloat             Remove bloatware (lite | standard | aggressive)
05_patch_target        Patch build.prop, vintf, SELinux, fstab
06_repack              Rebuild partition images → super.img → boot patch
07_build_flashable     Produce Odin .tar.md5 + recovery .zip (validated)
```

---

## Repository Layout

```
OneUI9Port/
├── .github/workflows/build-port.yml     # CI pipeline (GitHub Actions)
├── config/
│   ├── source.env                        # Source device (S26 Ultra) settings
│   ├── target.env                        # Target device (A53 5G) settings
│   └── devices.json                      # Device/partition definitions
├── scripts/
│   ├── lib/common.sh                     # Shared helpers (logging, image ops)
│   ├── firmware/samfw_fetcher.py         # Firmware fetcher (Cloudflare bypass)
│   ├── 00_setup.sh … 07_build_flashable.sh
├── debloat/
│   ├── debloat.conf                      # Level config + keep-lists
│   ├── packages_remove.list              # Candidates for removal (per level)
│   └── packages_keep.list                # Protected packages (never removed)
├── patches/
│   ├── build.prop.patch                  # Property overrides
│   └── vintf/vintf.json                  # Vendor interface compatibility
├── output/                               # Build artefacts (gitignored)
├── README.md
├── AGENTS.md                             # AI agent operating instructions
├── CONTRIBUTING.md
└── LICENSE
```

---

## Prerequisites

### For the GitHub Actions build

- A GitHub account with the repository forked or cloned.
- **Firmware**: either set as GitHub Secrets (direct URLs), uploaded as release
  assets, **or** left for automatic resolution from samfw.com (requires
  `cloudscraper`, which the pipeline installs automatically).

| Secret | Purpose |
|---|---|
| `SOURCE_FIRMWARE_URL` | (optional) direct `.tar.md5` URL for S26 Ultra |
| `TARGET_FIRMWARE_URL` | (optional) direct `.tar.md5` URL for A53 5G |
| `SOURCE_PDA` / `TARGET_PDA` | (optional) pin a specific PDA version |

### For the target device

- Galaxy A53 5G with **Bootloader unlocked** (OEM Unlock enabled in Developer
  Options).
- TWRP (or OrangeFox) recovery installed, or Odin + Samsung USB drivers on a
  Windows PC.
- Battery ≥ 60 % and a full backup.

---

## Quick Start — GitHub Actions

1. Fork <https://github.com/Alaa91H/Porting-OneUI-9-to-Samsung-A53-5G>.
2. *(Optional)* Add the `SOURCE_FIRMWARE_URL` / `TARGET_FIRMWARE_URL` secrets
   if you want to bypass samfw.com resolution.
3. Go to the **Actions** tab → **Build One UI 9 Port** → **Run workflow**.
4. Choose:
   - `debloat_level`: `lite` | `standard` | `aggressive`
   - `keep_gapps`: keep Google services even at `aggressive`
5. After ~30–60 minutes, download the artefacts from the run's **Artifacts**
   section (or the auto-created GitHub Release).

---

## Quick Start — Local Build

Tested on Ubuntu 22.04+ and WSL2 (Ubuntu).

```bash
git clone https://github.com/Alaa91H/Porting-OneUI-9-to-Samsung-A53-5G.git
cd Porting-OneUI-9-to-Samsung-A53-5G

bash scripts/00_setup.sh                                # install toolchain
bash scripts/01_download_firmware.sh                     # fetch both firmwares
sudo bash scripts/02_extract_firmware.sh
sudo bash scripts/03_port_framework.sh
sudo bash scripts/04_debloat.sh standard                 # lite|standard|aggressive
sudo bash scripts/05_patch_target.sh
sudo bash scripts/06_repack.sh
sudo bash scripts/07_build_flashable.sh
```

Artefacts appear in `output/`:

```
output/
├── OneUI9_a53x_Port_<build>.tar.md5   # Odin AP slot
└── OneUI9_a53x_Port_<build>.zip       # TWRP / stock recovery
```

For verbose diagnostics on any stage:

```bash
DEBUG=1 bash scripts/03_port_framework.sh --debug
```

---

## Firmware Acquisition

The pipeline resolves firmware automatically via
`scripts/firmware/samfw_fetcher.py`. Resolution order:

1. **Direct URL override** (`SOURCE_FIRMWARE_URL` / `TARGET_FIRMWARE_URL`
   environment variables or GitHub Secrets) — highest priority, skips listing
   resolution.
2. **samfw.com** — fetches the firmware listing for the model/region, picks the
   newest entry (or a specific `--pda`), follows the download endpoint through
   its enforced countdown, and streams the `.tar.md5` with resume support and
   SHA-1 verification. Cloudflare's JS challenge is bypassed transparently via
   `cloudscraper`.
3. **GitHub Releases fallback** — if both above fail, the fetcher looks for a
   manually uploaded asset named `SM-S948B_*` / `SM-A536B_*` in the latest
   release of the configured repository.

### Standalone usage

```bash
# List the 5 newest firmwares for A53 5G / EUX
python3 scripts/firmware/samfw_fetcher.py list SM-A536B EUX

# Download the latest A53 5G firmware
python3 scripts/firmware/samfw_fetcher.py fetch \
    --model SM-A536B --region EUX --out downloads/

# Download a specific PDA for the S26 Ultra
python3 scripts/firmware/samfw_fetcher.py fetch \
    --model SM-S948B --region XEU --pda S948BXXUxxxx --out downloads/
```

### Manual upload (when Cloudflare blocks the runner)

1. Download the firmware yourself from
   <https://samfw.com/firmware/SM-S948B/XEU> and
   <https://samfw.com/firmware/SM-A536B/EUX>.
2. Create a GitHub Release (any tag) and upload the `.tar.md5` files as assets,
   named `SM-S948B_<pda>.tar.md5` and `SM-A536B_<pda>.tar.md5`.
3. Re-run the workflow — the fetcher will pick them up automatically.

---

## Device Configuration

Edit `config/source.env` and `config/target.env` to match the actual firmware
you are porting from/to.

```bash
# config/target.env (excerpt)
DEVICE_CODENAME=a53x
DEVICE_MODEL=SM-A536B
DEVICE_ARCH=arm64-v8a
ANDROID_VERSION=16                # after the port
ONEUI_VERSION=9.0
VENDOR_ANDROID=14                 # target vendor stays on its original Android
DYNAMIC_PARTITIONS=true
SUPER_PARTITION_SIZE=9126805504   # verify via: adb shell sm partition disk:super
EROFs_SUPPORTED=true
```

Full partition names, group names and image-format metadata live in
`config/devices.json`.

---

## Debloat Levels

Three configurable levels, defined in `debloat/debloat.conf`:

| Level | Scope | Approx. packages removed |
|---|---|---:|
| `lite` | Marketing / carrier apps (Facebook, TikTok, Netflix, Office, …) | ~15 |
| `standard` | + redundant Samsung services (Bixby, Samsung Free, AR Emoji, Galaxy Store, …) | ~45 |
| `aggressive` | + non-essential Google apps + Samsung Pay/Secure Folder/Smart View | ~80 |

- `debloat/packages_remove.list` — removal candidates, one package per line,
  annotated with the level they belong to. `#` starts a comment.
- `debloat/packages_keep.list` — protection list. Any package here is never
  removed, even if it also appears in `packages_remove.list`.
- `scripts/04_debloat.sh` applies the chosen level and silently skips packages
  not present on the device.

> [!WARNING]
> The `aggressive` level can break Samsung Pay, Secure Folder and Knox-based
> features. Start with `standard`.

---

## Flashing the Result

### Option A — TWRP / OrangeFox (recommended)

1. Boot into recovery.
2. **Backup** your current `boot`, `system`, `vendor`, `data` partitions.
3. Transfer `OneUI9_a53x_Port_<build>.zip` to the device.
4. **Install** → select the zip → **Swipe to confirm**.
5. Reboot to system (first boot may take 5–10 minutes).

### Option B — Odin (Windows)

1. Reboot to Download mode (Volume Down + Power + Bixby while connected).
2. Open Odin, load `OneUI9_a53x_Port_<build>.tar.md5` into **AP**.
3. If the package does **not** bundle `modem`/`vendor`, flash the matching
   target `CP` and `vendor`/`system` first from the original A53 firmware.
4. Click **Start**. Wait for `PASS!`, then the device reboots.

> [!CAUTION]
> Always flash with **Auto Reboot** on and **Re-Partition** off unless you know
> exactly what you are doing.

### Option C — Stock recovery

The zip uses the standard edify v3 `update-binary` + `updater-script`, so it is
accepted by stock Android recovery too (signature verification permitting).

---

## Verification & Post-flash Checks

The build pipeline runs the following sanity checks before emitting artefacts
(see `scripts/07_build_flashable.sh`):

- ✅ Critical files present (`super.img`, `boot.img`).
- ✅ `super.img` metadata is valid (`lpdump`).
- ✅ Target fingerprint present in `build.prop`
  (`ro.product.device=a53x`).
- ✅ Recovery zip contains `META-INF/com/google/android/update-binary` and
  `updater-script` plus `super.img`.
- ✅ Debloat statistics recorded in `work/port_status.env`.

After flashing, verify on the device:

```bash
adb shell getprop ro.build.version.oneui        # expect: 9.0
adb shell getprop ro.build.version.release       # expect: 16
adb shell getprop ro.product.device              # expect: a53x
adb shell getprop ro.product.model               # expect: SM-A536B
adb shell pm list packages | wc -l               # lower than stock
```

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Bootloop after flash | Vendor mismatch — flash the A53 original `vendor`/`modem` first, then the port |
| `dm-verity verification failed` | Ensure the patched `boot.img` (verity disabled) was flashed |
| Samsung Pay / Knox disabled | Expected on unlocked bootloader — cannot be reversed |
| `dump.erofs` fails | Confirm `EROFs_SUPPORTED` in `target.env` matches the image |
| GitHub Actions out of disk | Use `lite` debloat, `--no-gapps`, or enable firmware cache |
| `lpmake` size mismatch | Verify `SUPER_PARTITION_SIZE` in `target.env` against `adb shell sm partition disk:super` |
| samfw.com returns 403 | Cloudflare blocked the runner — upload firmware to GitHub Releases |
| First boot > 10 min | Normal — the system is dex-opting / migrating packages |

Enable verbose logs for any stage:

```bash
DEBUG=1 bash scripts/04_debloat.sh standard --debug
```

---

## Known Technical Limitations

These are hard technical constraints, not bugs to fix:

- **Play Integrity KEYBOX** will not pass on an unlocked bootloader (expected).
- **Knox eFuse** trips when Bootloader is unlocked — irreversible.
- **HAL compatibility** between Exynos 1280 vendor (Android 14) and One UI 9
  framework (Android 16) may be partial; some features may degrade.
- **Samsung-exclusive services** (Bixby Vision, Samsung DeX, AR Emoji) depend
  on framework + HAL cooperation and may not fully work on the A53 hardware.
- **Carrier-specific CSC features** are not migrated; only the base region
  (XEU/EUX) is preserved.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Pull requests for new debloat entries,
device configs, or alternative firmware sources are welcome.

---

## Disclaimer

This project is **not affiliated with, endorsed by, or sponsored by Samsung
Electronics**. "One UI", "Galaxy", "Samsung" and related marks are trademarks
of Samsung Electronics Co., Ltd. Use of this project is entirely at your own
risk and may void your device warranty or cause data loss or bricking.
