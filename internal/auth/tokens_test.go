// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

package auth

import (
	"strings"
	"testing"
)

// Realistic tokens: what `openssl rand -base64 32` produces.
const (
	tokenA = "kO0Zq2XjP1sVn8mWcR4tYuI6oPaSdF7gHjKlZxCvBnM="
	tokenB = "9aB8cD7eF6gH5iJ4kL3mN2oP1qR0sT9uV8wX7yZ6aB4="
	tokenC = "Zm9vYmFyYmF6cXV1eGNvcmdlZ3JhdWx0Z2FycGx5MDE="
)

func TestAConfiguredTokenResolvesToItsDataset(t *testing.T) {
	set := New([]string{tokenA, tokenB})

	got, ok := set.Lookup(tokenA)
	if !ok {
		t.Fatal("a configured token was refused")
	}
	if got != Dataset(tokenA) {
		t.Errorf("want dataset %q, got %q", Dataset(tokenA), got)
	}
}

// A token's position in the list must not change the answer, which is the thing a naive early-return
// implementation gets right by accident and a broken constant-time one gets wrong.
func TestEveryConfiguredTokenResolves(t *testing.T) {
	tokens := []string{tokenA, tokenB, tokenC}
	set := New(tokens)

	for i, token := range tokens {
		got, ok := set.Lookup(token)
		if !ok {
			t.Errorf("token %d was refused", i)
			continue
		}
		if got != Dataset(token) {
			t.Errorf("token %d resolved to the wrong dataset: want %q, got %q", i, Dataset(token), got)
		}
	}
}

func TestAnUnknownTokenIsRefused(t *testing.T) {
	set := New([]string{tokenA})

	for _, presented := range []string{
		tokenB,
		"",
		"Bearer " + tokenA,     // the scheme, not stripped
		tokenA + " ",           // trailing space
		tokenA[:len(tokenA)-1], // one character short
		strings.ToUpper(tokenA),
	} {
		if _, ok := set.Lookup(presented); ok {
			t.Errorf("an unknown token was accepted: %q", presented)
		}
	}
}

func TestEmptySetAcceptsNothing(t *testing.T) {
	set := New(nil)
	if _, ok := set.Lookup(tokenA); ok {
		t.Error("an empty token set accepted a token")
	}
	if set.Len() != 0 {
		t.Errorf("want length 0, got %d", set.Len())
	}
}

// Each token gets its own dataset, so two readers on one server cannot see each other. This is the
// property that makes multiple datasets safe on a shared instance.
func TestDifferentTokensGiveDifferentDatasets(t *testing.T) {
	seen := map[string]string{}
	for _, token := range []string{tokenA, tokenB, tokenC} {
		d := Dataset(token)
		if previous, clash := seen[d]; clash {
			t.Fatalf("two tokens produced the same dataset %q (%q and %q)", d, previous, token)
		}
		seen[d] = token
	}
}

func TestDatasetIsStable(t *testing.T) {
	// The same token must resolve to the same dataset across restarts and across versions of this
	// server, or an upgrade would orphan every reader's history.
	if Dataset(tokenA) != Dataset(tokenA) {
		t.Fatal("Dataset is not deterministic")
	}
	if got := len(Dataset(tokenA)); got != DatasetLength {
		t.Errorf("want a %d-character dataset, got %d", DatasetLength, got)
	}
}

// The dataset identifier goes into the database and into logs, so it must not be reversible to the
// token or contain any part of it.
func TestDatasetDoesNotRevealTheToken(t *testing.T) {
	d := Dataset(tokenA)
	if strings.Contains(d, tokenA) {
		t.Fatal("the dataset identifier contains the token")
	}
	// A hash prefix, so no substring of the token of any useful length should appear.
	for size := 6; size <= len(tokenA); size++ {
		if strings.Contains(d, tokenA[:size]) {
			t.Fatalf("the dataset identifier contains a %d-character prefix of the token", size)
		}
	}
	for _, r := range d {
		if !strings.ContainsRune("0123456789abcdef", r) {
			t.Fatalf("the dataset identifier is not hex: %q", d)
		}
	}
}

func TestDatasetsAreListedInConfigurationOrder(t *testing.T) {
	set := New([]string{tokenA, tokenB, tokenC})
	got := set.Datasets()
	want := []string{Dataset(tokenA), Dataset(tokenB), Dataset(tokenC)}
	if len(got) != len(want) {
		t.Fatalf("want %d datasets, got %d", len(want), len(got))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("dataset %d: want %q, got %q", i, want[i], got[i])
		}
	}
}
