# ADR 0005: Keychain для ключей; App Sandbox остаётся выключенным

Дата: 2026-10-15. Статус: принято.

## Фактическое состояние до изменения

- `CompositionRoot` использовал `UserDefaultsSecretStore`, хотя README обещал Keychain.
- `project.yml`: `ENABLE_APP_SANDBOX: NO`; `Resources/MeetingAssistant.entitlements`: `com.apple.security.app-sandbox = false`. Проверено в собранном бинаре (`codesign -d --entitlements`): `app-sandbox => false`. README утверждал обратное.

## Решение по ключам

Оба ключа (OpenAI, Anthropic) хранятся в Keychain. Старый ключ OpenAI мигрирует с проверкой (`LegacyAPIKeyMigrator`): запись → чтение и сравнение → удаление старого значения; при ошибке старое значение сохраняется и используется как резерв (`KeychainFirstSecretStore`). Цена: при ad-hoc-подписи macOS может повторно запрашивать доступ после пересборки.

## Решение по App Sandbox

Оставить выключенным, исправить документацию. Включение вслепую ломает:

- `DesktopMeetingExporter` пишет транскрипт прямо на `~/Desktop` без выбора пользователем — в песочнице это запрещено без отдельного entitlement и изменения UX;
- кеш модели WhisperKit, который скачивается в каталог вне контейнера приложения, — в песочнице путь меняется, модели пришлось бы перекачивать и переносить;
- существующие пользовательские данные в `~/Library/Application Support/MeetingAssistant` не будут видны из контейнера без миграции.

Нотаризации песочница не нужна (нужен Hardened Runtime — включён). Включать App Sandbox имеет смысл отдельным этапом: экспорт через `NSSavePanel`/security-scoped bookmarks, явный `downloadBase` для WhisperKit внутри контейнера, миграция данных.
