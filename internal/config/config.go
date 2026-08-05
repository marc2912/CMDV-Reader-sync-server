// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Package config reads and validates everything the server is told.
//
// Environment variables and no configuration file, deliberately, for something people run in a
// container: every setting is visible in the command or compose file that started it, and there is
// nothing to mount, template, or forget to update.
//
// Its own package because this is where a self-hosted service actually goes wrong. Nobody mistypes
// a route; everybody eventually mistypes an environment variable, and the failure people remember
// is the one where the service started anyway and ignored them.
package config

import (
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// Config is the resolved configuration.
type Config struct {
	// Tokens are the bearer tokens that grant access. Each one is an independent dataset.
	Tokens []string

	Host     string
	Port     int
	Database string
	LogLevel slog.Level
}

// Defaults. All interfaces rather than localhost, because inside a container binding to localhost
// makes the server unreachable from outside it — the single most common way a containerised service
// appears broken. The database defaults under /data because that is where the image's volume is.
const (
	DefaultHost     = "0.0.0.0"
	DefaultPort     = 8080
	DefaultDatabase = "/data/cmdv-sync.sqlite"

	// MinimumTokenLength is the shortest token accepted.
	//
	// A token is the only credential protecting a dataset, and unlike a password it is never typed
	// from memory — it is generated once and moved by QR code. So there is no usability argument
	// for allowing a short one, and a short one is catastrophic rather than merely weak: the server
	// does no key derivation and applies no rate limiting, precisely because a real token has
	// nothing to guess. 32 characters is comfortably above what an attacker could search and
	// comfortably below what `openssl rand -base64 32` produces.
	MinimumTokenLength = 32
)

// Variables is every environment variable this server reads.
//
// Listed so that a name which is *nearly* right can be reported. A mistyped environment variable
// that silently does nothing is the most annoying kind of misconfiguration, because the service
// starts, looks healthy, and ignores you.
var Variables = []string{
	"CMDV_SYNC_TOKENS",
	"CMDV_SYNC_TOKENS_FILE",
	"CMDV_SYNC_HOST",
	"CMDV_SYNC_PORT",
	"CMDV_SYNC_DATABASE",
	"CMDV_SYNC_LOG_LEVEL",
}

// Error describes a configuration problem in terms an operator can act on.
//
// Every case names the variable and what it was set to. A service that exits saying "invalid
// configuration" has told the person running it nothing.
type Error struct {
	Variable string
	Detail   string
}

func (e *Error) Error() string {
	if e.Variable == "" {
		return e.Detail
	}
	return e.Variable + " " + e.Detail
}

// Lookup is the shape of os.LookupEnv, taken as a parameter so this is testable.
type Lookup func(string) (string, bool)

// Load reads and validates the environment.
//
// Anything it cannot make sense of is refused rather than defaulted around: a server that silently
// ignored CMDV_SYNC_PORT=99999 and listened on 8080 would be a worse outcome than one that would
// not start.
func Load(look Lookup) (*Config, error) {
	c := &Config{
		Host:     DefaultHost,
		Port:     DefaultPort,
		Database: DefaultDatabase,
		LogLevel: slog.LevelInfo,
	}

	tokens, err := loadTokens(look)
	if err != nil {
		return nil, err
	}
	c.Tokens = tokens

	if v, err := text("CMDV_SYNC_HOST", look); err != nil {
		return nil, err
	} else if v != "" {
		c.Host = v
	}

	if v, ok, err := number("CMDV_SYNC_PORT", look); err != nil {
		return nil, err
	} else if ok {
		if v < 1 || v > 65535 {
			return nil, &Error{"CMDV_SYNC_PORT", fmt.Sprintf("was set to %d, which is outside the permitted range 1-65535.", v)}
		}
		c.Port = v
	}

	if v, err := text("CMDV_SYNC_DATABASE", look); err != nil {
		return nil, err
	} else if v != "" {
		c.Database = v
	}

	if v, err := text("CMDV_SYNC_LOG_LEVEL", look); err != nil {
		return nil, err
	} else if v != "" {
		level, ok := parseLevel(v)
		if !ok {
			return nil, &Error{"CMDV_SYNC_LOG_LEVEL", fmt.Sprintf("was set to %q. It must be one of: debug, info, warn, error.", v)}
		}
		c.LogLevel = level
	}

	return c, nil
}

// loadTokens reads the tokens, from a file if one is named and from the variable otherwise.
//
// A file is offered because it is what Docker secrets and compose both prefer, and because a token
// in a compose file ends up in shell history and `docker inspect` output. Both forms are accepted;
// naming both is a mistake rather than a merge, so it is refused.
func loadTokens(look Lookup) ([]string, error) {
	inline, inlineSet := look("CMDV_SYNC_TOKENS")
	path, pathSet := look("CMDV_SYNC_TOKENS_FILE")
	inline, inlineSet = strings.TrimSpace(inline), inlineSet && strings.TrimSpace(inline) != ""
	path, pathSet = strings.TrimSpace(path), pathSet && strings.TrimSpace(path) != ""

	switch {
	case inlineSet && pathSet:
		return nil, &Error{"", "CMDV_SYNC_TOKENS and CMDV_SYNC_TOKENS_FILE are both set. Use one or the other, so there is no question which is in force."}

	case pathSet:
		body, err := os.ReadFile(path)
		if err != nil {
			return nil, &Error{"CMDV_SYNC_TOKENS_FILE", fmt.Sprintf("names %q, which could not be read: %v. If this is a Docker secret, check that it is mounted.", path, err)}
		}
		return validateTokens(strings.FieldsFunc(string(body), func(r rune) bool {
			return r == '\n' || r == '\r'
		}), "CMDV_SYNC_TOKENS_FILE")

	case inlineSet:
		return validateTokens(strings.Split(inline, ","), "CMDV_SYNC_TOKENS")

	default:
		return nil, &Error{"", "No tokens are configured. Set CMDV_SYNC_TOKENS or CMDV_SYNC_TOKENS_FILE.\n" +
			"A token is what grants access to a dataset, and there is no other authentication, so\n" +
			"starting without one would mean starting an open server.\n\n" +
			"Generate one with:  openssl rand -base64 32"}
	}
}

func validateTokens(raw []string, variable string) ([]string, error) {
	seen := make(map[string]bool, len(raw))
	var tokens []string
	for _, t := range raw {
		t = strings.TrimSpace(t)
		if t == "" {
			continue
		}
		if len(t) < MinimumTokenLength {
			// The token itself is never echoed, in an error or anywhere else.
			return nil, &Error{variable, fmt.Sprintf("contains a token of %d characters. The minimum is %d, because a token is the only credential protecting a dataset and the server does no key derivation.\n\nGenerate one with:  openssl rand -base64 32", len(t), MinimumTokenLength)}
		}
		if seen[t] {
			return nil, &Error{variable, "lists the same token twice. Two identical tokens would be one dataset wearing two names, which is never what was meant."}
		}
		seen[t] = true
		tokens = append(tokens, t)
	}
	if len(tokens) == 0 {
		return nil, &Error{variable, "is set but contains no tokens."}
	}
	return tokens, nil
}

// text returns a variable's trimmed value, or "" when it is not set.
//
// A variable that is set but *empty* is refused rather than treated as unset. PORT="" in a compose
// file is a mistake every time, and defaulting it hides that.
func text(name string, look Lookup) (string, error) {
	raw, ok := look(name)
	if !ok {
		return "", nil
	}
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return "", &Error{name, "is set but empty. Unset it to take the default rather than setting it to nothing."}
	}
	return trimmed, nil
}

