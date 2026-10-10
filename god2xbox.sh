#!/usr/bin/env bash
#
# god2xbox.sh — upload every GOD game folder (named by Title ID) to an
# Xbox 360 over FTP with lftp, one game at a time, with a live progress bar.
#
# Usage:
#   ./god2xbox.sh [options] [god_dir]
#
# Options:
#   -H HOST  Xbox IP address, optionally HOST:PORT  (or $XBOX_HOST; required)
#   -u USER  FTP user                 (default: $XBOX_FTP_USER, else xboxftp)
#   -p PASS  FTP password             (default: $XBOX_FTP_PASS, else xboxftp)
#   -r PATH  remote Content folder    (default: $XBOX_REMOTE_PATH,
#                                      else /Hdd1/Content/0000000000000000)
#   -d       delete each local game folder after a successful upload
#            (or DELETE_AFTER_UPLOAD=1)
#   -n       dry run: list what would be uploaded, don't connect
#   -q       no progress bar (plain lftp output instead)
#   -h       show this help
#
# god_dir defaults to $GOD_DIR, else ./god (the output of iso2god-all.sh).
# Settings can also come from a .env file next to the script (see .env.example).
#
# Examples:
#   ./god2xbox.sh -H 192.168.1.50 ./god
#   ./god2xbox.sh              # everything taken from .env

set -uo pipefail
shopt -s nullglob

ENV_KEYS="XBOX_HOST XBOX_FTP_USER XBOX_FTP_PASS XBOX_REMOTE_PATH GOD_DIR DELETE_AFTER_UPLOAD ISO_DIR ISO2GOD_THREADS KEEP_ISOS"
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

HOST="${XBOX_HOST:-}"
USER_NAME="${XBOX_FTP_USER:-xboxftp}"
PASS="${XBOX_FTP_PASS:-xboxftp}"   # Aurora/FSD default login is xboxftp / xboxftp
REMOTE_BASE="${XBOX_REMOTE_PATH:-/Hdd1/Content/0000000000000000}"
REMOTE_BASE="${REMOTE_BASE%/}"
DELETE=$([[ "${DELETE_AFTER_UPLOAD:-0}" =~ ^(1|yes|true)$ ]] && echo 1 || echo 0)
DRY_RUN=0
SHOW_BAR=1

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit "${1:-0}"; }

while getopts ":H:u:p:r:dnqh" opt; do
  case "$opt" in
    H) HOST="$OPTARG" ;;
    u) USER_NAME="$OPTARG" ;;
    p) PASS="$OPTARG" ;;
    r) REMOTE_BASE="${OPTARG%/}" ;;
    d) DELETE=1 ;;
    n) DRY_RUN=1 ;;
    q) SHOW_BAR=0 ;;
    h) usage 0 ;;
    :) echo "Option -$OPTARG needs a value." >&2; usage 1 ;;
    \?) echo "Unknown option: -$OPTARG" >&2; usage 1 ;;
  esac
done
shift $((OPTIND - 1))

GOD_DIR="${1:-${GOD_DIR:-./god}}"
GOD_DIR="${GOD_DIR%/}"

# The bar only makes sense on a real terminal, and reads lftp's progress from /proc.
[[ -t 1 && -d /proc/self/fdinfo ]] || SHOW_BAR=0

# --- helpers -----------------------------------------------------------------

# Human-readable size: 7516192768 -> "7.0 GB"
human() {
  local b=$1
  if   (( b >= 1073741824 )); then printf '%d.%d GB' $((b/1073741824)) $(( (b%1073741824)*10/1073741824 ))
  elif (( b >= 1048576 ));    then printf '%d.%d MB' $((b/1048576))    $(( (b%1048576)*10/1048576 ))
  elif (( b >= 1024 ));       then printf '%d KB' $((b/1024))
  else printf '%d B' "$b"; fi
}

# Seconds -> "05:07" or "1:02:03"; "--:--" when unknown.
hms() {
  local s=$1
  (( s < 0 )) && { printf -- '--:--'; return; }
  if (( s >= 3600 )); then printf '%d:%02d:%02d' $((s/3600)) $((s%3600/60)) $((s%60))
  else printf '%02d:%02d' $((s/60)) $((s%60)); fi
}

