# Этап 01. Каркас macOS-проекта

## Цель

Создай воспроизводимый проект `MeetingAssistant`, который собирается для macOS 14+ на Apple Silicon и имеет модульную структуру для последующих этапов.

## Требования

1. Если в репозитории уже есть рабочий macOS-проект, аккуратно адаптируй его. Не пересоздавай и не удаляй пользовательскую работу.
2. Если проекта нет, используй XcodeGen:
   - `project.yml` в корне;
   - продукт `MeetingAssistant.app`;
   - bundle identifier `com.local.MeetingAssistant`;
   - deployment target macOS 14.0;
   - Swift 6;
   - схемы `MeetingAssistant` и `MeetingAssistantTests`.
3. Добавь каталоги или Swift targets с ясными границами:
   - `App`;
   - `Domain`;
   - `AudioCapture`;
   - `RealtimeClient`;
   - `Transcription`;
   - `Persistence`;
   - `OverlayUI`;
   - `HistoryUI`;
   - `Summary`;
   - `Security`;
   - `Diagnostics`.
4. Подключи Swift Package `https://github.com/argmaxinc/argmax-oss-swift.git` и продукт WhisperKit. Разреши актуальный стабильный релиз, после чего закрепи точную версию в проекте и `Package.resolved`.
5. Добавь `Info.plist` с понятными описаниями причин доступа к микрофону и записи экрана.
6. Добавь entitlements, необходимые для App Sandbox, аудиовхода и исходящих сетевых соединений. Не ослабляй sandbox без документированной причины.
7. Создай SwiftUI entry point. На старте `AppMode` обязан быть `passive`.
8. Создай composition root, но пока подключай только безопасные пустые сервисы, которые ничего не захватывают и не отправляют. Это не могут быть заглушки, имитирующие успешную работу: они должны явно реализовывать `inactive`-поведение.
9. Добавь базовый экран/меню со строго тремя режимами, пока без запуска реальных пайплайнов.
10. Добавь `.gitignore` для Xcode, локальных моделей, пользовательской базы, секретов, архивов и build artifacts.
11. Добавь `README.md` с требованиями среды, генерацией проекта и командами проверки.

## Команды проверки

Используй доступные эквиваленты следующих проверок:

```bash
xcodegen generate
xcodebuild -project MeetingAssistant.xcodeproj -scheme MeetingAssistant -destination 'platform=macOS' build
xcodebuild -project MeetingAssistant.xcodeproj -scheme MeetingAssistant -destination 'platform=macOS' test
```

Если `xcodegen` отсутствует, не устанавливай его автоматически: проверь `project.yml` статически, выполни все доступные Swift-проверки и укажи точную блокировку в статусе.

## Критерии приёмки

- Проект воспроизводимо генерируется и собирается либо есть точное внешнее препятствие.
- Приложение запускается в `passive`.
- Есть только три пользовательских режима.
- В репозитории нет API-ключей, локальных моделей и пользовательской базы.
- Структура позволяет тестировать доменную логику без ScreenCaptureKit и сети.

