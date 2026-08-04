# cmdv-sync-server

The reference sync server for [CMDV Reader](https://github.com/marc2912/CMDV-Reader). It keeps
reading positions, highlights, notes, bookmarks, reading sessions, and settings in step between a
reader's devices, and it is meant to be something you install once and forget.

It is deliberately small. It stores envelopes and hands them back in order, and it does not know
what a highlight *is*. Adding a new kind of synced data to the app needs no change here at all —
which is the property that makes a server you host yourself a reasonable thing to own, because the
app can grow without you having to keep up with it.

```bash
docker compose up -d
```

That is the whole installation. Everything below is detail.

---

## Contents

- [What it stores, and what it never stores](#what-it-stores-and-what-it-never-stores)
- [Quick start](#quick-start)
- [Configuration](#configuration)
- [Ports and networking](#ports-and-networking)
- [TLS and reverse proxies](#tls-and-reverse-proxies)
- [Pointing the app at it](#pointing-the-app-at-it)
- [Accounts](#accounts)
- [Your data: backup and restore](#your-data-backup-and-restore)
- [Upgrading](#upgrading)
- [Security](#security)
- [Troubleshooting](#troubleshooting)
- [The protocol](#the-protocol)
- [Developing on it](#developing-on-it)
- [Licence](#licence)

---

## What it stores, and what it never stores

**Stored, per account:** reading positions, highlights, notes, bookmarks, reading sessions, a few
settings, and — only if the reader turns it on — the addresses of their catalogs.

**Never stored:** book files, and the passwords for those catalogs. A catalog's address travels so
that another device can offer to sign in; the password stays in the first device's keychain and the
reader types it again on the second. That is the correct amount of friction for moving a credential
between machines: none of it happens automatically.

Passwords for *this* server are stored as PBKDF2-HMAC-SHA256 hashes at 600,000 iterations, the
count travelling with each hash so raising it later never invalidates an existing password. Device
tokens are stored only as SHA-256 hashes, so a stolen database yields no working tokens.

## Quick start

### With Docker Compose

Requires Docker with the Compose plugin. Nothing else — no Swift toolchain, no database to set up.

```bash
git clone https://github.com/marc2912/CMDV-Reader-sync-server.git
cd CMDV-Reader-sync-server
docker compose up -d
```

The first build compiles Swift from source and takes several minutes. Afterwards it is cached.

Check it is up:

```bash
curl http://127.0.0.1:8080/api/v1/health
```

```json
{"status":"ok","version":1}
```

Watch what it is doing:

```bash
docker compose logs -f
```

Stop it, keeping the data:

```bash
docker compose down
```

`docker compose down -v` also deletes the volume, and with it every reader's sync history. There is
no confirmation prompt.

By default the port is published on `127.0.0.1` only, so a fresh install is reachable from that
machine and nowhere else. That is deliberate — this server does not terminate TLS, and the default
configuration should not be the one exposed to the internet. See
[Ports and networking](#ports-and-networking).

### With Docker, without Compose

```bash
docker build -t cmdv-sync-server .

docker run -d \
  --name cmdv-sync-server \
  --restart unless-stopped \
  -p 127.0.0.1:8080:8080 \
  -v cmdv-sync-data:/data \
  cmdv-sync-server
```

Building for a different architecture than the machine you are on — an x86 server from an Apple
Silicon Mac, say — needs buildx:

```bash
docker buildx build --platform linux/amd64 -t cmdv-sync-server:amd64 --load .
```

### From source, without Docker

Needs Swift 6.1 or newer (Hummingbird's manifest declares `swift-tools-version 6.1`, so older
toolchains cannot read the dependency graph) and SQLite's development headers.

```bash
# Debian/Ubuntu
sudo apt-get install libsqlite3-dev

swift build -c release
./.build/release/cmdv-sync-server
```

On macOS the SQLite headers come with the Xcode command-line tools; there is nothing to install.

Without `CMDV_SYNC_DATABASE` set, the database is created as `cmdv-sync.sqlite` in the working
directory.

## Configuration

Environment variables and no configuration file, deliberately: every setting is visible in the
command or the compose file that started it, and there is nothing to mount, template, or forget to
update.

| Variable | Default | What it does |
|---|---|---|
| `CMDV_SYNC_HOST` | `0.0.0.0` | Interface to bind. All interfaces by default, because inside a container binding to `localhost` makes the server unreachable from outside it. |
| `CMDV_SYNC_PORT` | `8080` | Port to listen on. |
| `CMDV_SYNC_DATABASE` | `/data/cmdv-sync.sqlite` in the image, `cmdv-sync.sqlite` from source | Where the SQLite database lives. **Back this file up.** |
| `CMDV_SYNC_LOG_LEVEL` | `info` | `trace`, `debug`, `info`, `notice`, `warning`, `error`, or `critical`. One line per request at `info` and below; method and path only, never headers or bodies. |
| `CMDV_SYNC_REGISTRATION_ATTEMPTS` | `10` | Registration attempts permitted per window, across the whole server. `0` disables the limit. |
| `CMDV_SYNC_REGISTRATION_WINDOW` | `300` | The window, in seconds. |
| `CMDV_SYNC_USERNAMES` | *(unset — any username)* | A comma-separated list of the usernames allowed to hold an account. Set this before exposing the server to the internet. |
| `CMDV_SYNC_PASSWORD_ITERATIONS` | `600000` | PBKDF2 iterations for new passwords. Lower it only on hardware where registering a device takes uncomfortably long — see [below](#why-registration-is-rate-limited). Minimum `10000`. Existing passwords are unaffected. |

Bad configuration is refused at startup rather than defaulted around, with exit code `78`
(`EX_CONFIG`) and a message naming the variable. A variable beginning `CMDV_SYNC_` that this server
does not read produces a warning, so a typo says so instead of silently doing nothing:

```
cmdv-sync-server: warning: CMDV_SYNC_DATABSE is set but is not read by this server.
```

At startup it prints exactly what it resolved:

```
cmdv-sync-server
listening on:  0.0.0.0:8080
database:      /data/cmdv-sync.sqlite
log level:     info
registration:  10 attempt(s) per 300s
usernames:     any
pbkdf2:        600000 iterations

TLS is not terminated here. Put this behind a reverse proxy; do not expose it directly.
```

### Why registration is rate-limited

`POST /api/v1/devices` is the only endpoint that is both unauthenticated and expensive: it runs
PBKDF2 at 600,000 iterations, which is the point of the iteration count and also means one request
costs real time. Measured rather than assumed — **about 1.35 seconds** in a release build on an
Apple M-series machine, and proportionally longer on a Raspberry Pi. Compare a sync, which is under
a millisecond.

Left open, that is two problems: someone can pin your server's CPU with a handful of requests, and
grind at a password without anything slowing them down.

The limit is **global rather than per-address**, and that is a deliberate choice. This server is
meant to sit behind a reverse proxy, so every request arrives from the proxy's address; a
per-address limit would either throttle your whole household as one, or have to be taught to trust
a forwarded header that an attacker can set. A global limit needs no address and holds against a
distributed attempt that per-address counting would wave through.

The cost, stated rather than hidden: somebody hammering that endpoint can stop *you* from
registering a new device until the window passes. For a household server that is the right way
round — a delay you wait out rather than a machine that stops answering. If you are setting up a
dozen devices in one sitting, raise `CMDV_SYNC_REGISTRATION_ATTEMPTS` for the afternoon.

Nothing else is rate-limited, because nothing else is cheap to attack: every other endpoint needs a
token, and a token lookup is a single indexed hash comparison.

Key derivation runs on the same actor that guards the database, so a registration briefly holds up
other devices' syncs while it runs. Bounded by the throttle, and harmless in practice — a sync is a
background operation that retries — but real. If registering a device on your hardware takes long
enough to look broken, lower `CMDV_SYNC_PASSWORD_ITERATIONS`. It is a genuine trade against someone
who has stolen your database, so lower it deliberately: 210,000 is OWASP's older guidance for the
same construction and a reasonable floor to aim at. Existing passwords keep working, because the
count is stored alongside each hash.

## Ports and networking

| Port | Protocol | Purpose |
|---|---|---|
| `8080` | HTTP | The whole API. The only port this server uses. |

There is no second port — no admin interface, no metrics endpoint, no gRPC. The container declares
`EXPOSE 8080`, which documents the port and publishes nothing on its own.

The supplied compose file publishes it as `127.0.0.1:8080:8080`. Three reasonable ways to change
that:

```yaml
# Reachable only from the Docker host. The default, and correct until a proxy is in front.
ports: ["127.0.0.1:8080:8080"]

# Reachable from your home network or VPN. Plain HTTP, which the app permits to a *private*
# address.
ports: ["8080:8080"]

# Not published at all: the proxy is another container on a shared Docker network and reaches
# this one by service name. The best arrangement if you already run a proxy in Docker.
# (Omit `ports` entirely and put both services on the same network.)
```

Do not publish it to the internet directly. The app refuses plain HTTP to a public address, so it
would not work anyway — which is what makes this safe to state plainly rather than something to
work around.

**One process per database.** Do not scale this to several replicas over one SQLite file: the
server caches the sequence number that *is* the sync cursor, and two processes would hand out
cursors the other had already moved past. One container is the supported arrangement, and it is
comfortably enough — a household's sync traffic is a few short bursts a day.

## TLS and reverse proxies

**This server does not terminate TLS, and should not be exposed directly.**

Anyone self-hosting already runs a reverse proxy that handles certificates better than this ever
would, and half-doing it here would invite somebody to put it on the internet with a certificate
nobody renews. Put it behind your proxy and let that do the certificate.

### Caddy

Certificates are automatic, which makes this the shortest correct answer:

```caddyfile
sync.example.com {
	reverse_proxy 127.0.0.1:8080
}
```

### nginx

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name sync.example.com;

    ssl_certificate     /etc/letsencrypt/live/sync.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/sync.example.com/privkey.pem;

    # nginx defaults to 1 MB, and a first sync of a long reading history is larger than that.
    # Without this, a new device syncs for the first time and gets a 413 it cannot explain.
    # This server accepts bodies up to 16 MB.
    client_max_body_size 16m;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 120s;
    }
}
```

### Traefik

As labels on the service in `docker-compose.yml`, with the port unpublished and both containers on
a shared network:

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.cmdv-sync.rule=Host(`sync.example.com`)"
  - "traefik.http.routers.cmdv-sync.entrypoints=websecure"
  - "traefik.http.routers.cmdv-sync.tls.certresolver=letsencrypt"
  - "traefik.http.services.cmdv-sync.loadbalancer.server.port=8080"
```

### Hosting it under a path

This server serves absolute paths under `/api/v1/`. If you host it at
`example.com/cmdv-sync`, the proxy must strip that prefix before passing the request on — in Caddy,
`handle_path`; in nginx, a `proxy_pass` with a trailing slash; in Traefik, a `stripprefix`
middleware.

A prefix that is *not* stripped produces an honest `404` with a `malformedRequest` reason rather
than a server error, so this misconfiguration is at least legible when it happens.

## Pointing the app at it

In CMDV Reader, open the sync settings and enter the server's address, a username, and a password.
The first device to use a username creates the account.

- `https://sync.example.com` — through your proxy, from anywhere.
- `http://192.168.1.20:8080` — straight to the server on a home network or VPN. Permitted because
  that is what makes a home server reachable at all.
- `http://sync.example.com` — **refused by the app.** Plain HTTP to a public address is not
  allowed, and the app will say so rather than sync a reader's data in the clear.

## Accounts

There is no sign-up page and no administrator. The first device to use a username creates the
account; every later device with the same password joins it. That is the shape
[kosync](https://github.com/koreader/koreader-sync-server) has and the right one for something set
up once.

The consequence, stated rather than hidden: a **mistyped username creates a second, empty account**
rather than reporting an error. If a device syncs and finds nothing, check the username before
anything else.

Each device holds its own token, and any device can revoke any other from the app's sync screen —
so a lost phone is cut off without changing a password or re-pairing anything else.

### Closing registration

Because registration *is* sign-up, anyone who can reach the endpoint and invent a username gets an
account and somewhere to keep data. On a home network that does not matter. Once the server is
reachable from the internet, list the usernames you intend to exist:

```yaml
environment:
  CMDV_SYNC_USERNAMES: alice,bob
```

Any other username is then refused with the same answer a wrong password gets, so the list cannot
be used to discover which accounts exist. Existing accounts are unaffected, and readers already
signed in stay signed in — the check only runs at registration.

There is no command to delete an account. To remove one, stop the server and delete its rows; the
schema is three tables and `accounts` cascades.

## Your data: backup and restore

Everything is in one SQLite database — the file at `CMDV_SYNC_DATABASE`. There is no other state:
no cache to warm, no uploads directory, no secret generated at first run.

**Do not back it up by copying the file while the server is running.** The database is in WAL mode,
so a plain copy can capture a torn state that looks fine and restores broken. Use SQLite's online
backup, which is safe against a running server. The `sqlite3` tool is in the image for this:

```bash
docker compose exec -T sync \
  sqlite3 /data/cmdv-sync.sqlite ".backup '/data/backup.sqlite'"

docker compose cp sync:/data/backup.sqlite ./cmdv-sync-$(date +%F).sqlite
docker compose exec -T sync rm /data/backup.sqlite
```

The result is a single consistent file. Put it wherever your other backups go.

### Restoring

```bash
docker compose down
docker run --rm -v cmdv-sync_sync-data:/data -v "$PWD":/restore alpine \
  sh -c 'rm -f /data/cmdv-sync.sqlite*; cp /restore/cmdv-sync-2026-08-03.sqlite /data/cmdv-sync.sqlite'
docker compose up -d
```

Deleting the `-wal` and `-shm` files alongside it is the part that matters: left behind from the old
database, they would be replayed over the restored one.

After a restore, devices whose cursor is *ahead* of the restored history re-send what they hold, so
a reader's own device repopulates most of what the backup missed. Sessions are immutable and merge
as a set union, so nothing is duplicated by this.

### Looking inside

```bash
docker compose exec -T sync sqlite3 /data/cmdv-sync.sqlite \
  "SELECT username, created_at FROM accounts;"

docker compose exec -T sync sqlite3 /data/cmdv-sync.sqlite \
  "SELECT kind, count(*) FROM documents GROUP BY kind;"
```

Payloads are opaque bytes — the server cannot decode a highlight and neither can `sqlite3`.

## Upgrading

```bash
git pull
docker compose up -d --build
```

The schema migrates itself on startup (`CREATE TABLE IF NOT EXISTS`, and additive from there), so
there is no migration step to run and no downtime beyond the restart. Take a backup first anyway.

The protocol is versioned, and a version this server cannot speak is refused with an explanation
rather than guessed at. A newer app against an older server therefore says so plainly instead of
silently corrupting anything — but keep them in step, since a refused version means no sync at all.

## Security

What is done, and what is deliberately not:

- **Passwords** — PBKDF2-HMAC-SHA256, 600,000 iterations (OWASP's guidance for this construction),
  a 16-byte random salt each, verified in constant time. The iteration count is stored with each
  hash, so changing it later does not invalidate existing passwords. A memory-hard function
  (Argon2id, scrypt) would be stronger against a GPU farm, and every implementation of one is long
  enough that writing it here would be the wrong call.
- **Tokens** — 256 bits from the platform CSPRNG, stored only as a SHA-256 hash. A stolen database
  yields no working tokens. No salt and no iterations, unlike a password, and that is correct
  rather than an oversight: a token is 256 random bits, so there is no dictionary to attack and no
  benefit to slowing a lookup that happens on every request.
- **Per-device revocation** — each device has its own token, revocable individually, and only from
  within its own account.
- **No SQL injection by construction** — every value that reaches SQL is a bound parameter. Nothing
  is interpolated into a statement string anywhere in this package.
- **Account isolation** — every query is scoped by account, and revoking a device you do not own
  answers `404` rather than `403`, so identifiers cannot be probed.
- **Attribution is enforced** — a pushed document is recorded as coming from the device that
  actually pushed it, whatever the request claimed.
- **Logs hold nothing sensitive** — request logging records method and path only. Never the
  `Authorization` header, never a body. That is not configurable.
- **Runs unprivileged** — UID 1001 in the container, with `no-new-privileges` set.
- **No TLS here** — on purpose. See [TLS and reverse proxies](#tls-and-reverse-proxies).
- **No password reset, no email, no account recovery.** A forgotten password means the data in that
  account is unreachable. There is nowhere for a reset link to go, and inventing somewhere would
  mean holding an address and running a mail path for a server whose whole appeal is having neither.

Found something? Open an issue, or mail the address on the repository owner's profile for anything
you would rather not file in public.

## Troubleshooting

**The container exits immediately.** Read the logs first: `docker compose logs`. Exit code `78`
means the configuration was refused and the message names the variable. Exit code `74` means the
database could not be opened.

```
The database directory '/data' cannot be used: it is not writable by this process.
```

A bind mount whose host directory the container's user cannot write to. Either use a named volume
(the default in the supplied compose file, which does not have this problem), or match the
ownership:

```bash
stat -c '%u:%g' /path/on/host   # e.g. 1000:1000
```

```yaml
user: "1000:1000"
```

**The app says it cannot connect.** Work outwards. On the server: `curl
http://127.0.0.1:8080/api/v1/health`. If that answers, the server is fine and the problem is the
proxy or the network. If the app reaches the address but refuses to sync, check it is `https://`
for a public address.

**A device syncs successfully but finds nothing.** Almost always a mistyped username, which creates
a second empty account rather than an error. Check which usernames exist:

```bash
docker compose exec -T sync sqlite3 /data/cmdv-sync.sqlite "SELECT username FROM accounts;"
```

**`429 Too Many Requests` when registering.** The registration throttle. Wait the number of seconds
in the `Retry-After` header, or raise `CMDV_SYNC_REGISTRATION_ATTEMPTS` if you are genuinely setting
up many devices at once.

**`409 Conflict` with `versionUnsupported`.** The app and the server disagree about the protocol
version. Update whichever is behind.

**`404` on every endpoint through the proxy.** The proxy is passing a path prefix through. See
[Hosting it under a path](#hosting-it-under-a-path).

**A first sync fails with `413` through nginx.** `client_max_body_size`. See
[nginx](#nginx).

**Registering a device takes several seconds, and syncs stall while it does.** Expected. That is
600,000 PBKDF2 iterations — about 1.35 seconds on fast hardware, longer on a Pi — running on the
same actor that guards the database. Lower `CMDV_SYNC_PASSWORD_ITERATIONS` if it is bad enough to
matter on your hardware, understanding the trade. See
[Why registration is rate-limited](#why-registration-is-rate-limited).

## The protocol

Documented in the source, in one file: [`SyncProtocol.swift`](Sources/CMDVSyncProtocol/SyncProtocol.swift).
A protocol described in a document and implemented twice drifts; implemented once and read by both
ends cannot.

Three properties, and everything else follows from them:

- **The server does not understand the payloads.** A document is an envelope with a kind, an
  identity, a timestamp, and opaque bytes. A newer client can introduce a kind this server has
  never heard of and it is still stored and delivered.
- **The cursor is a server sequence number, not a clock.** Two devices whose clocks differ by
  minutes still exchange every document exactly once.
- **One request pushes and pulls.** A sync is a single exchange, so there is no half-finished state
  to reconcile after a failure.

### Endpoints

| Method | Path | What it does |
|---|---|---|
| `POST` | `/api/v1/devices` | Register a device, in exchange for a token. Unauthenticated, and rate-limited. |
| `GET` | `/api/v1/devices` | List the devices with access to this account. |
| `DELETE` | `/api/v1/devices/{id}` | Revoke a device. |
| `POST` | `/api/v1/sync` | Push changes and pull what came from elsewhere. |
| `GET` | `/api/v1/health` | Unauthenticated. What to point a monitor at. |

Every request carries `X-CMDV-Sync-Version: 1`; a mismatch is refused with `409`. A request with no
version header is treated as version 1, so a plain `curl` against the health endpoint — the first
thing anyone does when a server will not connect — is not refused for a missing header.

Every failure names a machine-readable reason alongside its prose, because a client's next step
differs between "sign in again" and "the server is full" and neither can be told from a status code
alone: `invalidCredentials`, `tokenRevoked`, `versionUnsupported`, `malformedRequest`,
`quotaExceeded`, `serverError`.

Registering by hand, if you want to see it work:

```bash
curl -sS -X POST http://127.0.0.1:8080/api/v1/devices \
  -H 'Content-Type: application/json' \
  -H 'X-CMDV-Sync-Version: 1' \
  -d '{
        "username": "reader",
        "password": "a good password",
        "deviceName": "Test",
        "deviceID": "11111111-1111-1111-1111-111111111111"
      }'
```

## Developing on it

```bash
swift build
swift test
```

The whole suite runs in under a second and needs nothing started by hand: every store test uses an
in-memory database, the endpoint tests drive the real router in-process through Hummingbird's test
support, and the socket tests bind an ephemeral port the kernel picks. There is nothing to skip and
no fixed port to collide with.

### The vendored wire format

`Sources/CMDVSyncProtocol/SyncProtocol.swift` is a **verbatim copy** of the same file in the app's
repository. In the app's repository the two ends could not disagree, because both imported one
file. Here they can, because a server anyone can host must build on Linux without the app's
iOS-only dependencies in the graph — so the copy is kept byte-identical, which makes `diff` the
whole parity check:

```bash
Scripts/check-protocol-parity.sh ~/src/CMDV-Reader
```

Never edit that file here. A change to the wire format is made in the app and copied across, and it
should come with a look at whether `SyncProtocolVersion.current` needs to move.

### Layout

```
Sources/
  CMDVSyncProtocol/   The wire format. Pure Foundation, no dependencies.
  CMDVSyncServer/     The server, as a library so tests can construct it.
  cmdv-sync-server/   The executable: reads the environment, starts the listener.
  CSQLiteShim/        SQLite's C API, portably — `import SQLite3` is Apple-only.
Tests/
  CMDVSyncServerTests/
```

Dependencies are [Hummingbird 2](https://github.com/hummingbird-project/hummingbird),
[swift-crypto](https://github.com/apple/swift-crypto), and
[swift-log](https://github.com/apple/swift-log) — all Apache-2.0, and all three needed for reasons
written down in `Package.swift`.

## Licence

[Mozilla Public License 2.0](LICENSE), like the app.
