#!/usr/bin/env bash
# One command from main to TestFlight.
# Usage: scripts/ship-testflight.sh --notes <file> [--version <marketing version>] [--skip-upload]
#   --notes        plain text for the en-US "What to Test" box (required; ASC rejects some symbols, e.g. ✕)
#   --version      new marketing version, e.g. 0.4 (default: keep the current one)
#   --skip-upload  no bump, no build: rerun the App Store Connect steps for the build in project.yml
# Bumps CURRENT_PROJECT_VERSION in ios/project.yml by one, archives Release,
# exports, uploads with altool, then waits for App Store Connect to put the
# build in internal testing. It does not commit; commit the bump yourself.
set -euo pipefail

KEY_ID=6CHR4MM9J4
ISSUER=ba5ac58d-794c-4386-8994-a5fab9aaf8f9
TEAM=GV3ZK5CT6G
KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS="$ROOT/ios"
YML="$IOS/project.yml"
ASC="node $ROOT/scripts/asc.mjs"

die() { echo "FAILED: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

NOTES="" VERSION="" SKIP_UPLOAD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes) NOTES="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --skip-upload) SKIP_UPLOAD=1; shift ;;
    *) die "unknown argument $1 (usage: $0 --notes <file> [--version X.Y])" ;;
  esac
done
[[ -n "$NOTES" ]] || die "--notes <file> is required"
NOTES="$(cd "$(dirname "$NOTES")" && pwd)/$(basename "$NOTES")"
[[ -s "$NOTES" ]] || die "notes file $NOTES is missing or empty"
[[ -f "$KEY_PATH" ]] || die "API key not found at $KEY_PATH"
command -v xcodegen >/dev/null || die "xcodegen not installed"
command -v node >/dev/null || die "node not installed"

# Wait while another xcodebuild runs or the 1-min load is 16 or more.
# While our xcodebuild runs, hold a lock file so other build agents wait.
LOCK="${PIP_BUILD_LOCK:-/private/tmp/claude-501/-Users-varun/0d8640a7-74b8-4f29-84db-6b062341cb15/scratchpad/build.lock}"
LOCK_NAME="${PIP_BUILD_LOCK_NAME:-ship-testflight}"
wait_idle() {
  local waited=0
  while true; do
    local load busy
    load=$(sysctl -n vm.loadavg | awk '{print $2}')
    busy=$(pgrep -x xcodebuild || true)
    if [[ -z "$busy" ]] && awk -v l="$load" 'BEGIN{exit !(l < 16)}'; then
      mkdir -p "$(dirname "$LOCK")"; echo "$LOCK_NAME" >"$LOCK"; return 0
    fi
    (( waited % 60 == 0 )) && echo "    waiting: load $load, xcodebuild running: ${busy:+yes}${busy:-no}"
    sleep 15; waited=$((waited + 15))
  done
}
unlock() { [[ "$(cat "$LOCK" 2>/dev/null)" == "$LOCK_NAME" ]] && rm -f "$LOCK"; return 0; }
trap unlock EXIT

if [[ -n "$SKIP_UPLOAD" ]]; then
  BUILD=$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: "?([0-9]+)"?.*/\1/p' "$YML")
  MARKETING=$(sed -nE 's/^ *MARKETING_VERSION: "?([0-9.]+)"?.*/\1/p' "$YML")
  echo "==> Skip upload: App Store Connect steps for $MARKETING ($BUILD)"
else
# --- 1. Bump versions -------------------------------------------------------
step "Bump version"
OLD_BUILD=$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: "?([0-9]+)"?.*/\1/p' "$YML")
[[ -n "$OLD_BUILD" ]] || die "CURRENT_PROJECT_VERSION not found in $YML"
BUILD=$((OLD_BUILD + 1))
[[ "$($ASC state "$BUILD" | awk '{print $1}')" == "NOT_FOUND" ]] || die "build $BUILD already exists in App Store Connect"
sed -i '' -E "s/^( *CURRENT_PROJECT_VERSION: )\"?[0-9]+\"?/\1\"$BUILD\"/" "$YML"
if [[ -n "$VERSION" ]]; then
  sed -i '' -E "s/^( *MARKETING_VERSION: )\"?[0-9.]+\"?/\1\"$VERSION\"/" "$YML"
