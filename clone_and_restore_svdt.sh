#!/usr/bin/env bash

#####################################################################################################################################################
# clone_and_restore_svdt.sh — SSD Clone & Restore Utility for macOS
# Clones any external SSD to a compressed image file (.img.gz) and restores it back.
# Works with Linux, FreeBSD, router/firewall appliances, NAS boot drives, and any
# NVMe, SATA or USB SSD visible in diskutil list.
# See README.md for full documentation. See CHANGELOG.md for version history.
SCRIPT_VERSION="2.2.1"
SCRIPT_NAME="SSD Clone & Restore Utility"
SCRIPT_YEAR="2026"
SCRIPT_AUTHOR="SVDT"
# Distributed under the MIT License
#####################################################################################################################################################

set -euo pipefail
umask 077

#############################################
# SINGLE INSTANCE LOCK (macOS safe)
#############################################

cleanup() {
  if [[ -n "${TMP_HASH:-}" && -f "$TMP_HASH" ]]; then
    rm -f "$TMP_HASH"
  fi
  if [[ -n "${TMP_IMAGE:-}" && -f "$TMP_IMAGE" ]]; then
    rm -f "$TMP_IMAGE"
  fi
  if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  fi
  if [[ -n "${LOCKDIR:-}" && -d "$LOCKDIR" ]]; then
    rm -rf "$LOCKDIR"
  fi
}

trap cleanup EXIT

LOCKDIR="/tmp/clone_and_restore_svdt_${UID}.lock"

if mkdir "$LOCKDIR" 2>/dev/null; then
  echo "$$" > "$LOCKDIR/pid"
else
  if [[ -f "$LOCKDIR/pid" ]]; then
    OLD_PID=$(cat "$LOCKDIR/pid" 2>/dev/null || echo "")
    if [[ -n "$OLD_PID" ]] && ! kill -0 "$OLD_PID" 2>/dev/null; then
      echo "Stale lock detected, removing..."
      rm -rf "$LOCKDIR" || exit 1
      if ! mkdir "$LOCKDIR"; then
        echo "Unable to acquire lock after stale removal."
        exit 1
      fi
      echo "$$" > "$LOCKDIR/pid"
    else
      echo "Another instance is already running."
      exit 1
    fi
  else
    echo "Stale lock without PID detected, removing..."
    rm -rf "$LOCKDIR" || exit 1
    mkdir "$LOCKDIR" || exit 1
    echo "$$" > "$LOCKDIR/pid"
  fi

fi

# Capture pv full path before restricting PATH (Homebrew installs to /opt/homebrew/bin on Apple Silicon)
PV_BIN=$(command -v pv 2>/dev/null || true)

# Lock down PATH to trusted system binaries
export PATH="/usr/sbin:/usr/bin:/bin:/sbin"

LOG="${HOME}/clone_and_restore_svdt_$(date +%Y%m%d_%H%M%S)_$$.log"
TMP_HASH=""
TMP_IMAGE=""
MODE=""
DEVICE=""
IO_DEVICE=""
IMAGE=""
DISK_SIZE=""
IMAGE_SIZE=""
FAST_MODE=0
DRY_RUN=0
USE_PV=0
PV_OPTS=()
SUDO_KEEPALIVE_PID=""

#############################################
# HELPER FUNCTIONS
#############################################

cleanup_orphan_tmp() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  find "$dir" -maxdepth 1 -type f -name "*.tmp.*" -mmin +10 2>/dev/null \
    -exec rm -f -- {} \;
}

show_device_details() {
  local device="$1"
  local INFO
  INFO=$(diskutil info -plist "$device" 2>/dev/null) || return

  local VENDOR MEDIA SERIAL PROTOCOL LOCATION
  VENDOR=$(echo "$INFO"   | plutil -extract DeviceVendor   raw - 2>/dev/null || echo "Unknown")
  MEDIA=$(echo "$INFO"    | plutil -extract MediaName      raw - 2>/dev/null || echo "Unknown")
  SERIAL=$(echo "$INFO"   | plutil -extract SerialNumber   raw - 2>/dev/null || echo "Unknown")
  PROTOCOL=$(echo "$INFO" | plutil -extract BusProtocol    raw - 2>/dev/null || echo "Unknown")
  LOCATION=$(echo "$INFO" | plutil -extract DeviceLocation raw - 2>/dev/null || echo "Unknown")

  echo -e "${YELLOW}--- Target Disk Details ---${NC}"
  echo "Device:      $device"
  echo "Vendor:      $VENDOR"
  echo "Media Name:  $MEDIA"
  echo "Serial:      $SERIAL"
  echo "Protocol:    $PROTOCOL"
  echo "Location:    $LOCATION"
  echo -e "${YELLOW}----------------------------${NC}"
}

