#!/usr/bin/env python3
"""Validate release-critical source artifacts without Xcode or third-party packages."""

from __future__ import annotations

import json
import plistlib
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class ValidationFailure(Exception):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationFailure(message)


def load_plist(relative_path: str) -> dict[str, object]:
    with (ROOT / relative_path).open("rb") as file:
        value = plistlib.load(file)
    require(isinstance(value, dict), f"{relative_path} must contain a dictionary")
    return value


def validate_info_plist() -> None:
    info = load_plist("Resources/Info.plist")
    expected = {
        "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "$(MARKETING_VERSION)",
        "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        "LSUIElement": True,
        "NSPrincipalClass": "NSApplication",
    }
    for key, value in expected.items():
        require(info.get(key) == value, f"Info.plist {key} must be {value!r}")
    usage = info.get("NSMicrophoneUsageDescription")
    require(isinstance(usage, str) and len(usage.strip()) >= 12, "microphone usage text is missing")


def validate_entitlements() -> None:
    entitlements = load_plist("Resources/VoiceInput.entitlements")
    local_entitlements = load_plist("Resources/VoiceInputLocal.entitlements")
    require(
        entitlements.get("com.apple.security.device.audio-input") is True,
        "Hardened Runtime audio-input entitlement is required",
    )
    require(
        entitlements.get("com.apple.security.app-sandbox") is not True,
        "Accessibility insertion is incompatible with the current sandbox configuration",
    )
    require(
        entitlements.get("com.apple.security.cs.disable-library-validation") is not True,
        "Developer ID releases must keep library validation enabled",
    )
    require(
        local_entitlements.get("com.apple.security.device.audio-input") is True
        and local_entitlements.get("com.apple.security.cs.disable-library-validation") is True,
        "local self-signed builds need audio input and disabled library validation",
    )
    project = (ROOT / "project.yml").read_text(encoding="utf-8")
    require("ENABLE_HARDENED_RUNTIME: YES" in project, "Hardened Runtime must remain enabled")
    require(
        "CODE_SIGN_ENTITLEMENTS: Resources/VoiceInput.entitlements" in project,
        "application target must use VoiceInput.entitlements",
    )


def png_size(path: Path) -> tuple[int, int]:
    data = path.read_bytes()[:24]
    require(data[:8] == b"\x89PNG\r\n\x1a\n", f"{path.name} is not a PNG")
    return struct.unpack(">II", data[16:24])


def png_color_type(path: Path) -> int:
    data = path.read_bytes()[:26]
    require(data[:8] == b"\x89PNG\r\n\x1a\n", f"{path.name} is not a PNG")
    return data[25]


def validate_app_icons() -> None:
    directory = ROOT / "Resources/Assets.xcassets/AppIcon.appiconset"
    catalog = json.loads((directory / "Contents.json").read_text(encoding="utf-8"))
    images = catalog.get("images")
    require(
        isinstance(images, list) and len(images) == 11,
        "AppIcon must have 10 macOS slots and one iOS marketing slot",
    )
    seen: set[str] = set()
    for item in images:
        require(isinstance(item, dict), "invalid AppIcon catalog entry")
        filename = item.get("filename")
        size = item.get("size")
        scale = item.get("scale", "1x")
        require(isinstance(filename, str) and filename not in seen, "AppIcon filename is missing/duplicate")
        require(isinstance(size, str) and isinstance(scale, str), f"invalid slot for {filename}")
        seen.add(filename)
        points = int(size.split("x", maxsplit=1)[0])
        multiplier = int(scale.removesuffix("x"))
        expected = points * multiplier
        require(png_size(directory / filename) == (expected, expected), f"wrong dimensions for {filename}")

    ios_slots = [
        item
        for item in images
        if item.get("idiom") == "universal" and item.get("platform") == "ios"
    ]
    require(
        len(ios_slots) == 1 and ios_slots[0].get("size") == "1024x1024",
        "AppIcon must include one universal 1024x1024 iOS icon",
    )
    ios_icon = directory / "icon-ios-1024.png"
    require(png_color_type(ios_icon) == 2, "iOS AppIcon must be opaque RGB without an alpha channel")


