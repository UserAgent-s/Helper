struct FTSIndex {
    let name: String
    let tokenize: String

    static func words(_ table: String) -> FTSIndex {
        FTSIndex(name: "\(table)_fts", tokenize: "unicode61 remove_diacritics 2")
    }

    static func trigrams(_ table: String) -> FTSIndex {
        FTSIndex(name: "\(table)_trgm", tokenize: "trigram")
    }
}

enum SessionSchema {
    static func folded(_ expression: String) -> String {
        "replace(replace(\(expression), 'ё', 'е'), 'Ё', 'Е')"
    }

    static func searchable(table: String, columns: [String], indexes: [FTSIndex]) -> [String] {
        let columnList = columns.joined(separator: ", ")
        let newValues = columns.map { folded("new.\($0)") }.joined(separator: ", ")
        let oldValues = columns.map { folded("old.\($0)") }.joined(separator: ", ")
        let sourceValues = columns.map { folded($0) }.joined(separator: ", ")
        var statements = indexes.map { index in
            "CREATE VIRTUAL TABLE \(index.name) USING fts5(\(columnList), content='\(table)', content_rowid='rowid', tokenize='\(index.tokenize)')"
        }
        let inserts = indexes.map { "INSERT INTO \($0.name)(rowid, \(columnList)) VALUES (new.rowid, \(newValues));" }
        let deletes = indexes.map { "INSERT INTO \($0.name)(\($0.name), rowid, \(columnList)) VALUES ('delete', old.rowid, \(oldValues));" }
        statements.append("CREATE TRIGGER \(table)_search_ai AFTER INSERT ON \(table) BEGIN \(inserts.joined(separator: " ")) END")
        statements.append("CREATE TRIGGER \(table)_search_ad AFTER DELETE ON \(table) BEGIN \(deletes.joined(separator: " ")) END")
        statements.append("CREATE TRIGGER \(table)_search_au AFTER UPDATE ON \(table) BEGIN \(deletes.joined(separator: " ")) \(inserts.joined(separator: " ")) END")
        statements += indexes.map { "INSERT INTO \($0.name)(rowid, \(columnList)) SELECT rowid, \(sourceValues) FROM \(table)" }
        return statements
    }

    static let statements: [String] = meetings + spans + utterances + screenContexts + questionAnswers + expansions + bookmarks + aliases

    static let meetings: [String] = [
        "ALTER TABLE meetings ADD COLUMN kind TEXT NOT NULL DEFAULT 'recording'",
        "ALTER TABLE meetings ADD COLUMN title_source TEXT",
        "ALTER TABLE meetings ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE meetings ADD COLUMN last_activity_at TEXT",
        "ALTER TABLE meetings ADD COLUMN knowledge_digest TEXT",
        "UPDATE meetings SET last_activity_at = COALESCE(ended_at, started_at), title_source = CASE WHEN title IS NULL THEN NULL ELSE 'legacy' END",
        "CREATE INDEX idx_meetings_kind_started ON meetings(kind, started_at)",
    ]

    static let spans: [String] = [
        """
        CREATE TABLE session_spans (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            mode TEXT NOT NULL,
            started_at TEXT NOT NULL,
            ended_at TEXT,
            end_reason TEXT
        )
        """,
        "CREATE INDEX idx_session_spans_session ON session_spans(session_id, started_at)",
        """
        INSERT INTO session_spans (id, session_id, mode, started_at, ended_at, end_reason)
        SELECT 'legacy_' || id, id, 'recording', started_at, ended_at, CASE WHEN ended_at IS NULL THEN NULL ELSE 'legacy' END FROM meetings
        """,
    ]

