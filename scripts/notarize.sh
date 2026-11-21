#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "notarization must run on macOS" >&2
  exit 1
fi
if [[ -z "${VOICE_INPUT_NOTARY_PROFILE:-}" ]]; then
  echo "VOICE_INPUT_NOTARY_PROFILE is required" >&2
  exit 1
fi
if [[ ! -f dist/VoiceInput.zip ]]; then
  echo "dist/VoiceInput.zip not found; run make mac-archive first" >&2
  exit 1
fi

xcrun notarytool submit dist/VoiceInput.zip \
  --keychain-profile "${VOICE_INPUT_NOTARY_PROFILE}" \
  --wait
xcrun stapler staple dist/VoiceInput.xcarchive/Products/Applications/VoiceInput.app
xcrun stapler validate dist/VoiceInput.xcarchive/Products/Applications/VoiceInput.app
codesign --verify --deep --strict --verbose=2 \
  dist/VoiceInput.xcarchive/Products/Applications/VoiceInput.app
spctl --assess --type execute --verbose=2 \
  dist/VoiceInput.xcarchive/Products/Applications/VoiceInput.app
ditto -c -k --keepParent \
  dist/VoiceInput.xcarchive/Products/Applications/VoiceInput.app \
  dist/VoiceInput-notarized.zip