def validate_ios_configuration() -> None:
    app_info = load_plist("ios/Resources/VoiceInputIOS-Info.plist")
    keyboard_info = load_plist("ios/Resources/VoiceInputKeyboard-Info.plist")
    app_entitlements = load_plist("ios/Resources/VoiceInputIOS.entitlements")
    keyboard_entitlements = load_plist("ios/Resources/VoiceInputKeyboard.entitlements")
    app_group = "group.com.aivoiceinput.shared"

    usage = app_info.get("NSMicrophoneUsageDescription")
    require(isinstance(usage, str) and len(usage.strip()) >= 12, "iOS microphone usage text is missing")
    ats = app_info.get("NSAppTransportSecurity")
    require(
        isinstance(ats, dict) and ats.get("NSAllowsArbitraryLoads") is True,
        "iOS ATS must permit the explicitly validated Tailscale ws:// deployment",
    )
    extension = keyboard_info.get("NSExtension")
    require(isinstance(extension, dict), "keyboard extension configuration is missing")
    require(
        extension.get("NSExtensionPointIdentifier") == "com.apple.keyboard-service",
        "keyboard extension point is invalid",
    )
    attributes = extension.get("NSExtensionAttributes")
    require(
        isinstance(attributes, dict) and attributes.get("RequestsOpenAccess") is True,
        "keyboard App Group transfer requires Full Access",
    )
    for name, entitlements in [
        ("iOS app", app_entitlements),
        ("keyboard", keyboard_entitlements),
    ]:
        require(
            entitlements.get("com.apple.security.application-groups") == [app_group],
            f"{name} must use the shared App Group",
        )

    project = (ROOT / "ios/project.yml").read_text(encoding="utf-8")
    require("VoiceInputKeyboard:" in project, "iOS project must embed the keyboard target")
    require(
        "Sources/VoiceInputApp/WebSocketASRClient.swift" in project
        and "Sources/VoiceInputApp/AudioCaptureService.swift" in project,
        "iOS app must reuse the reviewed transport and audio sources",
    )
    shared_store = (ROOT / "Sources/VoiceInputMobileShared/SharedTranscriptStore.swift").read_text(
        encoding="utf-8"
    )
    require(
        "pendingTranscriptLifetime: TimeInterval = 10 * 60" in shared_store
        and "public func consume" in shared_store,
        "mobile transcript transfer must remain expiring and one-time",
    )


def validate_dependency_locks() -> None:
    pinned = re.compile(r"^[A-Za-z0-9_.-]+==[^\s]+$")
    for relative_path in ["server/requirements.lock", "server/requirements-dev.lock"]:
        for number, raw_line in enumerate(
            (ROOT / relative_path).read_text(encoding="utf-8").splitlines(), start=1
        ):
            line = raw_line.strip()
            if not line or line.startswith("-r "):
                continue
            require(pinned.fullmatch(line) is not None, f"{relative_path}:{number} is not pinned")

    dockerfile = (ROOT / "server/Dockerfile").read_text(encoding="utf-8")
    first_line = dockerfile.splitlines()[0]
    require(
        re.fullmatch(r"FROM python:3\.12-slim-bookworm@sha256:[0-9a-f]{64}", first_line) is not None,
        "Docker base image must use a multi-architecture digest",
    )


