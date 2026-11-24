#!/usr/bin/env bash
# Generates the Android project for the FM-Stream Deck app from obs-deck.html.
# Usage: bash scripts/prepare-android.sh [versionName] [versionCode]
# Needs Node.js (run "npm ci" first). Building the APK afterwards needs JDK 21 and the Android SDK:
#   cd android && ./gradlew assembleDebug
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-0.0.0-dev}"
CODE="${2:-1}"

# the app shows the same deck page the PC server serves
rm -rf www && mkdir -p www
cp ../obs-deck.html www/index.html
cp ../favicon.svg ../favicon.ico ../apple-touch-icon.png www/

[ -d android ] || npx cap add android
npx cap sync android

# launcher icon and splash from the logo (replace Capacitor's defaults)
RES=android/app/src/main/res
find "$RES" -name 'splash.png' -delete
cp -R res/. "$RES/"

# QR reader: ask Play Services to download the Google code scanner together with the app
MANIFEST=android/app/src/main/AndroidManifest.xml
# OBS WebSocket is plain ws:// on the local network; Android blocks cleartext traffic by default
grep -q 'usesCleartextTraffic' "$MANIFEST" ||
  sed -i 's#android:supportsRtl="true"#android:supportsRtl="true"\n        android:usesCleartextTraffic="true"#' "$MANIFEST"
grep -q 'mlkit.vision.DEPENDENCIES' "$MANIFEST" ||
  sed -i 's#</application>#    <meta-data android:name="com.google.mlkit.vision.DEPENDENCIES" android:value="barcode_ui" />\n    </application>#' "$MANIFEST"

sed -i -E "s/versionCode [0-9]+/versionCode $CODE/; s/versionName \"[^\"]*\"/versionName \"$VERSION\"/" android/app/build.gradle
echo "Android project ready: version $VERSION ($CODE)"
