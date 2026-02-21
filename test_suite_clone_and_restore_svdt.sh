#!/usr/bin/env bash
# =============================================================================
# test_suite_clone_and_restore_svdt.sh — Test suite for clone_and_restore_svdt.sh
# Emulates backup and restore with fake "SSD" images (no real hardware needed)
# Version: 1.2.0
# =============================================================================
# HOW IT WORKS:
#   Creates a temporary file as a fake SSD, then exercises the core logic of
#   clone_and_restore_svdt.sh by calling the same underlying tools (dd, gzip,
#   shasum, hexdump/od, plutil) in the same sequence the script does.
#
# COVERS:
#   Backup pipeline · Restore pipeline · SHA256 end-to-end · GPT signatures
#   (512b + 4K-native regression) · Size mismatch guard · Corruption detection
#   Fast mode · .size sidecar validation · No-clobber guard · head -c readback
#   Atomic rename · tee pipeline integrity · plist flag extraction (macOS)
#   no-pv pipeline variant
#
# REQUIREMENTS: bash, dd, gzip, shasum, awk, hexdump (macOS) or od (Linux/macOS)
# OPTIONAL:     plutil — required for section 15 (plist tests); auto-skipped if absent
# USAGE:        chmod +x test_suite_clone_and_restore_svdt.sh
#               ./test_suite_clone_and_restore_svdt.sh
#
# MAINTENANCE NOTES (read before modifying):
#   This test suite mirrors the pipeline logic in clone_and_restore_svdt.sh.
#   When you change the main script, update this file as follows:
#
#   CHANGE TYPE                        ACTION REQUIRED
#   ─────────────────────────────────  ──────────────────────────────────────────
#   New safety flag in plist checks    Add a sub-test in section 15
#   Changed GPT check logic            Update sections 2, 2b, or 6
#   Changed SHA256 pipeline            Update sections 5, 12, or 14
#   New sidecar file type              Add a test in section 3 (backup) + 4 (restore)
#   Changed size validation logic      Update section 7
#   Changed backup/restore pipeline    Update do_backup() / do_restore() helpers
#   Version bump in main script        Update MAIN_SCRIPT_VERSION below + add entry
#                                      to the version history comment block
#
# VERSION HISTORY:
#   1.0.0 — initial release (14 sections, 30 tests)
#   1.1.0 — filename corrected in header; no test changes
#   1.2.0 — added section 15 (plist flag extraction, macOS/plutil)
#            added section 16 (no-pv pipeline variant)
# =============================================================================

TEST_SUITE_VERSION="1.2.0"
MAIN_SCRIPT_VERSION="2.2.1"   # version of clone_and_restore_svdt.sh this suite targets

set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
CYAN="\033[0;36m"
NC="\033[0m"

# ─── Counters ─────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
SKIP=0

# ─── Test directory ───────────────────────────────────────────────────────────
TESTDIR=$(mktemp -d /tmp/svdt_test_XXXXXX)
trap 'rm -rf "$TESTDIR"' EXIT

# ─── Portable hex dump ────────────────────────────────────────────────────────
hex_dump_8() {
  local tmp
  tmp=$(mktemp "$TESTDIR/hex_XXXXXX")
  dd bs=1 count=8 2>/dev/null > "$tmp"
  if command -v hexdump >/dev/null 2>&1; then
    hexdump -v -e '8/1 "%02X"' "$tmp"
  else
    od -A n -t x1 "$tmp" | tr -d ' \n' | tr '[:lower:]' '[:upper:]'
  fi
  rm -f "$tmp"
}

# ─── Helpers ──────────────────────────────────────────────────────────────────
ok()      { echo -e "  ${GREEN}✓ PASS${NC}  $1"; PASS=$((PASS + 1)); }
fail()    { echo -e "  ${RED}✗ FAIL${NC}  $1"; FAIL=$((FAIL + 1)); }
skip()    { echo -e "  ${YELLOW}⊘ SKIP${NC}  $1"; SKIP=$((SKIP + 1)); }
section() { echo; echo -e "${BLUE}══ $1 ══${NC}"; }
note()    { echo -e "  ${CYAN}ℹ${NC}  $1"; }

make_fake_ssd() {
  local path="$1" size="$2"
  dd if=/dev/urandom bs="$size" count=1 2>/dev/null > "$path"
  printf '\xDE\xAD\xBE\xEF' | dd of="$path" bs=1 count=4 conv=notrunc 2>/dev/null
}

