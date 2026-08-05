// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

package store

import (
	"database/sql"
	"fmt"
)

// migrate brings the schema up to date, on every start.
//
// Idempotent statements rather than a version table and a migration list. The schema is two tables
// and one index; a migration framework here would be more code than the thing it migrates. When a
// real change becomes necessary, add it as a further statement that is safe to run twice.
func migrate(db *sql.DB) error {
	statements := []string{
		// The whole of storage.
		//
		// `sequence` is INTEGER PRIMARY KEY AUTOINCREMENT, which makes it the rowid and gives the
		// arrival order for free. AUTOINCREMENT rather than plain INTEGER PRIMARY KEY so a number is
		// never reused after a delete — a reused sequence would land below a cursor already handed
		// out, and the entry would be silently never delivered.
		//
		// Note what is not here: no kind, no document identity, no timestamp, and no unique
		// constraint. Storing an entry is one INSERT with nothing to compare it against.
		`CREATE TABLE IF NOT EXISTS entries (
		     sequence  INTEGER PRIMARY KEY AUTOINCREMENT,
		     dataset   TEXT NOT NULL,
		     device_id TEXT NOT NULL,
		     blob      BLOB NOT NULL
		 )`,

		// Every read is "everything for this dataset above this sequence, in order", which this
		// index answers directly.
		`CREATE INDEX IF NOT EXISTS entries_by_dataset_sequence
		     ON entries(dataset, sequence)`,

		// Devices exist only so a reader can see and manage the list. This is *not* an
		// authentication table: a token is checked against configuration, never against a row here,
		// so a writable database grants nobody access.
		`CREATE TABLE IF NOT EXISTS devices (
		     dataset       TEXT NOT NULL,
		     device_id     TEXT NOT NULL,
		     name          TEXT NOT NULL,
		     first_seen_at REAL NOT NULL,
		     last_seen_at  REAL NOT NULL,
		     PRIMARY KEY (dataset, device_id)
		 )`,
	}

	for _, s := range statements {
		if _, err := db.Exec(s); err != nil {
			return fmt.Errorf("migrating schema: %w", err)
		}
	}
	return nil
}
