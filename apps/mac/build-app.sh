#!/bin/sh
# Build, sign and install "Guilty Spark.app" (work name: disk) into ~/Applications.
#   apps/mac/build-app.sh            # build + install + relaunch
# Needs the local disk-web server (packaging/macos/install.sh) to show anything.
set -eu
cd "$(dirname "$0")"
identity=${DISK_SIGN_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}
[ -n "$identity" ] || { echo "no Apple Development identity; set DISK_SIGN_ID" >&2; exit 1; }
app="build/Guilty Spark.app"
rm -rf "$app" build/icon.iconset
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" build/icon.iconset

xcrun swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos26.0 \
  -framework SwiftUI Sources/*.swift -o "$app/Contents/MacOS/GuiltySpark"

xcrun swift tools/icon.swift build/icon-1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon-1024.png --out build/icon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s * 2)) $((s * 2)) build/icon-1024.png --out build/icon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/icon.iconset -o "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Guilty Spark</string>
  <key>CFBundleDisplayName</key><string>Guilty Spark</string>
  <key>CFBundleIdentifier</key><string>com.sevensevensix.disk</string>
  <key>CFBundleExecutable</key><string>GuiltySpark</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- The app only talks to disk-web on 127.0.0.1 over plain HTTP. -->
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

codesign -f -s "$identity" -o runtime --timestamp=none "$app"
codesign -v "$app"
# com.asif.disk-app keeps the menu-bar app running: it starts at login and launchd relaunches it
# after a crash (an unsuccessful exit), but not after Quit (exit 0). ThrottleInterval spaces the
# relaunches so a crash on launch cannot spin. The app counts its crash reports in the menu panel.
label=com.asif.disk-app
agent="$HOME/Library/LaunchAgents/$label.plist"
uid=$(id -u)
launchctl bootout "gui/$uid/$label" 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
pkill -x GuiltySpark 2>/dev/null || true
rm -rf "$HOME/Applications/Guilty Spark.app"
cp -R "$app" "$HOME/Applications/"
echo "installed $HOME/Applications/Guilty Spark.app"

cat > "$agent" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$HOME/Applications/Guilty Spark.app/Contents/MacOS/GuiltySpark</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/$label.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/$label.log</string>
</dict>
</plist>
PLIST
# bootout returns before a running job has exited; bootstrap fails (error 5) until it has.
for try in 1 2 3 4 5 6 7 8 9 10; do
  launchctl bootstrap "gui/$uid" "$agent" 2>/dev/null && break
  sleep 1
done
launchctl print "gui/$uid/$label" >/dev/null && echo "launched by $label (relaunches on crash)"
