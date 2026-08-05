// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Package auth resolves a presented bearer token to the dataset it may reach.
//
// That is the whole of authentication here. There are no accounts, no usernames, no passwords, and
// no registration — the operator lists tokens in configuration and each one namespaces an
// independent dataset. A token is 256 pre-shared random bits, so there is nothing to guess, which
// is why the server needs no key derivation, no lockout, and no rate limiting on this path.
package auth

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
)

// DatasetLength is how many hex characters of the token's hash name its dataset.
//
// Sixteen, which is 64 bits. Long enough that two tokens cannot collide by accident, short enough
// to read in a log line and compare by eye against the startup banner.
const DatasetLength = 16

// TokenSet maps tokens to datasets without storing the tokens.
type TokenSet struct {
	entries []entry
}

type entry struct {
	// The token's SHA-256, not the token. A fixed 32 bytes, which is what makes the comparison
	// constant-time without also leaking the presented token's length.
	hash    [sha256.Size]byte
	dataset string
}

// New builds a set from the configured tokens.
func New(tokens []string) *TokenSet {
	set := &TokenSet{entries: make([]entry, 0, len(tokens))}
	for _, t := range tokens {
		h := sha256.Sum256([]byte(t))
		set.entries = append(set.entries, entry{hash: h, dataset: Dataset(t)})
	}
	return set
}

// Dataset is the stable identifier a token grants access to.
//
// Derived rather than configured, so an operator adding a token does not also have to invent a name
// for its data, and cannot accidentally point two tokens at one dataset. A hash rather than the
// token itself, so the database never contains a working credential — a stolen database yields no
// access, only the knowledge that some dataset exists.
func Dataset(token string) string {
	sum := sha256.Sum256([]byte("cmdv-sync-dataset-v2\x00" + token))
	return hex.EncodeToString(sum[:])[:DatasetLength]
}

// Lookup resolves a presented token.
//
// Every configured token is compared, every time, even after a match: returning early would make
// the response time depend on the matched token's position in the list, which over enough requests
// discloses how many tokens are configured and eventually which one was used.
//
// The comparison is over SHA-256 digests rather than the raw strings, so it is a fixed-width
// constant-time compare and the presented token's length leaks nothing either.
func (s *TokenSet) Lookup(presented string) (dataset string, ok bool) {
	h := sha256.Sum256([]byte(presented))
	matched := 0
	for _, e := range s.entries {
		if subtle.ConstantTimeCompare(h[:], e.hash[:]) == 1 {
			dataset = e.dataset
			matched = 1
		}
	}
	return dataset, matched == 1
}

// Datasets lists the dataset identifiers, in configuration order.
//
// For the startup banner, so an operator can see which datasets exist without any token being
// printed.
func (s *TokenSet) Datasets() []string {
	out := make([]string, 0, len(s.entries))
	for _, e := range s.entries {
		out = append(out, e.dataset)
	}
	return out
}

// Len is how many tokens are configured.
func (s *TokenSet) Len() int { return len(s.entries) }
