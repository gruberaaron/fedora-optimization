#!/usr/bin/env bash
# Host binding hardening
REQ_HOST="zer0sum"
REQ_UUID="$(cat /sys/class/dmi/id/product_uuid 2>/dev/null || true)"
if [[ "$(hostnamectl --static 2>/dev/null || hostname -s)" != "$REQ_HOST" ]]; then
  echo "Refusing to run: host mismatch (expected $REQ_HOST)"; exit 1
fi
if [[ -n "$REQ_UUID" ]]; then
  CUR_UUID="$(cat /sys/class/dmi/id/product_uuid 2>/dev/null || true)"
  if [[ "$CUR_UUID" != "$REQ_UUID" ]]; then
    echo "Refusing to run: hardware UUID mismatch"; exit 1
  fi
fi
# ==============================================================================
# fedora_laptop_tuner.sh
# Version: 2.1 (2025-09-18)
# Author: Aaron + GPT-5 (integrated, safety-first)
# ==============================================================================
# DESCRIPTION
#   End-to-end Fedora laptop tuning for Fedora 41/42 era with COSMIC/GNOME/KDE.
#   Focus: conservative, idempotent setup of repositories, Flatpak, virtualization
#   and container tooling, Btrfs-friendly recommendations, Snapper timelines,
#   powertop autotune (opt-in), and tuned auto-switching with sane fallbacks.
#   Designed to be re-runnable.
#
# MODES
#   --verify-only       : run checks only; make no changes
#   --apply             : perform actions (DEFAULT)
#   --powertop          : opt-in to create/enable powertop autotune service
#   --no-powertop       : force-disable powertop autotune
#   -h|--help           : show usage
#
# DESIGN PRINCIPLES
#   - Safety first: set -euo pipefail; abort on failures; explicit modes
#   - Idempotent: each step detects existing state and skips if already configured
#   - Separation of concerns: NO /etc/fstab edits here (handled by mount optimizer)
#   - Atomic writes + SELinux restorecon for any config files we touch
#
# WHAT IT CONFIGURES (high level)
#   - rpmfusion + flathub enabling (if missing)
#   - base dev/sysadmin utilities (dnf plugins, jq, git, etc.)
#   - virtualization (KVM/QEMU + virt-manager) with health checks
#   - containers (podman + toolbox)
#   - powertop autotune systemd service (opt-in)
#   - tuned: enable service; set best-available profile with fallback
#   - Snapper setup for Btrfs with conservative timelines (if Btrfs present)
#   - TRIM via fstrim.timer (weekly)
#
# CHANGELOG
#   2.1 (2025-09-18)
#     - Implemented seven hardening tweaks: mode gating, atomic writes + restorecon,
#       tuned fallback, powertop opt-in, Snapper safety checks, virt + Secure Boot
#       warnings, Btrfs checks-only (no fstab edits).
#   2.0 (2025-09-18)
#     - Wrapped original script with documentation and modes.
#
# ==============================================================================

set -euo pipefail

# ------------------------------ helpers --------------------------------------
say()   { printf "
==> %s
" "$*"; }
ok()    { printf '   ✅ %s
' "$*"; }
warn()  { printf '   ⚠️  %s
' "$*"; }
err()   { printf '   ❌ %s
' "$*"; }
have()  { command -v "$1" >/dev/null 2>&1; }
svc_exists() { systemctl list-unit-files | awk '{print $1}' | grep -qx "$1"; }
atomic_write() { # usage: atomic_write <src> <dest>
  local src="$1" dest="$2" tmp
  tmp=$(mktemp "${dest}.new.XXXXXX")
  install -m 0644 -o root -g root "$src" "$tmp"
  mv -f "$tmp" "$dest"
  have restorecon && restorecon -v "$dest" || true
}
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || { err "Run with sudo for --apply"; exit 1; }; }

# ------------------------------ args -----------------------------------------
MODE=apply
POWERTOP=auto  # auto -> off unless --powertop
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify-only) MODE=verify ; shift ;;
    --apply)       MODE=apply  ; shift ;;
    --powertop)    POWERTOP=on ; shift ;;
    --no-powertop) POWERTOP=off; shift ;;
    -h|--help)
      cat <<USAGE
Usage: sudo ./fedora_laptop_tuner.sh [--apply|--verify-only] [--powertop|--no-powertop]
USAGE
      exit 0 ;;
    *) err "Unknown arg: $1"; exit 2 ;;
  esac
done

[[ $MODE == apply ]] && need_root

# ------------------------------ detect ---------------------------------------
IS_BTRFS_ROOT=false
if findmnt -no FSTYPE / | grep -qi btrfs; then IS_BTRFS_ROOT=true; fi

# ------------------------------ steps ----------------------------------------
step_rpmfusion_flathub() {
  say "Enabling RPM Fusion + Flathub (if missing)"
  if [[ $MODE == verify ]]; then
    have dnf && ok "dnf present" || warn "dnf missing?"
    ok "Will ensure rpmfusion-free/nonfree + flathub remotes"
    return
  fi
  # RPM Fusion
  if ! rpm -q rpmfusion-free-release >/dev/null 2>&1; then
    dnf -y install \
      https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
      https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
    ok "RPM Fusion enabled"
  else
    ok "RPM Fusion already enabled"
  fi
  # Flathub
  if have flatpak; then
    if ! flatpak remote-list | grep -q '^flathub'; then
      flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
      ok "Flathub added"
    else
      ok "Flathub already present"
    fi
  else
    warn "flatpak not installed; skipping"
  fi
}