#############################################
# COLORS
#############################################

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
NC="\033[0m"

#############################################
# INTERRUPT HANDLER (CTRL+C / SIGTERM)
#############################################

interrupt_handler() {
  echo
  echo -e "${RED}Operation interrupted by user.${NC}" >&2
  {
    echo "result=INTERRUPTED"
    echo "error_message=Operation interrupted by signal"
    echo "exit_code=130"
  } >> "$LOG"
  exit 130
}

trap interrupt_handler INT TERM

error_exit() {
  local msg="$1"
  local code="${2:-1}"
  echo -e "${RED}ERROR: ${msg}${NC}" >&2
  {
    echo "result=FAILURE"
    echo "error_message=${msg}"
    echo "exit_code=${code}"
  } >> "$LOG"
  exit "$code"
}

#############################################
# HELP
#############################################

usage() {
  echo -e "${BLUE}${SCRIPT_NAME} v${SCRIPT_VERSION} — (c) ${SCRIPT_YEAR} ${SCRIPT_AUTHOR}${NC}"
  echo
  echo "  A safety-hardened disk imaging tool for macOS."
  echo "  Clones any external SSD to a compressed .img.gz file and restores it back."
  echo "  Works with Linux, FreeBSD, router/firewall appliances, NAS drives,"
  echo "  and any NVMe, SATA or USB SSD visible in diskutil list."
  echo
  echo -e "${YELLOW}USAGE${NC}"
  echo "  ./clone_and_restore_svdt.sh"
  echo "  ./clone_and_restore_svdt.sh --help"
  echo
  echo -e "${YELLOW}MODES${NC}"
  echo "  When launched, you will be prompted to choose:"
  echo "  1) Backup  — reads a source SSD and writes a compressed .img.gz image file"
  echo "  2) Restore — decompresses an .img.gz image and writes it back to a target SSD"
  echo
  echo -e "${YELLOW}BACKUP FLOW${NC}"
  echo "  1. Select the source disk (external only — internal Mac disk is blocked)"
  echo "  2. Confirm disk selection (type YES)"
  echo "  3. Choose dry-run mode (simulates without writing)"
  echo "  4. Choose FAST mode (skips SHA256 hashing for speed)"
  echo "  5. Optionally set a throughput speed limit in MB/s (requires pv)"
  echo "  6. Enter output image filename prefix (default: disk_backup)"
  echo "  7. Confirm start (type YES)"
  echo "  8. Script unmounts disk, clones via dd | gzip to a temp file"
  echo "  9. gzip integrity is verified, temp file is atomically renamed"
  echo " 10. A .size metadata sidecar file is created alongside the image"
  echo " 11. Optional SHA256 hash computed and saved to a .sha256 sidecar file"
  echo " 12. Disk is ejected"
  echo
  echo -e "${YELLOW}RESTORE FLOW${NC}"
  echo "  1. Select the target disk (external only — internal Mac disk is blocked)"
  echo "  2. Confirm disk selection (type YES)"
  echo "  3. Choose dry-run mode (simulates without writing)"
  echo "  4. Choose FAST mode (skips SHA256 verification)"
  echo "  5. Provide absolute path to the .img.gz image file"
  echo "  6. gzip integrity is validated"
  echo "  7. Image size is checked against target disk capacity"
  echo "  8. Restore summary shown (incl. expected SHA256 if .sha256 sidecar exists)"
  echo "  9. Type I AM SURE to confirm"
  echo " 10. Disk is unmounted"
  echo " 11. Image is decompressed and written to disk via gzip | dd"
  echo " 12. Primary and secondary GPT headers are validated"
  echo " 13. Optional SHA256 hash of restored disk compared to .sha256 sidecar"
  echo " 14. diskutil verifyDisk run post-restore"
  echo " 15. Choice to mount disk or safely eject"
  echo
  echo -e "${YELLOW}SIDECAR FILES${NC}"
  echo "  Each backup produces up to three files alongside the .img.gz:"
  echo "  .img.gz        — the compressed disk image"
  echo "  .img.gz.size   — uncompressed byte count for fast restore validation"
  echo "  .img.gz.sha256 — SHA256 hash of uncompressed data (skipped in FAST mode)"
  echo "  Keep all three files together when moving a backup."
  echo
  echo -e "${YELLOW}OPTIONS${NC}"
  echo "  --help           Show this help screen and exit"
  echo "  --version        Show version number and exit"
  echo
  echo -e "${YELLOW}INTERACTIVE OPTIONS (prompted at runtime)${NC}"
  echo "  Dry-run          Simulates the full operation without reading or writing"
  echo "                   any data. Use to verify disk selection and flow."
  echo "  FAST mode        Skips SHA256 hashing. Faster, but no integrity guarantee."
  echo "                   Recommended only in trusted environments."
  echo "  Speed limit      Caps throughput in MB/s. Applies to both backup and restore."
  echo "                   Only prompted if pv is installed (brew install pv)."
  echo "                   Useful for slow USB enclosures or to avoid thermal throttling."
  echo "                   If pv is not installed, this option is silently skipped."
  echo
  echo -e "${YELLOW}REQUIREMENTS${NC}"
  echo "  Built-in (no install needed): diskutil dd gzip shasum awk head wc tee hexdump plutil"
  echo "  Optional (strongly recommended): pv — enables progress bar, ETA, throughput display, speed limiting"
  echo
  echo "  To install pv:"
  echo "  Step 1 — Install Homebrew (if not already installed):"
  echo "    /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
  echo "  Step 2 — Add Homebrew to your PATH (required on Apple Silicon — do this once):"
  echo "    echo >> ~/.zprofile"
  echo "    echo 'eval \"\$(/opt/homebrew/bin/brew shellenv zsh)\"' >> ~/.zprofile"
  echo "    eval \"\$(/opt/homebrew/bin/brew shellenv zsh)\""
  echo "  Step 3 — Install pv:"
  echo "    brew install pv"
  echo "  The script auto-detects pv on every run — no configuration needed."
  echo
  echo -e "${YELLOW}SAFETY${NC}"
  echo "  - Internal macOS disks (disk0) are blocked unconditionally"
  echo "  - APFS physical stores and virtual disks are blocked"
  echo "  - Disk size is re-validated immediately before any destructive write"
  echo "  - Single-instance locking prevents concurrent runs"
  echo "  - sudo keep-alive prevents password prompts mid-operation"
  echo "  - Restore requires typing I AM SURE as explicit confirmation"
  echo "  - All operations are logged to a timestamped file in your home directory"
  echo
  echo -e "${YELLOW}LOGGING${NC}"
  echo "  Every run writes a log file to:"
  echo "  ~/clone_and_restore_svdt_YYYYMMDD_HHMMSS_PID.log"
  echo "  Logs include: mode, disk identifiers, disk size, image path,"
  echo "  duration, SHA256 hashes, errors, and final result."
  echo
  echo -e "${YELLOW}HARDWARE TIP${NC}"
  echo "  Use USB 3.x enclosures — USB 2.x tops out around 30 MB/s in practice."
  echo "  For Apple Silicon Macs, an NVMe enclosure with Realtek RTL9210B"
  echo "  chipset gives the best transfer speeds."
  echo
  echo -e "${YELLOW}LICENSE${NC}"
  echo "  MIT License — (c) ${SCRIPT_YEAR} ${SCRIPT_AUTHOR}"
  echo "  Freely use, modify, distribute and integrate into other projects."
  echo
  exit 0
}

