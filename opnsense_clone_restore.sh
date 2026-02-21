#!/usr/bin/env bash

#####################################################################################################################################################
# OPNsense SSD Clone Utility for MacOS
# SSD clone to file and restore from file to SSD
# Can be freely used, modified and distributed ...
# Be careful and think before you type, no warranties!
#
# TIP: Use a NVMe enclosure with Realtek RTL9210B-chipset for fast transfers
#      Use USB 3.x enclosures, USB 2.x is limited to around 30 MB/s in practice
#
SCRIPT_VERSION="2.1.0"
SCRIPT_NAME="OPNsense SSD Clone Utility"
SCRIPT_YEAR="2026"
SCRIPT_AUTHOR="SVDT"
#
# VERSION HISTORY:
# ----------------
# 20/02/2026 - V1.0.0 - Initial Version
#              V1.1.0 - Bugfixes after extensive testing
#              V1.2.0 - Add locking mechanism
#              v1.3.0 - Add ETA and percentage completion
#              v1.4.0 - Performance and bug fixes
#              v1.5.0 - Optimizations after code review Claude
#              v2.0.0 - Code review fixes (Claude/Anthropic):
#                       - PV_OPTS refactored to bash array (safe word-splitting)
#                       - IMAGE_SIZE via .size sidecar (avoids full decompression)
#                       - Merge ORIGINAL_SIZE and IMAGE_SIZE checks into one block
#  21/02/2026  v2.1.0 - Cosmetic cleanup:
#                       - Consistent section header widths and ALL CAPS titles
#                       - Helper functions grouped into one section
#                       - Added missing section headers
#
#####################################################################################################################################################
#
# Security & Responsibility Notice
# --------------------------------
# This utility performs low-level disk imaging operations using raw block devices (/dev/rdiskX). Improper use can result in permanent data loss.
# 
# By using this tool, you acknowledge that:
# You understand that selecting the wrong disk may irreversibly destroy data.
# You are responsible for verifying the target device before confirming restore operations.
# You have ensured that the selected disk is not your system disk.
# You accept that hardware failures (power loss, USB disconnects, device errors) during write operations may leave a disk in an inconsistent state.
#
# This tool includes multiple safeguards:
#  - Internal system disks are blocked
#  - Virtual and APFS physical store devices are blocked
#  - Disk size validation prevents restoring to smaller targets
#  - Device re-validation occurs before destructive operations
#  - GPT headers are validated after restore
#  - Optional SHA256 integrity verification is available
#
# However, no script can protect against hardware failure or incorrect user input and the script can contain bugs.
# Use at your own risk! The author is not responsible for any damage caused by this script.
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

LOCKDIR="/tmp/opnsense_clone_${UID}.lock"

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

# Lock down PATH to trusted system binaries
export PATH="/usr/sbin:/usr/bin:/bin:/sbin"

LOG="${HOME}/opnsense_clone_$(date +%Y%m%d_%H%M%S)_$$.log"
TMP_HASH=""
TMP_IMAGE=""
MODE=""
DEVICE=""
IMAGE=""
DISK_SIZE=""
IMAGE_SIZE=""
FAST_MODE=0
DRY_RUN=0
USE_PV=0
PV_OPTS=()

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
  echo -e "${BLUE}${SCRIPT_NAME} v${SCRIPT_VERSION} - (c) ${SCRIPT_YEAR} ${SCRIPT_AUTHOR}${NC}"
  echo
  echo "Usage:"
  echo "  ./opnsense_clone_restore.sh"
  echo "  ./opnsense_clone_restore.sh --help"
  echo
  exit 0
}

[[ "${1:-}" == "--help" ]] && usage

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

if command -v pv >/dev/null 2>&1; then
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

echo -e "${BLUE}${SCRIPT_NAME} v${SCRIPT_VERSION} - (c) ${SCRIPT_YEAR} ${SCRIPT_AUTHOR}${NC}"
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
  echo -e "Select the ${YELLOW}source SSD${NC} containing your OPNsense installation."
  echo -e "This is usually an ${GREEN}external USB/SATA/NVMe SSD${NC}."
else
  echo -e "${GREEN}Restore mode selected.${NC}"
  echo -e "Select the ${YELLOW}target SSD${NC} that will be overwritten."
  echo -e "This SSD will be ${RED}fully erased${NC}."
fi

