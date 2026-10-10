#!/usr/bin/env bash
#
# xbox360-tui.sh — optional menu front-end for iso2god-all.sh and god2xbox.sh.
#
# Lets you convert, upload, preview, edit the .env settings and read the logs
# from a simple menu. The two scripts keep working on their own; this only
# runs them for you.
#
# Needs whiptail (Debian/Ubuntu: whiptail, Arch: libnewt, Fedora: newt)
# or dialog (set XBOX_TUI=dialog to prefer it). Uses the same .env as the scripts (next to this file, or
# $ENV_FILE).

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENVF="${ENV_FILE:-$SCRIPT_DIR/.env}"
CONVERT="$SCRIPT_DIR/iso2god-all.sh"
UPLOAD="$SCRIPT_DIR/god2xbox.sh"
BACKTITLE="Xbox 360 GOD tools"

# --- pick a dialog program -----------------------------------------------------
# Prefer whiptail; set XBOX_TUI=dialog to use dialog instead.
if [[ "${XBOX_TUI:-}" =~ ^(dialog|whiptail)$ ]] && command -v "$XBOX_TUI" >/dev/null 2>&1; then UI=$XBOX_TUI
elif command -v whiptail >/dev/null 2>&1; then UI=whiptail
elif command -v dialog >/dev/null 2>&1; then UI=dialog
else
  echo "The TUI needs whiptail or dialog. Install one, for example:" >&2
  echo "  Debian/Ubuntu: sudo apt install whiptail" >&2
  echo "  Arch:          sudo pacman -S libnewt" >&2
  echo "  Fedora:        sudo dnf install newt" >&2
  echo "Or run iso2god-all.sh and god2xbox.sh directly." >&2
  exit 1
fi
[[ -t 0 && -t 1 ]] || { echo "xbox360-tui.sh must be run in a terminal." >&2; exit 1; }
for s in "$CONVERT" "$UPLOAD"; do
  [[ -x "$s" ]] || { echo "Missing or not executable: $s" >&2; exit 1; }
done

# Box size: fit the terminal, up to 76x22.
size() {
  local lines cols
  lines=$(tput lines 2>/dev/null || echo 24); cols=$(tput cols 2>/dev/null || echo 80)
  H=$(( lines - 4 )); (( H > 22 )) && H=22; (( H < 10 )) && H=10
  W=$(( cols - 4 ));  (( W > 76 )) && W=76; (( W < 40 )) && W=40
  MH=$(( H - 12 ));   (( MH < 3 )) && MH=3   # leaves room for 4 lines of text
}

