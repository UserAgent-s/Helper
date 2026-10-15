# Этап 08. SQLite, миграции, история и поиск

## Цель

Реализуй надёжное локальное хранилище для Q&A и текстовых протоколов митингов без смешивания двух типов данных.

## SQLite

Используй SQLite3 с:

- WAL;
- foreign keys;
- numbered migrations;
- транзакциями;
- actor-изолированным доступом;
- FTS5 для текстового поиска;
- тестовой in-memory базой.

## Минимальная схема

Создай таблицы с полными типизированными моделями и миграциями.

### `meetings`

- `id` UUID primary key;
- `title`;
- `source_bundle_id`;
- `started_at`;
- nullable `ended_at`;
- `status`: recording/completed/interrupted/failed;
- `created_at` и `updated_at`.

### `utterances`

- `id` UUID primary key;
- `meeting_id` foreign key with cascade;
- `source`: remote/local;
- `started_ms`;
- `ended_ms`;
- `text`;
- nullable `language`;
- nullable `confidence`;
- `created_at`.

### `qa_entries`

- `id` UUID primary key;
- `asked_at`;
- nullable `source_bundle_id`;
- nullable `question_text`;
- `question_status`;
- nullable `context_started_at` и `context_duration_ms`;
- `trigger_kind`: automatic/manual;
- `answer_text`;
- `answer_status`;
- `model_id`;
- nullable `response_id`;
- nullable latency fields;
- nullable input/output token counts;
- nullable estimated cost;
- `created_at` и `updated_at`.

### `summaries`

- `id` UUID primary key;
- `meeting_id` foreign key with cascade;
- `model_id`;
- `schema_version`;
- `content_json`;
- `rendered_markdown`;
- usage/cost fields;
- `created_at`.

Создай FTS virtual tables и синхронизирующие triggers либо явную транзакционную синхронизацию. Поиск должен охватывать meeting utterances, вопросы и ответы, но показывать их в разных разделах.

## Репозитории

Реализуй `MeetingRepository`, `QuestionAnswerRepository` и `SummaryRepository`. UI и режимы не должны выполнять SQL напрямую.

Поддержи:

- постраничную историю;
- поиск;
- получение полного митинга по времени;
- обновление асинхронно распознанного вопроса;
- атомарную финализацию встречи;
- удаление одной записи;
- каскадное удаление встречи;
- очистку всей пользовательской истории с подтверждением;
- экспорт snapshot без удержания долгой write-транзакции.

## История UI

Сделай две верхнеуровневые вкладки:

- `Вопросы и ответы`;
- `Митинги`.

Не объединяй полный transcript с Q&A в одну ленту. Для встречи показывай продолжительность, источник, количество реплик, поиск и кнопку саммари.

## Миграции и сбои

- Миграция выполняется до запуска режимов.
- Ошибка базы не должна приводить к скрытой потере данных: останови активный режим и покажи ошибку.
- Не удаляй повреждённую базу автоматически.
- Добавь backup/export перед потенциально необратимой миграцией, если такая появится.

## Тесты

Проверь миграции с нулевой версии, CRUD, foreign keys, FTS, параллельное обновление draft Q&A, `trigger_kind`, длительность context window, финализацию встречи, interrupted status, cascade delete и отсутствие контекста без показанного ответа.

## Критерии приёмки

- Полный transcript существует только внутри meeting records.
- Q&A обновляется асинхронно без потери ответа.
- Поиск работает по русскому и английскому тексту настолько, насколько поддерживает выбранная FTS tokenization; ограничения документированы.
- Все записи и удаления проходят через репозитории и транзакции.