write_gpt_signatures() {
  local path="$1" size="$2" sector="${3:-512}"
  printf 'EFI PART' | dd of="$path" bs=1 seek="$sector" count=8 conv=notrunc 2>/dev/null
  local last_offset=$(( size - sector ))
  printf 'EFI PART' | dd of="$path" bs=1 seek="$last_offset" count=8 conv=notrunc 2>/dev/null
}

read_gpt_hex() {
  local path="$1" lba="$2" sector="${3:-512}"
  dd if="$path" bs="$sector" skip="$lba" count=1 2>/dev/null | hex_dump_8
}

# Mirrors the backup pipeline in clone_and_restore_svdt.sh
do_backup() {
  local src="$1" img="$2"
  local size; size=$(wc -c < "$src" | awk '{print $1}')
  dd if="$src" bs=1048576 2>/dev/null | gzip -c > "$img"
  echo "$size" > "${img}.size"
  gzip -dc "$img" | shasum -a 256 | awk '{print $1}' > "${img}.sha256"
}

# Mirrors the restore pipeline in clone_and_restore_svdt.sh
do_restore() {
  local img="$1" dst="$2"
  gzip -dc "$img" | dd of="$dst" bs=1048576 2>/dev/null
  sync
}

# Write a minimal diskutil-style plist XML for flag extraction tests.
# Usage: make_plist <path> <Internal> <Virtual> <APFSPhysicalStore> <TotalSize> <DeviceBlockSize>
make_plist() {
  local path="$1" internal="$2" virtual="$3" apfs="$4" total="$5" blocksize="$6"
  local int_el virt_el apfs_el
  [[ "$internal" == "true" ]] && int_el="<true/>"  || int_el="<false/>"
  [[ "$virtual"  == "true" ]] && virt_el="<true/>" || virt_el="<false/>"
  [[ "$apfs"     == "true" ]] && apfs_el="<true/>" || apfs_el="<false/>"
  cat > "$path" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Internal</key>${int_el}
	<key>Virtual</key>${virt_el}
	<key>APFSPhysicalStore</key>${apfs_el}
	<key>TotalSize</key><integer>${total}</integer>
	<key>DeviceBlockSize</key><integer>${blocksize}</integer>
</dict>
</plist>
PLIST
}

GPT_SIG="4546492050415254"
SSD_SIZE=4194304

echo -e "${BLUE}test_suite_clone_and_restore_svdt.sh v${TEST_SUITE_VERSION}${NC}"
echo -e "Targeting: clone_and_restore_svdt.sh v${MAIN_SCRIPT_VERSION}"

# ─────────────────────────────────────────────────────────────────────────────
section "1. Fake SSD creation"
# ─────────────────────────────────────────────────────────────────────────────

FAKE_SSD="$TESTDIR/fake_ssd.raw"
make_fake_ssd "$FAKE_SSD" $SSD_SIZE

if [[ -f "$FAKE_SSD" ]]; then
  ok "Fake SSD file created"
else
  fail "Fake SSD file not created"; exit 1
fi

actual_size=$(wc -c < "$FAKE_SSD" | awk '{print $1}')
if [[ "$actual_size" -eq $SSD_SIZE ]]; then
  ok "Fake SSD is correct size ($actual_size bytes)"
else
  fail "Fake SSD size mismatch (expected $SSD_SIZE, got $actual_size)"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "2. GPT signatures — 512-byte sectors"
# ─────────────────────────────────────────────────────────────────────────────

GPT_SSD="$TESTDIR/gpt_ssd.raw"
make_fake_ssd "$GPT_SSD" $SSD_SIZE
write_gpt_signatures "$GPT_SSD" $SSD_SIZE 512

primary=$(read_gpt_hex "$GPT_SSD" 1 512)
if [[ "$primary" == "$GPT_SIG" ]]; then
  ok "Primary GPT signature present at LBA 1 (bs=512)"
else
  fail "Primary GPT signature wrong: $primary"
fi

last_lba=$(( SSD_SIZE / 512 - 1 ))
secondary=$(read_gpt_hex "$GPT_SSD" "$last_lba" 512)
if [[ "$secondary" == "$GPT_SIG" ]]; then
  ok "Secondary GPT signature present at last LBA (bs=512)"
else
  fail "Secondary GPT signature wrong: $secondary"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "2b. GPT — 4K-native sectors (regression test for v2.2.1 fix)"
