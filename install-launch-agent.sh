#!/bin/sh
set -eu

project_dir="$(cd "$(dirname "$0")" && pwd)"
binary="$project_dir/.build/release/clipboard-history-hud"
plist="$HOME/Library/LaunchAgents/com.local.clipboard-history-hud.plist"

cd "$project_dir"
swift build -c release

mkdir -p "$HOME/Library/LaunchAgents"

cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.local.clipboard-history-hud</string>
  <key>ProgramArguments</key>
  <array>
    <string>$binary</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/clipboard-history-hud.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/clipboard-history-hud.err.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$plist"
launchctl kickstart -k "gui/$(id -u)/com.local.clipboard-history-hud"

echo "Installed com.local.clipboard-history-hud"
