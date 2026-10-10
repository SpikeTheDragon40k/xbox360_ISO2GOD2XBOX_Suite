# xbox360-god-tools

Bash scripts for Linux that batch-convert Xbox 360 `.iso` images to
**Games on Demand (GOD)** format and upload them to a modded Xbox 360 over FTP.

| File | What it does |
|---|---|
| `iso2god-all.sh` | Converts every `.iso` in a folder with [iso2god-rs](https://github.com/iliazeus/iso2god-rs), deleting each ISO only after a successful conversion. |
| `god2xbox.sh` | Uploads every converted game to the console with `lftp`, with a live progress bar, speed and ETA. |
| `xbox360-tui.sh` | Optional menu that runs the two scripts and edits your settings. |
| `.env.example` | Template for your settings. |

## Requirements

- Linux with Bash 4.3+
- [iso2god-rs](https://github.com/iliazeus/iso2god-rs) on your `PATH` as `iso2god`
- `lftp` (`sudo apt install lftp`, `sudo pacman -S lftp`, `sudo dnf install lftp`, …)
- An Xbox 360 running Aurora or FreeStyle Dash with its FTP server enabled
- For the optional menu only: `whiptail` (Debian/Ubuntu: `whiptail`,
  Arch: `libnewt`, Fedora: `newt`) or `dialog`

## Settings (.env)

Put your settings in a `.env` file next to the scripts once, and you won't
need to pass them on the command line:

```bash
cp .env.example .env
chmod 600 .env        # it holds your FTP password
nano .env
```

```ini
ISO_DIR=~/xbox360/isos
GOD_DIR=~/xbox360/isos/god
ISO2GOD_THREADS=16
KEEP_ISOS=0
XBOX_HOST=192.168.1.50
XBOX_FTP_USER=xboxftp
XBOX_FTP_PASS=xboxftp
XBOX_REMOTE_PATH=/Hdd1/Content/0000000000000000
DELETE_AFTER_UPLOAD=0
```

- **Precedence:** command-line flags, then real environment variables, then
  `.env`, then built-in defaults.
- **Location:** the `.env` next to the scripts is used whatever folder you run
  them from. To use a different file, set `ENV_FILE=/path/to/file`.
- **Safety:** the file is parsed, never executed. Only `KEY=value` lines with
  the keys above are used. Quotes are optional, `~` expands to your home
  folder, and `#` starts a comment. `god2xbox.sh` warns if the file is
  readable by other users.
- `.env` is in `.gitignore`, so it won't be committed.

## Option 1: the menu

```bash
./xbox360-tui.sh
```

From the menu you can:
- **Convert:** preview the ISOs, then convert them and either delete or keep each ISO.
- **Upload:** preview the games, then upload them and either keep or delete the local copies.
- **Convert, then upload:** do both in one go.
- **Settings:** edit your settings. They're saved to `.env` with mode 600.
- **Logs:** open the latest log.

The conversions and uploads run in the normal terminal, so you still see the
full output and the upload progress bar. Set `XBOX_TUI=dialog` to use
`dialog` instead of `whiptail`.

## Option 2: the scripts directly

### 1. Convert ISOs to GOD

```bash
./iso2god-all.sh -n                    # preview, using ISO_DIR from .env
./iso2god-all.sh                       # convert
./iso2god-all.sh -j 16 ~/other/isos    # or give everything on the command line
```

| Option | Meaning |
|---|---|
| `-o DIR` | Output folder (default: `GOD_DIR`, else `<iso_dir>/god`) |
| `-j N` | Threads for iso2god (default: `ISO2GOD_THREADS`, else 16) |
| `-k` | Keep the ISOs instead of deleting them (or `KEEP_ISOS=1`) |
| `-n` | Dry run |

Safety checks: an ISO is deleted only if `iso2god` exits successfully **and**
the output folder actually grew. Games are skipped when there isn't enough free
disk space, and Ctrl+C never deletes the ISO being converted. Each run writes a
log file to the output folder.

### 2. Upload to the Xbox

```bash
./god2xbox.sh -n                          # preview, using GOD_DIR from .env
./god2xbox.sh                             # upload
./god2xbox.sh -H 192.168.1.50 ~/other/god # or give everything on the command line
```

```
[3/12] 4D5307E6  Crackdown 2 (7.0 GB)
  Game  [#################-------------]  58%  4.1 GB / 7.0 GB  10.8 MB/s  ETA 04:35
  Total [######------------------------]  21%  16.4 GB / 78.0 GB  game 3/12  ETA 1:35:02
```

| Option | Meaning |
|---|---|
| `-H HOST` | Console IP, optionally `HOST:PORT` (or `XBOX_HOST`) |
| `-u USER` | FTP user (default `XBOX_FTP_USER`, else `xboxftp`) |
| `-p PASS` | FTP password (default `XBOX_FTP_PASS`, else `xboxftp`) |
| `-r PATH` | Remote Content folder (default `XBOX_REMOTE_PATH`, else `/Hdd1/Content/0000000000000000`) |
| `-d` | Delete each local game folder after a successful upload (or `DELETE_AFTER_UPLOAD=1`) |
| `-n` | Dry run |
| `-q` | No progress bar; show plain lftp output |

Notes:

- The password is passed to lftp through an environment variable, so it never
  appears in the process list. Keep it in `.env` rather than using `-p`, which
  ends up in your shell history.
- An interrupted upload can be resumed by running the script again: `mirror`
  skips files that are already on the console.
- If the drive folder doesn't exist, the script lists the folders at the top of
  the FTP server so you can pick the right one with `-r` (e.g. `/Usb0/...`).
- After uploading, run a content scan in Aurora/FSD so the games show up.

## How the progress bar works

lftp doesn't print usable progress when its output isn't a terminal, so
`god2xbox.sh` runs it in the background and reads how far into each file it
has got from `/proc/<pid>/fdinfo`. lftp reads each local file sequentially
while sending it, so this tracks upload progress closely. This is Linux-only;
on other systems, or when the output isn't a terminal, the script falls back to
plain output.

## Disclaimer

Only use these scripts with games you own. Not affiliated with Microsoft or
with the iso2god-rs project.

## License

[MIT](LICENSE)