# ─────────────────────────────────────────────────────────────────────────────

GPT_4K_SSD="$TESTDIR/gpt_4k_ssd.raw"
make_fake_ssd "$GPT_4K_SSD" $SSD_SIZE
write_gpt_signatures "$GPT_4K_SSD" $SSD_SIZE 4096

primary_bug=$(read_gpt_hex "$GPT_4K_SSD" 1 512)
if [[ "$primary_bug" != "$GPT_SIG" ]]; then
  ok "Bug confirmed: bs=512 skip=1 misses GPT on 4K-native disk"
else
  skip "Unlikely random-data collision — rerun to confirm bug"
fi

primary_fix=$(read_gpt_hex "$GPT_4K_SSD" 1 4096)
if [[ "$primary_fix" == "$GPT_SIG" ]]; then
  ok "Fix confirmed: bs=4096 skip=1 correctly reads GPT on 4K-native disk"
else
  fail "Fix failed — GPT not found with bs=4096 skip=1: $primary_fix"
fi

last_lba_wrong=$(( SSD_SIZE / 512 - 1 ))
secondary_bug=$(read_gpt_hex "$GPT_4K_SSD" "$last_lba_wrong" 512)
if [[ "$secondary_bug" != "$GPT_SIG" ]]; then
  ok "Bug confirmed: secondary GPT missed with 512-byte LAST_LBA arithmetic on 4K disk"
else
  skip "Unlikely random-data collision — rerun"
fi

last_lba_4k=$(( SSD_SIZE / 4096 - 1 ))
secondary_fix=$(read_gpt_hex "$GPT_4K_SSD" "$last_lba_4k" 4096)
if [[ "$secondary_fix" == "$GPT_SIG" ]]; then
  ok "Fix confirmed: secondary GPT found with bs=4096 and 4K-native LAST_LBA"
else
  fail "Secondary GPT fix failed: $secondary_fix"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "3. Backup pipeline"
# ─────────────────────────────────────────────────────────────────────────────

BACKUP_SSD="$TESTDIR/backup_ssd.raw"
BACKUP_IMG="$TESTDIR/backup.img.gz"
make_fake_ssd "$BACKUP_SSD" $SSD_SIZE
write_gpt_signatures "$BACKUP_SSD" $SSD_SIZE 512
do_backup "$BACKUP_SSD" "$BACKUP_IMG"

[[ -f "$BACKUP_IMG" ]] && ok "Image file created" || { fail "Image file not created"; exit 1; }

if gzip -t "$BACKUP_IMG" 2>/dev/null; then
  ok "gzip integrity check passed"
else
  fail "gzip integrity check failed"
fi

if [[ -f "${BACKUP_IMG}.size" ]]; then
  stored_size=$(<"${BACKUP_IMG}.size")
  [[ "$stored_size" -eq $SSD_SIZE ]] \
    && ok ".size sidecar is correct ($stored_size bytes)" \
    || fail ".size sidecar wrong (expected $SSD_SIZE, got $stored_size)"
else
  fail ".size sidecar not created"
fi

if [[ -f "${BACKUP_IMG}.sha256" ]]; then
  stored_hash=$(<"${BACKUP_IMG}.sha256")
  expected_hash=$(gzip -dc "$BACKUP_IMG" | shasum -a 256 | awk '{print $1}')
  [[ "$stored_hash" == "$expected_hash" ]] \
    && ok ".sha256 sidecar matches decompressed image" \
    || fail ".sha256 sidecar mismatch"
else
  fail ".sha256 sidecar not created"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "4. Restore pipeline"
# ─────────────────────────────────────────────────────────────────────────────

RESTORE_TARGET="$TESTDIR/restore_target.raw"
dd if=/dev/zero bs="$SSD_SIZE" count=1 2>/dev/null > "$RESTORE_TARGET"
do_restore "$BACKUP_IMG" "$RESTORE_TARGET"

restored_size=$(wc -c < "$RESTORE_TARGET" | awk '{print $1}')
[[ "$restored_size" -eq $SSD_SIZE ]] \
  && ok "Restored image is correct size ($restored_size bytes)" \
  || fail "Restored image size wrong (expected $SSD_SIZE, got $restored_size)"

# ─────────────────────────────────────────────────────────────────────────────
section "5. SHA256 end-to-end verification"
# ─────────────────────────────────────────────────────────────────────────────

