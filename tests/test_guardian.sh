#!/usr/bin/env bash
set -euo pipefail
source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/config" "$tmp/state" "$tmp/mock-bin"
printf 'pi\n' > "$tmp/config/role"
printf 'pi-bt-pan\n' > "$tmp/config/pan-profile"
cat > "$tmp/mock-bin/systemctl" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == is-enabled && "${3:-}" == pi-recovery-wifi.timer ]]; then exit "${MOCK_LEGACY_ENABLED:-1}"; fi
if [[ "$1" == is-active && "${3:-}" == pi-recovery-wifi.timer ]]; then exit "${MOCK_LEGACY_ACTIVE:-1}"; fi
exit 0
SH
cat > "$tmp/mock-bin/nmcli" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_LOG"
case "$*" in
  '-g UUID connection show') printf '%s\n' '11111111-1111-1111-1111-111111111111' '22222222-2222-2222-2222-222222222222' '33333333-3333-3333-3333-333333333333' '44444444-4444-4444-4444-444444444444' ;;
  '-g connection.type connection show 11111111-1111-1111-1111-111111111111') echo bridge ;;
  '-g connection.type connection show 22222222-2222-2222-2222-222222222222') echo bluetooth ;;
  '-g connection.type connection show 33333333-3333-3333-3333-333333333333') echo 802-11-wireless ;;
  '-g connection.id connection show 33333333-3333-3333-3333-333333333333') echo 'My:Wi-Fi' ;;
  '-g 802-11-wireless.mode connection show 33333333-3333-3333-3333-333333333333') echo infrastructure ;;
  '-g connection.type connection show 44444444-4444-4444-4444-444444444444') echo 802-11-wireless ;;
  '-g connection.id connection show 44444444-4444-4444-4444-444444444444') echo Pi-Zero2W-Recovery ;;
  '-g 802-11-wireless.mode connection show 44444444-4444-4444-4444-444444444444') echo ap ;;
  '-t --escape yes -f SSID,BSSID,CHAN,FREQ,SIGNAL,SECURITY device wifi list ifname wlan0 --rescan yes')
    printf '%s\n' 'My\:Wi-Fi:11\:22\:33\:44\:55\:66:6:2437 MHz:90:WPA2' 'My\:Wi-Fi:AA\:BB\:CC\:DD\:EE\:FF:11:2462 MHz:55:WPA2 WPA3' ':99\:99\:99\:99\:99\:99:1:2412 MHz:15:--'
    ;;
  *' device wifi connect '*) exit 0 ;;
  '-g connection.id connection show pi-bt-pan') echo pi-bt-pan ;;
  '-g connection.id connection show pi-zero2w-pan') echo pi-zero2w-pan ;;
  '-g NAME connection show') echo YusukeOhi_iPhone17 ;;
  '-g connection.type connection show YusukeOhi_iPhone17') echo 802-11-wireless ;;
  '-g connection.id connection show Pi-Zero2W-Recovery') [[ "${MOCK_AP_EXISTS:-1}" == 1 ]] && echo Pi-Zero2W-Recovery ;;
  '-g connection.type connection show pi-bt-pan') echo bridge ;;
  '-g connection.interface-name connection show pi-bt-pan') echo btnap0 ;;
  '-g bluetooth.type connection show pi-bt-pan') echo nap ;;
  '-g connection.type connection show pi-zero2w-pan') echo bluetooth ;; 
  '-g bluetooth.type connection show pi-zero2w-pan') echo panu ;;
  '-g connection.uuid connection show pi-bt-pan') echo '11111111-1111-1111-1111-111111111111' ;;
  '-g connection.uuid connection show pi-zero2w-pan') echo '22222222-2222-2222-2222-222222222222' ;;
  '-g connection.type connection show Pi-Zero2W-Recovery') echo 802-11-wireless ;;
  '-g 802-11-wireless.mode connection show Pi-Zero2W-Recovery') echo ap ;;
  '-g connection.interface-name connection show Pi-Zero2W-Recovery') echo wlan0 ;;
  '-t -f UUID connection show --active') [[ "${MOCK_PAN_ACTIVE:-0}" == 1 ]] && echo '11111111-1111-1111-1111-111111111111' ;;
  '-g GENERAL.CONNECTION device show wlan0') echo "${MOCK_WIFI_PROFILE:---}" ;;
  '-g GENERAL.STATE device show wlan0') echo "${MOCK_WIFI_STATE:-30 (disconnected)}" ;;
  *' connection up '*) exit 0 ;;
  *) echo "unexpected mock nmcli args: $*" >&2; exit 1 ;;
esac
SH
chmod +x "$tmp/mock-bin/"*
export PATH="$tmp/mock-bin:$PATH" PG_CONFIG_DIR="$tmp/config" PG_STATE_DIR="$tmp/state" MOCK_LOG="$tmp/log"
export MOCK_LEGACY_ENABLED=1 MOCK_LEGACY_ACTIVE=1 MOCK_AP_EXISTS=1
bin="$source_dir/bin/pi-panctl"

