#!/usr/bin/env bash
#
# iso2god-all.sh — convert every Xbox 360 .iso in a folder to GOD format
# with iso2god-rs, deleting each ISO only after a successful conversion.
#
# Usage:
#   ./iso2god-all.sh [options] [iso_dir]
#
# Options:
#   -o DIR   output folder for GOD files (default: $GOD_DIR, else <iso_dir>/god)
#   -j N     threads passed to iso2god (default: $ISO2GOD_THREADS, else 16)
#   -k       keep ISOs (don't delete anything; or KEEP_ISOS=1)
#   -n       dry run: only list what would be converted
#   -h       show this help
#
# iso_dir defaults to $ISO_DIR, else the current folder.
# Settings can also come from a .env file next to the script (see .env.example).
#
# Example:
#   ./iso2god-all.sh -j 16 ~/xbox360/isos

set -uo pipefail
shopt -s nullglob nocaseglob   # no-match -> empty list; match .iso and .ISO

# One .env is shared by both scripts, so the upload settings are accepted
# (and ignored) here too.
ENV_KEYS="ISO_DIR GOD_DIR ISO2GOD_THREADS KEEP_ISOS XBOX_HOST XBOX_FTP_USER XBOX_FTP_PASS XBOX_REMOTE_PATH DELETE_AFTER_UPLOAD"
# --- .env support --------------------------------------------------------------
# Settings are read from a .env file next to this script, or from the file
# named in $ENV_FILE. Precedence: command-line flags > environment variables
# > .env > built-in defaults. The file is parsed, never executed: only
# KEY=value lines with the keys listed in ENV_KEYS are used.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

