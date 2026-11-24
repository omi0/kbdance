#!/bin/zsh
# Builds KeyboardDance.app, installs it into ~/Applications and launches it.
set -euo pipefail
cd "${0:A:h}"

swift build -c release --product KeyboardDance
bin=$(swift build -c release --show-bin-path)

app=.build/KeyboardDance.app
rm -rf $app
mkdir -p $app/Contents/MacOS
cp $bin/KeyboardDance $app/Contents/MacOS/
cp Resources/App-Info.plist $app/Contents/Info.plist
codesign --force --sign - $app

# SIGTERM makes a running copy give the backlight back before it quits.
pkill -x KeyboardDance && sleep 1 || true
mkdir -p ~/Applications
rm -rf ~/Applications/KeyboardDance.app
cp -R $app ~/Applications/
open ~/Applications/KeyboardDance.app
