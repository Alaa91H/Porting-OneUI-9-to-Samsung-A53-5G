# AGENTS.md — Operating instructions for AI coding agents (Kilo, Claude, etc.)

## Project overview

This repository ports **One UI 9** (Android 16) from the Samsung Galaxy S26
Ultra (`SM-S948B`, codename `s26x`) to the Samsung Galaxy A53 5G (`SM-A536B`,
codename `a53x`), with a configurable debloat stage. The entire build runs on
GitHub Actions via a numbered pipeline of Bash scripts.

## Repository layout

- `config/` — device settings (`source.env`, `target.env`, `devices.json`).
- `scripts/` — numbered pipeline scripts (`00`–`07`). Each is self-contained.
- `scripts/lib/common.sh` — shared helpers (logging, image ops, super.img).
- `scripts/firmware/samfw_fetcher.py` — firmware fetcher (Cloudflare bypass).
- `debloat/` — removal/keep lists and level configuration.
- `patches/` — `build.prop`, vintf and SELinux patches.
- `output/` — build artefacts (gitignored): `.tar.md5` (Odin) and `.zip` (TWRP).
- `work/`, `downloads/` — intermediate files (gitignored).

## Key commands

```bash
# Install toolchain (Ubuntu/WSL)
bash scripts/00_setup.sh

# Full pipeline (requires firmware URLs in env/secrets)
bash scripts/01_download_firmware.sh
sudo bash scripts/02_extract_firmware.sh
sudo bash scripts/03_port_framework.sh
sudo bash scripts/04_debloat.sh standard        # lite|standard|aggressive
sudo bash scripts/05_patch_target.sh
sudo bash scripts/06_repack.sh
sudo bash scripts/07_build_flashable.sh

# Debug any stage
DEBUG=1 bash scripts/03_port_framework.sh --debug
```

## Health checks (lint / typecheck)

The project is Bash + Python. Validate syntax with:

```bash
# Bash syntax check (no execution)
bash -n scripts/*.sh scripts/lib/*.sh
# Or, if shellcheck is available:
shellcheck scripts/*.sh scripts/lib/*.sh

# Python fetcher syntax
python3 -c "import ast; ast.parse(open('scripts/firmware/samfw_fetcher.py',encoding='utf-8').read())"
```

There is **no `npm run lint`**. Use `bash -n` for Bash and `ast.parse` for the
Python fetcher.

## Editing rules

- Scripts are numbered sequentially — **do not reorder or renumber them**.
- Every script starts with
  `source "$(dirname "$0")/lib/common.sh"`.
- Never commit secrets (firmware URLs, keys). Use GitHub Secrets.
- Comments may be in English (preferred for this repo) — variable names must
  be English.
- The following are device facts, not variables to guess: `a53x` (target),
  `s26x` (source), `SM-A536B` (target model), `SM-S948B` (source model).
- When adding firmware sources, extend `scripts/firmware/samfw_fetcher.py`
  rather than adding ad-hoc download code in the Bash pipeline.

## Known technical limitations (do not attempt to "fix")

- **Play Integrity KEYBOX** will not pass on an unlocked bootloader (expected).
- **Knox eFuse** trips on Bootloader unlock — irreversible.
- **HAL compatibility** between Exynos 1280 (Android 14 vendor) and the One UI 9
  framework (Android 16) may be partial.
- **Cloudflare on samfw.com** may intermittently block the CI runner. The
  GitHub Releases fallback exists for this reason — do not try to bypass
  Cloudflare with captcha-solving services.

## CI behaviour

- The workflow at `.github/workflows/build-port.yml` runs the full pipeline on
  `ubuntu-22.04` and uploads both artefacts, plus creates a prerelease GitHub
  Release tagged `port-v<run_number>`.
- Firmware is cached via `actions/cache` keyed on the commit SHA, so re-runs
  within the same commit skip re-downloading.
- If `skip_download` is true, the workflow restores the firmware cache instead
  of resolving from samfw.com.
