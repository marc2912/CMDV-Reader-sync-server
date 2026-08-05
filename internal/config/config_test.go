// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

package config

import (
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const (
	tokenA = "kO0Zq2XjP1sVn8mWcR4tYuI6oPaSdF7gHjKlZxCvBnM="
	tokenB = "9aB8cD7eF6gH5iJ4kL3mN2oP1qR0sT9uV8wX7yZ6aB4="
)

// env builds a Lookup from a map, so these tests never touch the real environment.
func env(pairs map[string]string) Lookup {
	return func(name string) (string, bool) {
		v, ok := pairs[name]
		return v, ok
	}
}

func TestDefaultsWorkUnchangedInAContainer(t *testing.T) {
	c, err := Load(env(map[string]string{"CMDV_SYNC_TOKENS": tokenA}))
	if err != nil {
		t.Fatalf("loading: %v", err)
	}
	// All interfaces, because inside a container localhost is unreachable from outside it.
	if c.Host != "0.0.0.0" {
		t.Errorf("want host 0.0.0.0, got %q", c.Host)
	}
	if c.Port != 8080 {
		t.Errorf("want port 8080, got %d", c.Port)
	}
	if c.Database != "/data/cmdv-sync.sqlite" {
		t.Errorf("want the volume path, got %q", c.Database)
	}
	if c.LogLevel != slog.LevelInfo {
		t.Errorf("want info, got %v", c.LogLevel)
	}
}

func TestEverySettingCanBeGiven(t *testing.T) {
	c, err := Load(env(map[string]string{
		"CMDV_SYNC_TOKENS":    tokenA + "," + tokenB,
		"CMDV_SYNC_HOST":      "127.0.0.1",
		"CMDV_SYNC_PORT":      "9000",
		"CMDV_SYNC_DATABASE":  "/srv/sync.sqlite",
		"CMDV_SYNC_LOG_LEVEL": "debug",
	}))
	if err != nil {
		t.Fatalf("loading: %v", err)
	}
	if len(c.Tokens) != 2 {
		t.Errorf("want 2 tokens, got %d", len(c.Tokens))
	}
	if c.Host != "127.0.0.1" || c.Port != 9000 || c.Database != "/srv/sync.sqlite" {
		t.Errorf("settings were not applied: %+v", c)
	}
	if c.LogLevel != slog.LevelDebug {
		t.Errorf("want debug, got %v", c.LogLevel)
	}
}

// The most important refusal in the file. Starting without a token would be starting an open server,
// and there is no other authentication to fall back on.
func TestStartingWithoutATokenIsRefused(t *testing.T) {
	_, err := Load(env(map[string]string{}))
	if err == nil {
		t.Fatal("a server with no tokens was allowed to start")
	}
	// The message has to tell an operator what to do about it, not just what is wrong.
	if !strings.Contains(err.Error(), "openssl rand") {
		t.Errorf("the message does not say how to generate a token: %v", err)
	}
}

func TestAShortTokenIsRefusedAndNotEchoed(t *testing.T) {
	short := "tooshort"
	_, err := Load(env(map[string]string{"CMDV_SYNC_TOKENS": short}))
	if err == nil {
		t.Fatal("a short token was accepted")
	}
	if strings.Contains(err.Error(), short) {
		t.Errorf("the error echoed the token back: %v", err)
	}
	if !strings.Contains(err.Error(), "32") {
		t.Errorf("the message does not state the minimum: %v", err)
	}
}

func TestADuplicateTokenIsRefused(t *testing.T) {
	_, err := Load(env(map[string]string{"CMDV_SYNC_TOKENS": tokenA + "," + tokenA}))
	if err == nil {
		t.Fatal("the same token twice was accepted")
	}
}

func TestTokensSurviveTheSpacesPeoplePutAfterCommas(t *testing.T) {
	c, err := Load(env(map[string]string{"CMDV_SYNC_TOKENS": " " + tokenA + " , " + tokenB + " ,, "}))
	if err != nil {
		t.Fatalf("loading: %v", err)
	}
	if len(c.Tokens) != 2 || c.Tokens[0] != tokenA || c.Tokens[1] != tokenB {
		t.Errorf("tokens were not trimmed: %+v", c.Tokens)
	}
}

func TestTokensCanComeFromAFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "tokens")
	if err := os.WriteFile(path, []byte(tokenA+"\n"+tokenB+"\n\n"), 0o600); err != nil {
		t.Fatalf("writing token file: %v", err)
	}

	c, err := Load(env(map[string]string{"CMDV_SYNC_TOKENS_FILE": path}))
	if err != nil {
		t.Fatalf("loading: %v", err)
	}
	if len(c.Tokens) != 2 || c.Tokens[0] != tokenA || c.Tokens[1] != tokenB {
		t.Errorf("want both tokens from the file, got %+v", c.Tokens)
	}
}