def validate_release_scripts() -> None:
    archive = ROOT / "scripts/archive.sh"
    notarize = ROOT / "scripts/notarize.sh"
    local_setup = ROOT / "scripts/setup_local_signing.sh"
    local_install = ROOT / "scripts/install_local_signed_app.sh"
    for script in [archive, notarize, local_setup, local_install]:
        require(script.stat().st_mode & 0o111 != 0, f"{script.name} must be executable")
    archive_text = archive.read_text(encoding="utf-8")
    notarize_text = notarize.read_text(encoding="utf-8")
    local_setup_text = local_setup.read_text(encoding="utf-8")
    local_install_text = local_install.read_text(encoding="utf-8")
    require("Developer ID Application" in archive_text, "archive must use Developer ID signing")
    require("--timestamp" in archive_text, "archive must request a secure timestamp")
    require("notarytool submit" in notarize_text, "notarize script must submit the artifact")
    require("stapler staple" in notarize_text, "notarize script must staple the application")
    require("VoiceInput-notarized.zip" in notarize_text, "notarized app must be repackaged")
    require(
        "extendedKeyUsage=codeSigning" in local_setup_text
        and "security add-trusted-cert" in local_setup_text,
        "local setup must create and trust a persistent code-signing identity",
    )
    require(
        "-x" in local_setup_text and "-T /usr/bin/codesign" in local_setup_text,
        "local signing private key must be non-exportable and restricted to signing tools",
    )
    require(
        'voice_input_destination_app="/Applications/VoiceInput.app"' in local_install_text,
        "local signed app must use a stable installation path",
    )
    require(
        "--options runtime" in local_install_text
        and "--entitlements Resources/VoiceInputLocal.entitlements" in local_install_text
        and "codesign --verify --deep --strict" in local_install_text,
        "local installation must preserve runtime/entitlements and verify the signed app",
    )
    require(
        "refusing to install a hash-bound ad-hoc signature" in local_install_text,
        "local installation must reject unstable ad-hoc designated requirements",
    )


def validate_protocol_fixture() -> None:
    relative_path = "Tests/VoiceInputCoreTests/Fixtures/asr_v1.json"
    fixture = json.loads((ROOT / relative_path).read_text(encoding="utf-8"))
    require(isinstance(fixture, dict), "protocol fixture must be a JSON object")
    client = fixture.get("client")
    server = fixture.get("server")
    require(isinstance(client, dict), "protocol fixture client messages are missing")
    require(isinstance(server, list) and len(server) == 4, "protocol fixture server events are missing")
    start = client.get("start")
    stop = client.get("stop")
    require(isinstance(start, dict) and start.get("protocol_version") == 1, "invalid v1 start fixture")
    require(isinstance(stop, dict) and stop.get("type") == "stop", "invalid stop fixture")
    session_id = fixture.get("session_id")
    require(
        start.get("session_id") == session_id
        and stop.get("session_id") == session_id
        and all(isinstance(message, dict) and message.get("session_id") == session_id for message in server),
        "protocol fixture session IDs must match",
    )
    swift_tests = (ROOT / "Tests/VoiceInputCoreTests/ASRProtocolTests.swift").read_text(
        encoding="utf-8"
    )
    python_tests = (ROOT / "server/tests/test_protocol.py").read_text(encoding="utf-8")
    require("Fixtures/asr_v1.json" in swift_tests, "Swift tests must consume the shared fixture")
    require("asr_v1.json" in python_tests, "Python tests must consume the shared fixture")


def validate_secure_settings_storage() -> None:
    store = (ROOT / "Sources/VoiceInputApp/SettingsStore.swift").read_text(encoding="utf-8")
    codec = (ROOT / "Sources/VoiceInputApp/SecureSettingsCodec.swift").read_text(encoding="utf-8")
    project = (ROOT / "project.yml").read_text(encoding="utf-8")
    require('appendingPathComponent("settings.enc")' in store, "settings must use encrypted storage")
    require("AES.GCM.seal" in codec and "AES.GCM.open" in codec, "settings must use AES-GCM")
    require(
        'KeychainDataStore(account: "settings-encryption-key-v1")' in codec,
        "settings encryption key must be stored in Keychain",
    )
    require(".posixPermissions: 0o600" in store, "encrypted settings file must be owner-only")
    require("VoiceInputAppTests:" in project, "macOS app tests must remain in the Xcode scheme")
    require(
        (ROOT / "Tests/VoiceInputAppTests/SecureSettingsCodecTests.swift").is_file(),
        "secure settings codec tests are missing",
    )


def main() -> int:
    checks = [
        validate_info_plist,
        validate_entitlements,
        validate_app_icons,
        validate_ios_configuration,
        validate_dependency_locks,
        validate_release_scripts,
        validate_protocol_fixture,
        validate_secure_settings_storage,
    ]
    try:
        for check in checks:
            check()
    except (OSError, ValueError, ValidationFailure) as error:
        print(f"release source validation failed: {error}", file=sys.stderr)
        return 1
    print(f"release source validation passed ({len(checks)} checks)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
