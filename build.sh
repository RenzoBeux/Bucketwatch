#!/bin/bash
# Builds Bucketwatch.app into build/. With --install it replaces /Applications/Bucketwatch.app and opens it.
set -euo pipefail
cd "$(dirname "$0")"

command -v xcodegen >/dev/null || { echo "xcodegen is required: brew install xcodegen" >&2; exit 1; }
xcodegen generate --quiet

xcodebuild -project Bucketwatch.xcodeproj -scheme Bucketwatch -configuration Release \
  -derivedDataPath build/DerivedData -allowProvisioningUpdates -quiet build

APP="build/DerivedData/Build/Products/Release/Bucketwatch.app"
codesign --verify --deep --strict "$APP"
echo "OK: $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Bucketwatch || true
  rm -rf /Applications/Bucketwatch.app
  ditto "$APP" /Applications/Bucketwatch.app
  open /Applications/Bucketwatch.app
  echo "Installed /Applications/Bucketwatch.app"
fi
