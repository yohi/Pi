#!/bin/sh
# Remove only Guardian's files and timers; never remove NM profiles, keys or Bluetooth pairings.
set -eu
[ "$(id -u)" -eq 0 ] || { echo 'Run as root: sudo sh uninstall.sh' >&2; exit 1; }
for svc in pi-pan-guardian-pan.timer pi-pan-guardian-recovery.timer; do
    systemctl disable --now "$svc" >/dev/null 2>&1 || :
done
for file in pi-pan-guardian-pan.service pi-pan-guardian-pan.timer pi-pan-guardian-recovery.service pi-pan-guardian-recovery.timer; do
    rm -f "/etc/systemd/system/$file"
done
rm -f /usr/local/sbin/pi-panctl /usr/local/sbin/pi-pan-guardian-uninstall
# Deliberately preserve /etc/pi-pan-guardian, NM connection secrets, recovery AP profile.
systemctl daemon-reload
printf 'Uninstalled programs/timers. Saved NM profiles and config/credentials were preserved.\n'
