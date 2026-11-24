#!/usr/bin/env bash
# Perpanjang izin app iOS (Apple ID gratis: berlaku 7 hari) dengan build ulang lalu pasang
# ulang ke iPhone yang tersambung kabel. Data di app tidak hilang.
#
#   tool/renew_ios.sh                 # rawa + tutles (folder ../tutles, bila ada)
#   tool/renew_ios.sh ../tutles       # hanya folder yang disebut
#   DEVICE=<id> tool/renew_ios.sh     # pilih iPhone tertentu (id dari: xcrun devicectl list devices)
#
# iPhone harus tersambung kabel dan tidak terkunci.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ $# -gt 0 ]; then
  projects=("$@")
else
  projects=("$ROOT")
  [ -d "$ROOT/../tutles" ] && projects+=("$(cd "$ROOT/../tutles" && pwd)")
fi

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# iPhone fisik yang sudah dipasangkan dengan Mac ini.
device="${DEVICE:-}"
if [ -z "$device" ]; then
  json="$(mktemp)"
  trap 'rm -f "$json"' EXIT
  xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 || true
  device="$(python3 -I - "$json" <<'PY'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devices = []
phones = [
    d for d in devices
    if d.get("hardwareProperties", {}).get("platform") == "iOS"
    and d.get("hardwareProperties", {}).get("reality") == "physical"
    and d.get("connectionProperties", {}).get("pairingState") == "paired"
]
phones.sort(key=lambda d: d.get("connectionProperties", {}).get("tunnelState") != "connected")
print(phones[0]["identifier"] if phones else "")
PY
)"
fi
if [ -z "$device" ]; then
  echo "Tidak ada iPhone yang dipasangkan. Sambungkan kabel, buka kunci, lalu coba lagi." >&2
  exit 1
fi

# Jalankan perintah devicectl sampai 3 kali (koneksi kabel kadang putus sesaat).
retry() {
  local out
  for i in 1 2 3; do
    if out="$("$@" 2>&1)"; then return 0; fi
    if [ "$i" -lt 3 ]; then sleep 3; fi
  done
  echo "$out" | grep -m3 -iE "error|locked|unavailable" >&2 || echo "$out" | tail -3 >&2
  return 1
}

failed=()
for dir in "${projects[@]}"; do
  name="$(basename "$dir")"
  say "== $name: build"
  if ! (cd "$dir" && flutter build ios --release); then
    failed+=("$name (build)")
    continue
  fi
  app="$dir/build/ios/iphoneos/Runner.app"
  bundle="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")"

  say "== $name: pasang ke iPhone ($bundle)"
  if ! retry xcrun devicectl device install app --device "$device" "$app"; then
    echo "Gagal memasang. Pastikan iPhone tersambung kabel dan tidak terkunci." >&2
    failed+=("$name (install)")
    continue
  fi
  retry xcrun devicectl device process launch --terminate-existing --device "$device" "$bundle" ||
    echo "Terpasang, tapi gagal dibuka otomatis. Buka manual di iPhone." >&2
  echo "$name diperpanjang 7 hari (sampai $(date -v+7d '+%d %b %Y'))."
done

if [ ${#failed[@]} -gt 0 ]; then
  say "Gagal: ${failed[*]}"
  exit 1
fi
say "Selesai."
