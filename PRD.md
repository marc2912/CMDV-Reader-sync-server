# CMDV Sync Server v2 — PRD and Architecture

**Baseline.** The only implementation that exists today is `CMDV-Reader/Server/` inside the app repository (27 tracked files). `CMDV-Reader-sync-server` is treated here as greenfield: v2 shares no schema, no wire format and no auth model with the current server, so anything already sitting in that repository is superseded rather than extended.

---

# Part 1 — Why a separate repository

## The coupling as it stands

`Server/Package.swift:42` declares:

```swift
.package(path: "../Packages/CMDVReaderKit"),
```

The server imports the app's `CMDVSync` module so that both ends share one definition of the wire format. That was a defensible instinct — a protocol described in a document and implemented twice drifts — but it has four consequences that outweigh it.

**1. You cannot build the server without the iOS app.** A path dependency means the server's checkout is the app's checkout. Someone who wants to run a sync server has to clone an iOS application they will never build.

**2. It cannot be made to build for any server platform.** `CMDVSync` depends on `CMDVCore`, `CMDVModels`, `CMDVNetworking` and `CMDVStatistics`. `CMDVNetworking` reaches URLSession and the Security framework, and the package declares `.iOS(.v18)`. So the graph reaches iOS and, awkwardly, macOS for headless testing — and nothing else. Linux and Windows, the platforms people actually host on, are unreachable through it by construction.

**3. The product shape is wrong.** A sync server should be a thing users download and install — `docker compose up -d`, or a binary — with its own README, its own releases, and its own version number. Right now it is a subdirectory of an unrelated application.

**4. Release cadences are incompatible.** The app ships through App Store review on a scale of weeks; a server fix should be deployable in minutes. Coupling them means the server's dependency graph moves whenever the app's does.

## Why not just publish `CMDVSync` as a shared package?

It would work, and it is the obvious alternative. It is rejected because:

- It reintroduces build coupling and adds a release step *between* the two repositories. Changing the wire format becomes: tag the shared package, bump the server, bump the app.
- It keeps the app's data model reachable from the server, so nothing structurally prevents the server growing knowledge of it again.
- After the v2 changes below, the shared surface is an envelope with **no app-domain concepts in it at all**. There is nothing left worth sharing code for.

The replacement is a written specification plus golden JSON fixtures committed to both repositories, with each side asserting byte-identical round trips. That tests the wire, which is what actually has to agree, rather than one language's rendering of it. And it is what makes a third-party client or an alternative server implementation possible.

---

# Part 2 — Why v2 is shaped this way

## What a sync server's job actually is

**Collect data. Hand it back. Done.**

Not credential management. Not user management. Not deciding which of two versions of a record is the right one. Every one of those is something the current server does, and every one of them is why it has to know what the app's data looks like.

Read the current server against that sentence and the excess is obvious: an `accounts` table, password hashing at 600,000 iterations, a work queue to stop that hashing blocking everything else, two throttle implementations to stop it being abused, a registration policy, a username allowlist — and `supersedes`, which is the server forming an opinion about a reader's highlight.

One clarification, because it looks like an exception and is not: the server *does* stamp each entry with a sequence number. That is not the server working out an ordering. It is a receipt number — `AUTOINCREMENT`, the order things arrived in, assigned without looking at them. The value of it is that arrival order is the one ordering the server can produce for free and that every device will agree on, which is precisely why nothing else needs to reason about order at all.

## The two problems it solves

**Whole-object last-write-wins destroys data.** `SyncDocument.supersedes()` compares whole documents, and `AnnotationMerge` does the same by explicit choice (`SyncMerge.swift:141`, "not field-by-field"). Trim a highlight's range on one device while editing its comment on another, and one change is lost — including reverting a field nobody touched. A synced record is not a single value; it is a set of independently-editable parts.

**Data semantics live in two places, so backward compatibility has two homes.** Whenever the app's model evolves, something has to be reasoned about on both sides.

Both have the same root cause: **the server arbitrates writes.** That is the only reason it holds `supersedes`, `isImmutable`, and a `UNIQUE(kind, document_id)` constraint that makes one row a contended resource. Remove arbitration and every piece of app knowledge in the server goes with it.

## How it works

```
Operator              Device A                  Server                Device B
────────              ────────                  ──────                ────────
sets CMDV_SYNC_TOKENS
                      URL + token
                        + passphrase
                      KDF → data key
                                                                scans QR
                                                           (URL+token+passphrase)
                                                                KDF → same key

                      ── IMPORT ──────────────►
                      POST /sync  entries:[]
                                                entries where
                                                sequence > cursor
                                                and device_id ≠ A
                      ◄────────────────────────
                      decrypt, upcast

                      ── RESOLVE ──
                      any incoming field whose
                      local value has unpushed
                      changes → ask the reader

                      ── EXPORT ──────────────►
                      POST /sync  entries:[…]
                                                assigns sequence
                                                INSERT (opaque blob)
```