[[ "${1:-}" == "--help" ]] && usage
[[ "${1:-}" == "--version" ]] && { echo "${SCRIPT_NAME} v${SCRIPT_VERSION}"; exit 0; }

#############################################
# REQUIRED TOOLS
#############################################

for cmd in diskutil dd gzip shasum awk head wc tee hexdump plutil; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo -e "${RED}Missing required tool: $cmd${NC}"
    exit 1
  }
done

#############################################
# OPTIONAL: PV PROGRESS TOOL
#############################################

if [[ -n "$PV_BIN" && -x "$PV_BIN" ]]; then
  USE_PV=1
fi

#############################################
# REQUIRE SUDO UPFRONT
#############################################

echo -e "${BLUE}Validating sudo access...${NC}"
sudo -v || error_exit "sudo validation failed"

# Keep sudo session alive during long operations
(
  while true; do
    sudo -n true
    sleep 60
  done
) &
SUDO_KEEPALIVE_PID=$!

echo -e "${BLUE}${SCRIPT_NAME} v${SCRIPT_VERSION} — (c) ${SCRIPT_YEAR} ${SCRIPT_AUTHOR}${NC}"
NOW_TS="$(date '+%Y-%m-%d %H:%M:%S')"
echo "$NOW_TS" | tee -a "$LOG"
echo

#############################################
# MODE
#############################################

echo -e "${BLUE}Select mode:${NC}"
echo "1) Backup  (read SSD → create .img.gz)"
echo "2) Restore (write .img.gz → SSD)"
read -rp "Choice (1/2): " MODE
[[ "$MODE" == "1" || "$MODE" == "2" ]] || error_exit "Invalid mode selection"

MODE_STR="unknown"
[[ "$MODE" == "1" ]] && MODE_STR="backup"
[[ "$MODE" == "2" ]] && MODE_STR="restore"