# Progress bar: bar <percent> <width> -> "#########-----------"
bar() {
  local p=$1 w=$2 f full empty
  (( p > 100 )) && p=100
  f=$(( p * w / 100 ))
  printf -v full  '%*s' "$f" '';         full=${full// /#}
  printf -v empty '%*s' $(( w - f )) ''; empty=${empty// /-}
  printf '%s%s' "$full" "$empty"
}

# Total bytes of all files in a folder.
dirbytes() { find "$1" -type f -printf '%s\n' | awk '{s += $1} END {print s + 0}'; }

# Game name from the GOD header file (display name, UTF-16BE at 0x411).
# Prints nothing if it can't be read.
game_title() {
  local f t
  for f in "$1"/*/*; do
    [[ -f "$f" ]] || continue
    t=$(tail -c +$((0x411 + 1)) -- "$f" 2>/dev/null | head -c 128 \
        | iconv -f UTF-16BE -t UTF-8 2>/dev/null | tr -d '\000')
    if [[ -n "$t" && "$t" =~ ^[[:print:]]+$ ]]; then printf '%s' "$t"; return; fi
  done
}

# Monotonic-ish clock in milliseconds.
now_ms() {
  if [[ -n "${EPOCHREALTIME:-}" ]]; then local t=${EPOCHREALTIME/[.,]/}; NOW_MS=$(( t / 1000 ))
  else NOW_MS=$(date +%s%3N); fi
}

# How many bytes of the game lftp has read so far. lftp reads each local file
# sequentially while uploading, so the read position of its open file
# descriptors (in /proc/PID/fdinfo) tracks upload progress. Files it has
# opened and closed again count as fully sent. Result goes in $PROG.
declare -A SEEN=()
game_progress() {
  local pid=$1 src=$2 fd t pos k v total=0
  local -A open=()
  for fd in /proc/"$pid"/fd/*; do
    t=$(readlink -- "$fd" 2>/dev/null) || continue
    [[ "$t" == "$src"/* ]] || continue
    pos=0
    while read -r k v; do
      [[ $k == pos: ]] && { pos=$v; break; }
    done < "/proc/$pid/fdinfo/${fd##*/}" 2>/dev/null
    open[$t]=$pos
    [[ -n "${SEEN[$t]+x}" ]] || SEEN[$t]=$(stat -c %s -- "$t" 2>/dev/null || echo 0)
  done
  for t in "${!SEEN[@]}"; do
    if [[ -n "${open[$t]+x}" ]]; then total=$(( total + open[$t] ))
    else total=$(( total + SEEN[$t] )); fi
  done
  PROG=$total
}

# Quote a string for use inside an lftp command (double quotes, escaped).
lq() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"; }

# --- sanity checks -----------------------------------------------------------
command -v lftp >/dev/null 2>&1 || { echo "lftp not found in PATH." >&2; exit 1; }
[[ -d "$GOD_DIR" ]] || { echo "Not a directory: $GOD_DIR" >&2; exit 1; }

# Game folders are 8-character hex Title IDs (e.g. 4D5307DC). Anything else
# in the folder (logs, stray files) is ignored.
games=()
for d in "$GOD_DIR"/*/; do
  id="$(basename "$d")"
  [[ "$id" =~ ^[0-9A-Fa-f]{8}$ ]] && games+=("$id")
done

if (( ${#games[@]} == 0 )); then
  echo "No Title ID folders (e.g. 4D5307DC) found in: $GOD_DIR"
  exit 0
fi

declare -A SIZE=() TITLE=()
TOTAL=0
for id in "${games[@]}"; do
  SIZE[$id]=$(dirbytes "$GOD_DIR/$id")
  TITLE[$id]=$(game_title "$GOD_DIR/$id")
  TOTAL=$(( TOTAL + SIZE[$id] ))
done

if [[ -n "$ENV_LOADED" ]]; then
  echo "Settings from:  $ENV_LOADED"
  # The .env holds the FTP password: warn if other users can read it.
  perms=$(stat -c %a -- "$ENV_LOADED" 2>/dev/null || echo 600)
  if (( (8#$perms & 8#077) != 0 )) && grep -q '^[[:space:]]*\(export \)\?XBOX_FTP_PASS=' "$ENV_LOADED"; then
    echo "Warning: $ENV_LOADED contains your FTP password and is readable by other users. Fix with: chmod 600 \"$ENV_LOADED\"" >&2
  fi
fi
echo "Found ${#games[@]} game(s), $(human "$TOTAL") in: $GOD_DIR"
echo "Target:         ftp://$USER_NAME@$HOST/${REMOTE_BASE#/}/"
echo "Delete local:   $([[ $DELETE -eq 1 ]] && echo 'yes, after successful upload' || echo no)"
echo

if (( DRY_RUN )); then
  for id in "${games[@]}"; do
    printf '  would upload: %s  %-40s %9s\n' "$id" "${TITLE[$id]:-}" "$(human "${SIZE[$id]}")"
  done
  exit 0
fi

# Common lftp settings. cmd:fail-exit makes lftp exit non-zero as soon as
# a command (e.g. mirror) fails, so the script can tell success from failure.
# (Must stay on one line: lftp -e stops at a newline.)
SETTINGS='set ftp:ssl-allow no; set ftp:passive-mode on; set xfer:clobber on; set net:timeout 20; set net:max-retries 3; set net:reconnect-interval-base 5; set cmd:fail-exit yes'

LOG="$GOD_DIR/upload-$(date +%Y%m%d-%H%M%S).log"

if [[ -z "$HOST" ]]; then
  echo "No Xbox address given. Use -H 192.168.x.x or set XBOX_HOST." >&2
  exit 1
fi

# lftp reads the password from this variable (--env-password), so it never
# shows up in the process list.
export LFTP_PASSWORD="$PASS"

# --- connection test ---------------------------------------------------------
# Checks that we can log in, then that the drive folder (first part of the
# remote path, e.g. /Hdd1) exists. The Content folder itself may not exist
# yet; it is created before each upload.
echo "Testing connection to $HOST ..."
if ! lftp --env-password -u "$USER_NAME" -e "$SETTINGS; cls -1 >/dev/null; quit" "ftp://$HOST" >>"$LOG" 2>&1 </dev/null; then
  echo "!! Can't connect or log in to $HOST." >&2
  echo "   Is the Xbox on, with Aurora/FSD's FTP server running? Details in: $LOG" >&2
  exit 1
fi
if [[ "$REMOTE_BASE" == /* ]]; then
  drive="/$(cut -d/ -f2 <<<"$REMOTE_BASE")"
  if ! lftp --env-password -u "$USER_NAME" -e "$SETTINGS; cd $(lq "$drive"); quit" "ftp://$HOST" >>"$LOG" 2>&1 </dev/null; then
    echo "!! Logged in, but the folder $drive doesn't exist on the Xbox." >&2
    echo "   Folders at the top of the FTP server:" >&2
    lftp --env-password -u "$USER_NAME" -e "set ftp:ssl-allow no; cls -1 /; quit" "ftp://$HOST" 2>/dev/null </dev/null | sed 's/^/     /' >&2
    echo "   Pick the right drive and pass it with -r, e.g. -r /Hdd1/Content/0000000000000000" >&2
    exit 1
  fi
fi
echo "Connected."
echo

# Create the remote Content folder (and parents) if missing. Errors are
# ignored on purpose: if it already exists, mkdir fails harmlessly.
MKDIR_BASE="set cmd:fail-exit no; mkdir -p -f $(lq "$REMOTE_BASE"); set cmd:fail-exit yes"

LFTP_PID=""
on_interrupt() {
  [[ -n "$LFTP_PID" ]] && kill "$LFTP_PID" 2>/dev/null
  (( SHOW_BAR )) && printf '\033[?25h'   # show cursor again
  echo
  echo "Interrupted — re-run the script to resume (mirror skips files already uploaded)." | tee -a "$LOG"
  exit 130
}
trap on_interrupt INT TERM

ok=()
failed=()
DONE_BEFORE=0     # bytes of games already finished (or skipped) this run
RUN_START=$SECONDS
i=0
for id in "${games[@]}"; do
  i=$((i + 1))
  src="$GOD_DIR/$id"
  dst="$REMOTE_BASE/$id"
  gsize=${SIZE[$id]}
  name="${TITLE[$id]:+  ${TITLE[$id]}}"

  echo "[$i/${#games[@]}] $id$name ($(human "$gsize"))" | tee -a "$LOG" >/dev/null
  printf '[%d/%d] %s%s (%s)\n' "$i" "${#games[@]}" "$id" "$name" "$(human "$gsize")"

  cmd="$SETTINGS; $MKDIR_BASE; mirror -R --verbose $(lq "$src") $(lq "$dst"); quit"
  game_start=$SECONDS
  log_start=$(wc -l < "$LOG")

  if (( SHOW_BAR )); then
    # Run lftp in the background (output to the log) and draw the bar ourselves.
    lftp --env-password -u "$USER_NAME" -e "$cmd" "ftp://$HOST" >>"$LOG" 2>&1 </dev/null &
    LFTP_PID=$!
    src_abs=$(realpath -- "$src")
    SEEN=()
    hist_b=(); hist_t=()     # recent samples for a smoothed speed
    printf '\033[?25l\n\n'   # hide cursor, reserve two lines

    draw() {
      local gdone=$1 speed=$2 alldone gp tp geta teta cols bw l1 l2
      alldone=$(( DONE_BEFORE + gdone ))
      gp=$(( gsize > 0 ? gdone * 100 / gsize : 100 ))
      tp=$(( TOTAL > 0 ? alldone * 100 / TOTAL : 100 ))
      if (( speed > 0 )); then
        geta=$(( (gsize - gdone) / speed )); teta=$(( (TOTAL - alldone) / speed ))
      else geta=-1; teta=-1; fi
      # Fit the bar to the terminal so lines never wrap (wrapping breaks the redraw).
      cols=$(tput cols 2>/dev/null || echo 80); (( cols > 0 )) || cols=80
      bw=$(( cols - 66 )); (( bw > 40 )) && bw=40; (( bw < 10 )) && bw=10
      printf -v l1 '  Game  [%s] %3d%%  %s / %s  %s/s  ETA %s' \
        "$(bar "$gp" "$bw")" "$gp" "$(human "$gdone")" "$(human "$gsize")" "$(human "$speed")" "$(hms "$geta")"
      printf -v l2 '  Total [%s] %3d%%  %s / %s  game %d/%d  ETA %s' \
        "$(bar "$tp" "$bw")" "$tp" "$(human "$alldone")" "$(human "$TOTAL")" "$i" "${#games[@]}" "$(hms "$teta")"
      printf '\033[2A\r\033[K%.*s\n\r\033[K%.*s\n' $(( cols - 1 )) "$l1" $(( cols - 1 )) "$l2"
    }

    speed=0
    while kill -0 "$LFTP_PID" 2>/dev/null; do
      game_progress "$LFTP_PID" "$src_abs"
      gdone=$(( PROG > gsize ? gsize : PROG ))
      now_ms
      hist_b+=("$gdone"); hist_t+=("$NOW_MS")
      if (( ${#hist_b[@]} > 10 )); then hist_b=("${hist_b[@]:1}"); hist_t=("${hist_t[@]:1}"); fi
      dt=$(( hist_t[-1] - hist_t[0] ))
      (( dt > 0 )) && speed=$(( (hist_b[-1] - hist_b[0]) * 1000 / dt ))
      draw "$gdone" "$speed"
      sleep 1
    done
    wait "$LFTP_PID"; rc=$?
    LFTP_PID=""
    (( rc == 0 )) && draw "$gsize" "$speed"
    printf '\033[?25h'   # show cursor
  else
    lftp --env-password -u "$USER_NAME" -e "$cmd" "ftp://$HOST" 2>&1 </dev/null | tee -a "$LOG"
    rc=${PIPESTATUS[0]}
  fi

  took=$(( SECONDS - game_start ))
  if (( rc == 0 )); then
    avg=$(( took > 0 ? gsize / took : 0 ))
    msg="  ok in $(hms "$took") (avg $(human "$avg")/s)"
    if (( DELETE )); then
      rm -rf -- "$src" && msg="$msg, local copy deleted"
    fi
    echo "$msg" | tee -a "$LOG"
    ok+=("$id")
  else
    # Show lftp's own error (the last lines it wrote for this game).
    reason=$(tail -n +$(( log_start + 1 )) "$LOG" | grep -v '^\(Making directory\|Transferring file\)' | tail -n 2 | sed 's/^/     /')
    echo "  !! upload failed — local copy kept. Re-run to resume." | tee -a "$LOG"
    [[ -n "$reason" ]] && echo "$reason"
    failed+=("$id")
  fi
  DONE_BEFORE=$(( DONE_BEFORE + gsize ))
done

echo
echo "Done: ${#ok[@]} uploaded, ${#failed[@]} failed, total time $(hms $(( SECONDS - RUN_START )))." | tee -a "$LOG"
if (( ${#failed[@]} )); then
  echo "Failed:" | tee -a "$LOG"
  printf '  - %s\n' "${failed[@]}" | tee -a "$LOG"
fi
echo "Log: $LOG"
echo "Tip: run a content scan in Aurora/FSD so the new games show up."

(( ${#failed[@]} == 0 ))