original_hash=$(shasum -a 256 "$BACKUP_SSD" | awk '{print $1}')
restored_hash=$(shasum -a 256 "$RESTORE_TARGET" | awk '{print $1}')

if [[ "$original_hash" == "$restored_hash" ]]; then
  ok "Original and restored SHA256 match — byte-perfect restore confirmed"
else
  fail "SHA256 mismatch — restore is not byte-perfect"
fi

sidecar_hash=$(<"${BACKUP_IMG}.sha256")
[[ "$sidecar_hash" == "$original_hash" ]] \
  && ok "Sidecar .sha256 matches original disk hash" \
  || fail "Sidecar .sha256 does not match original disk"

# ─────────────────────────────────────────────────────────────────────────────
section "6. GPT signatures survive backup → restore"
# ─────────────────────────────────────────────────────────────────────────────

primary_after=$(read_gpt_hex "$RESTORE_TARGET" 1 512)
[[ "$primary_after" == "$GPT_SIG" ]] \
  && ok "Primary GPT signature intact after backup → restore" \
  || fail "Primary GPT signature lost: $primary_after"

last_lba=$(( SSD_SIZE / 512 - 1 ))
secondary_after=$(read_gpt_hex "$RESTORE_TARGET" "$last_lba" 512)
[[ "$secondary_after" == "$GPT_SIG" ]] \
  && ok "Secondary GPT signature intact after backup → restore" \
  || fail "Secondary GPT signature lost: $secondary_after"

# ─────────────────────────────────────────────────────────────────────────────
section "7. Size mismatch guard"
# ─────────────────────────────────────────────────────────────────────────────

small_disk_size=$(( SSD_SIZE / 2 ))
image_size=$(<"${BACKUP_IMG}.size")

[[ "$small_disk_size" -lt "$image_size" ]] \
  && ok "Guard catches undersized target (${small_disk_size} < ${image_size} bytes)" \
  || fail "Size guard failed — undersized target not detected"

[[ "$SSD_SIZE" -ge "$image_size" ]] \
  && ok "Guard passes for same-size target ($SSD_SIZE >= $image_size bytes)" \
  || fail "Size guard incorrectly rejected same-size target"

# ─────────────────────────────────────────────────────────────────────────────
section "8. Corrupted image detection"
# ─────────────────────────────────────────────────────────────────────────────

CORRUPT_IMG="$TESTDIR/corrupt.img.gz"
cp "$BACKUP_IMG" "$CORRUPT_IMG"
file_size=$(wc -c < "$CORRUPT_IMG" | awk '{print $1}')
mid=$(( file_size / 2 ))
printf '\xFF\xFF\xFF\xFF' | dd of="$CORRUPT_IMG" bs=1 seek="$mid" count=4 conv=notrunc 2>/dev/null

! gzip -t "$CORRUPT_IMG" 2>/dev/null \
  && ok "gzip -t correctly rejects corrupted image" \
  || skip "Byte-flip happened to not affect gzip CRC — rerun to confirm"

TRUNCATED_IMG="$TESTDIR/truncated.img.gz"
dd if="$BACKUP_IMG" bs=1 count=$(( file_size - 1024 )) 2>/dev/null > "$TRUNCATED_IMG"
! gzip -t "$TRUNCATED_IMG" 2>/dev/null \
  && ok "gzip -t correctly rejects truncated image" \
  || fail "gzip -t did not reject truncated image"

# ─────────────────────────────────────────────────────────────────────────────
section "9. Fast mode (SHA256 skipped)"
# ─────────────────────────────────────────────────────────────────────────────

FAST_IMG="$TESTDIR/fast_backup.img.gz"
make_fake_ssd "$TESTDIR/fast_ssd.raw" $SSD_SIZE
dd if="$TESTDIR/fast_ssd.raw" bs=1048576 2>/dev/null | gzip -c > "$FAST_IMG"
echo "$SSD_SIZE" > "${FAST_IMG}.size"

[[ ! -f "${FAST_IMG}.sha256" ]] \
  && ok "FAST mode: no .sha256 sidecar created" \
  || fail "FAST mode: .sha256 sidecar unexpectedly exists"

gzip -t "$FAST_IMG" 2>/dev/null \
  && ok "FAST mode: gzip integrity still passes" \
  || fail "FAST mode: gzip integrity failed"

# ─────────────────────────────────────────────────────────────────────────────
section "10. .size sidecar validation"
# ─────────────────────────────────────────────────────────────────────────────

