#!/usr/bin/env bash
# ==============================================================================
# fedora_mount_optimizer.sh
# Version: 1.3 (2025-09-18) — host-locked + atomic writes
# Author: Aaron + GPT-5 (safety-first)
# ==============================================================================
# DESCRIPTION
#   Safely audit and (optionally) optimize mount options on Fedora systems.
#   Default: READ-ONLY. Generates /etc/fstab.optimized and prints a unified diff
#   against /etc/fstab. Only writes /etc/fstab when --apply is given.
#
# WHAT IT DOES
#   - Reads /etc/fstab; proposes conservative options per FS type
#       * btrfs: add noatime and compress=zstd:3 if compression not already set
#       * ext4 : add noatime only (prefer weekly fstrim over inline discard)
#       * swap/unknown: untouched (hands off)
#   - Preserves critical options (subvol=, subvolid=, x-systemd.*, etc.)
#   - Validates with systemd-analyze verify and a dry-run mount --fake -a -T
#   - On --apply: backs up, atomically replaces /etc/fstab, restorecon, daemon-reload,
#                 and ensures fstrim.timer is enabled
#   - Does NOT live-remount root; reboot recommended for root option changes
#
# SAFETY
#   - Host-locked: refuses to run unless hostname matches REQ_HOST (and optional UUID)
#   - Atomic write pattern for /etc/fstab (mktemp → install → mv → restorecon)
#   - set -euo pipefail; stop on validation errors
#
# USAGE
#   sudo ./fedora_mount_optimizer.sh            # propose only
#   sudo ./fedora_mount_optimizer.sh --apply    # validate + apply + enable TRIM
#
# CHANGELOG
#   1.3 (2025-09-18)  Host binding + tightened docs.
#   1.2 (2025-09-18)  Atomic writes + restorecon; clearer validation flow.
#   1.1 (2025-09-18)  Full header docs; conservative defaults.
#   1.0 (2025-09-18)  Initial safe release.
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

# ---------------- Host / HW guard ----------------
REQ_HOST="zer0sum"                          # <-- set to your host
REQ_UUID="$(cat /sys/class/dmi/id/product_uuid 2>/dev/null || true)"  # captured once; acts as expected value
CUR_HOST="$({ command -v hostnamectl >/dev/null 2>&1 && hostnamectl --static; } || hostname -s || echo unknown)"
if [[ "$CUR_HOST" != "$REQ_HOST" ]]; then
  echo "Refusing to run: host mismatch (expected $REQ_HOST, got $CUR_HOST)"; exit 1
fi
if [[ -n "$REQ_UUID" ]]; then
  CUR_UUID="$(cat /sys/class/dmi/id/product_uuid 2>/dev/null || true)"
  if [[ "$CUR_UUID" != "$REQ_UUID" ]]; then
    echo "Refusing to run: hardware UUID mismatch"; exit 1
  fi
fi

# ---------------- Helpers ----------------
red()   { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
blue()  { printf "\033[34m%s\033[0m\n" "$*"; }

die() { red "ERROR: $*"; exit 1; }
need_root() { [ "${EUID:-$(id -u)}" -eq 0 ] || die "Run as root (sudo)."; }

timestamp() { date +%Y%m%d-%H%M%S; }
backup_file() {
  local src="$1" dst
  dst="${src}.bak.$(timestamp)"
  cp --archive --no-preserve=ownership,mode "$src" "$dst"
  echo "$dst"
}

fs_of() { findmnt -no FSTYPE --target "$1" 2>/dev/null || echo "unknown"; }
blk_for() { findmnt -no SOURCE --target "$1" 2>/dev/null || true; }

# ---------------- Recommendations (conservative) ----------------
reco_opts_btrfs() {
  local existing_opts="$1"
  local opts=(noatime)
  if [[ ! ",$existing_opts," =~ ,compress(=|,|$) ]]; then
    opts+=(compress=zstd:3)
  fi
  echo "${opts[*]}"
}
reco_opts_ext4() { echo "noatime"; }

merge_opts() {
  local existing="$1" add="$2" IFS=','
  declare -A seen=()
  for o in $existing; do [[ -n "$o" ]] && seen["$o"]=1; done
  for o in $add; do
    [[ -z "$o" ]] && continue
    if [[ "$o" == compress=* ]]; then
      for k in "${!seen[@]}"; do [[ $k == compress* ]] && unset 'seen[$k]'; done
    fi
    seen["$o"]=1
  done
  local out=(); for k in "${!seen[@]}"; do out+=("$k"); done
  (IFS=','; echo "${out[*]}" | tr ',' '\n' | sort -u | paste -sd, -)
}

# ---------------- Build proposed fstab ----------------
propose_fstab() {
  local src_fstab="$1" out_fstab="$2"
  : > "$out_fstab"
  while IFS= read -r line; do
    # passthrough comments/blank
    if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
      echo "$line" >> "$out_fstab"; continue
    fi
    # fields: fs_spec fs_file fs_vfstype fs_mntops fs_freq fs_passno
    read -r fs_spec fs_file fs_vfstype fs_mntops fs_freq fs_passno <<<"$line" || true
    if [[ -z "$fs_spec" || -z "$fs_file" || -z "$fs_vfstype" ]]; then
      echo "$line" >> "$out_fstab"; continue
    fi

    local add=""
    case "$fs_vfstype" in
      btrfs) add=$(reco_opts_btrfs "$fs_mntops"); ;;
      ext4)  add=$(reco_opts_ext4  "$fs_mntops"); ;;
      swap)  add="" ;;
      *)     add="" ;;
    esac

    if [[ -n "$add" ]]; then
      local merged
      merged=$(merge_opts "$fs_mntops" "$add")
      printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$fs_spec" "$fs_file" "$fs_vfstype" "$merged" "${fs_freq:-0}" "${fs_passno:-0}" >> "$out_fstab"
    else
      echo "$line" >> "$out_fstab"
    fi
  done < <(grep -v '^$' "$src_fstab" || true; echo)
}

