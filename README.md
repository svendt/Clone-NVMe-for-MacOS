# Clone-NVMe-for-MacOS

![Version](https://img.shields.io/badge/version-2.1.0-blue)
![Platform](https://img.shields.io/badge/platform-macOS-lightgrey)
![License](https://img.shields.io/badge/license-MIT-green)

**OPNsense SSD Clone & Restore Utility for macOS:
A robust and safety‑focused disk imaging tool for macOS that allows you to clone SSDs to compressed image files (.img.gz) and restore them back to new drives. Although designed for OPNsense and Deciso hardware appliances, the script should probably also work for cloning other systems (Linux, FreeBSD, router appliances, NAS boot drives, etc.) from NVMe, SATA or USB SSDs to an image file.

The utility includes hardened safety checks, GPT integrity validation, optional SHA256 verification, progress indicators, speed limiting, and full audit logging. It has been tested on the latest version of macOS Tahoe (26.3).**

Before running the script, make it executable:
chmod +x opnsense_clone_restore.shh

Show the help screen:
./opnsense_clone_restore.sh –help

---
FEATURES
1. Backup (SSD → .img.gz)
   • Byte‑accurate cloning using raw block devices (/dev/rdiskX)
   • Optional SHA256 hashing for integrity verification
   • Automatic .size metadata file for fast restore validation
   • Progress bar, ETA and speed limiting (when pv is installed)
   • Safe temporary file handling and atomic finalization
   
2. Restore (image → SSD)
   • Full disk overwrite with safety confirmations
   • GPT header validation (primary and secondary)
   • Optional SHA256 verification of restored data
   • Post‑restore GPT verification via diskutil
   • Optional automatic mount or safe eject
   
3. Safety & Hardening
   • Internal macOS disks are blocked
   • APFS physical stores and virtual disks are blocked
   • Disk size validation prevents mismatches
   • Device re‑validation before destructive operations
   • Single‑instance locking to prevent concurrent runs
   • Sudo keep‑alive to avoid mid‑operation password prompts
  
4. Additional Capabilities
The script should be able to clone any system readable by macOS:
   • OPNsense (Deciso hardware appliances)
   • Linux installations
   • FreeBSD systems
   • Router appliances
   • NAS boot drives
   • Any NVMe/SATA/USB SSD visible in diskutil list
   
---
REQUIREMENTS
macOS built‑in tools:
diskutil, dd, gzip, shasum, awk, head, wc, tee, hexdump, plutil
Optional:
pv (for progress bar, ETA, speed limiting)

Install via Homebrew (but should be present on macOS Tahoe by default):
brew install pv

---
INSTALLATION
1. Download the script.
2. Make it executable:
chmod +x opnsenseclone_restore.shh
3. Run the help screen:
./opnsense_clone_restore.sh –help

---
USAGE OVERVIEW
When running the script, you will be asked to choose:
1. Backup  (read SSD → create .img.gz)
2. Restore (write .img.gz → SSD)

The script is fully interactive and guides you through:
   • Disk selection
   • Safety confirmations
   • Optional modes
   • Speed limits
   • Hashing options
  
---
BACKUP MODE (SSD → IMAGE)
Backup flow:
1. Select the source disk
2. Confirm safety warnings
3. Choose dry‑run or real execution
4. Choose FAST mode (skip hashing)
5. Optionally set a speed limit
6. Script unmounts the disk
7. Disk is cloned and compressed
8. gzip integrity is verified
9. .size metadata file is created
10. Optional SHA256 hash is calculated
    
---
RESTORE MODE (IMAGE → SSD)
Restore flow:
1. Select the target disk
2. Provide absolute path to .img.gz
3. gzip integrity is validated
4. Image size is checked against target disk
5. Safety confirmation required: “I AM SURE”
6. Disk is unmounted
7. Image is decompressed and written
8. GPT headers validated (primary + secondary)
9. Optional SHA256 verification
10. Post‑restore GPT verification
11. Optionally mount or eject disk
    
---
PARAMETERS & OPTIONS
Dry‑run mode:
Simulates the entire process without writing data. Perfect for testing and verifying disk selection.

FAST mode:
Skips SHA256 verification. Faster but less safe. Recommended only for trusted environments.

Speed limit (requires pv):
Allows limiting throughput (MB/s). Useful for slow USB enclosures or avoiding thermal throttling.

Progress display:
If pv is installed, you get ETA, percentage, throughput and total bytes processed.
If not installed, dd shows basic progress.

---
INTEGRITY & VERIFICATION
gzip integrity:
 Every backup and restore validates gzip structure.
 SHA256 verification (optional):
 Backup: hash of uncompressed data.
 Restore: hash of restored disk.
 Ensures bit‑perfect accuracy.
 
GPT validation:
 The script checks:
   • Primary GPT header
   • Secondary GPT header
   • Post‑restore GPT structure via diskutil verifyDisk
   
---
SAFETY WARNINGS
This script performs low‑level disk operations. Misuse can permanently destroy data.
The script blocks:
   • Internal macOS disks
   • APFS physical stores
   • Virtual disks
   • Disks whose size changes mid‑operation
You must explicitly confirm destructive actions.
Use at your own risk.

---
LOGGING
Every run generates a timestamped log file:
~/opnsenseclone_YYYYMMDD_HHHMMSS_PID.log

Logs include:
• Mode
• Disk identifiers
• Disk size
• Image path
• Duration
• Hashes
• Errors
• Final result

---
COMPATIBILITY
• Tested on the latest macOS (Tahoe 26.3)
• Works with:
  USB SSDs
  NVMe enclosures (Realtek RTL9210B recommended for speed, USB 3.x recommended)
  SATA SSDs
  Any block device visible in diskutil list
  
---
CONTRIBUTING
Pull requests and improvements are welcome.
Please maintain:
  • Safety guarantees
  • Deterministic behavior
  • Clear logging
  • macOS compatibility
If you find this script usefull, let me know in the forum!

---
LICENSE
This project is licensed under the MIT License.
You may freely use, modify, distribute and integrate it into other projects.