func number(name string, look Lookup) (int, bool, error) {
	raw, err := text(name, look)
	if err != nil || raw == "" {
		return 0, false, err
	}
	v, convErr := strconv.Atoi(raw)
	if convErr != nil {
		return 0, false, &Error{name, fmt.Sprintf("must be a whole number, but was set to %q.", raw)}
	}
	return v, true, nil
}

func parseLevel(s string) (slog.Level, bool) {
	switch strings.ToLower(s) {
	case "debug":
		return slog.LevelDebug, true
	case "info":
		return slog.LevelInfo, true
	case "warn", "warning":
		return slog.LevelWarn, true
	case "error":
		return slog.LevelError, true
	}
	return 0, false
}

// Unrecognised returns names in the environment that look like they were meant for this server but
// are not read.
//
// Returned rather than treated as fatal. A stray CMDV_SYNC_ variable is nearly always a typo worth
// mentioning, but refusing to start over one would make this server the awkward member of a compose
// file that also sets variables for something else.
func Unrecognised(environ []string) []string {
	known := make(map[string]bool, len(Variables))
	for _, v := range Variables {
		known[v] = true
	}
	var found []string
	for _, entry := range environ {
		name, _, ok := strings.Cut(entry, "=")
		if ok && strings.HasPrefix(name, "CMDV_SYNC_") && !known[name] {
			found = append(found, name)
		}
	}
	sort.Strings(found)
	return found
}

