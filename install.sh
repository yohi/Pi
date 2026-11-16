#!/bin/sh
# GitHub bootstrap: curl -fsSL https://raw.githubusercontent.com/yohi/Pi/master/install.sh | sudo sh -s -- --role pi
set -eu

ROLE=''
INSTALL_REF="${PG_REF:-master}"
REPOSITORY="${PG_REPO:-yohi/Pi}"
PAN_PROFILE=''
INSTALL_DEPS=1
DRY_RUN=0

usage() {
  cat <<USAGE
Usage: sudo sh install.sh --role pi|host [--profile NAME] [--ref COMMIT_OR_TAG] [--no-install-deps] [--dry-run]
Examples (after publishing the repository):
  curl -fsSL https://raw.githubusercontent.com/yohi/Pi/master/install.sh | sudo sh -s -- --role pi
  curl -fsSL https://raw.githubusercontent.com/yohi/Pi/master/install.sh | sudo sh -s -- --role host
Environment: PG_REPO=owner/repo, PG_REF=master (pin to a full commit hash for production).
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --role) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; ROLE="$2"; shift 2 ;;
    --profile) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; PAN_PROFILE="$2"; shift 2 ;;
    --ref) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; INSTALL_REF="$2"; shift 2 ;;
    --no-install-deps) INSTALL_DEPS=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[ "$ROLE" = pi ] || [ "$ROLE" = host ] || { echo 'Specify --role pi or --role host' >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo 'Installer requires sudo/root' >&2; exit 1; }
printf '%s' "$REPOSITORY" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || { echo 'Invalid PG_REPO' >&2; exit 1; }
printf '%s' "$INSTALL_REF" | grep -Eq '^[A-Za-z0-9_.-]+$' || { echo 'Invalid PG_REF/--ref' >&2; exit 1; }
if [ -z "$PAN_PROFILE" ]; then
  if [ "$ROLE" = pi ]; then PAN_PROFILE=pi-bt-pan; else PAN_PROFILE=pi-zero2w-pan; fi
fi
[ -n "$PAN_PROFILE" ] || { echo 'Empty PAN profile name' >&2; exit 1; }
[ "$(printf '%s' "$PAN_PROFILE" | tr -d '\r\n')" = "$PAN_PROFILE" ] || { echo 'PAN profile must be one line' >&2; exit 1; }
# The role is intentionally immutable. Never convert a running Pi into a host or vice versa.
if [ -r /etc/pi-pan-guardian/role ] && [ "$(cat /etc/pi-pan-guardian/role)" != "$ROLE" ]; then
  echo 'Different role already installed. Refusing to overwrite it.' >&2
  exit 1
fi
for req in curl sha256sum bash nmcli bluetoothctl systemctl; do
  command -v "$req" >/dev/null 2>&1 || { echo "Missing required command: $req" >&2; exit 1; }
done

# Fetch all sources and verify complete file integrity before modifying installed files.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM
mkdir -p "$STAGE/bin" "$STAGE/systemd"
BASE="https://raw.githubusercontent.com/$REPOSITORY/$INSTALL_REF"
fetch() { curl -fsSL --retry 3 --connect-timeout 15 --max-time 60 --proto '=https' --tlsv1.2 "$BASE/$1" -o "$STAGE/$1"; }
fetch MANIFEST.sha256
for file in \
  bin/pi-panctl \
  uninstall.sh \
  systemd/pi-pan-guardian-pan.service \
  systemd/pi-pan-guardian-pan.timer \
  systemd/pi-pan-guardian-recovery.service \
  systemd/pi-pan-guardian-recovery.timer; do
  fetch "$file"
done
( cd "$STAGE" && sha256sum --status --check MANIFEST.sha256 ) || { echo 'Manifest verification failed; no files installed.' >&2; exit 1; }
bash -n "$STAGE/bin/pi-panctl" || { echo 'Invalid application script; no files installed.' >&2; exit 1; }
sh -n "$STAGE/uninstall.sh" || { echo 'Invalid uninstaller; no files installed.' >&2; exit 1; }
if [ "$DRY_RUN" -eq 1 ]; then echo 'DRY RUN PASS: downloaded and verified; nothing was installed or activated.'; exit 0; fi

if ! command -v fzf >/dev/null 2>&1 || { [ "$ROLE" = pi ] && ! command -v dnsmasq >/dev/null 2>&1; }; then
  if [ "$INSTALL_DEPS" -eq 0 ]; then
    echo 'Missing fzf or dnsmasq-base; rerun without --no-install-deps.' >&2
    exit 1
  fi
  command -v apt-get >/dev/null 2>&1 || { echo 'Missing dependencies and apt-get is unavailable.' >&2; exit 1; }
  # Only UI and DHCP packages: NetworkManager/BlueZ are required and are not reinstalled.
  apt-get update -qq
  if [ "$ROLE" = pi ]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends fzf dnsmasq-base
  else
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends fzf
  fi
fi

install -d -m 755 /etc/pi-pan-guardian
if [ -r /etc/pi-pan-guardian/pan-profile ] && [ "$(cat /etc/pi-pan-guardian/pan-profile)" != "$PAN_PROFILE" ]; then
  echo 'Existing PAN profile differs; refusing implicit change. Specify the existing name with --profile.' >&2
  exit 1
fi
printf '%s\n' "$ROLE" > /etc/pi-pan-guardian/role
printf '%s\n' "$PAN_PROFILE" > /etc/pi-pan-guardian/pan-profile
chmod 644 /etc/pi-pan-guardian/role /etc/pi-pan-guardian/pan-profile
install -m 755 "$STAGE/bin/pi-panctl" /usr/local/sbin/pi-panctl
install -m 755 "$STAGE/uninstall.sh" /usr/local/sbin/pi-pan-guardian-uninstall
for file in "$STAGE"/systemd/*; do
  install -m 644 "$file" "/etc/systemd/system/$(basename "$file")"
done
systemctl daemon-reload

# Idempotent autoconnect setup only for the already configured, correctly typed profile.
if nmcli -g connection.id connection show "$PAN_PROFILE" >/dev/null 2>&1; then
  if ! /usr/local/sbin/pi-panctl pan configure; then
    echo 'PAN profile could not be enabled. Files installed; correct the profile and run sudo pi-panctl pan configure.' >&2
    exit 1
  fi
else
  echo "PAN profile '$PAN_PROFILE' absent. Files installed, timer not enabled. Existing network settings preserved." >&2
  echo 'Configure a correct NM Bluetooth NAP/PANU profile, then run: sudo pi-panctl pan configure' >&2
fi

# No automatic AP activation at install time. Existing Wi-Fi and legacy recovery services are untouched.
echo "Installed pi-pan-guardian role=$ROLE, profile=$PAN_PROFILE"
echo 'Next: sudo pi-panctl tui'
if [ "$ROLE" = pi ]; then
  echo 'Recovery Wi-Fi remains OFF until: sudo pi-panctl recovery setup && sudo pi-panctl recovery enable'
fi
