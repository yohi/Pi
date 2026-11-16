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
chmod +x "$tmp/stubs/"*
export PATH="$tmp/stubs:$PATH" MOCK_SOURCE="$root"
output="$(sh "$root/install.sh" --role pi --dry-run 2>&1)"
grep -q 'DRY RUN PASS' <<< "$output"
echo 'PASS installer downloads and checks manifest (dry-run)'
if MOCK_TAMPER=1 sh "$root/install.sh" --role host --dry-run >/dev/null 2>&1; then
  echo 'FAIL tampered binary was accepted' >&2
  exit 1
fi
echo 'PASS tampered installer payload rejected'
