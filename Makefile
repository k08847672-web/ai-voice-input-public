.PHONY: icons validate-release mac-project mac-test mac-local-signing-setup mac-local-install mac-archive mac-notarize ios-project ios-test android-test android-apk android-install server-bootstrap server-test server-run check

icons:
	python3 scripts/generate_app_icons.py

validate-release:
	python3 scripts/validate_release_sources.py

mac-project: icons
	xcodegen generate

mac-test: mac-project
	swift test
	xcodebuild -project VoiceInput.xcodeproj -scheme VoiceInput -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO

mac-local-signing-setup:
	./scripts/setup_local_signing.sh

mac-local-install:
	./scripts/install_local_signed_app.sh

mac-archive: mac-project
	./scripts/archive.sh

mac-notarize:
	./scripts/notarize.sh

ios-project: icons
	cd ios && xcodegen generate

ios-test: ios-project
	VOICE_INPUT_IOS_SIMULATOR_ID="$$(python3 scripts/select_ios_simulator.py)"; \
	xcodebuild -project ios/VoiceInputIOS.xcodeproj -scheme VoiceInputIOS \
		-destination "platform=iOS Simulator,id=$${VOICE_INPUT_IOS_SIMULATOR_ID}" \
		test CODE_SIGNING_ALLOWED=NO

android-test:
	JAVA_HOME="$${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}" \
	ANDROID_HOME="$${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}" \
		./android/gradlew -p android testDebugUnitTest lintDebug

android-apk:
	JAVA_HOME="$${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}" \
	ANDROID_HOME="$${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}" \
		./android/gradlew -p android assembleDebug
	mkdir -p dist
	cp android/app/build/outputs/apk/debug/app-debug.apk dist/VoiceInput-android-debug.apk

android-install: android-apk
	adb install -r dist/VoiceInput-android-debug.apk

server-bootstrap:
	python3 -m venv server/.venv
	server/.venv/bin/pip install --requirement server/requirements-dev.lock
	server/.venv/bin/pip install --no-deps --editable server

server-test:
	server/.venv/bin/ruff check server/src server/tests scripts/generate_app_icons.py
	server/.venv/bin/mypy --config-file server/pyproject.toml server/src
	server/.venv/bin/pytest server

server-run:
	VOICE_INPUT_BEARER_TOKEN=development-token server/.venv/bin/uvicorn voice_input_server.app:app --app-dir server/src --host 127.0.0.1 --port 8765

check: validate-release server-test
	git diff --check
