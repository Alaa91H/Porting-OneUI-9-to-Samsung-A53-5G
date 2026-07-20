# Contributing to One UI 9 Port

Thank you for your interest in improving this project. Contributions are
welcome in the following areas.

## Areas that welcome contributions

- **Debloat lists** — additional bloatware entries for `debloat/packages_remove.list`
  with the correct level tag, or critical packages to protect in
  `debloat/packages_keep.list`.
- **Device configs** — verified `SUPER_PARTITION_SIZE`, group names and partition
  layouts for other A53 5G CSC regions in `config/devices.json`.
- **Alternative firmware sources** — additional fetchers in
  `scripts/firmware/samfw_fetcher.py` (e.g. SamFreaks, SamFirms).
- **Bug fixes** for partition repacking, EROFS handling or build.prop patches.

## Before submitting a PR

1. Run the syntax checks locally:

   ```bash
   bash -n scripts/*.sh scripts/lib/*.sh
   python3 -c "import ast; ast.parse(open('scripts/firmware/samfw_fetcher.py',encoding='utf-8').read())"
   ```

2. If you modify a debloat list, verify the package name is correct (you can
   check with `adb shell pm list packages | grep <name>` on a stock device).

3. Keep commits focused — one logical change per commit, with a clear message
   following the existing repo style.

4. **Never** commit firmware files, secrets, keys, or large binaries. They are
   gitignored for a reason.

## Reporting issues

When reporting a build failure, include:

- The stage that failed (e.g. `03_port_framework.sh`).
- The full log output (run with `DEBUG=1`).
- The `config/target.env` values you used.
- The PDA / firmware versions of both source and target.