#############################################
# DISK SELECTION HELP
#############################################

echo
echo -e "${BLUE}=== Disk Selection Help ===${NC}"

if [[ "$MODE" == "1" ]]; then
  echo -e "${GREEN}Backup mode selected.${NC}"
  echo -e "Select the ${YELLOW}source SSD${NC} to clone (e.g. an external USB, SATA or NVMe drive)."
else
  echo -e "${GREEN}Restore mode selected.${NC}"
  echo -e "Select the ${YELLOW}target SSD${NC} that will be overwritten."
  echo -e "This SSD will be ${RED}fully erased${NC}."
fi

echo
echo -e "${YELLOW}Do NOT select:${NC}"
echo -e "  - ${RED}disk0${NC} (internal Mac disk — blocked)"
echo -e "  - APFS synthesized containers (shown as virtual disks in diskutil list)"
echo -e "  - Any disk marked as ${RED}Internal: Yes${NC}"
echo -e "  - Any disk marked as ${RED}Virtual: Yes${NC}"
echo
echo -e "${BLUE}Your current disks:${NC}"
sudo diskutil list
echo

#############################################
# DISK INPUT
#############################################

read -rp "Enter physical disk identifier (e.g. disk4): " DISK
[[ -n "$DISK" ]] || error_exit "No disk specified"
[[ "$DISK" != "disk0" ]] || error_exit "disk0 is blocked (internal Mac disk)"

DEVICE="/dev/${DISK}"
RAW_DEVICE="/dev/r${DISK}"

[[ -b "$DEVICE" ]] || error_exit "Invalid device: $DEVICE"

# Use raw device if available (faster), otherwise fallback
if [[ -b "$RAW_DEVICE" ]]; then
  IO_DEVICE="$RAW_DEVICE"
else
  IO_DEVICE="$DEVICE"
fi
echo -e "${BLUE}Using device: ${GREEN}${IO_DEVICE}${NC}"

#############################################
# HARDENED DISK VALIDATION (single plist)
#############################################

DISK_INFO_PLIST="$(diskutil info -plist "$DEVICE" 2>/dev/null)" \
  || error_exit "Failed to read disk info (plist)"

INTERNAL_FLAG=$(echo "$DISK_INFO_PLIST" \
  | plutil -extract Internal raw - 2>/dev/null || echo "unknown")

VIRTUAL_FLAG=$(echo "$DISK_INFO_PLIST" \
  | plutil -extract Virtual raw - 2>/dev/null || echo "unknown")

APFS_PHYSICAL=$(echo "$DISK_INFO_PLIST" \
  | plutil -extract APFSPhysicalStore raw - 2>/dev/null || echo "false")

DISK_SIZE=$(echo "$DISK_INFO_PLIST" \
  | plutil -extract TotalSize raw - 2>/dev/null)

[[ "$INTERNAL_FLAG" == "true" ]] && error_exit "Internal disk blocked"
[[ "$VIRTUAL_FLAG" == "true" ]] && error_exit "Virtual/synthesized disk blocked"
[[ "$APFS_PHYSICAL" == "true" ]] && error_exit "APFS Physical Store blocked"
[[ -z "$DISK_SIZE" ]] && error_exit "Unable to determine disk size"

echo -e "Detected disk size: ${GREEN}${DISK_SIZE} bytes${NC}"
read -rp "Type YES to confirm disk selection: " CONFIRM_DISK
[[ "$CONFIRM_DISK" == "YES" ]] || error_exit "Disk selection not confirmed"

#############################################
# DRY RUN
#############################################

read -rp "Enable dry-run? (yes/no): " DRY
DRY_RUN=0
[[ "$DRY" == "yes" ]] && DRY_RUN=1

#############################################
# FAST MODE
#############################################

read -rp "Enable FAST mode (skip hashing)? (yes/no): " FAST
FAST_MODE=0
[[ "$FAST" == "yes" ]] && FAST_MODE=1

#############################################
# SPEED LIMIT
#############################################

if [[ "$USE_PV" -eq 1 ]]; then
  read -rp "Speed limit MB/s (Enter for none): " LIMIT

  if [[ -n "${LIMIT:-}" ]]; then
    if [[ "$LIMIT" =~ ^[0-9]+$ ]]; then
      PV_OPTS=("-L" "${LIMIT}m")
    else
      echo -e "${YELLOW}Invalid speed limit ignored.${NC}"
    fi
  fi
fi

#############################################
# LOG RUN PARAMETERS (AUDIT)
#############################################

{
  echo "--------------------------------------------"
  echo "timestamp=${NOW_TS}"
  echo "mode=${MODE_STR}"
  echo "device=${DEVICE}"
  echo "disk_size=${DISK_SIZE}"
  echo "dry_run=${DRY_RUN}"
  echo "fast_mode=${FAST_MODE}"
} >> "$LOG"