Six decisions carry the whole design.

### 1. The server's sequence number is the only total order

Assigned on arrival, monotonic, global. **No wall clocks anywhere in the merge path.**

Every device replays the same sequence in the same order, so they land in identical states. Convergence stops being a CRDT argument and becomes an observation. And a whole category of machinery disappears: no hybrid logical clocks, no `deviceID` tiebreaks, no monotonic timestamp clamps, no `clockSkewWarning`, no `tolerableClockSkew`, no `Outcome.clockSkew`.

The semantics change from "last device to *edit* wins" to "last device to *sync* wins". That is easier to explain to a reader, and with field-level deltas the blast radius of getting it wrong is one field rather than a whole record.

No sync lock is needed. A single SQLite writer plus `AUTOINCREMENT` already assigns sequences atomically.

### 2. Storage is append-only

Nothing is ever overwritten, so nothing is contended, so there is nothing to arbitrate.

Volume is a non-issue. Sync is user-triggered, and `progressDocuments(since:)` reads one row per changed book rather than one per page turn, so realistic traffic is roughly 10–15 entries per device per day — about 10,000 a year for two devices.

**Compaction is a permanent non-goal, not a deferred one.** The only cost of an append-only log is a slower first import on a new device, and that is a one-time operation during setup where ten seconds is unremarkable. Weigh that against what compaction would require: a device deciding which of another device's entries are safe to discard, a truncation endpoint, a window where two representations coexist, and a failure mode where the thing discarded turns out to have been the only copy. It trades a one-off ten seconds for a permanent class of data-loss bug. Not worth it at any volume this server will see.

Nothing is ever deleted. Wiping means deleting the database file.

### 3. Payloads are encrypted

This converts "the server does not parse payloads" from a convention into a guarantee. It also removes plaintext metadata that exists today: `BookSyncKey` currently produces `documentID` values like `t:hobbit|jrr tolkien` in an indexed SQLite column.

### 4. Changes are field-level deltas

One entry per changed object per sync, carrying only the fields that changed. This is the fix for the trim-range-plus-edit-comment case.

### 5. Auth is a pre-shared bearer token; one token, one dataset

No accounts, no usernames, no passwords, no registration endpoint. The operator lists tokens in configuration and each one namespaces an independent dataset.

This is the single largest simplification in the design. A 256-bit pre-shared token has nothing to guess, so everything built to defend a guessable secret becomes dead weight: PBKDF2 on the server, the ~1.35s registration cost, both throttle implementations, the password work queue, the registration policy, the username allowlist, the registration secret, and the `accounts` table.

### 6. A sync is import, then resolve, then export

This is what keeps "last sync wins" from being a licence to lose data.

The order is load-bearing and must not be collapsed back into a single combined exchange:

1. **Import.** Pull everything above the cursor. Decrypt, upcast, and work out what it would change.
2. **Resolve.** For any incoming field whose local counterpart has **unpushed local changes**, do not apply it. Raise it to the reader as a conflict and let them choose. Everything else applies silently.
3. **Export.** Push local changes, including whatever the reader just decided.

Why this order rather than one combined call: if a device exported first it would claim the higher sequence, win by fiat, and the collision would never be visible to anyone. Importing first means a device sees what the others asserted *before* asserting its own version, which is the only point at which a conflict can still be detected.

**The detection mechanism is free.** The field clock that field-level deltas already require — "which fields changed since I last pushed" — is exactly the predicate for "does this field have unpushed local changes". One mechanism, two jobs.

**Conflicts should be genuinely rare**, which is what makes prompting acceptable rather than noisy. Two devices editing *different* fields of one record produce no conflict at all, because field-level deltas merge. A conflict requires the same field, on two devices, both edited since their last sync.

The existing progress prompt becomes one case of a general mechanism rather than a special one. `ProgressMerge`'s backwards-jump rule survives as an *additional* heuristic, because a large backwards jump is worth questioning even when there is no unpushed local change to collide with.

**Consequence for the protocol:** a sync may be two requests rather than one. The endpoint is unchanged — an import is simply a `POST /sync` with an empty `entries` array — so this is entirely an app-side flow decision with no server involvement. That is a useful demonstration of the design's premise: a change to how syncing behaves required no change to the server at all.

## What we gain