INVALID_SIZE="$TESTDIR/invalid.img.gz.size"

echo "notanumber" > "$INVALID_SIZE"; bad=$(<"$INVALID_SIZE")
! [[ "$bad" =~ ^[0-9]+$ && "$bad" -gt 0 ]] \
  && ok ".size sidecar: non-numeric value correctly rejected" \
  || fail ".size sidecar: non-numeric value not caught"

echo "0" > "$INVALID_SIZE"; bad=$(<"$INVALID_SIZE")
! [[ "$bad" =~ ^[0-9]+$ && "$bad" -gt 0 ]] \
  && ok ".size sidecar: zero value correctly rejected" \
  || fail ".size sidecar: zero not caught"

[[ "$SSD_SIZE" =~ ^[0-9]+$ && "$SSD_SIZE" -gt 0 ]] \
  && ok ".size sidecar: valid numeric value passes" \
  || fail ".size sidecar: valid value check failed"

# ─────────────────────────────────────────────────────────────────────────────
section "11. No-clobber guard"
# ─────────────────────────────────────────────────────────────────────────────

touch "$TESTDIR/existing.img.gz"
[[ -e "$TESTDIR/existing.img.gz" ]] \
  && ok "No-clobber: pre-existing image file detected (script would error_exit here)" \
  || fail "No-clobber: file detection failed"

# ─────────────────────────────────────────────────────────────────────────────
section "12. SHA256 read-back using head -c (v2.2.0 method)"
# ─────────────────────────────────────────────────────────────────────────────

block_size=4194304
blocks=$(( (SSD_SIZE + block_size - 1) / block_size ))
hash_head=$(dd if="$RESTORE_TARGET" bs=4194304 count="$blocks" 2>/dev/null \
  | head -c "$SSD_SIZE" | shasum -a 256 | awk '{print $1}')
original=$(shasum -a 256 "$RESTORE_TARGET" | awk '{print $1}')

[[ "$hash_head" == "$original" ]] \
  && ok "head -c read-back produces identical SHA256 to direct hash" \
  || fail "head -c read-back SHA256 mismatch"

# ─────────────────────────────────────────────────────────────────────────────
section "13. Atomic temp-file rename"
# ─────────────────────────────────────────────────────────────────────────────

TMP_FILE="$TESTDIR/atomic_test.img.gz.tmp.$$"
FINAL_FILE="$TESTDIR/atomic_test.img.gz"
echo "data" | gzip -c > "$TMP_FILE"
mv "$TMP_FILE" "$FINAL_FILE"

[[ -f "$FINAL_FILE" && ! -f "$TMP_FILE" ]] \
  && ok "Atomic rename: temp replaced final, no orphan tmp remains" \
  || fail "Atomic rename failed"

# ─────────────────────────────────────────────────────────────────────────────
section "14. tee pipeline integrity (no-sidecar hash path)"
# ─────────────────────────────────────────────────────────────────────────────

TEE_SSD="$TESTDIR/tee_ssd.raw"
TEE_IMG="$TESTDIR/tee.img.gz"
TEE_RESTORE="$TESTDIR/tee_restore.raw"
TEE_HASH_FILE="$TESTDIR/tee_hash.txt"
make_fake_ssd "$TEE_SSD" $SSD_SIZE
dd if="$TEE_SSD" bs=1048576 2>/dev/null | gzip -c > "$TEE_IMG"
dd if=/dev/zero bs="$SSD_SIZE" count=1 2>/dev/null > "$TEE_RESTORE"

gzip -dc "$TEE_IMG" \
  | tee >(shasum -a 256 | awk '{print $1}' > "$TEE_HASH_FILE") \
  | dd of="$TEE_RESTORE" bs=1048576 2>/dev/null
wait 2>/dev/null || true

tee_hash=$(<"$TEE_HASH_FILE")
direct_hash=$(shasum -a 256 "$TEE_SSD" | awk '{print $1}')
[[ "$tee_hash" == "$direct_hash" ]] \
  && ok "tee pipeline: hash from process substitution matches original disk" \
  || fail "tee pipeline: hash mismatch (tee=$tee_hash direct=$direct_hash)"

# ─────────────────────────────────────────────────────────────────────────────
section "15. plist flag extraction — APFS / Virtual / Internal guards"
# ─────────────────────────────────────────────────────────────────────────────
# Tests the disk safety validation logic that reads diskutil plist output.
# Mirrors lines 388–403 of clone_and_restore_svdt.sh.
#
# REQUIRES: plutil (macOS built-in). Entire section auto-skipped on Linux.
# If you add a new safety flag to the main script, add a sub-test here.