#############################################
# BACKUP
#############################################

if [[ "$MODE" == "1" ]]; then

  read -rp "Filename prefix (default: disk_backup): " PREFIX
  PREFIX=${PREFIX:-disk_backup}

  TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  SALT=$(head -c 16 /dev/urandom | shasum -a 256 | awk '{print $1}')
  SHORT_HASH=$(printf "%s" "${DISK}_${TIMESTAMP}_${SALT}" | shasum -a 256 | awk '{print $1}' | cut -c1-8)

  DEFAULT_IMAGE="${HOME}/${PREFIX}_${TIMESTAMP}_${SHORT_HASH}.img.gz"

  echo -e "${BLUE}Backup image will be:${NC} ${GREEN}${DEFAULT_IMAGE}${NC}"
  read -rp "Image path [default above]: " IMAGE
  IMAGE=${IMAGE:-$DEFAULT_IMAGE}

  cleanup_orphan_tmp "$(dirname "$IMAGE")"

  [[ -e "$IMAGE" ]] && error_exit "Image file already exists (noclobber active)"

  mkdir -p -- "$(dirname "$IMAGE")"

  {
    echo "image_path=${IMAGE}"
  } >> "$LOG"

  echo
  echo -e "${BLUE}=== Backup summary ===${NC}"
  echo -e "Mode:        ${GREEN}backup${NC}"
  echo -e "Source disk: ${GREEN}${DEVICE}${NC}"
  echo -e "Disk size:   ${GREEN}${DISK_SIZE} bytes${NC}"
  echo -e "Image file:  ${GREEN}${IMAGE}${NC}"
  echo -e "FAST mode:   ${GREEN}$([[ $FAST_MODE -eq 1 ]] && echo enabled || echo disabled)${NC}"
  echo -e "Dry-run:     ${GREEN}$([[ $DRY_RUN -eq 1 ]] && echo yes || echo no)${NC}"
  echo
  read -rp "Type YES to start backup: " CONFIRM
  [[ "$CONFIRM" == "YES" ]] || error_exit "Backup not confirmed"

  #############################################
  # FINAL DEVICE VALIDATION (pre-backup)
  #############################################

  # Re-check device still exists
  [[ -b "$IO_DEVICE" ]] || error_exit "Device disappeared before backup"

  # Re-check disk size (anti device swap protection)
  CURRENT_SIZE=$(diskutil info -plist "$DEVICE" \
    | plutil -extract TotalSize raw - 2>/dev/null || echo "")

  [[ -n "$CURRENT_SIZE" && "$CURRENT_SIZE" -eq "$DISK_SIZE" ]] \
    || error_exit "Disk size changed before backup (device may have been swapped)"

  # Dry-run exit before destructive actions
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo -e "${YELLOW}[DRY RUN] Backup skipped.${NC}"
    echo "result=DRY-RUN" >> "$LOG"
    exit 0
  fi

  #############################################
  # READ-ONLY PARTITION CHECK
  #############################################

  diskutil list "$DEVICE" \
    | awk '/disk[0-9]+s[0-9]+/ {print $NF}' \
    | while read -r part; do
        INFO=$(diskutil info -plist "/dev/$part" 2>/dev/null || true)
        RO=$(echo "$INFO" | plutil -extract ReadOnly raw - 2>/dev/null || echo "false")
        if [[ "$RO" == "true" ]]; then
          echo -e "${YELLOW}Warning: /dev/$part is read-only (will be unmounted before dd).${NC}"
        fi
      done

  #############################################
  # START BACKUP
  #############################################

  START=$(date +%s)

  sudo diskutil unmountDisk "$DEVICE" \
    || error_exit "Failed to unmount disk before backup"

  TMP_IMAGE="${IMAGE}.tmp.$$"

  if [[ -e "$TMP_IMAGE" ]]; then
    error_exit "Temporary image file already exists: $TMP_IMAGE"
  fi

  if [[ "$USE_PV" -eq 1 ]]; then
    echo -e "${BLUE}Starting backup with progress + ETA...${NC}"
    sudo dd if="$IO_DEVICE" bs=4m 2>/dev/null \
      | "$PV_BIN" -p -t -e -r -b -s "$DISK_SIZE" ${PV_OPTS[@]+"${PV_OPTS[@]}"} \
      | gzip -c > "$TMP_IMAGE"
  else
    echo -e "${YELLOW}pv not found — limited progress output. Press Ctrl+T for a status update.${NC}"
    sudo dd if="$IO_DEVICE" bs=4m \
      | gzip -c > "$TMP_IMAGE"
  fi

  echo -e "${BLUE}Backup write completed. Flushing write buffers...${NC}"
  sync

  #############################################
  # VERIFY + FINALIZE
  #############################################

  echo -e "${BLUE}Verifying compressed image integrity...${NC}"
  gzip -t "$TMP_IMAGE" || error_exit "gzip integrity test failed"

  echo -e "${BLUE}Finalizing image file...${NC}"

  sync
  mv "$TMP_IMAGE" "$IMAGE" \
    || error_exit "Failed to move temp image into place"

  sync

  echo "$DISK_SIZE" > "${IMAGE}.size"
  sync

  TMP_IMAGE=""

  #############################################
  # OPTIONAL HASHING
  #############################################

  if [[ "$FAST_MODE" -eq 0 ]]; then
    echo -e "${BLUE}Calculating SHA256 hash (this may take several minutes for large images)...${NC}"
    IMAGE_HASH=$(gzip -dc "$IMAGE" | shasum -a 256 | awk '{print $1}')
    echo "IMAGE SHA256: $IMAGE_HASH" | tee -a "$LOG"
    echo "$IMAGE_HASH" > "${IMAGE}.sha256"
    echo -e "${GREEN}SHA256 saved to: ${IMAGE}.sha256${NC}"
  fi

  #############################################
  # LOGGING + CLEAN EXIT (BACKUP)
  #############################################

  END=$(date +%s)
  DURATION=$((END-START))

  {
    echo "duration_seconds=${DURATION}"
    echo "result=SUCCESS"
    echo "exit_code=0"
  } >> "$LOG"

  sudo diskutil eject "$DEVICE" || true

  echo -e "${GREEN}Backup completed in ${DURATION}s.${NC}"

