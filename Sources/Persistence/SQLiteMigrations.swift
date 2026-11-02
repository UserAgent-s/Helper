struct SQLiteMigration {
    let version: Int
    let statements: [String]
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
            """
            CREATE TABLE IF NOT EXISTS knowledge_notes (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                content TEXT NOT NULL,
                is_enabled INTEGER NOT NULL,
                source_file_name TEXT,
                updated_at TEXT NOT NULL
            )
            """,
        ]),
        SQLiteMigration(version: 3, statements: [
            """
            CREATE TABLE IF NOT EXISTS expert_domains (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                role TEXT NOT NULL,
                guidance TEXT NOT NULL,
                is_active INTEGER NOT NULL,
                sort_order INTEGER NOT NULL,
                updated_at TEXT NOT NULL
            )
            """,
            "ALTER TABLE knowledge_notes ADD COLUMN domain_id TEXT",
            "ALTER TABLE knowledge_notes ADD COLUMN origin TEXT NOT NULL DEFAULT 'manual'",
        ]),
        SQLiteMigration(version: 4, statements: [
            "ALTER TABLE qa_entries ADD COLUMN expansion_text TEXT",
        ]),
    ]
}
