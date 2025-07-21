#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -euo pipefail

printf "\n🚀 Starting omaccy installation...\n\n"

# Directory where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ensure Homebrew is installed (required for optional Hammerspoon install)
if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew not detected. Please install Homebrew first: https://brew.sh" >&2
  exit 1
fi

# Install Hammerspoon if it is not already present
if ! command -v hs >/dev/null 2>&1 && [ ! -d "/Applications/Hammerspoon.app" ]; then
  echo "Installing Hammerspoon via Homebrew..."
  brew install --cask hammerspoon
fi

# Link (or copy) the Hammerspoon configuration
CONFIG_SRC="$SCRIPT_DIR/hammerspoon"
CONFIG_DEST="$HOME/.hammerspoon"

# Ensure the destination directory exists and is not a symlink
if [ -L "$CONFIG_DEST" ]; then
  BACKUP="$CONFIG_DEST.backup.$(date +%s)"
  echo "Existing Hammerspoon symlink detected. Backing up to $BACKUP"
  mv "$CONFIG_DEST" "$BACKUP"
fi

# Create the directory if it doesn't exist
mkdir -p "$CONFIG_DEST"

# Link individual configuration files
echo "Linking Hammerspoon configuration files into $CONFIG_DEST"
for FILE in init.lua serpent.lua wm.lua; do
  SRC="$CONFIG_SRC/$FILE"
  DEST="$CONFIG_DEST/$FILE"

  if [ -e "$DEST" ] && [ ! -L "$DEST" ]; then
    BACKUP="$DEST.backup.$(date +%s)"
    echo "Existing file $DEST detected. Backing up to $BACKUP"
    mv "$DEST" "$BACKUP"
  fi

  ln -sfn "$SRC" "$DEST"
done

# Install Chrome scripts (Chrome extension)
CHROME_SRC="$SCRIPT_DIR/chrome-scripts"
CHROME_DEST="$HOME/.config/chrome-scripts"

# Ensure destination parent directory exists
mkdir -p "$(dirname "$CHROME_DEST")"

if [ -d "$CHROME_SRC" ]; then
  if [ -e "$CHROME_DEST" ] && [ ! -L "$CHROME_DEST" ]; then
    BACKUP="$CHROME_DEST.backup.$(date +%s)"
    echo "Existing Chrome scripts detected. Backing up to $BACKUP"
    mv "$CHROME_DEST" "$BACKUP"
  fi

  echo "Linking Chrome scripts from $CHROME_SRC to $CHROME_DEST"
  ln -sfn "$CHROME_SRC" "$CHROME_DEST"
else
  echo "Chrome scripts source directory not found at $CHROME_SRC" >&2
fi

echo "\n✅ Installation complete."
echo " • Open Hammerspoon and press ⌘+R to reload the configuration."
echo " • Open Google Chrome, navigate to chrome://extensions, enable Developer mode, click 'Load unpacked', and select $CHROME_DEST to load the omaccy extension.\n" 