elif [[ "$MODE" == "2" ]]; then

  #############################################
  # RESTORE
  #############################################

  read -rp "Image path (.img.gz): " IMAGE
  [[ "$IMAGE" = /* ]] || error_exit "Image path must be absolute"
  [[ -f "$IMAGE" ]] || error_exit "Image not found: $IMAGE"

  gzip -t "$IMAGE" || error_exit "gzip integrity check failed for image"

  #############################################
  # IMAGE SIZE + COMPATIBILITY CHECK
  #############################################

  SIZE_FILE="${IMAGE}.size"

  if [[ -f "$SIZE_FILE" ]]; then
    IMAGE_SIZE=$(<"$SIZE_FILE")
    if [[ ! "$IMAGE_SIZE" =~ ^[0-9]+$ || "$IMAGE_SIZE" -eq 0 ]]; then
      error_exit "Invalid size metadata in ${SIZE_FILE} — recreate backup or remove the .size file"
    fi
    echo -e "${BLUE}Image size from metadata: ${GREEN}${IMAGE_SIZE} bytes${NC}"

    if [[ "$DISK_SIZE" -lt "$IMAGE_SIZE" ]]; then
      error_exit "Target disk (${DISK_SIZE} bytes) is smaller than original source disk (${IMAGE_SIZE} bytes)"
    fi
  else
    echo -e "${YELLOW}Warning: No .size metadata found — calculating via full decompression (slow for large images)...${NC}"
    IMAGE_SIZE=$(gzip -dc "$IMAGE" | wc -c | awk '{print $1}')
    [[ -n "$IMAGE_SIZE" && "$IMAGE_SIZE" -gt 0 ]] \
      || error_exit "Unable to determine uncompressed image size"
  fi

  (( IMAGE_SIZE <= DISK_SIZE )) || error_exit "Image is larger than target disk"

  {
    echo "image_path=${IMAGE}"
    echo "image_size=${IMAGE_SIZE}"
  } >> "$LOG"

  echo
  echo -e "${BLUE}=== Restore summary ===${NC}"
  echo -e "Mode:        ${GREEN}restore${NC}"

  show_device_details "$DEVICE"

  RESTORE_SECTOR_SIZE=$(echo "$DISK_INFO_PLIST" \
    | plutil -extract DeviceBlockSize raw - 2>/dev/null || echo "512")
  [[ "$RESTORE_SECTOR_SIZE" =~ ^[0-9]+$ && "$RESTORE_SECTOR_SIZE" -gt 0 ]] || RESTORE_SECTOR_SIZE=512

  echo -e "Disk size:   ${GREEN}${DISK_SIZE} bytes${NC}"
  echo -e "Block size:  ${GREEN}${RESTORE_SECTOR_SIZE} bytes${NC}"
  echo -e "Image file:  ${GREEN}${IMAGE}${NC}"
  echo -e "Image size:  ${GREEN}${IMAGE_SIZE} bytes${NC}"
  echo -e "FAST mode:   ${GREEN}$([[ $FAST_MODE -eq 1 ]] && echo enabled || echo disabled)${NC}"
  echo -e "Dry-run:     ${GREEN}$([[ $DRY_RUN -eq 1 ]] && echo yes || echo no)${NC}"
  echo -e "Progress:    ${GREEN}$([[ $USE_PV -eq 1 ]] && echo "pv installed — full progress + ETA" || echo "pv not found — Ctrl+T for status")${NC}"

  HASH_SIDECAR="${IMAGE}.sha256"
  EXPECTED_HASH=""
  if [[ -f "$HASH_SIDECAR" ]]; then
    EXPECTED_HASH=$(<"$HASH_SIDECAR")
    echo -e "Expected SHA256: ${GREEN}${EXPECTED_HASH}${NC}"
  else
    echo -e "Expected SHA256: ${YELLOW}no .sha256 sidecar found — will compute during restore${NC}"
  fi
  echo
  echo -e "${RED}WARNING: The target disk will be fully overwritten.${NC}"

  read -rp "Type I AM SURE to restore: " CONFIRM
  [[ "$CONFIRM" == "I AM SURE" ]] || error_exit "Restore not confirmed"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo -e "${YELLOW}[DRY RUN] Restore skipped.${NC}"
    {
      echo "result=DRY-RUN"
    } >> "$LOG"
    exit 0
  fi

  #############################################
  # FINAL DEVICE VALIDATION (pre-restore)
  #############################################

  CURRENT_SIZE=$(diskutil info -plist "$DEVICE" \
    | plutil -extract TotalSize raw - 2>/dev/null || echo "")

  [[ -b "$IO_DEVICE" ]] || error_exit "Device disappeared before restore"

  [[ -n "$CURRENT_SIZE" && "$CURRENT_SIZE" -eq "$DISK_SIZE" ]] \
    || error_exit "Disk size changed before restore (device may have been swapped)"

  if ! sudo diskutil verifyDisk "$DEVICE"; then
    echo -e "${YELLOW}Warning: diskutil verifyDisk reported issues on the target disk.${NC}"
    echo -e "${YELLOW}This is normal for blank, uninitialized or freshly erased disks.${NC}"
    echo -e "${YELLOW}Continuing with restore...${NC}"
  fi

  sudo diskutil unmountDisk "$DEVICE" \
    || error_exit "Failed to unmount disk before restore"

  #############################################
  # START RESTORE
  #############################################

  START=$(date +%s)

  if [[ "$FAST_MODE" -eq 0 ]]; then
    if [[ -n "$EXPECTED_HASH" ]]; then
      # .sha256 sidecar available — no need to tee during write, hash already known
      if [[ "$USE_PV" -eq 1 ]]; then
        echo -e "${BLUE}Progress:${NC}"
        gzip -dc "$IMAGE" \
          | "$PV_BIN" -p -t -e -r -b -s "$IMAGE_SIZE" ${PV_OPTS[@]+"${PV_OPTS[@]}"} \
          | sudo dd of="$IO_DEVICE" bs=4m 2>/dev/null
      else
        echo -e "${YELLOW}pv not found — limited progress output. Press Ctrl+T for a status update.${NC}"
        gzip -dc "$IMAGE" \
          | sudo dd of="$IO_DEVICE" bs=4m
      fi
    else
      # No sidecar — compute hash on the fly during write via tee
      TMP_HASH=$(mktemp) || error_exit "Failed to create temporary hash file"
      if [[ "$USE_PV" -eq 1 ]]; then
        echo -e "${BLUE}Progress:${NC}"
        gzip -dc "$IMAGE" \
          | tee >(shasum -a 256 | awk '{print $1}' > "$TMP_HASH") \
          | "$PV_BIN" -p -t -e -r -b -s "$IMAGE_SIZE" ${PV_OPTS[@]+"${PV_OPTS[@]}"} \
          | sudo dd of="$IO_DEVICE" bs=4m 2>/dev/null
      else
        echo -e "${YELLOW}pv not found — limited progress output. Press Ctrl+T for a status update.${NC}"
        gzip -dc "$IMAGE" \
          | tee >(shasum -a 256 | awk '{print $1}' > "$TMP_HASH") \
          | sudo dd of="$IO_DEVICE" bs=4m
      fi
    fi
  else
    if [[ "$USE_PV" -eq 1 ]]; then
      echo -e "${BLUE}Progress:${NC}"
      gzip -dc "$IMAGE" \
        | "$PV_BIN" -p -t -e -r -b -s "$IMAGE_SIZE" ${PV_OPTS[@]+"${PV_OPTS[@]}"} \
        | sudo dd of="$IO_DEVICE" bs=4m 2>/dev/null
    else
      echo -e "${YELLOW}pv not found — limited progress output. Press Ctrl+T for a status update.${NC}"
      gzip -dc "$IMAGE" \
        | sudo dd of="$IO_DEVICE" bs=4m
    fi
  fi

  sync

  #############################################
  # GPT INTEGRITY CHECK
  #############################################

  # Read actual block size from disk — handles both 512-byte and 4K native drives
  SECTOR_SIZE=$(echo "$DISK_INFO_PLIST" \
    | plutil -extract DeviceBlockSize raw - 2>/dev/null || echo "512")
  [[ "$SECTOR_SIZE" =~ ^[0-9]+$ && "$SECTOR_SIZE" -gt 0 ]] || SECTOR_SIZE=512

  # Primary GPT header (LBA 1)
  GPT_HEX=$(sudo dd if="$IO_DEVICE" bs="$SECTOR_SIZE" skip=1 count=1 2>/dev/null \
    | dd bs=1 count=8 2>/dev/null \
    | hexdump -v -e '8/1 "%02X"')

  [[ "$GPT_HEX" == "4546492050415254" ]] \
    || error_exit "Primary GPT header signature mismatch"

  # Secondary GPT header (last sector)
  LAST_LBA=$(( (DISK_SIZE / SECTOR_SIZE) - 1 ))

  GPT_HEX_LAST=$(sudo dd if="$IO_DEVICE" bs="$SECTOR_SIZE" skip="$LAST_LBA" count=1 2>/dev/null \
    | dd bs=1 count=8 2>/dev/null \
    | hexdump -v -e '8/1 "%02X"')

  [[ "$GPT_HEX_LAST" == "4546492050415254" ]] \
    || error_exit "Secondary GPT header signature mismatch"

  #############################################
  # SHA256 VERIFICATION
  #############################################

  if [[ "$FAST_MODE" -eq 0 ]]; then
    # Get the reference hash — from sidecar if available, otherwise from tee pipeline
    if [[ -n "$EXPECTED_HASH" ]]; then
      IMAGE_HASH="$EXPECTED_HASH"
    else
      IMAGE_HASH=$(cat "$TMP_HASH")
    fi

    BLOCK_SIZE=$((4 * 1024 * 1024))
    BLOCKS=$(( (IMAGE_SIZE + BLOCK_SIZE - 1) / BLOCK_SIZE ))

    echo -e "${BLUE}Verifying SHA256 of restored disk...${NC}"
    RESTORE_HASH=$(sudo dd if="$IO_DEVICE" bs=4m count="$BLOCKS" 2>/dev/null \
                   | head -c "$IMAGE_SIZE" \
                   | shasum -a 256 | awk '{print $1}')

    echo "Image   SHA256: $IMAGE_HASH"   | tee -a "$LOG"
    echo "Restore SHA256: $RESTORE_HASH" | tee -a "$LOG"

    if [[ "$IMAGE_HASH" != "$RESTORE_HASH" ]]; then
      echo -e "${RED}Verification FAILED.${NC}"
      echo -e "${YELLOW}Expected SHA256: ${IMAGE_HASH}${NC}"
      echo -e "${YELLOW}Actual   SHA256: ${RESTORE_HASH}${NC}"
      echo -e "${RED}Disk is left in written but UNVERIFIED state.${NC}"
      {
        echo "result=FAILURE"
        echo "error_message=SHA256 verification mismatch"
      } >> "$LOG"
      exit 1
    fi
    echo -e "${GREEN}SHA256 verification passed.${NC}"
  fi

  #############################################
  # LOGGING + CLEAN EXIT (RESTORE)
  #############################################

  END=$(date +%s)
  DURATION=$((END-START))

  echo
  echo -e "${BLUE}Finalizing restore...${NC}"

  # Flush
  sync

  echo -e "${BLUE}Verifying GPT integrity...${NC}"

  if ! sudo diskutil verifyDisk "$DEVICE"; then
    error_exit "GPT verification failed after restore (CRC or structure mismatch)"
  fi

  read -rp "Mount disk after restore? (yes/no): " MOUNT_AFTER

  if [[ "$MOUNT_AFTER" == "yes" ]]; then
    echo -e "${BLUE}Mounting disk...${NC}"
    sudo diskutil mountDisk "$DEVICE" \
      || error_exit "Failed to mount disk after restore"
  else
    echo -e "${BLUE}Ejecting disk safely...${NC}"
    sudo diskutil eject "$DEVICE" \
      || error_exit "Failed to eject disk after restore"
  fi

  {
    echo "duration_seconds=${DURATION}"
    echo "result=SUCCESS"
    echo "exit_code=0"
  } >> "$LOG"

  echo -e "${GREEN}Restore completed successfully in ${DURATION}s.${NC}"
  exit 0

fi
