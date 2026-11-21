#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "archive must run on macOS" >&2
  exit 1
fi
if [[ -z "${VOICE_INPUT_TEAM_ID:-}" ]]; then
  echo "VOICE_INPUT_TEAM_ID is required" >&2
  exit 1
fi

voice_input_version="${VOICE_INPUT_VERSION:-1.0.0}"
voice_input_build_number="${VOICE_INPUT_BUILD_NUMBER:-1}"
voice_input_bundle_id="${VOICE_INPUT_BUNDLE_ID:-com.aivoiceinput.mac}"

if [[ ! "${VOICE_INPUT_TEAM_ID}" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "VOICE_INPUT_TEAM_ID must be a 10-character Apple Team ID" >&2
  exit 1
fi
if [[ ! "${voice_input_version}" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  echo "VOICE_INPUT_VERSION must contain two or three numeric components" >&2
  exit 1
fi
if [[ ! "${voice_input_build_number}" =~ ^[1-9][0-9]*$ ]]; then
  echo "VOICE_INPUT_BUILD_NUMBER must be a positive integer" >&2
  exit 1
fi
if [[ ! "${voice_input_bundle_id}" =~ ^[A-Za-z0-9]+([.-][A-Za-z0-9]+)+$ ]]; then
  echo "VOICE_INPUT_BUNDLE_ID is invalid" >&2
  exit 1
fi

mkdir -p dist
xcodebuild \
  -project VoiceInput.xcodeproj \
  -scheme VoiceInput \
  -configuration Release \
  -archivePath dist/VoiceInput.xcarchive \
  DEVELOPMENT_TEAM="${VOICE_INPUT_TEAM_ID}" \
  PRODUCT_BUNDLE_IDENTIFIER="${voice_input_bundle_id}" \
  MARKETING_VERSION="${voice_input_version}" \
  CURRENT_PROJECT_VERSION="${voice_input_build_number}" \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  archive

ditto -c -k --keepParent \
  dist/VoiceInput.xcarchive/Products/Applications/VoiceInput.app \
  dist/VoiceInput.zip

codesign --verify --deep --strict --verbose=2 \
  dist/VoiceInput.xcarchive/Products/Applications/VoiceInput.app