load_env() {
  local file=$1 line key val n=0
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    line="${line%$'\r'}"                                   # tolerate CRLF files
    line="${line#"${line%%[![:space:]]*}"}"                # trim leading space
    [[ -z "$line" || "$line" == \#* ]] && continue         # blank / comment
    line="${line#export }"
    if [[ ! "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      echo "Warning: ignoring line $n of $file (not KEY=value)" >&2; continue
    fi
    key=${BASH_REMATCH[1]}; val=${BASH_REMATCH[2]}
    if [[ "$val" =~ ^\"(.*)\"[[:space:]]*$ || "$val" =~ ^\'(.*)\'[[:space:]]*$ ]]; then
      val=${BASH_REMATCH[1]}                               # quoted value, kept as-is
    else
      val="${val%%[[:space:]]#*}"                          # strip " # comment"
      val="${val%"${val##*[![:space:]]}"}"                 # trim trailing space
    fi
    [[ "$val" == "~" ]] && val=$HOME
    [[ "$val" == \~/* ]] && val="$HOME/${val:2}"
    if [[ " $ENV_KEYS " != *" $key "* ]]; then
      echo "Warning: unknown setting $key in $file (ignored)" >&2; continue
    fi
    [[ -n "${!key+x}" ]] || printf -v "$key" '%s' "$val"   # real env var wins
  done < "$file"
  ENV_LOADED=$file
}
ENV_LOADED=""
if [[ -n "${ENV_FILE:-}" && ! -f "$ENV_FILE" ]]; then
  echo "ENV_FILE is set but not found: $ENV_FILE" >&2; exit 1
fi
load_env "${ENV_FILE:-$SCRIPT_DIR/.env}"

THREADS="${ISO2GOD_THREADS:-16}"
OUT_DIR="${GOD_DIR:-}"
KEEP=$([[ "${KEEP_ISOS:-0}" =~ ^(1|yes|true)$ ]] && echo 1 || echo 0)
DRY_RUN=0

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit "${1:-0}"; }

while getopts ":o:j:knh" opt; do
  case "$opt" in
    o) OUT_DIR="$OPTARG" ;;
    j) THREADS="$OPTARG" ;;
    k) KEEP=1 ;;
    n) DRY_RUN=1 ;;
    h) usage 0 ;;
    :) echo "Option -$OPTARG needs a value." >&2; usage 1 ;;
    \?) echo "Unknown option: -$OPTARG" >&2; usage 1 ;;
  esac
done
shift $((OPTIND - 1))

ISO_DIR="${1:-${ISO_DIR:-.}}"
OUT_DIR="${OUT_DIR:-$ISO_DIR/god}"

# --- sanity checks -----------------------------------------------------------
command -v iso2god >/dev/null 2>&1 || { echo "iso2god not found in PATH." >&2; exit 1; }
[[ -d "$ISO_DIR" ]] || { echo "Not a directory: $ISO_DIR" >&2; exit 1; }
[[ "$THREADS" =~ ^[0-9]+$ ]] || { echo "-j must be a number." >&2; exit 1; }

isos=("$ISO_DIR"/*.iso)
if (( ${#isos[@]} == 0 )); then
  echo "No .iso files found in: $ISO_DIR"
  exit 0
fi

[[ -n "$ENV_LOADED" ]] && echo "Settings from:  $ENV_LOADED"
echo "Found ${#isos[@]} ISO(s) in: $ISO_DIR"
echo "Output folder:  $OUT_DIR"
echo "Threads:        $THREADS"
echo "Delete ISOs:    $([[ $KEEP -eq 1 ]] && echo no || echo 'yes, after successful conversion')"
echo

if (( DRY_RUN )); then
  printf '  would convert: %s\n' "${isos[@]##*/}"
  exit 0
fi

mkdir -p -- "$OUT_DIR" || { echo "Cannot create $OUT_DIR" >&2; exit 1; }

LOG="$OUT_DIR/iso2god-$(date +%Y%m%d-%H%M%S).log"
ok=()
failed=()

# Stop cleanly on Ctrl+C: the ISO being converted is never deleted.
trap 'echo; echo "Interrupted — current ISO left untouched. Partial output may remain in $OUT_DIR." | tee -a "$LOG"; exit 130' INT TERM

i=0
for iso in "${isos[@]}"; do
  i=$((i + 1))
  name="${iso##*/}"
  echo "[$i/${#isos[@]}] $name" | tee -a "$LOG"

  # Free-space check: need roughly the ISO's size free in the output folder.
  iso_kb=$(du -k -- "$iso" | cut -f1)
  free_kb=$(df -Pk -- "$OUT_DIR" | awk 'NR==2 {print $4}')
  if (( free_kb < iso_kb )); then
    echo "  !! Not enough free space (need ~$((iso_kb/1024)) MB, have $((free_kb/1024)) MB). Skipping." | tee -a "$LOG"
    failed+=("$name (no space)")
    continue
  fi

  before_kb=$(du -sk -- "$OUT_DIR" | cut -f1)

  if iso2god -j "$THREADS" "$iso" "$OUT_DIR" >>"$LOG" 2>&1; then
    after_kb=$(du -sk -- "$OUT_DIR" | cut -f1)
    # Extra safety: make sure iso2god actually wrote something.
    if (( after_kb > before_kb )); then
      if (( KEEP )); then
        echo "  ok (ISO kept)" | tee -a "$LOG"
      else
        rm -- "$iso" && echo "  ok, ISO deleted" | tee -a "$LOG"
      fi
      ok+=("$name")
    else
      echo "  !! iso2god reported success but output didn't grow. ISO kept." | tee -a "$LOG"
      failed+=("$name (no output)")
    fi
  else
    echo "  !! iso2god failed (exit $?). ISO kept — see log." | tee -a "$LOG"
    failed+=("$name")
  fi
done

echo
echo "Done: ${#ok[@]} converted, ${#failed[@]} failed." | tee -a "$LOG"
if (( ${#failed[@]} )); then
  echo "Failed:" | tee -a "$LOG"
  printf '  - %s\n' "${failed[@]}" | tee -a "$LOG"
fi
echo "Log: $LOG"

(( ${#failed[@]} == 0 ))
