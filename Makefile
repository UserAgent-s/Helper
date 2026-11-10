XCODEGEN_VERSION := 2.45.4
DERIVED_DATA := build/DerivedData
XCODEBUILD_FLAGS := -project UserAgent057.xcodeproj -scheme UserAgent057 -destination 'platform=macOS,arch=arm64' -derivedDataPath $(DERIVED_DATA) CODE_SIGNING_ALLOWED=NO

.PHONY: verify-fast verify-real verify-real-me verify-real-claude lint-no-comments build test xcode-test ui-test check-tools dev-identity signing-status

verify-fast: check-tools lint-no-comments build test xcode-test

check-tools:
	@actual="$$(xcodegen --version 2>/dev/null | awk '{print $$2}')"; \
	if [ "$$actual" != "$(XCODEGEN_VERSION)" ]; then \
		echo "XcodeGen $(XCODEGEN_VERSION) required, found '$$actual'"; exit 1; \
	fi

lint-no-comments:
	@scripts/check-no-comments.sh

build:
	swift build

test:
	swift test --skip RealAPITests

xcode-test:
	xcodegen generate --quiet
	xcodebuild $(XCODEBUILD_FLAGS) test -quiet

ui-test:
	xcodegen generate --quiet
	xcodebuild -project UserAgent057.xcodeproj -scheme UserAgent057UITests -destination 'platform=macOS,arch=arm64' -derivedDataPath $(DERIVED_DATA)-ui test

dev-identity:
	scripts/make-dev-signing-identity.sh
	xcodegen generate --quiet

signing-status:
	@scripts/signing-status.sh $(APP)

verify-real:
	@if [ -z "$$OPENAI_API_KEY" ]; then \
		echo "verify-real needs OPENAI_API_KEY in the environment. It calls the paid OpenAI Realtime API."; exit 2; \
	fi
	RUN_REAL_API_TESTS=1 swift test --filter RealAPITests

verify-real-me:
	@if [ -z "$$OPENAI_API_KEY" ]; then \
		echo "verify-real-me needs OPENAI_API_KEY in the environment. It calls the paid OpenAI Realtime API."; exit 2; \
	fi
	set -o pipefail; RUN_REAL_API_TESTS=1 swift test --filter MeChannelLatencyTests 2>&1 | tee .build/verify-real-me.log | grep -E "VERIFY_REAL|✔|✘|error"

verify-real-claude:
	@if [ -z "$$ANTHROPIC_API_KEY" ]; then \
		echo "verify-real-claude needs ANTHROPIC_API_KEY in the environment. It calls the paid Anthropic Messages API (about \$$0.5-1 per run)."; exit 2; \
	fi
	@mkdir -p .build
	set -o pipefail; RUN_REAL_API_TESTS=1 swift test --filter ClaudeExpansionRealTests 2>&1 | tee .build/verify-real-claude.log | grep -E "VERIFY_REAL|✔|✘|error"
