XCODEGEN_VERSION := 2.45.4
DERIVED_DATA := build/DerivedData
XCODEBUILD_FLAGS := -project UserAgent057.xcodeproj -scheme UserAgent057 -destination 'platform=macOS,arch=arm64' -derivedDataPath $(DERIVED_DATA) CODE_SIGNING_ALLOWED=NO

.PHONY: verify-fast verify-real lint-no-comments build test xcode-test check-tools

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

verify-real:
	@if [ -z "$$OPENAI_API_KEY" ]; then \
		echo "verify-real needs OPENAI_API_KEY in the environment. It calls the paid OpenAI Realtime API."; exit 2; \
	fi
	RUN_REAL_API_TESTS=1 swift test --filter RealAPITests
