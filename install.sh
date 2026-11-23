#!/bin/bash
# Builds Claude Usage, installs it to /Applications and starts it at every login.
# A LaunchAgent restarts it if it crashes; choosing "Quit" in the app still closes it.
# Uninstall:  ./install.sh --uninstall
set -euo pipefail
cd "$(dirname "$0")"

LABEL="local.claude-usage-bar"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
DEST="/Applications/Claude Usage.app"
UID_NUM=$(id -u)

launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
pkill -x ClaudeUsage 2>/dev/null || true

if [[ "${1:-}" == "--uninstall" ]]; then
  rm -f "$AGENT"
  rm -rf "$DEST"
  echo "Uninstalled."
  exit 0
fi

./build.sh
rm -rf "$DEST"
cp -R "Claude Usage.app" "$DEST"

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$DEST/Contents/MacOS/ClaudeUsage</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict></plist>
PL

launchctl bootstrap "gui/$UID_NUM" "$AGENT"
echo "Installed to $DEST and started. It will start again at every login."