echo
echo -e "${YELLOW}Do NOT select:${NC}"
echo -e "  - ${RED}disk0${NC} (internal Mac disk — blocked)"
echo -e "  - APFS synthesized containers (disk2, disk3, …)"
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

  read -rp "Filename prefix (default: opnsense_backup): " PREFIX
  PREFIX=${PREFIX:-opnsense_backup}

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
    sudo dd if="$IO_DEVICE" bs=4M status=none \
      | pv -p -t -e -r -b -s "$DISK_SIZE" "${PV_OPTS[@]}" \
      | gzip -c > "$TMP_IMAGE"
  else
    echo -e "${YELLOW}pv not found — limited progress output.${NC}"
    sudo dd if="$IO_DEVICE" bs=4M status=progress \
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
  if command -v fsync >/dev/null 2>&1; then
    fsync "$TMP_IMAGE"
  fi

  mv "$TMP_IMAGE" "$IMAGE" \
    || error_exit "Failed to move temp image into place"

  sync

  echo "$DISK_SIZE" > "${IMAGE}.size"

  if command -v fsync >/dev/null 2>&1; then
    fsync "${IMAGE}.size"
  fi

  TMP_IMAGE=""

  #############################################
  # OPTIONAL HASHING
  #############################################

  if [[ "$FAST_MODE" -eq 0 ]]; then
    echo -e "${BLUE}Calculating SHA256 hash (this may take several minutes for large images)...${NC}"
    IMAGE_HASH=$(gzip -dc "$IMAGE" | shasum -a 256 | awk '{print $1}')
    echo "IMAGE SHA256: $IMAGE_HASH" | tee -a "$LOG"
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

  echo -e "Disk size:   ${GREEN}${DISK_SIZE} bytes${NC}"
  echo -e "Image file:  ${GREEN}${IMAGE}${NC}"
  echo -e "Image size:  ${GREEN}${IMAGE_SIZE} bytes${NC}"
  echo -e "FAST mode:   ${GREEN}$([[ $FAST_MODE -eq 1 ]] && echo enabled || echo disabled)${NC}"
  echo -e "Dry-run:     ${GREEN}$([[ $DRY_RUN -eq 1 ]] && echo yes || echo no)${NC}"
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
    echo "Warning: diskutil verify reported issues. Continuing restore..."
  fi

  sudo diskutil unmountDisk "$DEVICE" \
    || error_exit "Failed to unmount disk before restore"

  #############################################
  # START RESTORE
  #############################################

  START=$(date +%s)

  if [[ "$FAST_MODE" -eq 0 ]]; then
    TMP_HASH=$(mktemp) || error_exit "Failed to create temporary hash file"
  fi

  if [[ "$FAST_MODE" -eq 0 ]]; then
    if [[ "$USE_PV" -eq 1 ]]; then
      echo -e "${BLUE}Progress:${NC}"
      gzip -dc "$IMAGE" \
        | tee >(shasum -a 256 | awk '{print $1}' > "$TMP_HASH") \
        | pv -p -t -e -r -b -s "$IMAGE_SIZE" "${PV_OPTS[@]}" \
        | sudo dd of="$IO_DEVICE" bs=4M status=none
    else
      gzip -dc "$IMAGE" \
        | tee >(shasum -a 256 | awk '{print $1}' > "$TMP_HASH") \
        | sudo dd of="$IO_DEVICE" bs=4M status=progress
    fi
  else
    if [[ "$USE_PV" -eq 1 ]]; then
      echo -e "${BLUE}Progress:${NC}"
      gzip -dc "$IMAGE" \
        | pv -p -t -e -r -b -s "$IMAGE_SIZE" "${PV_OPTS[@]}" \
        | sudo dd of="$IO_DEVICE" bs=4M status=none
    else
      gzip -dc "$IMAGE" \
        | sudo dd of="$IO_DEVICE" bs=4M status=progress
    fi
  fi

  sync

  #############################################
  # GPT INTEGRITY CHECK
  #############################################

  # Primary GPT header (LBA 1)
  GPT_HEX=$(sudo dd if="$IO_DEVICE" bs=512 skip=1 count=1 2>/dev/null \
    | dd bs=1 count=8 2>/dev/null \
    | hexdump -v -e '8/1 "%02X"')

  [[ "$GPT_HEX" == "4546492050415254" ]] \
    || error_exit "Primary GPT header signature mismatch"

  # Secondary GPT header (last sector)
  SECTOR_SIZE=512
  LAST_LBA=$(( (DISK_SIZE / SECTOR_SIZE) - 1 ))

  GPT_HEX_LAST=$(sudo dd if="$IO_DEVICE" bs=512 skip="$LAST_LBA" count=1 2>/dev/null \
    | dd bs=1 count=8 2>/dev/null \
    | hexdump -v -e '8/1 "%02X"')

  [[ "$GPT_HEX_LAST" == "4546492050415254" ]] \
    || error_exit "Secondary GPT header signature mismatch"

  #############################################
  # SHA256 VERIFICATION
  #############################################

  if [[ "$FAST_MODE" -eq 0 ]]; then
    IMAGE_HASH=$(cat "$TMP_HASH")

    BLOCK_SIZE=$((4 * 1024 * 1024))
    BLOCKS=$(( (IMAGE_SIZE + BLOCK_SIZE - 1) / BLOCK_SIZE ))

    RESTORE_HASH=$(sudo dd if="$IO_DEVICE" bs=4M count="$BLOCKS" status=none \
                   | dd bs=1 count="$IMAGE_SIZE" status=none \
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
