#!/bin/zsh
# Build, archive and upload Walker (iOS) to TestFlight — fully headless.
#   ios/publish-testflight.sh [marketing-version]      e.g. ./publish-testflight.sh 1.1
#
# TestFlight builds expire after 90 days; rerun this to push a fresh one.
# The build number is the current timestamp, so every run is a new build.
#
# Credentials (App Store Connect API key, Admin/App Manager role) live outside
# the repo in ~/.config/bforp/release.env — the same file the Breaking for
# Parts release script uses:
#   ASC_KEY_ID=...  ASC_ISSUER_ID=...  ASC_KEY_PATH=... (optional)
# Override with WALKER_RELEASE_ENV=/path/to/other.env if you keep a separate one.
# TEAM_ID defaults to the lemonotype team; set TEAM_ID=... for your own.
set -euo pipefail

ROOT=${0:A:h}/LifeSpanWalk
cd "$ROOT"

ENV_FILE=${WALKER_RELEASE_ENV:-$HOME/.config/bforp/release.env}
[[ -f $ENV_FILE ]] && source "$ENV_FILE"
export ASC_KEY_ID=${ASC_KEY_ID:-} ASC_ISSUER_ID=${ASC_ISSUER_ID:-}
export ASC_KEY_PATH=${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}
TEAM_ID=${TEAM_ID:-A4RTBW9SM4}
[[ -n $ASC_KEY_ID && -n $ASC_ISSUER_ID && -f $ASC_KEY_PATH ]] || {
  echo "App Store Connect API key missing — see $ENV_FILE"; exit 1; }

VERSION=${1:-$(sed -nE 's/^ *MARKETING_VERSION: *"?([0-9.]+)"?.*/\1/p' project.yml | head -1)}
BUILD=$(date +%Y%m%d%H%M)
OUT=build/testflight
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

command -v xcodegen >/dev/null || { echo "brew install xcodegen"; exit 1; }
xcodegen generate --quiet
# xcodegen writes literal version strings into the Info.plists, so build
# setting overrides don't reach the bundle — stamp both plists directly
# (app and extension must match for TestFlight).
for plist in LifeSpanWalk/Info.plist WalkWidgets/Info.plist; do
  /usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" "$plist"
  /usr/libexec/PlistBuddy -c "Set CFBundleVersion $BUILD" "$plist"
done

rm -rf "$OUT" && mkdir -p "$OUT"
# Export to a local IPA, then upload with altool. (Letting xcodebuild upload
# directly — destination=upload — dies on the first slow App Store Connect
# response with a misleading "No Accounts with App Store Connect Access".)
cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>uploadSymbols</key><true/>
</dict></plist>
EOF
# altool only looks for the key in fixed locations
mkdir -p ~/.appstoreconnect/private_keys
[[ -e ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8 ]] || \
  ln -s "$ASC_KEY_PATH" ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8

echo "Walker iOS: archiving $VERSION ($BUILD)"
xcodebuild -quiet -project LifeSpanWalk.xcodeproj -scheme LifeSpanWalk -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$OUT/Walker.xcarchive" \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  "${AUTH[@]}" archive

echo "Walker iOS: exporting signed IPA"
xcodebuild -quiet -exportArchive -archivePath "$OUT/Walker.xcarchive" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/ipa" "${AUTH[@]}"

echo "Walker iOS: uploading to App Store Connect"
for attempt in 1 2 3; do
  if xcrun altool --upload-app -f "$OUT/ipa/LifeSpanWalk.ipa" -t ios \
       --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"; then
    echo "Uploaded Walker $VERSION ($BUILD). TestFlight processes it in ~5–15 min,"
    echo "then internal testers get it automatically."
    exit 0
  fi
  echo "upload attempt $attempt failed — retrying in 30s"; sleep 30
done
echo "Upload failed 3 times. The IPA is at $OUT/ipa — retry: xcrun altool --upload-app -f <ipa> -t ios --apiKey $ASC_KEY_ID --apiIssuer <issuer>"
exit 1