// PrepareDatabaseDirectory makes sure the database's directory exists and can be written to, before
// SQLite tries.
//
// SQLite's own failure for a missing directory is "unable to open database file", which names
// neither the directory nor the reason, and is what somebody with a volume mounted one path along
// would spend an evening on. Checked here so the message can say which directory and why.
//
// The directory is created when missing, since a compose file naming /data/cmdv-sync.sqlite on a
// fresh volume is the ordinary case rather than an error.
func (c *Config) PrepareDatabaseDirectory() error {
	dir := filepath.Dir(c.Database)
	if dir == "" || dir == "." {
		// The working directory, which exists by definition.
		return nil
	}

	if _, err := os.Stat(dir); errors.Is(err, os.ErrNotExist) {
		if mkErr := os.MkdirAll(dir, 0o755); mkErr != nil {
			return &Error{"CMDV_SYNC_DATABASE", fmt.Sprintf("names a directory %q that does not exist and could not be created: %v.\nIf this is a Docker volume, check that it is mounted and writable by this container's user.", dir, mkErr)}
		}
		return nil
	} else if err != nil {
		return &Error{"CMDV_SYNC_DATABASE", fmt.Sprintf("names a directory %q that could not be inspected: %v.", dir, err)}
	}

	// Write-ahead logging puts -wal and -shm files *beside* the database, so a writable database
	// file in a read-only directory is not enough and fails later rather than now. Probed by
	// creating a file, because permission bits do not account for ownership, ACLs, or a read-only
	// mount.
	probe := filepath.Join(dir, ".cmdv-write-probe")
	f, err := os.OpenFile(probe, os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return &Error{"CMDV_SYNC_DATABASE", fmt.Sprintf("names a directory %q that is not writable by this process: %v.\nIf this is a Docker volume, check that it is mounted and writable by this container's user.", dir, err)}
	}
	f.Close()
	os.Remove(probe)
	return nil
}

// Summary is the configuration as an operator sees it at startup.
//
// No token appears in it. Each is shown only as its dataset identifier, which is a hash and is
// exactly what an operator needs to correlate a token with what it can reach — including in a log,
// where the token itself must never be.
func (c *Config) Summary(datasets []string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "listening on:  %s:%d\n", c.Host, c.Port)
	fmt.Fprintf(&b, "database:      %s\n", c.Database)
	fmt.Fprintf(&b, "log level:     %s\n", strings.ToLower(c.LogLevel.String()))
	fmt.Fprintf(&b, "datasets:      %d", len(c.Tokens))
	for _, d := range datasets {
		fmt.Fprintf(&b, "\n               %s", d)
	}
	return b.String()
}