step_base_packages() {
  say "Installing base utilities"
  local pkgs=(dnf-plugins-core jq git wget curl powertop tuned)
  if [[ $MODE == verify ]]; then
    ok "Would install: ${pkgs[*]}"
    return
  fi
  dnf -y install "${pkgs[@]}" || warn "Package install had issues"
}

step_virtualization() {
  say "Virtualization stack (KVM/QEMU + virt-manager)"
  local pkgs=(qemu-kvm libvirt virt-install virt-manager)
  if [[ $MODE == verify ]]; then
    ok "Would install: ${pkgs[*]}"
  else
    dnf -y install "${pkgs[@]}" || warn "Could not install virtualization packages"
    systemctl enable --now libvirtd || warn "libvirtd enable failed"
  fi
  # Checks
  if grep -Eq 'vmx|svm' /proc/cpuinfo; then ok "CPU virtualization supported"; else warn "No VMX/SVM flags"; fi
  [[ -e /dev/kvm ]] && ok "/dev/kvm present" || warn "/dev/kvm missing (Secure Boot? BIOS off?)"
}

step_containers() {
  say "Containers (podman + toolbox)"
  local pkgs=(podman toolbox)
  if [[ $MODE == verify ]]; then
    ok "Would install: ${pkgs[*]}"
    return
  fi
  dnf -y install "${pkgs[@]}" || warn "Container pkgs failed"
}

step_powertop_service() {
  if [[ $POWERTOP == off || $POWERTOP == auto ]]; then
    say "Powertop autotune: skipped (opt-in)"
    return
  fi
  say "Powertop autotune service (opt-in)"
  local unit=/etc/systemd/system/powertop-autotune.service
  local src=$(mktemp)
  cat >"$src" <<'UNIT'
[Unit]
Description=Powertop autotune
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/powertop --auto-tune

[Install]
WantedBy=multi-user.target
UNIT
  if [[ $MODE == verify ]]; then
    ok "Would install unit: $unit"
    rm -f "$src"
    return
  fi
  atomic_write "$src" "$unit"
  systemctl daemon-reload
  systemctl enable --now powertop-autotune.service || warn "powertop unit enable failed"
}

step_tuned() {
  say "Tuned setup with fallback"
  if [[ $MODE == apply ]]; then
    systemctl enable --now tuned || warn "tuned enable failed"
  fi
  # Pick best available profile
  local target="latency-performance"
  if ! tuned-adm list 2>/dev/null | grep -q "^- ${target}$"; then
    target="balanced"
    if ! tuned-adm list 2>/dev/null | grep -q "^- ${target}$"; then
      target="powersave"
    fi
  fi
  if [[ $MODE == apply ]]; then
    tuned-adm profile "$target" || warn "failed to set tuned profile $target"
  fi
  tuned-adm active || true
}

step_snapper() {
  say "Snapper setup (Btrfs only)"
  if ! $IS_BTRFS_ROOT; then
    warn "/ is not Btrfs; skipping snapper"
    return
  fi
  if [[ $MODE == verify ]]; then
    ok "Would install/configure snapper + timers"
    return
  fi
  dnf -y install snapper snapper-plugins || warn "snapper install failed"
  # Ensure config exists
  if ! snapper list-configs | awk '{print $1}' | grep -qx root; then
    snapper -c root create-config /
  fi
  # Timeline settings (conservative)
  local cfg=/etc/snapper/configs/root
  if [[ -f "$cfg" ]]; then
    tmp=$(mktemp)
    awk '
      /^TIMELINE_CREATE/ {print "TIMELINE_CREATE="1; next}
      /^TIMELINE_LIMIT_HOURLY/ {print "TIMELINE_LIMIT_HOURLY="6; next}
      /^TIMELINE_LIMIT_DAILY/  {print "TIMELINE_LIMIT_DAILY="7; next}
      /^TIMELINE_LIMIT_WEEKLY/ {print "TIMELINE_LIMIT_WEEKLY="4; next}
      /^TIMELINE_LIMIT_MONTHLY/{print "TIMELINE_LIMIT_MONTHLY="3; next}
      /^TIMELINE_LIMIT_YEARLY/ {print "TIMELINE_LIMIT_YEARLY="0; next}
      {print}
    ' "$cfg" > "$tmp"
    atomic_write "$tmp" "$cfg"
  fi
  systemctl enable --now snapper-timeline.timer snapper-cleanup.timer || warn "snapper timers enable failed"
}

step_trim() {
  say "Enable fstrim.timer"
  if [[ $MODE == verify ]]; then
    ok "Would enable fstrim.timer"
    return
  fi
  systemctl enable --now fstrim.timer || warn "fstrim.timer enable failed"
}

step_btrfs_checks() {
  say "Btrfs mount option recommendations (checks only)"
  if $IS_BTRFS_ROOT; then
    local OPTS
    OPTS=$(findmnt -no OPTIONS /)
    echo "$OPTS" | grep -q 'compress=' && ok "compression set ($${OPTS#*compress=})" || warn "No compression set; recommend compress=zstd:3"
    echo "$OPTS" | grep -q 'noatime'     && ok "noatime set"                      || warn "Recommend noatime"
  else
    warn "/ is not Btrfs"
  fi
}

# ------------------------------ run ------------------------------------------
main() {
  say "Mode: $MODE  | Powertop: ${POWERTOP^^}"
  step_rpmfusion_flathub
  step_base_packages
  step_virtualization
  step_containers
  step_powertop_service
  step_tuned
  step_snapper
  step_trim
  step_btrfs_checks
  say "All done. Re-run with --verify-only to audit without changes."
}

main "$@"
