#!/bin/bash
# Builds LidSleepToggle.app, installs a narrowly-scoped passwordless sudo rule
# for the two pmset commands it needs, and registers it to launch at login.
#
#   ./build.sh            full install (asks for your password once)
#   ./build.sh --app-only rebuild the app only, no sudoers / launchd changes
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/LidSleepToggle.app"
USER_NAME="$(whoami)"
UID_NUM="$(id -u)"
PLIST="$HOME/Library/LaunchAgents/com.sufwan.lidsleeptoggle.plist"
APP_ONLY=0
[ "${1:-}" = "--app-only" ] && APP_ONLY=1

echo "==> Compiling…"
pkill -x LidSleepToggle 2>/dev/null || true
sleep 0.3
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"
# The Claude activity detector ships inside the bundle so the app is relocatable.
cp "$DIR/claude-active.py" "$APP/Contents/Resources/claude-active.py"

swiftc -O -swift-version 5 \
    -framework AppKit \
    -o "$APP/Contents/MacOS/LidSleepToggle" \
    "$DIR"/Sources/*.swift

# Ad-hoc signature keeps the status item and private framework calls happy.
codesign --force --sign - "$APP" 2>/dev/null || true
echo "    built $APP"

if [ "$APP_ONLY" = "0" ]; then
    echo "==> Installing passwordless sudo rule for pmset…"
    SUDOERS_TMP="$(mktemp)"
    cat > "$SUDOERS_TMP" <<EOF
# Installed by LidSleepToggle — lets $USER_NAME toggle lid-close sleep only.
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
EOF
    # visudo -c validates syntax before the file goes into place.
    if sudo visudo -c -f "$SUDOERS_TMP" >/dev/null; then
        sudo install -m 0440 -o root -g wheel "$SUDOERS_TMP" /etc/sudoers.d/lidsleeptoggle
        echo "    installed /etc/sudoers.d/lidsleeptoggle"
    else
        echo "    !! sudoers file failed validation — the toggle will prompt for a password."
    fi
    rm -f "$SUDOERS_TMP"

    echo "==> Installing login item…"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.sufwan.lidsleeptoggle</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP/Contents/MacOS/LidSleepToggle</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
EOF
    echo "    installed $PLIST"
fi

# Reload so launchd runs the freshly built binary.
launchctl bootout "gui/$UID_NUM" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST" 2>/dev/null || true

echo "==> Done. Look for the moon icon in your menubar."
