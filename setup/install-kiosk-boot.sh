#!/usr/bin/env bash
# Ubuntu/LightDM: configure passwordless Openbox login and kiosk startup.
set -euo pipefail
umask 077
usage() {
  cat <<'EOF'
Usage: bash install-kiosk-boot.sh [--kiosk-dir DIRECTORY] [path/to/boot.json]

Run over SSH as the desktop user, without sudo. Sudo is requested once.
Without JSON: start the launcher with remote hostname.json/local default.json selection.
With JSON: install the explicit configuration as the fixed boot.json.
Installs streamflow-bg.png as the LightDM GTK Greeter login background.
Requires the dependencies listed in README.md. Does not reboot or start/stop services.
Default layout: setup/install-kiosk-boot.sh uses ../kiosk/url-kiosk.sh.
--kiosk-dir must point to the directory containing url-kiosk.sh itself.
EOF
}
script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
kiosk_dir=''
config=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --kiosk-dir)
      if [[ $# -lt 2 || -z "$2" ]]; then usage >&2; exit 1; fi
      kiosk_dir="$2"; shift 2 ;;
    --*) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *)
      if [[ -n "$config" ]]; then usage >&2; exit 1; fi
      config="$1"; shift ;;
  esac
done
if [[ "$EUID" == 0 ]]; then
  echo 'Run as the desktop user, without sudo. Only system configuration will request sudo.' >&2
  exit 1
fi
if [[ "$(uname -s)" != Linux ]]; then echo 'This installer requires Ubuntu/Linux.' >&2; exit 1; fi
if [[ -z "$kiosk_dir" ]]; then
  kiosk_dir="$script_dir/../kiosk"
fi
[[ -n "$kiosk_dir" && -f "$kiosk_dir/url-kiosk.sh" ]] || {
  echo "Launcher not found: $kiosk_dir/url-kiosk.sh" >&2
  echo 'Keep the dist structure (setup/ and kiosk/), or pass --kiosk-dir /path/to/kiosk.' >&2; exit 1;
}
kiosk_dir="$(cd -- "$kiosk_dir" && pwd -P)"
[[ -r "$kiosk_dir/streamflow-bg.png" ]] || { echo "Missing wallpaper: $kiosk_dir/streamflow-bg.png" >&2; exit 1; }
user_name="$(id -un)"
[[ "$user_name" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*\$?$ ]] || { echo 'Invalid login username.' >&2; exit 1; }
if [[ -n "$config" && ! -f "$config" ]]; then echo "Missing configuration: $config" >&2; exit 1; fi
[[ -f /usr/share/xsessions/openbox.desktop ]] || { echo 'Openbox is missing. Run the single dependency installation command in README.md.' >&2; exit 1; }
[[ -f /usr/share/xgreeters/lightdm-gtk-greeter.desktop ]] || { echo 'LightDM GTK Greeter is missing. Run the single dependency installation command in README.md.' >&2; exit 1; }
for dependency in lightdm debconf-set-selections systemctl; do
  command -v "$dependency" >/dev/null || { echo "Missing dependency: $dependency. Run the installation command in README.md." >&2; exit 1; }
done
lightdm_binary="$(command -v lightdm)"
/usr/bin/python3 -c 'import websocket' || { echo 'WebSocket support is missing. Run the single dependency installation command in README.md.' >&2; exit 1; }
if [[ -n "$config" ]]; then bash "$kiosk_dir/url-kiosk.sh" "$config" --no-update --check; fi
# Check administrator permission before modifying the user installation.
sudo -v
backup_suffix="$(date +%Y%m%d-%H%M%S)-$$"
temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT
# Configure the login background before enabling automatic Openbox startup.
greeter_config='/etc/lightdm/lightdm-gtk-greeter.conf'
greeter_background='/usr/share/backgrounds/url-kiosk/streamflow-bg.png'
if sudo test -f "$greeter_config"; then
  sudo cp -p -- "$greeter_config" "$greeter_config.backup-$backup_suffix"
  sudo cat "$greeter_config" > "$temporary/greeter.conf"
else
  : > "$temporary/greeter.conf"
fi
/usr/bin/python3 - "$temporary/greeter.conf" "$greeter_background" <<'PY'
import configparser
from pathlib import Path
import sys

path = Path(sys.argv[1])
config = configparser.ConfigParser(interpolation=None, strict=False)
config.read(path, encoding='utf-8')
if not config.has_section('greeter'):
    config.add_section('greeter')
config.set('greeter', 'background', sys.argv[2])
config.set('greeter', 'user-background', 'false')
with path.open('w', encoding='utf-8') as stream:
    config.write(stream, space_around_delimiters=False)
PY
sudo install -d -m 755 /usr/share/backgrounds/url-kiosk /etc/lightdm
if sudo test -f "$greeter_background"; then
  sudo cp -p -- "$greeter_background" "$greeter_background.backup-$backup_suffix"
fi
sudo install -m 644 "$kiosk_dir/streamflow-bg.png" "$greeter_background"
sudo install -m 644 "$temporary/greeter.conf" "$greeter_config"
if [[ -n "$config" ]]; then
  bash "$kiosk_dir/url-kiosk.sh" "$config" --no-update --install-autostart
else
  bash "$kiosk_dir/url-kiosk.sh" --no-update --install-autostart
fi
# Back up the selected display manager before changing the next boot.
for path in /etc/X11/default-display-manager /etc/systemd/system/display-manager.service; do
  if sudo test -e "$path" || sudo test -L "$path"; then
    sudo cp -a -- "$path" "$path.backup-$backup_suffix"
  fi
done
# Set the package preference without opening an interactive display-manager selector.
printf '%s\n' 'lightdm shared/default-x-display-manager select lightdm' | sudo debconf-set-selections
printf '%s\n' "$lightdm_binary" | sudo tee /etc/X11/default-display-manager >/dev/null
sudo chmod 644 /etc/X11/default-display-manager
# Enable for the next boot only. Do not start or restart the running desktop.
sudo systemctl enable --force lightdm.service
lightdm_config='/etc/lightdm/lightdm.conf.d/99-url-kiosk-autologin.conf'
cat > "$temporary/autologin.conf" <<EOF
# URL Kiosk: unattended local Openbox session.
[Seat:*]
autologin-user=$user_name
autologin-user-timeout=0
autologin-session=openbox
user-session=openbox
greeter-session=lightdm-gtk-greeter
EOF
sudo install -d -m 755 /etc/lightdm/lightdm.conf.d
if sudo test -f "$lightdm_config"; then
  sudo cp -p -- "$lightdm_config" "$lightdm_config.backup-$(date +%Y%m%d-%H%M%S)-$$"
fi
sudo install -m 644 "$temporary/autologin.conf" "$lightdm_config"
sudo systemctl set-default graphical.target
# A main lightdm.conf or seat-specific section may override this drop-in.
echo 'Effective LightDM configuration (check for overrides):'
sudo lightdm --show-config
echo "Configured automatic Openbox login for: $user_name"
echo "Configured LightDM login background: $greeter_background"
if [[ -n "$config" ]]; then
  echo 'Openbox runs ~/.local/bin/run-kiosk.sh with the fixed ~/.config/url-kiosk/boot.json.'
else
  echo 'Openbox runs the original launcher without JSON: remote hostname.json, then local default.json.'
fi
echo "Kiosk directory: $kiosk_dir"
echo 'Other JSON files are never scanned or automatically loaded.'
echo "Startup diagnostics: $kiosk_dir/kiosk-startup.log (hostname mode)"
echo 'No session has been restarted. Reboot when ready: sudo reboot'