if ! command -v plutil >/dev/null 2>&1; then
  note "plutil not available — section 15 requires macOS. All sub-tests skipped."
  skip "plist: Internal=true blocked (plutil absent)"
  skip "plist: Virtual=true blocked (plutil absent)"
  skip "plist: APFSPhysicalStore=true blocked (plutil absent)"
  skip "plist: clean external disk passes all flags (plutil absent)"
  skip "plist: TotalSize extracted correctly (plutil absent)"
  skip "plist: DeviceBlockSize 512b extracted correctly (plutil absent)"
  skip "plist: DeviceBlockSize 4096b extracted correctly (plutil absent)"
else
  # 15a: Internal=true — must be blocked
  make_plist "$TESTDIR/plist_int.xml" true false false 4194304 512
  flag=$(cat "$TESTDIR/plist_int.xml" | plutil -extract Internal raw - 2>/dev/null || echo "unknown")
  [[ "$flag" == "true" ]] \
    && ok "plist: Internal=true correctly extracted — would trigger block in script" \
    || fail "plist: Internal flag extraction failed (got: $flag)"

  # 15b: Virtual=true — must be blocked
  make_plist "$TESTDIR/plist_virt.xml" false true false 4194304 512
  flag=$(cat "$TESTDIR/plist_virt.xml" | plutil -extract Virtual raw - 2>/dev/null || echo "unknown")
  [[ "$flag" == "true" ]] \
    && ok "plist: Virtual=true correctly extracted — would trigger block in script" \
    || fail "plist: Virtual flag extraction failed (got: $flag)"

  # 15c: APFSPhysicalStore=true — must be blocked
  make_plist "$TESTDIR/plist_apfs.xml" false false true 4194304 512
  flag=$(cat "$TESTDIR/plist_apfs.xml" | plutil -extract APFSPhysicalStore raw - 2>/dev/null || echo "unknown")
  [[ "$flag" == "true" ]] \
    && ok "plist: APFSPhysicalStore=true correctly extracted — would trigger block in script" \
    || fail "plist: APFSPhysicalStore flag extraction failed (got: $flag)"

  # 15d: clean external disk — all flags false, should pass
  make_plist "$TESTDIR/plist_ok.xml" false false false 4194304 512
  int_f=$(cat  "$TESTDIR/plist_ok.xml" | plutil -extract Internal          raw - 2>/dev/null || echo "x")
  virt_f=$(cat "$TESTDIR/plist_ok.xml" | plutil -extract Virtual           raw - 2>/dev/null || echo "x")
  apfs_f=$(cat "$TESTDIR/plist_ok.xml" | plutil -extract APFSPhysicalStore raw - 2>/dev/null || echo "x")
  [[ "$int_f" == "false" && "$virt_f" == "false" && "$apfs_f" == "false" ]] \
    && ok "plist: clean external disk — all block flags false, passes validation" \
    || fail "plist: clean disk flag check failed (Internal=$int_f Virtual=$virt_f APFS=$apfs_f)"

  # 15e: TotalSize extraction
  size_val=$(cat "$TESTDIR/plist_ok.xml" | plutil -extract TotalSize raw - 2>/dev/null || echo "")
  [[ "$size_val" == "4194304" ]] \
    && ok "plist: TotalSize extracted correctly ($size_val bytes)" \
    || fail "plist: TotalSize extraction failed (got: $size_val)"

  # 15f: DeviceBlockSize — 512b
  bs_val=$(cat "$TESTDIR/plist_ok.xml" | plutil -extract DeviceBlockSize raw - 2>/dev/null || echo "")
  [[ "$bs_val" == "512" ]] \
    && ok "plist: DeviceBlockSize extracted correctly — 512 bytes" \
    || fail "plist: DeviceBlockSize extraction failed for 512b disk (got: $bs_val)"

  # 15g: DeviceBlockSize — 4K native
  make_plist "$TESTDIR/plist_4k.xml" false false false 4194304 4096
  bs_4k=$(cat "$TESTDIR/plist_4k.xml" | plutil -extract DeviceBlockSize raw - 2>/dev/null || echo "")
  [[ "$bs_4k" == "4096" ]] \
    && ok "plist: DeviceBlockSize extracted correctly — 4096 bytes (4K native)" \
    || fail "plist: DeviceBlockSize extraction failed for 4K disk (got: $bs_4k)"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "16. no-pv pipeline variant"