| Gain | Mechanism |
|---|---|
| Adding a synced data type never touches the server | The server holds no kind, identity, or timestamp |
| Backward compatibility has exactly one home | Only the app can read payloads |
| Concurrent edits to different fields both survive | Field-level deltas |
| Clock skew ceases to exist as a concept | Server sequence is the order |
| A colliding edit is surfaced to the reader rather than silently discarded | Import → resolve → export, detected by the field clock |
| The server cannot read a reader's notes | Encryption |
| No unauthenticated expensive endpoint | Pre-shared tokens; no key derivation server-side |
| **A hosted offering becomes viable** | Because the server cannot read what it stores, running instances *for other people* stops requiring them to trust the operator — including trusting them with reading history and private notes. That makes a low-cost subscription a real option alongside self-hosting, sharing one codebase and one protocol, with no privacy claim that has to be taken on faith. Self-hosters lose nothing by it. |
| **End-to-end encryption stays a roadmap, not a rewrite** | The server never learns whether a blob is encrypted, under what scheme, or with which key model. So encryption can be introduced, strengthened, re-keyed, or have its key derivation replaced entirely as app-side work with **zero server change** — including changes that would be breaking in any design where the server understood payloads. |
| Installable on macOS, Windows and Linux, by anyone, without the app | Standalone repo, no path dependency, container-first |
| Anyone can write their own server or client | Open source, and a spec plus fixtures rather than shared code |
| Server is ~300 lines: two tables, three endpoints, one `INSERT` | Everything above, compounded |

## What we give up, and why that is acceptable

| Given up | Why acceptable |
|---|---|
| **Server-side debuggability.** `SELECT kind, count(*)` becomes impossible. | This was my main objection and it loses to the counter-argument: keeping semantics server-side means maintaining backward compatibility in two repositories. Diagnostics move on-device, where the data can actually be read. |
| **Per-device server-side revocation.** | Replaced by two paths that cover both real cases — self-removal for a device you hold, token rotation for one you have lost. See §Revocation. |
| **Bounded storage.** Append-only grows with edits rather than objects. | ~10k entries/year for two devices. Disk is irrelevant; replay is sub-second. Revisit if background sync is ever added. |
| **"Last edit wins" semantics.** | Becomes "last sync wins" — but this is *mitigated rather than merely accepted*. Field-level deltas mean edits to different fields of one record never collide at all. A genuine collision, meaning the same field edited on two devices since either last synced, is detected during import and put to the reader as a conflict instead of being resolved silently. So "last sync wins" applies only where the reader has been asked and answered, or where there was nothing to lose. |
| **Recoverability without the passphrase.** | Inherent to encryption. Mitigated by deriving the key from a passphrase rather than generating it randomly, so recovery needs three obtainable values rather than a copy of a random key. |
| **A single source of truth in code.** | Replaced by a spec plus fixtures that test the wire rather than one language's rendering of it. Strictly better for interoperability, and unavoidable anyway once the two sides are in different languages. |
| **A smaller app.** | The app absorbs encryption, key derivation, QR pairing and ordered replay. This is the real cost: complexity moves to the side that is slower to fix. Mitigated by the fact that ordered replay is *simpler* than the merge logic it replaces. |

---

# Part 3 — Product requirements

## Goals

1. A reader's positions, highlights, notes, sessions and settings stay in step across their devices.
2. An operator installs and forgets it. One command, one file to back up.
3. The server never needs updating because the app changed.
4. The server cannot read what it holds.
5. It does one job — collect data and hand it back — and holds no credential store, no user model, and no opinion about the data.
6. It is open source and specified well enough that someone can replace it with their own implementation.

## Non-goals

- Multi-user accounts with sign-up, password reset or recovery.
- TLS termination. A reverse proxy does that.
- Book file storage. Books are never uploaded.
- Any server-side view, search, or report over reader data.
- Horizontal scaling. One process, one SQLite file.
- **Compaction, permanently.** Not deferred — rejected. See Part 2.
- Any server-side opinion about which version of a record is correct.

## Stack and distribution — decided

**The server is written in Go.** Not Swift, despite the app being Swift, and the reasoning is worth recording because it looks like an inconsistency until you see why.

Sharing a language with the app was the *only* argument for Swift here, and v2 removes it: there is no shared code left, because the envelope contains no app-domain concept and the contract is a spec plus fixtures. With that gone, Go wins on every axis this server is judged by.

| | Go | Swift |
|---|---|---|
| Native binaries for macOS, Windows, Linux | One cross-compile step, from any machine | Windows is the weakest platform; SwiftNIO's Windows support is far less exercised than its Linux support |
| Container image | `FROM scratch`, ~10 MB | Swift runtime image, hundreds of MB |
| Build time | Seconds | ~52 s cold |
| Dependencies | One pure-Go SQLite driver; `net/http` covers four routes | Hummingbird, SwiftNIO and its transitive graph |
| CGO | Off. `modernc.org/sqlite` is pure Go, which is what makes cross-compilation trivial and `scratch` possible | n/a |

**Distribution is both**, and they are cheap together rather than two efforts:

- **Docker** is the documented path and what the README leads with. Docker Desktop covers macOS and Windows; the image is Linux.
- **Tagged GitHub releases** carry prebuilt binaries for macOS, Windows and Linux on amd64 and arm64. With `CGO_ENABLED=0` this is one matrix step in CI producing six artefacts, so it costs a few lines rather than a second build system.

Nothing in Part 4's architecture depended on the language, which is why this decision could be deferred until after the design settled.