func TestAMissingTokenFileIsReportedByPath(t *testing.T) {
	_, err := Load(env(map[string]string{"CMDV_SYNC_TOKENS_FILE": "/no/such/file"}))
	if err == nil {
		t.Fatal("a missing token file was accepted")
	}
	if !strings.Contains(err.Error(), "/no/such/file") {
		t.Errorf("the message does not name the path: %v", err)
	}
}

// Setting both is ambiguous, and silently preferring one would be a trap.
func TestBothTokenSourcesAtOnceIsRefused(t *testing.T) {
	path := filepath.Join(t.TempDir(), "tokens")
	_ = os.WriteFile(path, []byte(tokenB), 0o600)

	_, err := Load(env(map[string]string{
		"CMDV_SYNC_TOKENS":      tokenA,
		"CMDV_SYNC_TOKENS_FILE": path,
	}))
	if err == nil {
		t.Fatal("both token sources at once was accepted")
	}
}

// Refused rather than defaulted around: a server that ignored CMDV_SYNC_PORT=99999 and listened on
// 8080 would be worse than one that would not start.
func TestAPortOutsideTheRangeIsRefused(t *testing.T) {
	for _, port := range []string{"0", "65536", "-1", "eighty"} {
		_, err := Load(env(map[string]string{"CMDV_SYNC_TOKENS": tokenA, "CMDV_SYNC_PORT": port}))
		if err == nil {
			t.Errorf("port %q was accepted", port)
			continue
		}
		if !strings.Contains(err.Error(), "CMDV_SYNC_PORT") {
			t.Errorf("port %q: the message does not name the variable: %v", port, err)
		}
	}
}

// PORT="" in a compose file is a mistake every time, and defaulting it hides that.
func TestASetButEmptyVariableIsRefused(t *testing.T) {
	for _, name := range []string{"CMDV_SYNC_HOST", "CMDV_SYNC_PORT", "CMDV_SYNC_DATABASE", "CMDV_SYNC_LOG_LEVEL"} {
		_, err := Load(env(map[string]string{"CMDV_SYNC_TOKENS": tokenA, name: "   "}))
		if err == nil {
			t.Errorf("%s set to whitespace was accepted", name)
			continue
		}
		if !strings.Contains(err.Error(), name) {
			t.Errorf("%s: the message does not name the variable: %v", name, err)
		}
	}
}

func TestAnUnknownLogLevelIsRefusedWithTheRealOnes(t *testing.T) {
	_, err := Load(env(map[string]string{"CMDV_SYNC_TOKENS": tokenA, "CMDV_SYNC_LOG_LEVEL": "verbose"}))
	if err == nil {
		t.Fatal("an unknown log level was accepted")
	}
	for _, level := range []string{"debug", "info", "warn", "error"} {
		if !strings.Contains(err.Error(), level) {
			t.Errorf("the message does not list %q: %v", level, err)
		}
	}
}

func TestLogLevelIsCaseInsensitive(t *testing.T) {
	c, err := Load(env(map[string]string{"CMDV_SYNC_TOKENS": tokenA, "CMDV_SYNC_LOG_LEVEL": "WARN"}))
	if err != nil {
		t.Fatalf("loading: %v", err)
	}
	if c.LogLevel != slog.LevelWarn {
		t.Errorf("want warn, got %v", c.LogLevel)
	}
}

