#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "local signing setup must run on macOS" >&2
  exit 1
fi

voice_input_identity="${VOICE_INPUT_LOCAL_SIGNING_IDENTITY:-VoiceInput Local Signing}"
if [[ ! "${voice_input_identity}" =~ ^[A-Za-z0-9._\ -]{3,80}$ ]]; then
  echo "VOICE_INPUT_LOCAL_SIGNING_IDENTITY contains unsupported characters" >&2
  exit 1
fi

voice_input_keychain="$(
  security default-keychain -d user \
    | sed -E 's/^[[:space:]]*\"//; s/\"[[:space:]]*$//'
)"
if [[ -z "${voice_input_keychain}" || ! -f "${voice_input_keychain}" ]]; then
  echo "the default user keychain could not be resolved" >&2
  exit 1
fi

voice_input_existing_hash="$({
  security find-identity -v -p codesigning "${voice_input_keychain}" 2>/dev/null || true
} | awk -v name="${voice_input_identity}" 'index($0, "\"" name "\"") { print $2; exit }')"
if [[ -n "${voice_input_existing_hash}" ]]; then
  echo "local signing identity is ready: ${voice_input_identity} (${voice_input_existing_hash})"
  exit 0
fi

if security find-certificate -c "${voice_input_identity}" "${voice_input_keychain}" >/dev/null 2>&1; then
  echo "a certificate named '${voice_input_identity}' exists but is not a valid code-signing identity" >&2
  echo "inspect or remove that certificate in Keychain Access before retrying" >&2
  exit 1
fi

voice_input_temp_root="$(mktemp -d "${TMPDIR:-/tmp}/voiceinput-local-signing.XXXXXX")"
voice_input_private_key="${voice_input_temp_root}/identity.key.pem"
voice_input_certificate="${voice_input_temp_root}/identity.cert.pem"
voice_input_pkcs12="${voice_input_temp_root}/identity.p12"
voice_input_pkcs12_password="$(openssl rand -hex 32)"
voice_input_certificate_hash=""
voice_input_identity_imported=0
voice_input_setup_complete=0

cleanup() {
  voice_input_exit_status=$?
  if [[ "${voice_input_identity_imported}" -eq 1 \
        && "${voice_input_setup_complete}" -ne 1 \
        && -n "${voice_input_certificate_hash}" ]]; then
    security delete-identity \
      -Z "${voice_input_certificate_hash}" \
      -t \
      "${voice_input_keychain}" >/dev/null 2>&1 || true
  fi
  unlink "${voice_input_private_key}" >/dev/null 2>&1 || true
  unlink "${voice_input_certificate}" >/dev/null 2>&1 || true
  unlink "${voice_input_pkcs12}" >/dev/null 2>&1 || true
  rmdir "${voice_input_temp_root}" >/dev/null 2>&1 || true
  trap - EXIT
  exit "${voice_input_exit_status}"
}
trap cleanup EXIT

openssl req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes \
  -subj "/CN=${voice_input_identity}/O=AI Voice Input/OU=Local Development" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=codeSigning" \
  -addext "subjectKeyIdentifier=hash" \
  -keyout "${voice_input_private_key}" \
  -out "${voice_input_certificate}" >/dev/null 2>&1
voice_input_certificate_hash="$(
  openssl x509 -in "${voice_input_certificate}" -noout -fingerprint -sha1 \
    | cut -d= -f2 \
    | tr -d ':'
)"

openssl pkcs12 -export -legacy \
  -name "${voice_input_identity}" \
  -inkey "${voice_input_private_key}" \
  -in "${voice_input_certificate}" \
  -out "${voice_input_pkcs12}" \
  -passout "pass:${voice_input_pkcs12_password}" >/dev/null 2>&1

# The imported private key is non-exportable. Only Apple's signing/security tools
# are granted access, and the certificate is trusted for code signing in the user domain.
security import "${voice_input_pkcs12}" \
  -k "${voice_input_keychain}" \
  -P "${voice_input_pkcs12_password}" \
  -x \
  -T /usr/bin/codesign \
  -T /usr/bin/security >/dev/null
voice_input_identity_imported=1
security add-trusted-cert \
  -r trustRoot \
  -p codeSign \
  -k "${voice_input_keychain}" \
  "${voice_input_certificate}"

voice_input_created_hash="$({
  security find-identity -v -p codesigning "${voice_input_keychain}" 2>/dev/null || true
} | awk -v name="${voice_input_identity}" 'index($0, "\"" name "\"") { print $2; exit }')"
if [[ -z "${voice_input_created_hash}" ]]; then
  echo "the local signing identity was imported but did not become valid" >&2
  exit 1
fi
voice_input_setup_complete=1

echo "created persistent local signing identity: ${voice_input_identity} (${voice_input_created_hash})"
echo "the private key is non-exportable and stored only in the default user keychain"
