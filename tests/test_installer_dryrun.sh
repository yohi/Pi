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
# curl -o creates a non-executable file even when the repository blob is executable.
chmod 0644 "$dest"
if [[ "${MOCK_TAMPER:-0}" == 1 && "$path" == 'bin/pi-panctl' ]]; then
  printf '# attacker modified content\n' >> "$dest"
fi
SH
for name in nmcli bluetoothctl; do
  cat > "$tmp/stubs/$name" <<'SH'
#!/bin/sh
printf '%s %s\n' "${0##*/}" "$*" >> "$MOCK_SERVICE_LOG"
exit 99
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

# Interactive --demo must work in a non-systemd container and must not call
# actual network/service commands. script(1) supplies a pseudo-terminal.
if command -v script >/dev/null 2>&1; then
  cat > "$tmp/stubs/fzf" <<'FZF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_DEMO_FZF_OPTS"
cat >> "$MOCK_DEMO_MENU"
if [[ -e "$MOCK_DEMO_STEP" ]]; then
  printf '[Exit]\n'
else
  : > "$MOCK_DEMO_STEP"
  printf '%s\n' "$MOCK_DEMO_FIRST_CHOICE"
fi
FZF
  chmod +x "$tmp/stubs/fzf"
  export MOCK_DEMO_MENU="$tmp/demo-menu" MOCK_DEMO_FZF_OPTS="$tmp/demo-fzf-opts" MOCK_DEMO_STEP="$tmp/demo-step"
  for demo_role in pi host; do
    if [[ "$demo_role" == pi ]]; then
      export MOCK_DEMO_FIRST_CHOICE='[Recovery AP Start]'
    else
      export MOCK_DEMO_FIRST_CHOICE='[PAN Autostart]'
    fi
    : > "$MOCK_DEMO_MENU"
    : > "$MOCK_DEMO_FZF_OPTS"
    rm -f "$MOCK_DEMO_STEP"
    : > "$MOCK_SERVICE_LOG"
    : > "$MOCK_APT_LOG"
    # The installer is read from a pipe, just like curl | sh, so the demo
    # must explicitly attach its own stdin to the controlling terminal.
    script -q -e -c "cat '$root/install.sh' | sh -s -- --role '$demo_role' --demo" /dev/null </dev/null > "$tmp/demo-$demo_role.out" 2>&1
    grep -q "DEMO: opening $demo_role TUI" "$tmp/demo-$demo_role.out"
    grep -Fq "DEMO: selected $MOCK_DEMO_FIRST_CHOICE; no command or service action executed" "$tmp/demo-$demo_role.out"
    grep -q 'DEMO ONLY - no system changes' "$MOCK_DEMO_FZF_OPTS"
    grep -q -- '--height=40%' "$MOCK_DEMO_FZF_OPTS"
    grep -q -- '--reverse' "$MOCK_DEMO_FZF_OPTS"
    grep -q -- '--border' "$MOCK_DEMO_FZF_OPTS"
    if [[ "$demo_role" == pi ]]; then
      grep -Fxq '[Recovery AP Start]' "$MOCK_DEMO_MENU"
      grep -q 'Select Pi action:' "$MOCK_DEMO_FZF_OPTS"
    else
      ! grep -q 'Recovery AP' "$MOCK_DEMO_MENU"
      grep -q 'Select Host action:' "$MOCK_DEMO_FZF_OPTS"
    fi
    [[ ! -s "$MOCK_SERVICE_LOG" && ! -s "$MOCK_APT_LOG" ]]
    echo "PASS $demo_role interactive demo via pipe without systemd/apt"
  done
fi
# Without a TTY, demo mode must fail without changing anything.
if sh "$root/install.sh" --role pi --demo > "$tmp/no-tty.out" 2>&1; then
  echo 'FAIL demo accepted a noninteractive TTY' >&2; exit 1
fi
grep -q 'Demo requires an interactive TTY' "$tmp/no-tty.out"
echo 'PASS noninteractive demo rejected safely'