// A mistyped variable that silently does nothing is the most annoying kind of misconfiguration,
// because the service starts, looks healthy, and ignores you.
func TestVariablesThatLookLikeOursButAreNotAreReported(t *testing.T) {
	got := Unrecognised([]string{
		"CMDV_SYNC_TOKENS=" + tokenA,
		"CMDV_SYNC_DATABSE=/data/x.sqlite", // transposed
		"CMDV_SYNC_TLS_CERT=/etc/cert.pem", // never a thing here
		"PATH=/usr/bin",
		"HOME=/root",
	})
	want := []string{"CMDV_SYNC_DATABSE", "CMDV_SYNC_TLS_CERT"}
	if len(got) != len(want) {
		t.Fatalf("want %v, got %v", want, got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("want %v, got %v", want, got)
		}
	}
}

// Guards against a variable being added to the documented list for the warning's benefit and never
// wired up, which would make the warning lie in the other direction.
func TestEveryDocumentedVariableIsRecognised(t *testing.T) {
	for _, name := range Variables {
		if found := Unrecognised([]string{name + "=x"}); len(found) != 0 {
			t.Errorf("%s is documented but reported as unrecognised", name)
		}
	}
}

// MARK: The database directory

// SQLite's own failure for a missing directory is "unable to open database file", which names neither
// the directory nor the reason.
func TestAMissingDatabaseDirectoryIsCreated(t *testing.T) {
	root := t.TempDir()
	c := &Config{Database: filepath.Join(root, "nested", "deeper", "sync.sqlite")}

	if err := c.PrepareDatabaseDirectory(); err != nil {
		t.Fatalf("preparing: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "nested", "deeper")); err != nil {
		t.Errorf("the directory was not created: %v", err)
	}
}

func TestABareFilenameNeedsNoDirectory(t *testing.T) {
	c := &Config{Database: "cmdv-sync.sqlite"}
	if err := c.PrepareDatabaseDirectory(); err != nil {
		t.Errorf("a bare filename was rejected: %v", err)
	}
}

// A writable database file in a read-only directory is not enough: WAL writes -wal and -shm beside
// it, so this has to be caught now rather than on the first write.
func TestAnUnwritableDirectoryIsReportedWithThePathAndReason(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("running as root, which can write to a read-only directory")
	}
	root := t.TempDir()
	readOnly := filepath.Join(root, "locked")
	if err := os.Mkdir(readOnly, 0o500); err != nil {
		t.Fatalf("creating a read-only directory: %v", err)
	}
	t.Cleanup(func() { os.Chmod(readOnly, 0o700) })

	c := &Config{Database: filepath.Join(readOnly, "sync.sqlite")}
	err := c.PrepareDatabaseDirectory()
	if err == nil {
		t.Fatal("an unwritable directory was accepted")
	}
	if !strings.Contains(err.Error(), readOnly) {
		t.Errorf("the message does not name the directory: %v", err)
	}
	// Says where to look, because a Docker volume mounted one path along is the usual cause.
	if !strings.Contains(err.Error(), "Docker volume") {
		t.Errorf("the message does not mention the usual cause: %v", err)
	}
}

// MARK: What the operator is shown

// A token in a log or a terminal is a working credential. The summary must show enough to be useful
// and nothing that grants access.
func TestTheSummaryShowsDatasetsAndNeverAToken(t *testing.T) {
	c, err := Load(env(map[string]string{
		"CMDV_SYNC_TOKENS": tokenA + "," + tokenB,
		"CMDV_SYNC_PORT":   "9000",
	}))
	if err != nil {
		t.Fatalf("loading: %v", err)
	}

	summary := c.Summary([]string{"1111111111111111", "2222222222222222"})
	for _, want := range []string{"0.0.0.0:9000", "/data/cmdv-sync.sqlite", "1111111111111111", "2222222222222222", "2"} {
		if !strings.Contains(summary, want) {
			t.Errorf("the summary is missing %q:\n%s", want, summary)
		}
	}
	for _, token := range []string{tokenA, tokenB} {
		if strings.Contains(summary, token) {
			t.Fatalf("the summary contains a token:\n%s", summary)
		}
	}
}