## Users

| User | Needs |
|---|---|
| **Operator** (usually the reader) | Install via Docker, set one or more tokens, back up one file, read logs that contain no reader data. |
| **Reader** | Enter three things once on the first device, scan a code on the rest, and never think about it again. |
| **Third-party implementer** | The repository is open source, and the spec plus fixtures are sufficient to build an independent server or client without reading the Go. Anyone who dislikes this implementation should be able to replace it and keep their app working. |
| **Hosted subscriber** *(possible future)* | Uses an instance someone else runs, without having to trust that operator with their reading history or private notes. Made possible by the server being unable to read what it stores. |

## Functional requirements

### Server must

| # | Requirement |
|---|---|
| S1 | Accept a batch of opaque blobs from an authenticated device and store each as one immutable entry. |
| S2 | Assign every entry a globally monotonic sequence number on arrival. This is the ordering authority. |
| S3 | Return entries with `sequence > cursor`, oldest first, excluding entries written by the calling device. |
| S4 | Page results with a server-enforced maximum, reporting whether more remain. |
| S5 | Support push and pull in one request, and pull alone (an empty `entries` array). Each request is atomic in itself. The app uses the pull-only form for the import step of import → resolve → export, so the server needs no knowledge of that flow. |
| S6 | Authenticate by bearer token, compared in constant time against a configured set. The matched token selects the dataset. |
| S7 | Record a device's identity and name on first contact, so other devices can list it. |
| S8 | Let a device be delisted by identifier. **Not** "its own only": every device in a dataset holds the same token, so the server cannot authenticate a device *as itself* — anything holding the token could claim to be any device. This is list management, not access control, and must not be presented as the latter. Cutting off a device you no longer hold is token rotation. |
| S9 | Answer an unauthenticated health check. |
| S10 | Refuse a protocol version it does not speak, with an explanation rather than a guess. |
| S11 | Isolate datasets absolutely. A token must never reach another token's entries. |

### Server must not

| # | Requirement |
|---|---|
| S12 | Never decrypt, parse or validate a payload. |
| S13 | Never compare, merge, supersede or discard one entry in favour of another. |
| S14 | Never hold an app-domain concept: no kind, no document identity, no record timestamp, no notion of immutability. |
| S15 | Never delete an entry. Removing a device removes its access and its listing, not its history — a reinstalled device has a new identity and a zero cursor, and needs every other device's entries. |
| S16 | Never write reader data, tokens, or payloads to a log. |

### App must

Listed here because the correctness of the whole system depends on them, even though the work is in the app repository. Implementation detail is in Part 5.

| # | Requirement |
|---|---|
| A1 | Sync in the order **import → resolve → export**, never a single combined exchange. Exporting before importing would let a device win a collision by fiat and hide it. |
| A2 | Emit one entry per changed object per sync, containing only the fields that changed. |
| A3 | Track, per field, whether it has local changes not yet pushed. This drives both what is exported and what counts as a conflict. |
| A4 | During import, do not apply an incoming field whose local counterpart has unpushed changes. Raise it to the reader and apply their choice. |
| A5 | Apply every non-conflicting entry in server-sequence order, with nothing skipped or reordered. |
| A6 | Persist unresolved conflicts so a question survives the app being killed, and ensure a reader's answer cannot be overwritten by a later entry in the same replay. |
| A7 | Encrypt every payload before it leaves the device, with authenticated encryption. |
| A8 | Carry a schema version in every payload, and upcast older versions to the current shape so exactly one ingestion path exists. |
| A9 | Retain and retry an entry from a *future* schema version rather than dropping it. Today a changed shape of a known kind is silently dropped — `decodePayload` turns a decode failure into `unreadableDocument` and counts it as skipped. |
| A10 | Retain an entry referring to a book not present on this device until the book arrives. |
| A11 | Store the cursor only after a page is durably applied, so a crash re-delivers rather than skips. |
| A12 | Never compare wall-clock times to decide precedence. |
| A13 | Let the reader remove this device from sync, and state plainly at setup that losing the passphrase loses the data. |

## Non-functional requirements

| # | Requirement |
|---|---|
| N1 | `docker compose up -d` is the whole installation. No configuration file; environment variables only. |
| N2 | Runs on **macOS, Windows and Linux**, amd64 and arm64. Builds without the app repository present. See the platform note below. |
| N3 | All state in one SQLite file. Documented backup via SQLite's online backup API, safe against a running server. |
| N4 | Graceful shutdown on SIGTERM so `docker stop` does not sever an in-flight sync. |
| N5 | Runs unprivileged in the container. |
| N6 | No unauthenticated endpoint is expensive enough to be a denial-of-service lever. |
| N7 | Bad configuration is refused at startup with the offending variable named, not defaulted around. |
| N8 | Schema migrates itself on startup. No migration command, no downtime beyond a restart. |

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `CMDV_SYNC_TOKENS` | *(required)* | Comma-separated bearer tokens. Each is an independent dataset. |
| `CMDV_SYNC_TOKENS_FILE` | — | Path to a file of tokens, one per line. Alternative to the above for secrets hygiene; Docker secrets and compose both prefer files. |
| `CMDV_SYNC_HOST` | `0.0.0.0` | Bind interface. All interfaces, because inside a container `localhost` is unreachable from outside. |
| `CMDV_SYNC_PORT` | `8080` | The only port used. |
| `CMDV_SYNC_DATABASE` | `/data/cmdv-sync.sqlite` | Back this file up. |
| `CMDV_SYNC_LOG_LEVEL` | `info` | One line per request at `info` and below — method and path only, never headers or bodies. |