# 1: Active PAN must not be reactivated.
: > "$MOCK_LOG"
export MOCK_PAN_ACTIVE=1
"$bin" pan ensure
! grep -q ' connection up ' "$MOCK_LOG"
echo 'PASS active PAN no-op'

# 2: Disconnected PAN should get exactly one attempt.
: > "$MOCK_LOG"
export MOCK_PAN_ACTIVE=0
"$bin" pan ensure
[[ "$(grep -c ' connection up ' "$MOCK_LOG")" == 1 ]]
echo 'PASS disconnected PAN one attempt'

# 3: Wi-Fi connected -> no AP activation or grace marker.
: > "$MOCK_LOG"
export MOCK_WIFI_STATE='100 (connected)' MOCK_WIFI_PROFILE=YusukeOhi_iPhone17
"$bin" recovery check
! grep -q ' connection up ' "$MOCK_LOG"
[[ ! -f "$tmp/state/wlan-disconnected-since" ]]
echo 'PASS STA connected => no AP'

# 4: First disconnected tick records timestamp only.
: > "$MOCK_LOG"
export MOCK_WIFI_STATE='30 (disconnected)' MOCK_WIFI_PROFILE='--'
"$bin" recovery check
[[ -f "$tmp/state/wlan-disconnected-since" ]]
! grep -q ' connection up ' "$MOCK_LOG"
echo 'PASS grace period on first tick'

# 5: Second tick after 91s activates AP.
: > "$MOCK_LOG"
printf '%s\n' "$(( $(date +%s) - 91 ))" > "$tmp/state/wlan-disconnected-since"
"$bin" recovery check
[[ "$(grep -c 'connection up Pi-Zero2W-Recovery ifname wlan0' "$MOCK_LOG")" == 1 ]]
echo 'PASS delayed AP activation'

# 6: Legacy timer prevents AP activation.
: > "$MOCK_LOG"
export MOCK_LEGACY_ENABLED=0
printf '%s\n' "$(( $(date +%s) - 100 ))" > "$tmp/state/wlan-disconnected-since"
"$bin" recovery check
! grep -q ' connection up ' "$MOCK_LOG"
echo 'PASS legacy conflict fail-closed'

# 7: Pi host mismatch must not activate PANU.
: > "$MOCK_LOG"
printf 'host\n' > "$tmp/config/role"
if "$bin" pan ensure >/dev/null 2>&1; then
  echo 'FAIL role mismatch should reject incorrect existing profile' >&2; exit 1
fi
! grep -q ' connection up ' "$MOCK_LOG"
echo 'PASS role/type mismatch rejection'

# 8: Host PANU is recognized, no Bluetooth reset, one activation attempt.
: > "$MOCK_LOG"
printf 'pi-zero2w-pan\n' > "$tmp/config/pan-profile"
"$bin" pan ensure
[[ "$(grep -c 'connection up pi-zero2w-pan' "$MOCK_LOG")" == 1 ]]
! grep -qE 'restart|rfkill|down' "$MOCK_LOG"
echo 'PASS host PANU activation'

# fzf TUI formatting and role-specific menu, without touching real services.
cat > "$tmp/mock-bin/fzf" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK_FZF_ARGS"
cat > "$MOCK_FZF_MENU"
printf '%s\n' "${MOCK_FZF_CHOICE:-[Exit]}"
SH
chmod +x "$tmp/mock-bin/fzf"
export MOCK_FZF_ARGS="$tmp/fzf-args" MOCK_FZF_MENU="$tmp/fzf-menu"
if command -v script >/dev/null 2>&1; then
  printf 'pi\n' > "$tmp/config/role"
  script -q -e -c "'$bin' tui" /dev/null > "$tmp/tui.out" 2>&1
  grep -Fxq '[PAN Autostart]' "$MOCK_FZF_MENU"
  grep -Fxq '[Recovery AP Start]' "$MOCK_FZF_MENU"
  grep -Fxq '[Exit]' "$MOCK_FZF_MENU"
  grep -Fxq -- '--height=40%' "$MOCK_FZF_ARGS"
  grep -Fxq -- '--reverse' "$MOCK_FZF_ARGS"
  grep -Fxq -- '--border' "$MOCK_FZF_ARGS"
  grep -Fxq -- '--prompt=Select Pi action: ' "$MOCK_FZF_ARGS"
  echo 'PASS Pi TUI matches dotfiles-term fzf layout'

  printf 'host\n' > "$tmp/config/role"
  script -q -e -c "'$bin' tui" /dev/null > "$tmp/tui.out" 2>&1
  grep -Fxq '[PAN Activate]' "$MOCK_FZF_MENU"
  grep -Fxq '[Exit]' "$MOCK_FZF_MENU"
  ! grep -q 'Recovery AP' "$MOCK_FZF_MENU"
  grep -Fxq -- '--prompt=Select Host action: ' "$MOCK_FZF_ARGS"
  echo 'PASS Host TUI keeps role-specific menu'
  printf 'pi\n' > "$tmp/config/role"
  : > "$MOCK_LOG"
  MOCK_FZF_CHOICE=YusukeOhi_iPhone17 "$bin" wifi connect
  grep -Fxq -- '--prompt=Select Wi-Fi profile: ' "$MOCK_FZF_ARGS"
  grep -Fxq -- '--height=40%' "$MOCK_FZF_ARGS"
  grep -Fxq -- '--reverse' "$MOCK_FZF_ARGS"
  grep -q 'connection up YusukeOhi_iPhone17 ifname wlan0' "$MOCK_LOG"
  echo 'PASS Wi-Fi selector matches dotfiles-term fzf layout'