# Shorten text to N columns: "fit text N" cuts the end, "fit text N left"
# keeps the end (for paths). Long menu entries break whiptail's layout.
fit() {
  local t=$1 n=$2
  (( n < 8 )) && n=8
  if (( ${#t} <= n )); then printf '%s' "$t"
  elif [[ ${3:-} == left ]]; then printf '…%s' "${t: -$(( n - 1 ))}"
  else printf '%s…' "${t:0:$(( n - 1 ))}"; fi
}

# A path shortened to fit inside the box (keeps the end of the path).
pth() { fit "$1" $(( W - 18 )) left; }

# Run the dialog program; the chosen value is printed on stdout.
ui() { "$UI" --backtitle "$BACKTITLE" "$@" 3>&1 1>&2 2>&3; }
msg()   { size; ui --title "${2:-Info}" --msgbox "$1" "$H" "$W"; }
ask()   { size; ui --title "${2:-Confirm}" --yesno "$1" "$H" "$W"; }
input() { size; ui --title "$1" --inputbox "$2" 10 "$W" "${3:-}"; }
secret() {
  size
  if [[ $UI == dialog ]]; then ui --title "$1" --insecure --passwordbox "$2" 10 "$W" "${3:-}"
  else ui --title "$1" --passwordbox "$2" 10 "$W" "${3:-}"; fi
}
textbox() {
  size
  if [[ $UI == whiptail ]]; then ui --title "$2" --scrolltext --textbox "$1" "$H" "$W"
  else ui --title "$2" --textbox "$1" "$H" "$W"; fi
}

# --- settings (.env) -----------------------------------------------------------
KEYS=(ISO_DIR GOD_DIR ISO2GOD_THREADS KEEP_ISOS XBOX_HOST XBOX_FTP_USER XBOX_FTP_PASS XBOX_REMOTE_PATH DELETE_AFTER_UPLOAD)
declare -A LABEL=(
  [ISO_DIR]="ISO folder"
  [GOD_DIR]="GOD output folder"
  [ISO2GOD_THREADS]="iso2god threads"
  [KEEP_ISOS]="Keep ISOs after converting (1/0)"
  [XBOX_HOST]="Xbox IP address"
  [XBOX_FTP_USER]="FTP user"
  [XBOX_FTP_PASS]="FTP password"
  [XBOX_REMOTE_PATH]="Remote Content folder"
  [DELETE_AFTER_UPLOAD]="Delete local copy after upload (1/0)"
)
declare -A DEFAULT=(
  [ISO_DIR]="" [GOD_DIR]="" [ISO2GOD_THREADS]="16" [KEEP_ISOS]="0"
  [XBOX_HOST]="" [XBOX_FTP_USER]="xboxftp" [XBOX_FTP_PASS]="xboxftp"
  [XBOX_REMOTE_PATH]="/Hdd1/Content/0000000000000000" [DELETE_AFTER_UPLOAD]="0"
)
declare -A CFG=()

# Read .env into CFG, with the same rules as the scripts (values kept raw, so
# "~/..." is written back unchanged).
load_cfg() {
  local line key val
  CFG=()
  [[ -f "$ENVF" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"; line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    line="${line#export }"
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key=${BASH_REMATCH[1]}; val=${BASH_REMATCH[2]}
    if [[ "$val" =~ ^\"(.*)\"[[:space:]]*$ || "$val" =~ ^\'(.*)\'[[:space:]]*$ ]]; then
      val=${BASH_REMATCH[1]}
    else
      val="${val%%[[:space:]]#*}"; val="${val%"${val##*[![:space:]]}"}"
    fi
    CFG[$key]=$val
  done < "$ENVF"
}

# Quote a value for .env: double quotes, or single quotes if it has a ".
quote() {
  if [[ "$1" != *\"* ]]; then printf '"%s"' "$1"; else printf "'%s'" "$1"; fi
}

# Write CFG back to .env, updating existing lines in place and keeping
# comments and unknown lines. New keys are appended. File mode 600.
save_cfg() {
  local tmp line key done_keys=" "
  tmp=$(mktemp "${ENVF}.XXXXXX") || { msg "Can't write next to $ENVF" "Error"; return 1; }
  if [[ -f "$ENVF" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)= ]] \
         && [[ -n "${CFG[${BASH_REMATCH[2]}]+x}" ]]; then
        key=${BASH_REMATCH[2]}
        printf '%s=%s\n' "$key" "$(quote "${CFG[$key]}")" >> "$tmp"
        done_keys+="$key "
      else
        printf '%s\n' "$line" >> "$tmp"
      fi
    done < "$ENVF"
  else
    printf '# Settings for iso2god-all.sh, god2xbox.sh and xbox360-tui.sh\n' >> "$tmp"
  fi
  for key in "${KEYS[@]}"; do
    [[ -n "${CFG[$key]+x}" && "$done_keys" != *" $key "* ]] \
      && printf '%s=%s\n' "$key" "$(quote "${CFG[$key]}")" >> "$tmp"
  done
  chmod 600 "$tmp" && mv -f -- "$tmp" "$ENVF"
}

# Effective value: real environment variable > .env > default; ~ expanded.
eff() {
  local key=$1 v
  if [[ -n "${!key+x}" ]]; then v=${!key}
  elif [[ -n "${CFG[$key]+x}" ]]; then v=${CFG[$key]}
  else v=${DEFAULT[$key]}; fi
  [[ "$v" == "~" ]] && v=$HOME
  [[ "$v" == \~/* ]] && v="$HOME/${v:2}"
  printf '%s' "$v"
}

iso_dir() { local d; d=$(eff ISO_DIR); printf '%s' "${d:-$PWD}"; }
god_dir() { local d; d=$(eff GOD_DIR); printf '%s' "${d:-$(iso_dir)/god}"; }

settings_menu() {
  local choice=ISO_DIR key shown dirty=0 items=() new
  load_cfg
  while true; do
    items=()
    for key in "${KEYS[@]}"; do
      shown=${CFG[$key]-}
      [[ $key == XBOX_FTP_PASS && -n "$shown" ]] && shown="********"
      [[ -z "$shown" ]] && shown="(not set${DEFAULT[$key]:+, default ${DEFAULT[$key]}})"
      [[ $key == XBOX_FTP_PASS && -z "${CFG[$key]-}" ]] && shown="(not set, default xboxftp)"
      size
      items+=("$key" "$(fit "${LABEL[$key]}: $shown" $(( W - 30 )))")
    done
    items+=("SAVE" "Save and go back" "BACK" "Go back without saving")
    choice=$(ui --title "Settings ($(fit "$ENVF" $(( W - 16 )) left))" --default-item "$choice" --menu "Choose a setting to change:" "$H" "$W" "$MH" "${items[@]}") || choice=BACK
    case "$choice" in
      SAVE)
        if save_cfg; then msg "Saved to $ENVF (readable only by you)." "Settings"; fi
        return ;;
      BACK)
        if (( dirty )) && ask "Discard your unsaved changes?" "Settings"; then return
        elif (( ! dirty )); then return; fi ;;
      XBOX_FTP_PASS)
        new=$(secret "${LABEL[$choice]}" "FTP password for the console:" "${CFG[$choice]-}") \
          && { CFG[$choice]=$new; dirty=1; } ;;
      *)
        new=$(input "${LABEL[$choice]}" "$choice (leave empty for the default${DEFAULT[$choice]:+: ${DEFAULT[$choice]}}):" "${CFG[$choice]-}") || continue
        if [[ -z "$new" ]]; then unset 'CFG[$choice]'; else CFG[$choice]=$new; fi
        dirty=1 ;;
    esac
  done
}

# --- running the scripts -------------------------------------------------------
pause() { echo; read -rp "$1 Press Enter to return to the menu... " _; }

# run "title" cmd args... : runs in the plain terminal so the progress bar works.
run() {
  local title=$1 rc; shift
  clear
  printf '=== %s ===\n\n' "$title"
  "$@"; rc=$?
  return "$rc"
}

convert_menu() {
  local choice dir mode=() envs=()
  size
  choice=$(ui --title "Convert ISOs to GOD" --menu "ISO folder: $(pth "$(iso_dir)")\nOutput:     $(pth "$(god_dir)")" "$H" "$W" "$MH" \
    preview "Preview: list the ISOs, change nothing" \
    delete  "Convert, delete each ISO after it converts" \
    keep    "Convert, keep the ISOs" \
    folder  "Pick a different ISO folder for this run") || return
  dir=$(iso_dir)
  if [[ $choice == folder ]]; then
    dir=$(input "ISO folder" "Folder with the .iso files:" "$dir") || return
    [[ "$dir" == \~/* ]] && dir="$HOME/${dir:2}"
    choice=$(ui --title "Convert ISOs to GOD" --menu "ISO folder: $(pth "$dir")" "$H" "$W" "$MH" \
      preview "Preview" delete "Convert and delete ISOs" keep "Convert and keep ISOs") || return
  fi
  [[ -d "$dir" ]] || { msg "Folder not found:\n$dir" "Error"; return; }
  case "$choice" in
    preview) mode=(-n) ;;
    delete)  ask "Convert every ISO in:\n$dir\n\nEach ISO is deleted after it converts successfully. Continue?" || return
             envs=(KEEP_ISOS=0) ;;
    keep)    mode=(-k) ;;
  esac
  run "Convert ISOs" env "${envs[@]}" "$CONVERT" "${mode[@]}" -o "$(god_dir)" "$dir"
  pause "Finished (exit $?)."
}

upload_menu() {
  local choice dir mode=() envs=()
  if [[ -z "$(eff XBOX_HOST)" ]]; then
    msg "Set your Xbox IP address first (Settings → XBOX_HOST)." "Upload"
    return
  fi
  dir=$(god_dir)
  size
  choice=$(ui --title "Upload to Xbox" --menu "From: $(pth "$dir")\nTo:   $(eff XBOX_HOST) $(eff XBOX_REMOTE_PATH)" "$H" "$W" "$MH" \
    preview "Preview: list the games, don't connect" \
    upload  "Upload, keep the local copies" \
    delete  "Upload, delete each local copy after it uploads" \
    folder  "Pick a different GOD folder for this run") || return
  if [[ $choice == folder ]]; then
    dir=$(input "GOD folder" "Folder with the converted games:" "$dir") || return
    [[ "$dir" == \~/* ]] && dir="$HOME/${dir:2}"
    choice=$(ui --title "Upload to Xbox" --menu "From: $(pth "$dir")" "$H" "$W" "$MH" \
      preview "Preview" upload "Upload, keep local copies" delete "Upload and delete local copies") || return
  fi
  [[ -d "$dir" ]] || { msg "Folder not found:\n$dir" "Error"; return; }
  case "$choice" in
    preview) mode=(-n) ;;
    upload)  envs=(DELETE_AFTER_UPLOAD=0) ;;
    delete)  ask "Upload every game in:\n$dir\n\nEach local game folder is deleted after it uploads successfully. Continue?" || return
             envs=(DELETE_AFTER_UPLOAD=1) ;;
  esac
  run "Upload to Xbox" env "${envs[@]}" "$UPLOAD" "${mode[@]}" "$dir"
  pause "Finished (exit $?)."
}

convert_then_upload() {
  local rc
  if [[ -z "$(eff XBOX_HOST)" ]]; then
    msg "Set your Xbox IP address first (Settings → XBOX_HOST)." "Convert and upload"
    return
  fi
  ask "Convert every ISO in:\n$(iso_dir)\n\nthen upload everything in:\n$(god_dir)\n\nto $(eff XBOX_HOST).\n\nISOs are $( [[ $(eff KEEP_ISOS) =~ ^(1|yes|true)$ ]] && echo kept || echo 'deleted after converting' ); local GOD copies are $( [[ $(eff DELETE_AFTER_UPLOAD) =~ ^(1|yes|true)$ ]] && echo 'deleted after uploading' || echo kept ) (change in Settings). Continue?" "Convert and upload" || return
  run "Step 1/2: convert" "$CONVERT" -o "$(god_dir)" "$(iso_dir)"; rc=$?
  if (( rc != 0 )); then
    echo
    local a
    read -rp "Some conversions failed (exit $rc). Upload what was converted anyway? [y/N] " a
    [[ $a == [yY]* ]] || { pause "Stopped before uploading."; return; }
  fi
  echo; printf '=== Step 2/2: upload ===\n\n'
  "$UPLOAD" "$(god_dir)"
  pause "Finished (exit $?)."
}

view_log() {
  local dir f
  dir=$(god_dir)
  f=$(ls -t -- "$dir"/*.log 2>/dev/null | head -n 1)
  [[ -n "$f" ]] || { msg "No log files in:\n$dir" "Logs"; return; }
  if command -v less >/dev/null 2>&1; then
    # less handles long logs much better (scroll, search with /). q quits.
    local name; name=$(basename "$f"); name=${name//./\\.}   # "." is special in less prompts
    clear
    less -R +G -P "$name — q to go back, / to search" -- "$f"
  else
    textbox "$f" "$(basename "$f")"
  fi
}

# --- main menu -----------------------------------------------------------------
load_cfg
if [[ ! -f "$ENVF" ]] && ask "No settings file yet ($ENVF).\n\nSet up your folders and Xbox address now?" "Welcome"; then
  settings_menu
fi

while true; do
  load_cfg
  size
  choice=$(ui --title "Main menu" --menu "ISOs: $(pth "$(iso_dir)")\nGOD:  $(pth "$(god_dir)")\nXbox: $(eff XBOX_HOST)" "$H" "$W" "$MH" \
    1 "Convert ISOs to GOD" \
    2 "Upload games to the Xbox" \
    3 "Convert, then upload" \
    4 "Settings (.env)" \
    5 "View the latest log" \
    q "Quit") || break
  case "$choice" in
    1) convert_menu ;;
    2) upload_menu ;;
    3) convert_then_upload ;;
    4) settings_menu ;;
    5) view_log ;;
    q) break ;;
  esac
done
clear