Startup with no tokens configured must fail, not start with an open server. Tokens shorter than a documented minimum must be refused, since a weak token is the one credential protecting a dataset.

## Success criteria

**The acceptance test for the entire design:** add a new synced data type to the app and ship it. The server is not modified and not redeployed, and an older device that does not understand the new type loses nothing. If any step requires a server change, the design has failed.

Secondary: a reader who loses every device recovers their history from server URL, token and passphrase alone.

---

# Part 4 — Server architecture

## Data model

The entire schema:

```sql
CREATE TABLE entries (
    sequence  INTEGER PRIMARY KEY AUTOINCREMENT,
    dataset   TEXT NOT NULL,
    device_id TEXT NOT NULL,
    blob      BLOB NOT NULL
);
CREATE INDEX entries_by_dataset_sequence ON entries(dataset, sequence);

CREATE TABLE devices (
    dataset      TEXT NOT NULL,
    device_id    TEXT NOT NULL,
    name         TEXT NOT NULL,
    first_seen_at REAL NOT NULL,
    last_seen_at  REAL NOT NULL,
    PRIMARY KEY (dataset, device_id)
);
```

Notes on what is deliberately absent. `entries` has no kind, no document identity, no timestamp, and no unique constraint beyond its primary key — so `store` is a single `INSERT` with no upsert, no `MAX(sequence)+1` arithmetic, and none of the sequence-integrity subtleties that arithmetic invites. `devices` exists only so a reader can see a device list; it is **not** an auth table, because auth is a comparison against configuration.

`dataset` is a stable identifier derived from the token — `SHA256(token)`, truncated — never the token itself, so the database never contains a working credential.

## Wire protocol

Three endpoints. `Authorization: Bearer <token>` on the first two.

```
POST /api/v1/sync
  → { "deviceID": "<uuid>", "deviceName": "Marc's phone",
      "cursor": 412, "limit": 500,
      "entries": [ { "blob": "<base64>" } ] }
  ← { "entries": [ { "sequence": 413, "deviceID": "<uuid>", "blob": "<base64>" } ],
      "cursor": 418, "hasMore": false }

GET /api/v1/devices
  ← [ { "deviceID": "<uuid>", "deviceName": "Marc's phone", "lastSeenAt": "…" } ]

DELETE /api/v1/devices/{deviceID}   ← 204, or 404 when not listed. Removes a listing; entries are kept.

GET /api/v1/health             ← { "status": "ok", "version": 2 }
```

An **import** is this same endpoint with `"entries": []`. The server does not know or care that the app calls it twice per sync — it sees two independent, individually atomic exchanges. This is deliberate: the conflict-resolution flow is entirely an app concern, and the server must stay ignorant of it so that changing the flow later needs no server release.

`X-CMDV-Sync-Version: 2` on every request; a mismatch is refused with `409`. A missing header is treated as the current version so a plain `curl` against health is not refused.

There is no `serverTime` — nothing depends on a clock any more. There is no registration endpoint; a device is known by presenting a valid token, and its name is recorded on first contact.

`deviceID` and `deviceName` are plaintext, deliberately. The server needs `deviceID` to exclude a device's own writes, and the reader needs names in the device list. Since operator and reader are the same person, a device name in the clear is not a leak worth encrypting around.

## Authentication

```
presented token → constant-time compare against configured set
                → matched? dataset = SHA256(token)[0..16]
                → unmatched? 401, with no indication of which part failed
```

No hashing cost, no storage, no rate limiting needed: a 256-bit pre-shared token has no dictionary to attack. Constant-time comparison is used so response timing does not leak a prefix.

## Ordering and encryption

The blob is sealed on-device and never opened by the server:

```
plaintext = { "v": 2, "type": "annotation", "id": "<uuid>",
              "changed": { "note": "…", "colorID": 3 } }

blob = ChaChaPoly.seal(plaintext, key: dataKey, authenticating: deviceID)
```

`deviceID` as associated data means a blob cannot be replayed under a different device's identity. The sequence cannot be authenticated, since the server assigns it after sealing — which is acceptable because the sequence is the server's to assign and a reordering attack by the server operator is not in the threat model.

