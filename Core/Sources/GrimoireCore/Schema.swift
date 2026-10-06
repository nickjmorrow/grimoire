import GRDB

enum Schema {
    static func migrator() -> DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: """
            CREATE TABLE pages (
              id TEXT PRIMARY KEY,
              title TEXT NOT NULL,
              title_lower TEXT NOT NULL UNIQUE,
              kind TEXT NOT NULL,
              journal_date TEXT UNIQUE,
              favorite INTEGER NOT NULL DEFAULT 0,
              favorite_order INTEGER,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL
            );
            CREATE INDEX pages_updated ON pages(updated_at);
            CREATE TABLE blocks (
              id TEXT PRIMARY KEY,
              page_id TEXT NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
              parent_id TEXT REFERENCES blocks(id) ON DELETE CASCADE,
              order_key TEXT NOT NULL,
              text TEXT NOT NULL,
              collapsed INTEGER NOT NULL DEFAULT 0,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL,
              author TEXT NOT NULL
            );
            CREATE INDEX blocks_tree ON blocks(page_id, parent_id, order_key);
            CREATE TABLE tags (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              name_lower TEXT NOT NULL UNIQUE,
              page_id TEXT NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
              created_at INTEGER NOT NULL
            );
            CREATE TABLE block_tags (
              block_id TEXT NOT NULL REFERENCES blocks(id) ON DELETE CASCADE,
              tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
              PRIMARY KEY (block_id, tag_id)
            );
            CREATE TABLE properties (
              id TEXT PRIMARY KEY,
              key TEXT NOT NULL UNIQUE,
              type TEXT NOT NULL,
              cardinality TEXT NOT NULL
            );
            CREATE TABLE block_props (
              owner_id TEXT NOT NULL,
              owner_kind TEXT NOT NULL,
              property_id TEXT NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
              value TEXT NOT NULL,
              position INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX block_props_owner ON block_props(owner_id);
            CREATE INDEX block_props_prop ON block_props(property_id, value);
            CREATE TABLE assets (
              hash TEXT PRIMARY KEY,
              filename TEXT NOT NULL,
              mime TEXT NOT NULL,
              size INTEGER NOT NULL,
              created_at INTEGER NOT NULL
            );
            CREATE TABLE ops (
              local_id INTEGER PRIMARY KEY AUTOINCREMENT,
              seq INTEGER UNIQUE,
              device TEXT NOT NULL,
              author TEXT NOT NULL,
              kind TEXT NOT NULL,
              payload TEXT NOT NULL,
              inverse TEXT,
              created_at INTEGER NOT NULL
            );
            CREATE TABLE links (
              from_block TEXT NOT NULL,
              to_page TEXT,
              to_block TEXT,
              kind TEXT NOT NULL
            );
            CREATE INDEX links_to_page ON links(to_page);
            CREATE INDEX links_to_block ON links(to_block);
            CREATE INDEX links_from ON links(from_block);
            CREATE VIRTUAL TABLE search USING fts5(
              owner_id UNINDEXED, owner_kind UNINDEXED, text,
              tokenize = 'unicode61 remove_diacritics 2'
            );
            """)
        }
        m.registerMigration("v2") { db in
            try db.execute(sql: """
            ALTER TABLE ops ADD COLUMN undone_by INTEGER;
            ALTER TABLE ops ADD COLUMN undoes INTEGER;
            """)
        }
        // FTS5 can't index UNINDEXED columns, so deleting a search row by owner scanned the whole table.
        // This maps each owner to its FTS rowid so deletes are a rowid lookup.
        m.registerMigration("v3") { db in
            try db.execute(sql: """
            CREATE TABLE search_ref (
              owner_id TEXT NOT NULL,
              owner_kind TEXT NOT NULL,
              fts_rowid INTEGER NOT NULL,
              PRIMARY KEY (owner_id, owner_kind)
            );
            INSERT OR REPLACE INTO search_ref (owner_id, owner_kind, fts_rowid) SELECT owner_id, owner_kind, rowid FROM search;
            """)
        }
        m.registerMigration("v4") { db in
            try db.execute(sql: """
            CREATE TABLE cards (
              block_id TEXT PRIMARY KEY REFERENCES blocks(id) ON DELETE CASCADE,
              due INTEGER NOT NULL,
              stability REAL NOT NULL,
              difficulty REAL NOT NULL,
              reps INTEGER NOT NULL,
              lapses INTEGER NOT NULL,
              phase INTEGER NOT NULL,
              last_review INTEGER
            );
            CREATE INDEX cards_due ON cards(due);
            CREATE TABLE reviews (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              block_id TEXT NOT NULL,
              rating INTEGER NOT NULL,
              reviewed_at INTEGER NOT NULL,
              stability REAL NOT NULL,
              difficulty REAL NOT NULL,
              due INTEGER NOT NULL
            );
            CREATE INDEX reviews_block ON reviews(block_id, reviewed_at);
            """)
        }
        m.registerMigration("v5") { db in
            try db.execute(sql: """
            ALTER TABLE ops ADD COLUMN origin_local_id INTEGER;
            ALTER TABLE ops ADD COLUMN rejected INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE ops ADD COLUMN local INTEGER NOT NULL DEFAULT 1;
            CREATE TABLE sync_state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE sync_issues (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              at INTEGER NOT NULL,
              source TEXT NOT NULL,
              payload TEXT NOT NULL,
              reason TEXT NOT NULL
            );
            """)
        }
        // blocks_tree starts with page_id, so child lookups, subtree walks and ON DELETE CASCADE on parent_id scanned all blocks;
        // the same goes for the tag and page cascades and for reading the op log by time.
        m.registerMigration("v6") { db in
            try db.execute(sql: """
            CREATE INDEX blocks_parent ON blocks(parent_id);
            CREATE INDEX block_tags_tag ON block_tags(tag_id);
            CREATE INDEX tags_page ON tags(page_id);
            CREATE INDEX ops_created ON ops(created_at);
            """)
        }
        return m
    }
}