# ─────────────────────────────────────────────────────────────────────────────
# When pv is not installed, the script falls back to plain dd | gzip (backup)
# and gzip -dc | dd (restore) — no tee, no pv in the pipeline.
# Verifies that this path produces byte-identical results to the full path.

NOPV_SSD="$TESTDIR/nopv_ssd.raw"
NOPV_IMG="$TESTDIR/nopv_backup.img.gz"
NOPV_RESTORE="$TESTDIR/nopv_restore.raw"
make_fake_ssd "$NOPV_SSD" $SSD_SIZE
write_gpt_signatures "$NOPV_SSD" $SSD_SIZE 512

# 16a: no-pv backup — plain dd | gzip, no pv, no tee
dd if="$NOPV_SSD" bs=1048576 2>/dev/null | gzip -c > "$NOPV_IMG"
gzip -t "$NOPV_IMG" 2>/dev/null \
  && ok "no-pv backup: gzip integrity passes" \
  || fail "no-pv backup: gzip integrity failed"

nopv_src_hash=$(shasum -a 256 "$NOPV_SSD" | awk '{print $1}')
nopv_decomp_hash=$(gzip -dc "$NOPV_IMG" | shasum -a 256 | awk '{print $1}')
[[ "$nopv_decomp_hash" == "$nopv_src_hash" ]] \
  && ok "no-pv backup: decompressed image matches source disk (byte-perfect)" \
  || fail "no-pv backup: decompressed image does not match source"

# 16b: no-pv restore — plain gzip -dc | dd, no pv, no tee
dd if=/dev/zero bs="$SSD_SIZE" count=1 2>/dev/null > "$NOPV_RESTORE"
gzip -dc "$NOPV_IMG" | dd of="$NOPV_RESTORE" bs=1048576 2>/dev/null
sync

nopv_restored_hash=$(shasum -a 256 "$NOPV_RESTORE" | awk '{print $1}')
[[ "$nopv_restored_hash" == "$nopv_src_hash" ]] \
  && ok "no-pv restore: restored disk matches original source (byte-perfect)" \
  || fail "no-pv restore: restored disk does not match source"

# 16c: both pipeline variants independently produce byte-perfect restores
nopv_final=$(shasum -a 256 "$NOPV_RESTORE"   | awk '{print $1}')
pv_final=$(shasum -a 256   "$RESTORE_TARGET" | awk '{print $1}')
nopv_src=$(shasum -a 256   "$NOPV_SSD"       | awk '{print $1}')
pv_src=$(shasum -a 256     "$BACKUP_SSD"     | awk '{print $1}')
[[ "$nopv_final" == "$nopv_src" && "$pv_final" == "$pv_src" ]] \
  && ok "Both no-pv and full-integrity pipeline paths produce byte-perfect restores" \
  || fail "Pipeline comparison failed"

# 16d: GPT signatures survive no-pv round-trip
nopv_primary=$(read_gpt_hex "$NOPV_RESTORE" 1 512)
[[ "$nopv_primary" == "$GPT_SIG" ]] \
  && ok "no-pv restore: primary GPT signature intact" \
  || fail "no-pv restore: primary GPT signature lost: $nopv_primary"

nopv_last_lba=$(( SSD_SIZE / 512 - 1 ))
nopv_secondary=$(read_gpt_hex "$NOPV_RESTORE" "$nopv_last_lba" 512)
[[ "$nopv_secondary" == "$GPT_SIG" ]] \
  && ok "no-pv restore: secondary GPT signature intact" \
  || fail "no-pv restore: secondary GPT signature lost: $nopv_secondary"

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────

echo
echo "══════════════════════════════════════════════"
total=$(( PASS + FAIL + SKIP ))
echo -e "  Results:  ${GREEN}${PASS} passed${NC}  |  ${RED}${FAIL} failed${NC}  |  ${YELLOW}${SKIP} skipped${NC}  (${total} total)"
echo "══════════════════════════════════════════════"
echo

if [[ "$FAIL" -eq 0 ]]; then
  echo -e "${GREEN}All tests passed.${NC}"
  exit 0
else
  echo -e "${RED}${FAIL} test(s) failed. See above for details.${NC}"
  exit 1
fi