Ordering is entirely the server's `sequence`. The app applies entries in that order and nothing else.

## Module layout

```
cmd/cmdv-sync-server/
  main.go                  Read environment, open store, listen, shut down cleanly
internal/config/
  config.go                Six variables, validated, with refusals that name the variable
internal/auth/
  tokens.go                Constant-time lookup, token → dataset
internal/store/
  store.go                 The two tables; append and page. Bound parameters only
  schema.go                Migration on open
internal/api/
  server.go                Four routes
  types.go                 Wire shapes. The only place JSON is defined
  errors.go                Errors → described JSON responses
spec/
  PROTOCOL.md              Normative. The single source of truth
  fixtures/*.json          One per message shape, round-tripped byte-identically
```

`internal/` rather than a public package tree, deliberately: nothing here is a library for anyone else to import, and marking it so means the compiler enforces that rather than a convention. The one thing that *is* public API is `spec/`.

**Dependencies: one.** `modernc.org/sqlite`, a pure-Go SQLite. `net/http` covers four routes with Go 1.22+ pattern routing, `crypto/sha256` and `crypto/subtle` cover dataset derivation and constant-time comparison, and `log/slog` covers structured logging — all standard library. No HTTP framework, no ORM, no logging library, no password hashing, and nothing that depends on the app.

## Operational architecture

- **Container:** multi-stage build, Go builder to `FROM scratch`, static binary, non-root UID, `/data` volume, exec-form entrypoint so SIGTERM reaches PID 1. `scratch` has no shell and no `curl`, so the health check is the binary itself invoked with a flag rather than an external tool — which keeps the image at roughly the size of the binary.
- **Compose:** publishes on `127.0.0.1` by default, since TLS is not terminated here and the default configuration must not be the exposed one.
- **Proxy:** Caddy, nginx and Traefik examples. nginx needs `client_max_body_size` raised — its 1 MB default would break a first sync.
- **Backup:** `sqlite3 … ".backup"` from inside the container. WAL mode means a plain file copy can capture a torn state.
- **Ports:** 8080 only. No admin interface, no metrics port.

## Revocation

**A device you hold — self-removal.** The app clears the derived key, token and cursor from the Keychain and calls `DELETE /api/v1/devices/{its own deviceID}` so it stops appearing in other devices' lists. Its entries remain, because other devices may not have replayed them.

Note the endpoint is deliberately *not* named `/me`. With a shared token the server cannot verify that a caller is the device it claims to be, so a "remove only yourself" restriction would be a control that looks like security and is not. Naming it honestly keeps the guarantee and the mechanism the same size.

**A device you have lost — token rotation.** Rotate the token in configuration and restart. All devices are cut off; the ones you still hold are re-paired by QR.

**A consequence that must be documented, not discovered:** if the KDF salt derives from the token (see §Key derivation), rotating the token changes the derived key, so existing entries become unreadable. Rotation is therefore "start a fresh dataset", not "keep syncing with a new credential". For a lost-device event that is arguably correct, but the README must say it plainly. *Open alternative:* give the salt its own recoverable value so rotation preserves data, at the cost of making the recovery bundle four values rather than three.

---

# Part 5 — Changes required in the app

All paths relative to `CMDV-Reader/Packages/CMDVReaderKit/Sources/`.

## New

| File | Purpose |
|---|---|
| `CMDVSync/SyncCrypto.swift` | `ChaChaPoly` seal and open, `deviceID` as associated data. |
| `CMDVSync/PassphraseKey.swift` | KDF, salt derivation, key handling. |
| `CMDVSync/Passphrase.swift` | Generation from a bundled wordlist, entropy floor, denylist check. |
| `CMDVSync/Resources/eff-long-wordlist.txt` | 7,776 words. Public domain / CC-BY. |
| `CMDVSync/SyncDelta.swift` | The v2 entry: version, type, id, changed fields. Plus the upcast chain. |
| `CMDVLibraryFeature/PairingCodeView.swift` | Displays the QR on a configured device. |
| `CMDVLibraryFeature/PairingScannerView.swift` | Scans it on a new one. |

## Replaced or substantially rewritten

