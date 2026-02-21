<div align="center">

# 🖥️ clone_and_restore_svdt.sh

### A robust, safety-hardened SSD imaging tool for macOS

[![Platform](https://img.shields.io/badge/platform-macOS-lightgrey?logo=apple)](https://www.apple.com/macos/)
[![Shell](https://img.shields.io/badge/shell-bash-blue?logo=gnu-bash)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Tested on](https://img.shields.io/badge/tested%20on-macOS%20Sequoia-brightgreen)](https://www.apple.com/macos/)
[![Latest Release](https://img.shields.io/github/v/release/yourusername/yourrepo?label=version&color=orange)](https://github.com/yourusername/yourrepo/releases/latest)

Clone any external SSD to a compressed image file and restore it back — with GPT validation, SHA256 integrity checks, progress bars, speed limiting, and full audit logging.

</div>

---

## 📖 Overview

`clone_and_restore_svdt.sh` is a fully interactive macOS shell script that performs **byte-accurate disk imaging** of external drives. It reads any block device visible to macOS and writes it to a compressed `.img.gz` file, or restores such an image back to a target disk.

It works with any system whose drive macOS can read:

> Linux · FreeBSD · router appliances · NAS boot drives · network firewall systems · or any NVMe / SATA / USB SSD visible in `diskutil list`

The script was built with a **safety-first** philosophy: it won't touch your internal macOS disk, validates GPT integrity before and after restore, requires explicit typed confirmation for destructive operations, and uses instance locking to prevent concurrent runs.

---

## ⚡ Quick Start

```bash
# 1. Make executable
chmod +x clone_and_restore_svdt.sh

# 2. Show help
./clone_and_restore_svdt.sh --help

# 3. Show version
./clone_and_restore_svdt.sh --version

# 4. Run interactively
./clone_and_restore_svdt.sh
```

> 💡 **Hardware tip:** Use USB 3.x enclosures — USB 2.x tops out around 30 MB/s in practice.  
> For Apple Silicon Macs, an NVMe enclosure with the **Realtek RTL9210B** chipset gives the best transfer speeds.  
> Example: [UGREEN NVMe Enclosure (Amazon.be)](https://www.amazon.com.be/dp/B09T8P9LKQ)

---

## ✨ Features

### 🔒 Backup — SSD → `.img.gz`

| Feature | Details |
|---|---|
| Byte-accurate cloning | Uses raw block devices (`/dev/rdiskX`) via `dd` |
| Compression | gzip on-the-fly; integrity verified after write |
| Metadata | `.size` sidecar auto-generated for fast restore validation |
| Integrity | Optional SHA256 hash saved to `.sha256` sidecar file |
| Progress | ETA, throughput, percentage via `pv` (if installed) |
| Speed limiter | Throttle throughput in MB/s to protect slow enclosures |
| Safe finalization | Atomic temp-file handling — no corrupt partial images |

### 🔄 Restore — `.img.gz` → SSD

| Feature | Details |
|---|---|
| Pre-restore checks | gzip integrity + image size vs. target disk validation |
| Safety gate | Must type `I AM SURE` to proceed |
| Rich summary | Shows block size, pv status, expected SHA256 if sidecar available |
| GPT validation | Primary + secondary GPT headers checked post-restore; dynamic sector size (512b / 4K native) |
| SHA256 verify | Restored disk hash compared against `.sha256` sidecar or computed on-the-fly |
| Post-restore | `diskutil verifyDisk` run automatically |
| Cleanup | Optional auto-mount or safe eject when done |

### 🛡️ Safety & Hardening

- Internal macOS disks are **blocked** — you cannot accidentally wipe your system drive
- APFS physical stores and virtual disks are **blocked**
- Disk size is re-validated immediately before any destructive write
- Single-instance locking prevents two runs operating simultaneously
- `sudo` keep-alive prevents password prompts from interrupting a mid-operation clone

---

## 🔁 Workflow

```
Run script
    │
    ├─ [1] BACKUP ──────► Select source disk
    │                      Confirm warnings
    │                      Choose dry-run or real
    │                      Choose FAST mode (skip SHA256)
    │                      Set optional speed limit
    │                      Script unmounts disk
    │                      dd | gzip ──► .img.gz
    │                      gzip integrity check
    │                      .size sidecar written
    │                      .sha256 sidecar written
    │                      Disk ejected
    │
    └─ [2] RESTORE ─────► Select target disk
                           Provide path to .img.gz
                           gzip integrity validated
                           Size checked vs. target
                           Set optional speed limit
                           Summary: block size, pv, SHA256
                           Type "I AM SURE" to confirm
                           Disk unmounted
                           gzip -dc | dd ──► disk
                           GPT headers validated
                           SHA256 verified vs. sidecar
                           diskutil verifyDisk
                           Mount or eject
```

---

## ⚙️ Options & Modes

| Mode | Description |
|---|---|
| **Dry-run** | Simulates the full process without writing anything — great for verifying disk selection and estimating duration |
| **FAST mode** | Skips SHA256 hashing for maximum speed. Recommended only when integrity verification isn't required |
| **Speed limit** | Requires `pv`. Caps throughput in MB/s for both backup and restore — useful on slow USB enclosures or when avoiding thermal throttling. Only prompted when `pv` is installed. |
| **Progress display** | With `pv`: ETA, %, throughput, total bytes. Without `pv`: press Ctrl+T for a status update |
| **`--help`** | Show full help screen and exit |
| **`--version`** | Show version number and exit |

---

## 🗂️ Sidecar Files

Each backup produces up to three files — keep them together when moving a backup:

| File | Purpose |
|---|---|
| `prefix_date_hash.img.gz` | The compressed disk image |
| `prefix_date_hash.img.gz.size` | Uncompressed byte count — enables fast restore size validation |
| `prefix_date_hash.img.gz.sha256` | SHA256 hash of uncompressed data — used for bit-perfect restore verification |

> The `.sha256` sidecar is skipped when running in FAST mode. If it is present at restore time, the restore pipeline is simplified (no tee overhead) and the expected hash is shown in the pre-restore summary.

---

## 🔐 Integrity & Verification

Every backup and restore validates gzip structure automatically. In addition:

- **SHA256 (backup):** Hash of uncompressed raw data before compression
- **SHA256 (restore):** Hash of the restored disk immediately after write — compared against backup hash for bit-perfect confirmation
- **GPT validation:** Primary header, secondary header, and `diskutil verifyDisk` structure check run post-restore

---

## 📋 Requirements

**Built-in macOS tools (no installation needed):**

```
diskutil  dd  gzip  shasum  awk  head  wc  tee  hexdump  plutil
```

**Optional — strongly recommended:**

`pv` enables the progress bar, ETA, throughput display, and speed limiting. Without it the script falls back to basic `dd` status output.

**Step 1 — Install Homebrew** (if not already installed):
```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

**Step 2 — Add Homebrew to your PATH** (required on Apple Silicon Macs — do this once):
```bash
echo >> ~/.zprofile
echo 'eval "$(/opt/homebrew/bin/brew shellenv zsh)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv zsh)"
```

**Step 3 — Install pv:**
```bash
brew install pv
```

The script auto-detects `pv` on every run — no configuration needed.

---

## 📦 Compatibility

| Disk interface | Supported |
|---|---|
| USB 2.0 / 3.x SSDs | ✅ |
| NVMe enclosures | ✅ (RTL9210B recommended for Apple Silicon) |
| SATA SSDs | ✅ |
| Any block device in `diskutil list` | ✅ |

**Guest OS / system types that can be cloned (non-exhaustive):**

- Linux (any distribution)
- FreeBSD and derivatives
- Network firewall appliances (OPNsense, pfSense, etc.)
- NAS boot drives
- Router and embedded systems

---

## 📄 Logging

Every run generates a timestamped log file:

```
~/clone_and_restore_svdt_YYYYMMDD_HHMMSS_PID.log
```

Logs capture: mode · disk identifiers · disk size · image path · duration · SHA256 hashes · errors · final result.

---

## ⚠️ Safety Warnings

> **This script performs low-level disk operations. Misuse can permanently destroy data.**

The script actively blocks:
- Your internal macOS boot disk
- APFS physical stores and virtual disks
- Any disk whose size changes between selection and write

Destructive operations always require **explicit typed confirmation**. Use at your own risk.

---

## 🤝 Contributing

Pull requests and improvements are welcome. Please maintain:

- The existing safety guarantees (no weakening of checks)
- Deterministic, predictable behavior
- Clear and complete logging
- Full macOS compatibility

---

## 📜 License

This project is licensed under the **MIT License** — you may freely use, modify, distribute, and integrate it into other projects.

---

<div align="center">
<sub>© 2026 SVDT</sub>
</div>
