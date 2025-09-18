#!/usr/bin/env bash
# ==============================================================================
# fedora_tune_driver.sh
# Version: 0.2 (2025-09-18)
# Author: Aaron + GPT-5
# ==============================================================================
# PURPOSE
#   One-button(ish) driver to orchestrate:
#     1) Fedora Mount Optimizer  (audit → optional atomic apply)
#     2) Fedora Laptop Tuner     (verify-only or apply, with powertop opt-in)
#
# DESIGN
#   - Host-locked to YOUR machine (hostname check)
#   - Interactive by default; supports non-interactive flags for CI-ish runs
#   - Centralized logging to /var/log/fedora-tune
#   - No /etc/fstab edits except via the mount optimizer step
#
# USAGE (common)
#   sudo ./fedora_tune_driver.sh                       # interactive flow
#   sudo ./fedora_tune_driver.sh --non-interactive \
#        --apply-mount --apply-tuner --powertop        # fully automated
#   sudo ./fedora_tune_driver.sh --log-dir /path/logs  # custom logs
#   sudo ./fedora_tune_driver.sh --skip-mount          # only run tuner
#   sudo ./fedora_tune_driver.sh --skip-tuner          # only run mount optimizer
#
# FLAGS
#   --non-interactive   : answer yes to prompts the same as providing apply flags
#   --apply-mount       : apply fstab changes after audit (atomic)
#   --apply-tuner       : run tuner in apply mode (else verify-only)
#   --powertop          : pass-through to tuner (opt-in)
#   --no-powertop       : pass-through to tuner (force off)
#   --verify-only       : forces tuner to verify-only
#   --skip-mount        : skip the mount optimizer step entirely
#   --skip-tuner        : skip the laptop tuner step entirely
#   --log-dir PATH      : change log directory (default /var/log/fedora-tune)
#   -h | --help         : show this help
#
# REQUIREMENTS
#   - The component scripts must be available (same dir as this driver by default):
#       fedora_mount_optimizer.sh
#       fedora_laptop_tuner.sh
#   - Run with sudo for any apply operations
# ==============================================================================

set -euo pipefail

# ---------------- Host guard ----------------
REQ_HOST="zer0sum"
HOST="$({ command -v hostnamectl >/dev/null 2>&1 && hostnamectl --static; } || hostname -s || echo unknown)"
if [[ "$HOST" != "$REQ_HOST" ]]; then
  echo "Refusing to run: host mismatch (expected $REQ_HOST, got $HOST)"; exit 1
fi

# ---------------- Defaults & args ----------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOUNT_OPT="$SCRIPT_DIR/fedora_mount_optimizer.sh"
TUNER="$SCRIPT_DIR/fedora_laptop_tuner.sh"

LOG_DIR="/var/log/fedora-tune"
NONINT=0
APPLY_MOUNT=0
APPLY_TUNER=0
POWERTOP_FLAG=""   # empty | --powertop | --no-powertop
FORCE_VERIFY=0
SKIP_MOUNT=0
SKIP_TUNER=0

usage(){ sed -n '1,120p' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --non-interactive) NONINT=1 ; shift ;;
    --apply-mount)     APPLY_MOUNT=1 ; shift ;;
    --apply-tuner)     APPLY_TUNER=1 ; shift ;;
    --powertop)        POWERTOP_FLAG="--powertop" ; shift ;;
    --no-powertop)     POWERTOP_FLAG="--no-powertop" ; shift ;;
    --verify-only)     FORCE_VERIFY=1 ; shift ;;
    --skip-mount)      SKIP_MOUNT=1 ; shift ;;
    --skip-tuner)      SKIP_TUNER=1 ; shift ;;
    --log-dir)         LOG_DIR="${2:?path required}" ; shift 2 ;;
    -h|--help)         usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

TS="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/run-$TS.log"
mkdir -p "$LOG_DIR"
command -v restorecon >/dev/null 2>&1 && restorecon -v "$LOG_DIR" || true

# ---------------- helpers ----------------
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[34m"; RESET="\033[0m"

log(){ printf "%s\n" "$*" | tee -a "$LOG_FILE"; }
run(){ log "> $*"; "$@" 2>&1 | tee -a "$LOG_FILE"; }

need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { log "ERROR: run with sudo"; exit 1; }; }

prompt_yes_no(){
  local prompt="$1"; local default_no="$2"
  if (( NONINT )); then
    [[ "$default_no" == "yes" ]] && return 0 || return 1
  fi
  read -rp "$prompt [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# ---------------- run orchestrator ----------------
log "=== Fedora Tune Driver @ $TS ==="
log "Host: $HOST | Log: $LOG_FILE"
log "Mount optimizer: ${MOUNT_OPT:-skipped}" 
log "Laptop tuner   : ${TUNER:-skipped}"

MOUNT_RESULT="skipped"
TUNER_RESULT="skipped"

# Step 1: Mount optimizer
if (( SKIP_MOUNT )); then
  log "[mount] skipped"
else
  log "[mount] audit"
  run sudo "$MOUNT_OPT"
  if (( APPLY_MOUNT )); then
    need_root
    log "[mount] applying per flag"
    run "$MOUNT_OPT" --apply
    MOUNT_RESULT="applied"
  else
    if prompt_yes_no "Apply fstab changes now?" no; then
      need_root
      run "$MOUNT_OPT" --apply
      MOUNT_RESULT="applied"
    else
      MOUNT_RESULT="audited"
    fi
  fi
fi

# Step 2: Laptop tuner
if (( SKIP_TUNER )); then
  log "[tuner] skipped"
else
  if (( FORCE_VERIFY )) && (( APPLY_TUNER )); then
    log "[tuner] conflicting flags: --verify-only and --apply-tuner"; exit 2
  fi
  if (( APPLY_TUNER )); then
    need_root
    log "[tuner] apply mode"
    run "$TUNER" --apply ${POWERTOP_FLAG}
    TUNER_RESULT="applied"
  else
    if (( FORCE_VERIFY )); then
      log "[tuner] verify-only per flag"
      run "$TUNER" --verify-only ${POWERTOP_FLAG}
      TUNER_RESULT="audited"
    else
      if prompt_yes_no "Run laptop tuner in APPLY mode now?" no; then
        need_root
        run "$TUNER" --apply ${POWERTOP_FLAG}
        TUNER_RESULT="applied"
      else
        log "[tuner] verify-only"
        run "$TUNER" --verify-only ${POWERTOP_FLAG}
        TUNER_RESULT="audited"
      fi
    fi
  fi
fi

# ---------------- summary ----------------
echo -e "${BLUE}=== Fedora Tune Summary ===${RESET}"
[[ $MOUNT_RESULT == applied ]] && echo -e "${GREEN}Mount optimizer: applied${RESET}" || echo -e "${YELLOW}Mount optimizer: $MOUNT_RESULT${RESET}"
[[ $TUNER_RESULT == applied ]] && echo -e "${GREEN}Laptop tuner   : applied${RESET}" || echo -e "${YELLOW}Laptop tuner   : $TUNER_RESULT${RESET}"
echo -e "${BLUE}Logs: $LOG_FILE${RESET}"
log "=== Done. Logs saved to $LOG_FILE ==="