| File | Change |
|---|---|
| `CMDVSync/SyncProtocol.swift` | Shrinks to the v2 envelope — no `kind`, no `documentID`, no `updatedAt`, no `supersedes`, no `isImmutable`. Then becomes generated-from-nothing: `spec/PROTOCOL.md` is authoritative. |
| `CMDVSync/SyncPayloads.swift` | The five whole-object payloads become field-level deltas carrying a schema version. |
| `CMDVSync/SyncMerge.swift` | **Reshaped rather than deleted.** Ordered replay in a total order needs no `AnnotationMerge`, `SettingMerge`, `SessionMerge`, or tiebreaks. What replaces them is one general rule: *incoming field versus unpushed local field → conflict*. `MergeDecision.askTheReader` survives and becomes the common case rather than a progress-only special case. `ProgressMerge`'s `backwardsToleranceFraction` heuristic stays as an extra trigger, for a large backwards jump with no unpushed change to collide with. |
| `CMDVSync/SyncClient.swift` | Three endpoints; `registerDevice` and `revokeDevice` removed, self-removal added. |
| `CMDVSync/SyncError.swift` | Fewer reasons: `invalidCredentials`, `versionUnsupported`, `malformedRequest`, `serverError`. `tokenRevoked` and `quotaExceeded` have no producer any more. Also update `Resources/Localizable.xcstrings`. |
| `CMDVLibrary/SyncService.swift` | **Restructured into import → resolve → export** rather than one combined exchange. Push emits deltas rather than snapshots. Remove `Outcome.clockSkew` and `tolerableClockSkew`. A sync that raises conflicts stops before exporting and resumes once the reader has answered. |
| `CMDVLibrary/SyncService+Applying.swift` | Decrypt, upcast, apply strictly in sequence order. Field-level application replaces per-kind merge dispatch. **New: field-level conflict detection** — an incoming field whose local counterpart has unpushed changes is withheld and raised rather than applied. Generalises `rememberUnresolved`/`resolve`, which are progress-only today. Keep hold-until-the-book-arrives and cursor-after-durable-apply. |
| `CMDVLibrary/SyncService+Configuration.swift` | Configuration becomes URL, token, derived key, cursor, device id. Username and password are gone. |
| `CMDVNetworking/SyncCredentialStore.swift` | Store the bearer token *and* the derived key, both `ThisDeviceOnly`. |
| `CMDVLibraryFeature/SyncSignInSheet.swift` | Fields become URL, token, passphrase — with a generated passphrase pre-filled and the entropy floor enforced. |
| `CMDVLibraryFeature/SyncScreen.swift` | Add QR display and scan. Device rows lose the swipe-to-revoke; add "Remove this device from sync". **Generalise `conflictSection`** — today it renders `ProgressConflictRow` with "Stay here"/"Go back" and handles progress only; it now has to present a field-level conflict on any record type. |
| `CMDVLibraryFeature/SyncViewModel.swift` | Follows the above. Drop `clockSkewWarning`. Sync becomes a two-stage operation that can pause awaiting the reader, so `isSyncing` and `lastOutcomeSummary` need a third state: imported, waiting on you, not yet exported. |

## Model and persistence

| File | Change |
|---|---|
| `CMDVModels/Annotation.swift` | One `Data` column holding a field clock, so the app knows which fields changed since it last pushed. |
| `CMDVModels/` (catalog model) | Same, if catalog sync keeps field-level granularity. |
| `CMDVPersistence/SwiftDataLibraryStore+Annotations.swift` | Stamp the field clock on local edit. Split the local-write path from the sync-apply path, which currently share `saveAnnotation`. |
| `CMDVPersistence/SwiftDataLibraryStore+Sync.swift` | Apply field-level changes rather than whole records. |

## Kept unchanged

`BookSyncKey` still derives cross-device book identity — it simply moves *inside* the encrypted payload instead of being a plaintext server column. `SyncedPreferences`' three-name allowlist stays. `HeldDocumentStore` stays. The progress-conflict prompt stays, including its persistence across an app kill.

## Tests

- `CMDVSyncTests/ConvergenceTests.swift` — currently only generates forward-only progress and records an issue if `askTheReader` fires, so it excludes the failing case. Extend to generate backwards jumps and out-of-order arrival, and assert order-independence over shuffled replay orders.
- New: the motivating case — trim a range on device A, edit the note on device B, assert both survive in either arrival order **and that no conflict is raised**, since the fields differ.
- New: the conflict case — edit the *same* field on two devices, both unpushed, and assert the import withholds it, raises it to the reader, and applies only what they chose. Then assert the export carries the resolved value and not the discarded one.
- New: exporting before importing is not possible — a test that asserts a sync which raises a conflict does not push anything until the conflict is answered.
- New: round-trip encryption, including that a blob sealed under device A's id fails to open when presented as device B's.
- New: passphrase floor — a generated passphrase carries ≥70 bits, a 19-character custom one is refused, a denylisted one is refused however long.
- New: recovery — pair, sync, wipe the device, reconstruct from URL + token + passphrase alone, confirm history decrypts.

## Deleted from the app repository, last

`Server/` — 27 files — once the app is talking to the standalone server and it has been verified end to end. No data migration: v1 has never shipped, and a first sync from a zero cursor reconstructs everything.

---

# Part 6 — Key derivation and passphrase strength

The passphrase is the root of all data at rest, so a weak one silently undoes the encryption. It is also typed **once** — every later device receives it by QR — so there is no memorability constraint to trade against strength.

**Default: generated, not chosen.** Six words from the EFF long wordlist (7,776 words) gives log₂(7776⁶) ≈ **77 bits**. Pre-filled, copyable, with an instruction to record it somewhere durable.