    static let utterances: [String] = [
        "DROP TRIGGER utterances_ai",
        "DROP TRIGGER utterances_ad",
        "DROP TRIGGER utterances_au",
        "DROP TABLE utterances_fts",
        "ALTER TABLE utterances ADD COLUMN speaker TEXT NOT NULL DEFAULT 'them'",
        "ALTER TABLE utterances ADD COLUMN origin TEXT NOT NULL DEFAULT 'whisper_local'",
        "ALTER TABLE utterances ADD COLUMN captured_at TEXT",
        "ALTER TABLE utterances ADD COLUMN translation_text TEXT",
        "ALTER TABLE utterances ADD COLUMN translation_lang TEXT",
        """
        UPDATE utterances SET
            speaker = CASE source WHEN 'local' THEN 'me' ELSE 'them' END,
            captured_at = (
                SELECT strftime('%Y-%m-%dT%H:%M:%SZ', meetings.started_at, '+' || (utterances.started_ms / 1000.0) || ' seconds')
                FROM meetings WHERE meetings.id = utterances.meeting_id
            )
        """,
        "CREATE INDEX idx_utterances_meeting_captured ON utterances(meeting_id, captured_at)",
    ] + searchable(table: "utterances", columns: ["text", "translation_text"], indexes: [.words("utterances"), .trigrams("utterances")])

    static let screenContexts: [String] = [
        """
        CREATE TABLE screen_contexts (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            captured_at TEXT NOT NULL,
            application TEXT,
            window_title TEXT,
            text TEXT NOT NULL,
            created_at TEXT NOT NULL
        )
        """,
        "CREATE INDEX idx_screen_contexts_session ON screen_contexts(session_id, captured_at)",
    ] + searchable(table: "screen_contexts", columns: ["application", "text"], indexes: [.words("screen_contexts"), .trigrams("screen_contexts")])

    static let questionAnswers: [String] = [
        "DROP TRIGGER qa_entries_ai",
        "DROP TRIGGER qa_entries_ad",
        "DROP TRIGGER qa_entries_au",
        "DROP TABLE qa_entries_fts",
        "ALTER TABLE qa_entries ADD COLUMN session_id TEXT REFERENCES meetings(id) ON DELETE CASCADE DEFAULT NULL",
        "ALTER TABLE qa_entries ADD COLUMN screen_context_id TEXT REFERENCES screen_contexts(id) ON DELETE SET NULL DEFAULT NULL",
        "CREATE INDEX idx_qa_entries_session ON qa_entries(session_id, asked_at)",
    ] + searchable(table: "qa_entries", columns: ["question_text", "answer_text"], indexes: [.words("qa_entries"), .trigrams("qa_entries")])

    static let expansions: [String] = [
        """
        CREATE TABLE deep_expansions (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            qa_entry_id TEXT REFERENCES qa_entries(id) ON DELETE CASCADE,
            requested_at TEXT NOT NULL,
            model_id TEXT NOT NULL,
            status TEXT NOT NULL,
            text TEXT NOT NULL,
            usage_tokens INTEGER,
            estimated_cost_usd REAL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )
        """,
        "CREATE INDEX idx_deep_expansions_session ON deep_expansions(session_id, requested_at)",
        "CREATE INDEX idx_deep_expansions_qa ON deep_expansions(qa_entry_id)",
    ] + searchable(table: "deep_expansions", columns: ["text"], indexes: [.words("deep_expansions"), .trigrams("deep_expansions")])

    static let bookmarks: [String] = [
        """
        CREATE TABLE bookmarks (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            kind TEXT NOT NULL,
            qa_entry_id TEXT REFERENCES qa_entries(id) ON DELETE CASCADE,
            marked_at TEXT NOT NULL,
            note TEXT,
            created_at TEXT NOT NULL
        )
        """,
        "CREATE INDEX idx_bookmarks_session ON bookmarks(session_id, marked_at)",
    ] + searchable(table: "bookmarks", columns: ["note"], indexes: [.words("bookmarks")])

    static let aliases: [String] = [
        """
        CREATE TABLE search_aliases (
            term TEXT NOT NULL COLLATE NOCASE,
            alias TEXT NOT NULL COLLATE NOCASE,
            PRIMARY KEY (term, alias)
        ) WITHOUT ROWID
        """,
        """
        INSERT INTO search_aliases (term, alias) VALUES
            ('kafka', 'кафка'), ('кафка', 'kafka'),
            ('postgres', 'постгрес'), ('постгрес', 'postgres'),
            ('postgresql', 'postgres'), ('kubernetes', 'кубернетес'),
            ('кубернетес', 'kubernetes'), ('k8s', 'kubernetes'),
            ('redis', 'редис'), ('редис', 'redis')
        """,
    ]
}
