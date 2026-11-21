#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "local signed installation must run on macOS" >&2
  exit 1
fi

voice_input_source_app="${1:-dist/VoiceInput.app}"
voice_input_destination_app="/Applications/VoiceInput.app"
voice_input_identity="${VOICE_INPUT_LOCAL_SIGNING_IDENTITY:-VoiceInput Local Signing}"
voice_input_expected_bundle_id="com.aivoiceinput.mac"

if [[ ! -d "${voice_input_source_app}" ]]; then
  echo "source app not found: ${voice_input_source_app}" >&2
  exit 1
fi

voice_input_source_bundle_id="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "${voice_input_source_app}/Contents/Info.plist"
)"
if [[ "${voice_input_source_bundle_id}" != "${voice_input_expected_bundle_id}" ]]; then
  echo "unexpected source bundle ID: ${voice_input_source_bundle_id}" >&2
  exit 1
fi

voice_input_identity_hash="$({
  security find-identity -v -p codesigning 2>/dev/null || true
} | awk -v name="${voice_input_identity}" 'index($0, "\"" name "\"") { print $2; exit }')"
if [[ -z "${voice_input_identity_hash}" ]]; then
  echo "local signing identity not found: ${voice_input_identity}" >&2
  echo "run scripts/setup_local_signing.sh first" >&2
  exit 1
fi

voice_input_staging_root="$(mktemp -d "${TMPDIR:-/tmp}/voiceinput-local-install.XXXXXX")"
voice_input_staged_app="${voice_input_staging_root}/VoiceInput.app"
cleanup() {
  if [[ -d "${voice_input_staging_root}" ]]; then
    find "${voice_input_staging_root}" -depth -delete >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

ditto "${voice_input_source_app}" "${voice_input_staged_app}"
xattr -cr "${voice_input_staged_app}"

if [[ -d "${voice_input_staged_app}/Contents/Frameworks" ]]; then
  while IFS= read -r -d '' voice_input_nested_code; do
    codesign --force \
      --sign "${voice_input_identity_hash}" \
      --options runtime \
      --timestamp=none \
      "${voice_input_nested_code}"
  done < <(
    find "${voice_input_staged_app}/Contents/Frameworks" -depth -type d \
      \( -name '*.framework' -o -name '*.xpc' -o -name '*.appex' -o -name '*.app' \) \
      -print0
  )
fi

codesign --force \
  --sign "${voice_input_identity_hash}" \
  --options runtime \
  --timestamp=none \
  --entitlements Resources/VoiceInputLocal.entitlements \
  "${voice_input_staged_app}"
codesign --verify --deep --strict --verbose=2 "${voice_input_staged_app}"

voice_input_designated_requirement="$(codesign -dr - "${voice_input_staged_app}" 2>&1)"
if [[ "${voice_input_designated_requirement}" == *'cdhash H"'* ]]; then
  echo "refusing to install a hash-bound ad-hoc signature" >&2
  exit 1
fi
if [[ "${voice_input_designated_requirement}" != *"${voice_input_expected_bundle_id}"* ]]; then
  echo "the designated requirement does not contain the expected bundle ID" >&2
  exit 1
fi

voice_input_backup_root="${HOME}/Library/Application Support/AI Voice Input/App Backups"
mkdir -p "${voice_input_backup_root}"
chmod 700 "${voice_input_backup_root}"
voice_input_backup_app=""

pkill -x VoiceInput >/dev/null 2>&1 || true

if [[ -e "${voice_input_destination_app}" ]]; then
  voice_input_backup_app="${voice_input_backup_root}/VoiceInput-$(date -u +%Y%m%dT%H%M%SZ)-$$.app"
  mv "${voice_input_destination_app}" "${voice_input_backup_app}"
fi

if ! mv "${voice_input_staged_app}" "${voice_input_destination_app}"; then
  if [[ -n "${voice_input_backup_app}" && -e "${voice_input_backup_app}" ]]; then
    mv "${voice_input_backup_app}" "${voice_input_destination_app}"
  fi
  exit 1
fi

if ! codesign --verify --deep --strict --verbose=2 "${voice_input_destination_app}"; then
  voice_input_failed_app="${voice_input_backup_root}/VoiceInput-failed-$(date -u +%Y%m%dT%H%M%SZ)-$$.app"
  mv "${voice_input_destination_app}" "${voice_input_failed_app}"
  if [[ -n "${voice_input_backup_app}" && -e "${voice_input_backup_app}" ]]; then
    mv "${voice_input_backup_app}" "${voice_input_destination_app}"
  fi
  echo "installed app verification failed; the previous app was restored" >&2
  exit 1
fi

launch_services="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
for voice_input_obsolete_app in \
  "${voice_input_source_app}" \
  "${HOME}/Downloads/VoiceInput.app"
do
  if [[ "${voice_input_obsolete_app}" != "${voice_input_destination_app}" ]]; then
    "${launch_services}" -u "${voice_input_obsolete_app}" >/dev/null 2>&1 || true
  fi
done
"${launch_services}" -f "${voice_input_destination_app}"
open "${voice_input_destination_app}"

echo "installed stable local build: ${voice_input_destination_app}"
echo "signing identity: ${voice_input_identity} (${voice_input_identity_hash})"
echo "designated requirement: ${voice_input_designated_requirement}"
if [[ -n "${voice_input_backup_app}" ]]; then
  echo "previous app backup: ${voice_input_backup_app}"
fi