**Custom permitted, but with a floor:** minimum 20 characters, and refused outright if it appears in a bundled common-passphrase list. Refused, not warned about.

Stated honestly: a zxcvbn-style estimator with dictionary, sequence and repetition penalties is the rigorous version of this check and runs to a few hundred lines. The length-plus-denylist floor is a cheap approximation, defensible *only* because generated is the default and recommended path.

**The KDF already exists and should move rather than be written.** `Server/Sources/CMDVSyncServer/PasswordHashing.swift` is hand-written PBKDF2-HMAC-SHA256 verified against RFC 8018 and RFC 6070's published vectors, with `PasswordHashingTests.swift` alongside. It stops being a server concern and becomes the client-side KDF, tests included — avoiding an Argon2 or scrypt dependency in a project whose only third-party dependency is Readium. 600,000 iterations costs ~1.35 s, paid once per device at setup, which is the right place for it.

**The salt must be recoverable.** Derive it from the bearer token — `salt = HKDF(token, info: "cmdv-sync-salt-v2")` — rather than generating it randomly and shipping it in the QR. The token lives in the server's configuration, so the reader always has it; a random salt would make a lost QR unrecoverable even with the passphrase remembered. It is also per-dataset, which defeats precomputation across installs.

Recovery therefore needs exactly three obtainable things: **server URL, bearer token, passphrase.**

---

# Part 7 — Handoff notes for the app team

Two project-configuration changes, neither of them code, both **blocking for App Store submission**, both consequences of adding payload encryption.

### 1. The export-compliance declaration becomes wrong

`App/Info.plist` sets `ITSAppUsesNonExemptEncryption` to `false`. The justification at `project.yml:151-159` reads:

> "The app's only cryptography is HTTPS through URLSession and SHA-256 hashing for book identity and sync tokens — both squarely within the exemptions in Category 5 Part 2 for authentication and integrity."

Sound today, and untrue the moment payloads are sealed with `ChaChaPoly` under a KDF-derived key. Encrypting a user's own data at rest is not covered by the authentication-and-integrity exemption.

**Needed:** re-evaluate the declaration; update `App/Info.plist` and the rationale in `project.yml`; determine whether the use self-classifies as exempt or requires a CCATS filing and annual self-report. The same claim is repeated at `docs/IMPLEMENTATION_PLAN.md:1032-1033`.

### 2. Camera permission does not exist

QR scanning needs `NSCameraUsageDescription`, absent from both `App/Info.plist` and `project.yml`. As configured the app cannot open the camera at all — the only usage description present is `NSLocalNetworkUsageDescription`, and `AVFoundation` is linked only for text-to-speech.

**Needed:** add the usage description, with copy stating it is used solely to scan a pairing code.

### 3. Adjacent, not blocking

`AnnotationService.purgeOldTombstones()` has a 180-day `tombstoneLifetime` and **is never called in production** — the only references are its definition and two tests. Annotation tombstones are immortal on-device today. The on-device purge was clearly intended to run.

---

# Part 8 — Build order

| Phase | Work | Independently shippable? |
|---|---|---|
| **1** | The server, greenfield in Go: two tables, four routes, token auth, Docker, cross-compiled release binaries, README, CI, `spec/`. `CMDV-Reader/Server/` keeps running untouched. | Yes — testable by `curl` alone |
| **2** | App crypto and key derivation: `SyncCrypto`, `PassphraseKey`, `Passphrase`, KDF moved across. | Yes — pure, unit-testable |
| **3** | App deltas and ordered replay: field clocks, delta emission, `SyncMerge` reshape, extended `ConvergenceTests`. | Yes — the convergence tests are the gate |
| **3b** | The import → resolve → export flow and field-level conflict UI. Depends on the field clocks from 3. | Yes |
| **4** | Pairing: QR display and scan, self-removal, sign-in sheet rework. Needs the two handoff items. | Yes |
| **5** | Cut over: point the app at the new server, verify on real devices, `git rm -r Server/`. | Terminal |

## Verification

- **The acceptance test:** add a synced data type, ship it, confirm the server was neither modified nor redeployed and that an older device loses nothing.
- Order-independence over shuffled replay orders, property-based, in `ConvergenceTests`.
- The motivating case: concurrent edits to different fields of one annotation both survive.
- Dataset isolation: token A never sees token B's entries; assert at the store and over HTTP.
- Blob fidelity: bytes returned exactly as sent.
- Recovery end to end, per §Part 5 tests — this is what proves the salt is derived rather than random.
- Against the real binary: `go build ./cmd/cmdv-sync-server`, run on a scratch database, drive sync with `curl`, confirm two devices' entries for one object both come back and that one token cannot see another's.
- `docker compose up -d`, plus a CI job that builds the image, exercises it, and times the graceful stop.
- Confirm no `.package(path:)` to `CMDVReaderKit` anywhere, and no `Server/` directory in the app repo.