fi
MARKETING=$(sed -nE 's/^ *MARKETING_VERSION: "?([0-9.]+)"?.*/\1/p' "$YML")
echo "    $MARKETING ($BUILD)"

WORK="$IOS/build/release/$MARKETING-$BUILD"
rm -rf "$WORK"; mkdir -p "$WORK"
ARCHIVE="$WORK/Pip.xcarchive"
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY_PATH" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER")

# --- 2. Generate and archive ------------------------------------------------
step "xcodegen"
(cd "$IOS" && xcodegen generate --quiet) || die "xcodegen"

step "Archive Release (log: $WORK/archive.log)"
wait_idle
(cd "$IOS" && xcodebuild archive -project Pip.xcodeproj -scheme Pip -configuration Release \
  -destination generic/platform=iOS -archivePath "$ARCHIVE" "${AUTH[@]}" >"$WORK/archive.log" 2>&1) \
  || { unlock; tail -30 "$WORK/archive.log"; die "archive"; }
unlock
GOT=$(/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleVersion" "$ARCHIVE/Info.plist")
[[ "$GOT" == "$BUILD" ]] || die "archive has CFBundleVersion $GOT, expected $BUILD"

# --- 3. Export --------------------------------------------------------------
step "Export (log: $WORK/export.log)"
cat >"$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
</dict></plist>
PLIST
wait_idle
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$WORK/export" \
  -exportOptionsPlist "$WORK/ExportOptions.plist" "${AUTH[@]}" >"$WORK/export.log" 2>&1 \
  || { unlock; tail -30 "$WORK/export.log"; die "export"; }
unlock
IPA="$WORK/export/Pip.ipa"
[[ -f "$IPA" ]] || die "no ipa at $IPA"

# --- 4. Upload --------------------------------------------------------------
step "Upload with altool (log: $WORK/upload.log)"
xcrun altool --upload-app -f "$IPA" -t ios --apiKey "$KEY_ID" --apiIssuer "$ISSUER" >"$WORK/upload.log" 2>&1 \
  || { tail -30 "$WORK/upload.log"; die "upload"; }
grep -q "UPLOAD SUCCEEDED" "$WORK/upload.log" || { tail -30 "$WORK/upload.log"; die "upload did not report success"; }
grep -m1 "Delivery UUID" "$WORK/upload.log" | sed 's/^ */    /'

fi

# --- 5. Wait for processing -------------------------------------------------
poll() { # poll <field 1|2> <want> <timeout seconds>
  local field=$1 want=$2 limit=$3 t=0 s val last=""
  while true; do
    s=$($ASC state "$BUILD") || die "App Store Connect state check"
    val=$(echo "$s" | awk -v f="$field" '{print $f}')
    [[ "$val" != "$last" ]] && echo "    $(date +%H:%M:%S) processing=$(echo "$s" | awk '{print $1}') internal=$(echo "$s" | awk '{print $2}')"
    last=$val
    [[ "$val" == "$want" ]] && return 0
    [[ "$val" == "INVALID" || "$val" == "FAILED" || "$val" == "PROCESSING_EXCEPTION" ]] && die "build $BUILD is $val"
    (( t >= limit )) && die "timed out after ${limit}s waiting for $want (last: $s)"
    sleep 30; t=$((t + 30))
  done
}
step "Wait for processingState VALID"
poll 1 VALID 3600

step "Export compliance"
$ASC no-encryption "$BUILD" || die "set usesNonExemptEncryption"

step "What to Test"
$ASC notes "$BUILD" "$NOTES" || die "set What to Test"

step "Wait for internalBuildState IN_BETA_TESTING"
poll 2 IN_BETA_TESTING 1800

echo
echo "DONE: Pip $MARKETING ($BUILD) is $($ASC state "$BUILD" | awk '{print $2}')"
