struct SQLiteMigration {
    let version: Int
    let statements: [String]
    var backsUpExistingDatabase = false
}

enum SQLiteMigrations {
    static let all: [SQLiteMigration] = [
        SQLiteMigration(version: 1, statements: [
            """
            CREATE TABLE meetings (
                id TEXT PRIMARY KEY,
                title TEXT,
                source_bundle_id TEXT,
                started_at TEXT NOT NULL,
                ended_at TEXT,
                status TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            """,
            """
            CREATE TABLE utterances (
                id TEXT PRIMARY KEY,
                meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                source TEXT NOT NULL,
                started_ms INTEGER NOT NULL,
                ended_ms INTEGER NOT NULL,
                text TEXT NOT NULL,
                language TEXT,
                confidence REAL,
                created_at TEXT NOT NULL
            )
            """,
            "CREATE INDEX idx_utterances_meeting_id ON utterances(meeting_id)",
            """
            CREATE TABLE qa_entries (
                id TEXT PRIMARY KEY,
                asked_at TEXT NOT NULL,
                source_bundle_id TEXT,
                question_text TEXT,
                question_status TEXT NOT NULL,
                context_started_at TEXT,
                context_duration_ms INTEGER,
                trigger_kind TEXT NOT NULL,
                answer_text TEXT NOT NULL,
                answer_status TEXT NOT NULL,
                model_id TEXT NOT NULL,
                response_id TEXT,
                speech_end_to_first_delta_ms INTEGER,
                first_delta_to_first_paint_ms INTEGER,
                response_total_ms INTEGER,
                usage_tokens INTEGER,
                estimated_cost_usd REAL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            """,
            """
            CREATE TABLE summaries (
                id TEXT PRIMARY KEY,
                meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                model_id TEXT NOT NULL,
                schema_version INTEGER NOT NULL,
                content_json TEXT NOT NULL,
                rendered_markdown TEXT NOT NULL,
                usage_tokens INTEGER,
                estimated_cost_usd REAL,
                created_at TEXT NOT NULL
            )
            """,
            "CREATE INDEX idx_summaries_meeting_id ON summaries(meeting_id)",
            """
            CREATE VIRTUAL TABLE utterances_fts USING fts5(
                text, content='utterances', content_rowid='rowid'
            )
            """,
            """
            CREATE VIRTUAL TABLE qa_entries_fts USING fts5(
                question_text, answer_text, content='qa_entries', content_rowid='rowid'
            )
            """,
            """
            CREATE TRIGGER utterances_ai AFTER INSERT ON utterances BEGIN
                INSERT INTO utterances_fts(rowid, text) VALUES (new.rowid, new.text);
            END
            """,
            """
            CREATE TRIGGER utterances_ad AFTER DELETE ON utterances BEGIN
                INSERT INTO utterances_fts(utterances_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
            END
            """,
            """
            CREATE TRIGGER utterances_au AFTER UPDATE ON utterances BEGIN
                INSERT INTO utterances_fts(utterances_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
                INSERT INTO utterances_fts(rowid, text) VALUES (new.rowid, new.text);
            END
            """,
            """
            CREATE TRIGGER qa_entries_ai AFTER INSERT ON qa_entries BEGIN
                INSERT INTO qa_entries_fts(rowid, question_text, answer_text) VALUES (new.rowid, new.question_text, new.answer_text);
            END
            """,
            """
            CREATE TRIGGER qa_entries_ad AFTER DELETE ON qa_entries BEGIN
                INSERT INTO qa_entries_fts(qa_entries_fts, rowid, question_text, answer_text) VALUES ('delete', old.rowid, old.question_text, old.answer_text);
            END
            """,
            """
            CREATE TRIGGER qa_entries_au AFTER UPDATE ON qa_entries BEGIN
                INSERT INTO qa_entries_fts(qa_entries_fts, rowid, question_text, answer_text) VALUES ('delete', old.rowid, old.question_text, old.answer_text);
                INSERT INTO qa_entries_fts(rowid, question_text, answer_text) VALUES (new.rowid, new.question_text, new.answer_text);
            END
            """,
        ]),
        SQLiteMigration(version: 2, statements: [
            "ALTER TABLE qa_entries ADD COLUMN question_transcription_model_id TEXT",
            """
            UPDATE qa_entries
            SET question_transcription_model_id = model_id, model_id = 'gpt-realtime-2.1'
            WHERE model_id NOT LIKE 'gpt-realtime%'
            """,
        ], backsUpExistingDatabase: true),
        SQLiteMigration(version: 3, statements: [
            """
            CREATE TABLE paired_devices (
                device_id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                token_hash TEXT NOT NULL UNIQUE,
                created_at TEXT NOT NULL,
                last_seen_at TEXT
            )
            """,
        ]),
        SQLiteMigration(version: 4, statements: SessionSchema.statements, backsUpExistingDatabase: true),
        SQLiteMigration(version: 5, statements: [
            "ALTER TABLE deep_expansions ADD COLUMN parent_id TEXT REFERENCES deep_expansions(id) ON DELETE SET NULL",
            "ALTER TABLE deep_expansions ADD COLUMN source_kind TEXT",
            "ALTER TABLE deep_expansions ADD COLUMN point_id TEXT",
            "ALTER TABLE deep_expansions ADD COLUMN source_text TEXT",
            "ALTER TABLE deep_expansions ADD COLUMN format TEXT",
            "ALTER TABLE deep_expansions ADD COLUMN language TEXT",
            "ALTER TABLE deep_expansions ADD COLUMN ttft_ms INTEGER",
            "ALTER TABLE deep_expansions ADD COLUMN input_tokens INTEGER",
            "ALTER TABLE deep_expansions ADD COLUMN output_tokens INTEGER",
            "ALTER TABLE deep_expansions ADD COLUMN cache_read_tokens INTEGER",
            "ALTER TABLE deep_expansions ADD COLUMN cache_write_tokens INTEGER",
            "ALTER TABLE deep_expansions ADD COLUMN stop_reason TEXT",
            "CREATE INDEX idx_deep_expansions_parent ON deep_expansions(parent_id)",
            "CREATE INDEX idx_qa_entries_response ON qa_entries(response_id)",
        ]),
        SQLiteMigration(version: 6, statements: [
            "ALTER TABLE meetings ADD COLUMN instruction_profile TEXT",
            "ALTER TABLE meetings ADD COLUMN realtime_digest_source TEXT",
        ]),
    ]
}