else
  echo 'SKIP TUI pseudo-terminal tests: script(1) unavailable'
fi

echo 'All 8 mock scenarios passed.'

# Wi-Fi list must never include PAN, lo or other non-Wi-Fi profiles.
printf 'pi\n' > "$tmp/config/role"
"$bin" wifi profiles > "$tmp/wifi-profiles.out"
grep -q 'My:Wi-Fi' "$tmp/wifi-profiles.out"
grep -q 'Pi-Zero2W-Recovery' "$tmp/wifi-profiles.out"
! grep -q 'pi-bt-pan' "$tmp/wifi-profiles.out"
! grep -q 'pi-zero2w-pan' "$tmp/wifi-profiles.out"
echo 'PASS saved Wi-Fi list excludes Bluetooth PAN'

cat > "$tmp/mock-bin/fzf" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK_FZF_ARGS"
cat > "$MOCK_FZF_MENU"
case "${MOCK_FZF_SELECTION:-first}" in
  cancel) exit 130 ;;
  second) sed -n '2p' "$MOCK_FZF_MENU" ;;
  *) sed -n '1p' "$MOCK_FZF_MENU" ;;
esac
SH
chmod +x "$tmp/mock-bin/fzf"
export MOCK_FZF_MENU="$tmp/fzf-menu" MOCK_FZF_ARGS="$tmp/fzf-args"
export MOCK_WIFI_PROFILE='YusukeOhi_iPhone17'
: > "$MOCK_LOG"
if command -v script >/dev/null 2>&1; then
  # The scan list is based on actual AP BSSIDs, not saved connection names.
  # Declining confirmation must never call the mutating nmcli command.
  printf 'NO\n' | script -q -e -c "'$bin' wifi scan" /dev/null > "$tmp/wifi-scan.out" 2>&1
  grep -Fq $'11:22:33:44:55:66\tMy:Wi-Fi\t6\t2437 MHz\t90\tWPA2' "$MOCK_FZF_MENU"
  grep -Fq $'AA:BB:CC:DD:EE:FF\tMy:Wi-Fi\t11\t2462 MHz\t55\tWPA2 WPA3' "$MOCK_FZF_MENU"
  ! grep -q 'pi-bt-pan' "$MOCK_FZF_MENU"
  ! grep -q 'device wifi connect' "$MOCK_LOG"
  echo 'PASS visible Wi-Fi BSSID/SSID scan and NO cancellation'

  # One confirmation selects the exact BSSID, preserving the colon in the SSID.
  : > "$MOCK_LOG"
  printf 'YES\n' | MOCK_FZF_SELECTION=second script -q -e -c "'$bin' wifi scan" /dev/null > "$tmp/wifi-connect.out" 2>&1
  grep -Fq 'device wifi connect My:Wi-Fi ifname wlan0 bssid AA:BB:CC:DD:EE:FF' "$MOCK_LOG"
  echo 'PASS scanned Wi-Fi target uses selected BSSID'

  # Saved Wi-Fi selector is limited to infrastructure profiles; uses UUID.
  : > "$MOCK_LOG"
  printf 'NO\n' | script -q -e -c "'$bin' wifi connect" /dev/null > "$tmp/wifi-saved.out" 2>&1
  ! grep -q 'Pi-Zero2W-Recovery' "$MOCK_FZF_MENU"
  grep -Fq '33333333-3333-3333-3333-333333333333' "$MOCK_FZF_MENU"
  ! grep -q ' connection up ' "$MOCK_LOG"
  echo 'PASS saved Wi-Fi selector excludes recovery AP and respects NO'
else
  echo 'SKIP Wi-Fi confirmation pseudo-terminal tests: script(1) unavailable'
fi

# Active Recovery AP must not be taken down implicitly.
export MOCK_WIFI_PROFILE='Pi-Zero2W-Recovery'
: > "$MOCK_LOG"
if "$bin" wifi scan > "$tmp/wifi-denied.out" 2>&1; then
  echo 'FAIL scan must refuse to disrupt active recovery AP' >&2; exit 1
fi
! grep -q 'device wifi connect' "$MOCK_LOG"
! grep -q -- '--rescan yes' "$MOCK_LOG"
echo 'PASS active recovery AP protected'
