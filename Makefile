.PHONY: verify-fast verify-real project

project:
	xcodegen generate

verify-fast: project
	swift build --build-tests
	swift test
	xcodebuild -project MeetingAssistant.xcodeproj -scheme MeetingAssistant -configuration Debug -derivedDataPath build/DerivedData build
	xcodebuild -project MeetingAssistant.xcodeproj -scheme MeetingAssistant -configuration Debug -derivedDataPath build/DerivedData test

verify-real:
	@echo "Real API checks are manual and paid; no automated real-API target exists."
	@echo "Protocol: README.md, section 'Сравнительный тренировочный тест провайдеров'."
	@exit 1