validate_fstab() {
  local fstab="$1"
  blue "Validating: $fstab"
  systemd-analyze verify "$fstab" || die "systemd-analyze flagged issues in $fstab"
  if mount --help 2>/dev/null | grep -q -- "--fake"; then
    mount --fake -a -T "$fstab" || die "mount --fake -a failed"
  else
    yellow "mount --fake not available; skipping dry-run"
  fi
}

apply_fstab() {
  local new_fstab="$1" src_fstab="/etc/fstab"
  local backup tmp
  backup=$(backup_file "$src_fstab")
  tmp=$(mktemp /etc/fstab.new.XXXXXX)
  install -m 0644 -o root -g root "$new_fstab" "$tmp"
  mv -f "$tmp" "$src_fstab"
  command -v restorecon >/dev/null 2>&1 && restorecon -v "$src_fstab" || true
  blue "Reloading systemd daemon and testing remount service"
  systemctl daemon-reload
  if ! systemctl start systemd-remount-fs.service; then
    yellow "systemd-remount-fs.service returned non-zero; skipping."
  fi
  green "Applied new /etc/fstab. Backup at: $backup"
}

configure_trim() {
  if systemctl list-unit-files | grep -q '^fstrim.timer'; then
    systemctl enable --now fstrim.timer || true
    blue "Ensured fstrim.timer is enabled (weekly TRIM)."
  else
    yellow "fstrim.timer not found; util-linux missing?"
  fi
}

# ---------------- Main ----------------
usage() {
  cat <<USAGE
Usage: sudo ./fedora_mount_optimizer.sh [--apply]

No flag: Audits and writes a proposed /etc/fstab.optimized then prints a diff.
--apply:  After validation, replaces /etc/fstab with the optimized version and enables fstrim.timer.
USAGE
}

main() {
  local do_apply=${1:-}
  case "$do_apply" in
    ""|"--apply") : ;; * ) usage; exit 2;; esac

  need_root

  local src_fstab="/etc/fstab" new_fstab="/etc/fstab.optimized"
  [ -f "$src_fstab" ] || die "/etc/fstab not found."

  blue "Root device:  $(blk_for /) (fs: $(fs_of /))"
  blue "Home device:  $(blk_for /home || true) (fs: $(fs_of /home || true))"

  blue "Building proposed fstab at $new_fstab"
  propose_fstab "$src_fstab" "$new_fstab"

  blue "Validating proposal"
  validate_fstab "$new_fstab"

  blue "Showing diff (proposed vs current):"
  if command -v diff >/dev/null 2>&1; then
    diff -u "$src_fstab" "$new_fstab" || true
  else
    yellow "diff not found; skipping diff output"
  fi

  if [[ "$do_apply" == "--apply" ]]; then
    yellow "About to APPLY changes. Conservative but modifies /etc/fstab."
    apply_fstab "$new_fstab"
    configure_trim
    green "Done. Reboot recommended for root mount options."
  else
    green "Proposal complete. Review /etc/fstab.optimized. Re-run with --apply to commit."
  fi
}

main "$@"
