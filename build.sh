#!/usr/bin/env bash
# Builds WalkieTales.apk with only the Android SDK + JDK (no Gradle).
set -euo pipefail
unset MSYS_NO_PATHCONV  # Windows tools need Git Bash path conversion
cd "$(dirname "$0")"

SDK="${ANDROID_SDK:-/c/Android/sdk}"
BT="$SDK/build-tools/36.0.0"
JAR="$SDK/platforms/android-36/android.jar"

# d8/apksigner .bat files need a valid JAVA_HOME; derive it from the javac on PATH.
JAVAC="$(command -v javac)"
export JAVA_HOME="$(cygpath -w "$(dirname "$(dirname "$JAVAC")")")"

rm -rf build && mkdir -p build/gen build/classes build/assets/web

# The remote-control page is shared with the Docker companion (companion/web/index.html).
cp companion/web/index.html build/assets/web/index.html

"$BT/aapt2" compile --dir res -o build/res.zip
"$BT/aapt2" link -o build/base.apk -I "$JAR" --manifest AndroidManifest.xml \
    --java build/gen --min-sdk-version 26 --target-sdk-version 36 \
    --version-code 6 --version-name 1.5 -A build/assets build/res.zip

javac -nowarn --release 11 -encoding UTF-8 -classpath "$JAR" \
    -d build/classes $(find src build/gen -name '*.java')

"$BT/d8.bat" --release --min-api 26 --lib "$JAR" --output build $(find build/classes -name '*.class')

# add classes.dex to the apk
(cd build && python -I -c "import zipfile; z=zipfile.ZipFile('base.apk','a'); z.write('classes.dex','classes.dex'); z.close()")

"$BT/zipalign" -f -p 4 build/base.apk build/aligned.apk

[ -f debug.keystore ] || keytool -genkeypair -keystore debug.keystore -storepass android -keypass android \
    -alias cardplayer -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Card Player" >/dev/null 2>&1

"$BT/apksigner.bat" sign --ks debug.keystore --ks-pass pass:android --key-pass pass:android \
    --out WalkieTales.apk build/aligned.apk
echo "Built $(pwd)/WalkieTales.apk"
