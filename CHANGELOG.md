# 📋 Changelog

All notable changes to `clone_and_restore_svdt.sh` are documented here.  
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) conventions.

---

## [2.3.0] — 2026-02-24

### Added
- Compression selection menu during backup: choose between `gzip` (default, single-core), `pigz` (parallel gzip, multi-core — requires `brew install pigz`), or no compression (raw `.img`, fastest write speed)
- `pigz` auto-detection at startup — menu option shown as unavailable if not installed
- Compression setting logged to audit log per run
- Backup summary now shows selected compression method
- Restore auto-detects compression from image extension (`.img.gz` → gzip/pigz decompression, `.img` → raw passthrough) — no manual selection needed on restore

### Changed
- Image file extension is now `.img.gz` for compressed backups and `.img` for uncompressed backups
- All `gzip -c` / `gzip -dc` calls replaced with dynamic `$COMPRESS_CMD` / `$DECOMPRESS_CMD` variables throughout backup and restore pipelines
- `gzip -t` integrity check skipped when compression is disabled (no-op for raw images)
- All remaining `${PV_OPTS[@]}` expansions in restore section fixed for `set -u` compatibility (same fix as v2.2.2)

---

## [2.2.2] — 2026-02-24

### Fixed
- `${PV_OPTS[@]}` expansions on lines 549, 724, 738 and 751 caused an `unbound variable` crash under `set -u` when no bandwidth limit was set and the array was empty. Fixed by replacing `"${PV_OPTS[@]}"` with `${PV_OPTS[@]+"${PV_OPTS[@]}"}` — the array is now only expanded when it contains at least one element.

---

## [2.2.1] — 2026-02-21

### Fixed
- GPT header validation was only half-dynamic: `SECTOR_SIZE` detection was placed between the primary and secondary GPT reads, so the primary header still used a hardcoded `bs=512` — causing it to read from the wrong byte offset on 4K-native drives. `SECTOR_SIZE` is now detected once, before both reads, and `bs="$SECTOR_SIZE"` is used consistently for both primary and secondary GPT header reads.

---

## [2.2.0] — 2026-02-21

### Added
- `--version` flag: prints script name and version number then exits
- `.img.gz.sha256` sidecar file: SHA256 hash saved alongside the image during backup for portable, external verification
- Dynamic sector size detection: GPT header validation now reads actual block size from `diskutil` (`DeviceBlockSize`) instead of assuming 512 bytes — correctly handles 4K native drives
- Richer restore pre-flight summary: now shows detected block size, `pv` status (installed or not), and expected SHA256 if `.sha256` sidecar is present
- Sidecar files section in `--help` output explaining all three sidecar files and their purpose

### Changed
- Restore pipeline simplified when `.sha256` sidecar is present — no `tee` subshell overhead during write since hash is already known
- `diskutil verifyDisk` warning before restore now explains that failures on blank or uninitialized disks are normal and expected
- APFS container warning in disk selection no longer references specific disk numbers (disk2, disk3) — uses generic description instead
- `dd` block size changed from `bs=4M` to `bs=4m` throughout for BSD dd compatibility on all macOS versions
- `dd status=none` and `dd status=progress` removed — not supported by macOS BSD dd; replaced with `2>/dev/null` suppression and `Ctrl+T` hint for no-pv fallback
- SHA256 read-back during restore now uses `head -c` instead of `dd bs=1 count=N` — functionally identical but orders of magnitude faster on large disks
- `IO_DEVICE` added to variable initialization block

---

## [2.1.1] — 2026-02-21

### Changed
- Removed inline version history from script itself (now tracked here)
- Extended built-in `--help` output with more detail
- Script made fully generic — works with any macOS-readable block device, not tied to any specific system or appliance type

---

## [2.1.0] — 2026-02-20

### Changed
- Consistent section header widths and ALL CAPS titles throughout script
- Helper functions grouped into a dedicated section for clarity
- Added missing section headers for better readability

---

## [2.0.0] — 2026-02-20

### Changed
- `PV_OPTS` refactored to a proper bash array (fixes unsafe word-splitting)
- Image size now read from `.size` sidecar file — avoids a costly full decompression just to get size
- `ORIGINAL_SIZE` and `IMAGE_SIZE` validation checks merged into a single consolidated block

---

## [1.5.0] — 2026-02-20

### Changed
- Optimizations following code review

---

## [1.4.0] — 2026-02-20

### Fixed
- Performance improvements and general bug fixes

---

## [1.3.0] — 2026-02-20

### Added
- ETA and percentage completion display during clone and restore operations

---

## [1.2.0] — 2026-02-20

### Added
- Single-instance locking mechanism to prevent concurrent runs

---

## [1.1.0] — 2026-02-20

### Fixed
- Bug fixes following extensive real-world testing

---

## [1.0.0] — 2026-02-20

### Added
- Initial release
