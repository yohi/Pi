#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/stubs"
cat > "$tmp/stubs/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
url=''; dest=''
for ((i=0; i<${#args[@]}; i++)); do
  if [[ "${args[i]}" == https://* ]]; then url="${args[i]}"; fi
  if [[ "${args[i]}" == '-o' ]]; then dest="${args[i+1]}"; fi
done
[[ -n "$url" && -n "$dest" ]] || exit 2
path="${url#*\/master\/}"
cp "$MOCK_SOURCE/$path" "$dest"
if [[ "${MOCK_TAMPER:-0}" == 1 && "$path" == 'bin/pi-panctl' ]]; then
  printf '# attacker modified content\n' >> "$dest"
fi
SH
for name in nmcli bluetoothctl; do
  cat > "$tmp/stubs/$name" <<'SH'
#!/bin/sh
exit 0
SH
done
cat > "$tmp/stubs/systemctl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_SERVICE_LOG"
exit 1
SH
cat > "$tmp/stubs/apt-get" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_APT_LOG"
exit 9
SH
chmod +x "$tmp/stubs/"*
export PATH="$tmp/stubs:$PATH" MOCK_SOURCE="$root"
export MOCK_SERVICE_LOG="$tmp/services.log" MOCK_APT_LOG="$tmp/apt.log"
: > "$MOCK_SERVICE_LOG"
: > "$MOCK_APT_LOG"
output="$(sh "$root/install.sh" --role pi --dry-run 2>&1)"
grep -q 'DRY RUN PASS' <<< "$output"
echo 'PASS installer downloads and checks manifest (dry-run)'
# Offline mode must succeed without systemd, NM/BlueZ daemons, or hardware.
output="$(sh "$root/install.sh" --role pi --offline-test 2>&1)"
grep -q 'OFFLINE TEST PASS' <<< "$output"
grep -q 'All 8 mock scenarios passed.' <<< "$output"
[[ ! -s "$MOCK_SERVICE_LOG" && ! -s "$MOCK_APT_LOG" ]]
echo 'PASS offline-test mocks without touching systemd or apt'
# A normal installation must fail before package changes when systemd is absent.
if sh "$root/install.sh" --role pi > "$tmp/normal.out" 2>&1; then
  echo 'FAIL normal install accepted a non-systemd container' >&2; exit 1
fi
grep -q 'systemd system manager is not running' "$tmp/normal.out"
[[ ! -s "$MOCK_APT_LOG" ]]
echo 'PASS non-systemd normal install rejected before apt/file changes' 
if MOCK_TAMPER=1 sh "$root/install.sh" --role host --dry-run >/dev/null 2>&1; then
  echo 'FAIL tampered binary was accepted' >&2
  exit 1
fi
echo 'PASS tampered installer payload rejected'
