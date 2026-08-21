# Splitting the mail stack: models, SMTP, IMAP

This is the plan for taking the current unified deploy — one Puma process
serving the web UI, Solid Queue, SMTP, and IMAP — and making each of
those pieces independently runnable, without giving up the option to
keep them in one container.

It is a design document, not a description of the running system. Until
the work lands, production is still the single-process Puma plugin in
[`config/puma.rb`](../config/puma.rb).

## Goal

Three independently useful pieces:

1. **Models and migrations** — a gem the rest of the stack depends on.
   The schema, Active Record models, inbound mailroom, outbound
   delivery jobs, settings, bans, and the Active Record store backends.
2. **SMTP** — a gem that runs the MX / submission / SMTPS listeners.
   Runnable as a Puma plugin next to a Rails app, or as its own process
   (a Kamal accessory in this deploy).
3. **IMAP** — the same idea for IMAP / IMAPS.

An operator should be able to:

- run **SMTP only** (no IMAP, no admin UI)
- run **IMAP only** and write `mail_on_rails_*` rows from their own app
- run **the admin UI only** against a database that other processes fill
- run **everything in one container**, as today, via the Puma plugin
- in development, choose SMTP, IMAP, both, or neither alongside this app

The production default for this app: SMTP and IMAP live in **separate
containers as Kamal accessories**. They boot the models gem
(ActiveRecord) and share Postgres with the web UI. They do **not** speak
HTTP to the app. The web UI never calls into the mail processes.

That last sentence is the load-bearing one. A previous HTTP control API
for live connections and kicks was cumbersome. The database already
carries mail, settings, and bans across process boundaries; the remaining
in-memory ops state can move onto the same path.

## Why this is feasible now

The gem is already layered that way, even though it currently ships as
one package and this app runs it in one process.

**Protocol servers do not touch Active Record.** SMTP and IMAP talk to
the world through a store interface that returns plain hashes
([`docs/store_contract.md`](store_contract.md)). The production
backends (`Store::SmtpBackend`, `Store::ImapBackend`) are the AR
implementations; memory backends exist for Rails-free protocol tests.
The protocol tree is deliberately not Zeitwerk-managed so it can load
without Rails (`ruby -Ilib -r mail_on_rails/imap/daemon`).

**A standalone CLI already exists.** [`bin/mail_server`](../bin/mail_server)
boots this Rails app and hands off to `MailOnRails::Cli`, which accepts
`--protocols smtp` / `imap`. Accessories are that command with a
different process title, not a new runtime.

**Cross-process configuration already works.** Dynamic settings and the
IP denylist are written from the web UI and consumed by the listeners
through a ~5s TTL poll (`Settings::DynamicOverrides`,
`Netserv::Denylist`). The in-process `after_commit` push is an
optimization for the unified deploy; the poll is the cross-process path
and it already exists.

**Compose never talks to local SMTP.** The web UI inserts
`SmtpOutboundMessage` rows. Delivery is an Active Job. Splitting
processes does not change that.

What is *not* already split is packaging (one gem), deploy topology
(mail ports published on the web container), and a handful of ops UI
calls that read **this process's** listener memory:
`MailOnRails.server`, `kick_connections`, `ready?`.

Those are the only things that need new machinery, and that machinery
is tables, not an HTTP API.

## What we are not doing

[`docs/store_contract.md`](store_contract.md) and a comment in
[`config/database.yml`](../config/database.yml) describe a different
end state: database-free protocol daemons whose stores speak HTTP, with
the Rails app holding all credentials. That is a valid design. It is
**not** this plan.

This plan's default is the opposite: SMTP and IMAP **depend on the
models gem**, boot ActiveRecord, and share `DATABASE_URL`. "IMAP only,
handle the mail in the DB yourself" means the operator writes the
`mail_on_rails_*` tables (accounts, mailboxes, `email_messages` with
UIDs and flags). It does not mean a custom schema behind an HTTP store.

An HTTP store can still be built later — the store interface stays —
but it is a different project. It would add latency on every FETCH and
a service to version and authenticate. Shared Postgres avoids that.

Also out of scope:

- Redis, or Action Cable between containers, as a control plane
- rewriting SMTP or IMAP protocol code
- dropping the Puma plugin (it remains the one-container path)
- splitting git repos on day one (see [Sequence](#sequence))

## Current architecture (today)

One Puma process, `WEB_CONCURRENCY` forced to 1, because the mail
listeners must exist in exactly one process:

```
Internet --HTTPS--> kamal-proxy --> web container :80
Internet --25/587/465/143/993--> web container (Puma plugin threads)
                                      |
                                      +--> PostgreSQL (unix socket)
                                      +--> clamav :3310
                                      +--> rspamd :11333
```

[`config/puma.rb`](../config/puma.rb) loads `:mail_on_rails` in
development always, and in production when `MAIL_ON_RAILS_SERVERS=true`.
[`HealthController`](../app/controllers/health_controller.rb) holds `/up`
down until `MailOnRails.ready?` so Kamal will not cut over a container
whose mail ports have not bound.

Live connection dashboards (`/smtp`, `/imap`) call
`MailOnRails.server(protocol).connections`. Ban and honeypot kick call
`MailOnRails.kick_connections`. Those methods no-op if the listeners
are not in this process — which is why a naive split would blank the
ops UI.

Closed-connection history, auth attempts, bans, settings, and mail
bodies are already database rows. The live table is the exception.

## Target architecture

```
Internet --HTTPS--> kamal-proxy --> web container (Rails UI + Solid Queue)
Internet --25/587/465--> smtp accessory (bin/mail_server --protocols smtp)
Internet --143/993-->    imap accessory (bin/mail_server --protocols imap)
                                      |
                    web, smtp, imap --+--> PostgreSQL
                    smtp, imap ----------> clamav, rspamd
```

Same Docker image, three commands. Not three Dockerfiles. The image
already knows how to boot Rails; the accessory just runs the CLI
instead of `rails server`.

| Process | Command | Publishes | `MAIL_ON_RAILS_SERVERS` |
|---|---|---|---|
| web | `./bin/thrust ./bin/rails server` | 80 (via proxy) | unset |
| smtp | `./bin/mail_server --protocols smtp` | 25→1025, 587→1587, 465→1465 | n/a (CLI starts SMTP) |
| imap | `./bin/mail_server --protocols imap` | 143→1143, 993→1993 | n/a |

Web `/up` means "this process can serve HTTP". It must **not** wait for
SMTP or IMAP. Each accessory gets its own TCP healthcheck on the ports
it binds. That also removes the reason for
[`.kamal/hooks/pre-app-boot`](../.kamal/hooks/pre-app-boot): today the
old web container must die before the new one can bind 25/587/… After
the split, web can rolling-deploy. SMTP/IMAP still cannot share those
host ports with a predecessor; their deploys drain and replace, and the
outage is mail-only.

Side effect: the web role may set `WEB_CONCURRENCY > 1`. The plugin's
single-process rule applies only when listeners live inside Puma.

### Dual run mode (same gems)

**In-process.** Host `config/puma.rb` loads `plugin :mail_on_rails`
(or the per-protocol plugins). `WEB_CONCURRENCY` stays 1. This remains
the documented one-container path and the default development path.

**Standalone.** `bin/mail_server --protocols smtp` (and/or `imap`).
This is the accessory path and the "I only wanted an SMTP server" path.

The ops UI does not distinguish them. It reads tables. The daemons
write those tables whether they were started by Puma or by the CLI.

## Gem layout

Three gems, no meta-gem. Protocol gems self-register with core so a
host that omits one does not boot empty listeners.

| Gem | Owns | Depends on |
|---|---|---|
| `mail_on_rails` | Models, migrations, jobs, `MailroomMailbox`, AR stores, engine (MTA-STS / unsubscribe / BIMI), settings, netserv, Runtime, combined Puma plugin | Rails 8 (Active Record, Active Job, Action Mailbox, Railties) |
| `mail_on_rails-smtp` | `SmtpServer`, `Smtp::Daemon`, sender auth, DNSBL, `plugin :mail_on_rails_smtp`, exe | `mail_on_rails` |
| `mail_on_rails-imap` | `ImapServer`, `Imap::Daemon`, SCRAM, `plugin :mail_on_rails_imap`, exe | `mail_on_rails` |

`config.mail_on_rails.protocols` already exists (default `[:imap, :smtp]`).
Wire Puma and the CLI to honor it, including an empty list.

Host Gemfile combinations:

- **This app, full product:** all three. Production: accessories, no
  plugin on web. Development: plugin, subset via env (below).
- **SMTP only:** `mail_on_rails` + `mail_on_rails-smtp`. A minimal Rails
  app (or this image with the CLI) plus Postgres. No IMAP, no admin UI.
- **IMAP only:** `mail_on_rails` + `mail_on_rails-imap`. The operator's
  app writes accounts / mailboxes / messages; IMAP serves them.
- **UI only:** `mail_on_rails`. Engine + models. Listeners run elsewhere
  against the same database.

Honest constraint on "standalone": with shared-DB Active Record,
SMTP-only is still a Rails process. It loads models, Action Mailbox
ingest, and jobs. It is standalone in the product sense (no IMAP, no
admin UI), not in the "tiny stdlib binary" sense.

HTTP endpoints that are part of the *mail product* — MTA-STS at
`/.well-known/mta-sts.txt`, one-click unsubscribe, BIMI logos — stay
on the Rails engine. They are not SMTP. An SMTP-only operator either
mounts the engine on some HTTP vhost or serves those files themselves.

## Database as the mailbox

No HTTP control API. Two kinds of rows:

- **State** — the daemon writes, the UI reads.
- **Commands** — the UI writes, the daemon reads and discards.

The live-connection pages already poll every ~5s
([`poll_controller.js`](../app/javascript/controllers/poll_controller.js)).
They do not need a synchronous RPC. Point that poll at tables instead
of `MailOnRails.server`.

Do this **even in Puma-plugin mode**, so accessory vs in-process is one
code path in the UI. `MailOnRails.server` / `kick_connections` become
daemon-internal.

### Already rows (nothing new)

| Need | Mechanism |
|---|---|
| Mail, accounts, aliases, mailboxes | existing tables |
| Settings (limits, scanner addrs, toggles) | `settings` + ~5s poll; in-process `after_commit` remains a fast path |
| Ban *future* connections | `banned_ips` + denylist poll (`Netserv::Denylist::TTL` = 5s) |
| Store-level auth throttle (credential guesses) | `auth_throttles` (AR), shared by IMAP, SMTP AUTH, and web login |
| Compose / outbox | `smtp_outbound_messages` |
| Closed-connection history | `closed_connections` (already written from the connection-close path) |

**Ban → drop already-open connections** does not need a new table.
Today `BannedIpsController` calls `kick_connections` in-process because
the denylist only silences *future* accepts. After the split, when a
daemon reloads `banned_cidrs` it also kicks live sockets whose peer
matches. The ban row *is* the command. Latency is the denylist TTL
(about 5s), which is the same order as the dashboard poll.

### New state: `open_connections`

Sibling of `ClosedConnection`. The live dashboard and `/metrics` gauge
`mail_on_rails_live_connections` read this instead of
`Server#connections`.

Lifecycle:

1. INSERT on accept (best-effort: a failed insert must not drop the
   mail session — same rule as `ClosedConnection.record`).
2. UPDATE session fields on a **throttled cadence** (~2s), not on every
   IMAP/SMTP command. Port 25 scanners and IMAP IDLE must not turn the
   accept path into a write amplifier.
3. DELETE on close, then `ClosedConnection.record` as today.
4. On daemon boot: `DELETE WHERE listener_id = me`.
5. Sweeper: delete rows whose heartbeat is older than ~30s (killed
   container that never ran its ensure).

Identity: a `listener_id` UUID minted at daemon boot, plus a
per-connection token. Crash leftovers are scoped to that listener.

Shape matches the hashes `Server#connections` already builds (plain
values, no sockets):

- protocol, peer_ip, port, role, connected_at, tarpit
- SMTP `live_info`: user, helo, messages, tls
- IMAP `live_info`: user, state (`pre-auth` / `SELECT …` / `IDLE …`), tls
- heartbeat / `updated_at`

This table is bounded by `max_connections`, not by scanner history.
`ClosedConnection` needs rollup because unauthenticated strangers
decide how fast *history* grows. Open connections cannot outgrow the
listener cap.

### New state: accept-side lockouts

The dashboard also shows addresses that are locked out *before* a
session exists (`Server#lockouts` → in-memory
`Netserv::AuthThrottle#locked_ips`). That throttle stays in memory on
the accept path — it must not take a database checkout to refuse a
banned scanner.

Project it: when the in-memory throttle trips, upsert a row
`(protocol, ip, locked_until, listener_id)`. Delete or let it expire
when the window ends. The UI queries `locked_until > now`. Display
only; the accept path does not read this table.

This is a different object from AR `AuthThrottle` (the store-level
credential budget). Both can appear on ops pages; do not collapse them.

### Optional state: `listener_heartbeats`

One row per protocol the process is serving: bind addresses, pid,
`heartbeat_at`, `ready`. Lets the admin UI show "SMTP is up" without
making web `/up` wait on mail ports. Kamal still health-checks
accessory TCP ports directly. Skip this table if open-connection
heartbeats plus Kamal are enough; add it if a status chip on the
dashboard is worth a migration.

### New commands: `connection_kicks`

The only command that is *not* already a domain row is **honeypot
kick**: drop this source's live connections **without** persisting a
ban ([`HoneypotController#kick`](../app/controllers/honeypot_controller.rb)).

Columns: `ip`, optional `protocol` (null = both), `created_at`,
`expires_at`, `processed_at`, `kicked_count`.

Flow: admin insert → daemon poll (~1s) → `Server#kick` → set
`processed_at` / `kicked_count` (or delete). Unprocessed rows expire
so a down accessory cannot queue kicks forever.

Flash copy becomes fire-and-forget: "Asked the mail servers to drop
connections from …". Waiting on `processed_at` inside the web request
recreates RPC-over-the-database; do not do that. Ban actions must
**not** insert a kick row.

### What must not be a row

- Web `/up` waiting for SMTP/IMAP bind. Wrong once mail is another
  container.
- Per-command session state at protocol rate. Throttled snapshots only.
- Synchronous "Dropped N" in the same HTTP request.

### Turbo broadcasts

`config.mail_on_rails.on_connection_activity` runs on the connection
thread in *this* process and pings
[`LiveConnectionsBroadcaster`](../app/models/live_connections_broadcaster.rb).
That remains a snappier path when the plugin is loaded. Accessory mode
relies on the existing 5s page poll against `open_connections`.
Correctness does not depend on Cable reaching the daemon.

## Jobs, inbound, and who is the MTA

`Store::SmtpBackend#smtp_store` creates `ActionMailbox::InboundEmail`
**in the SMTP process**, then enqueues work. That stays in the SMTP
process — it has the models gem. The mailroom (`MailroomMailbox`) and
outbound `DeliverSmtpOutboundJob` are Active Jobs against the shared
queue database.

In the full product, keep the Solid Queue supervisor on **web**
(`SOLID_QUEUE_IN_PUMA`), as today. The SMTP accessory accepts mail and
writes rows; web workers run mailroom and (until moved) outbound
delivery.

Outbound delivery is a natural fit on the SMTP accessory — it is the
MTA — and should move there once accessories exist, so a web-only
scale-out does not open outbound sockets. Web compose keeps inserting
queue rows and never speaks SMTP locally.

SMTP-only (no UI) must run Solid Queue itself, or inbound mail sits in
`action_mailbox_inbound_emails` unprocessed.

IMAP never needed Action Mailbox. IMAP-only does not boot SMTP or the
mailroom.

## Development

Today the plugin always loads in development. After this work:

```text
MAIL_ON_RAILS_SERVERS=smtp,imap   # default in development (current behavior)
MAIL_ON_RAILS_SERVERS=smtp
MAIL_ON_RAILS_SERVERS=imap
MAIL_ON_RAILS_SERVERS=0           # UI only; no listeners
```

`config.mail_on_rails.protocols` is the equivalent initializer knob.
`bin/dev` stays one process when plugins are on. A later optional
`Procfile.dev` can run `bin/mail_server` as sibling processes to mimic
accessories; not required for the first cut.

The `clamav_dev` Puma plugin remains a development convenience. In
accessory-style local runs, point `SMTP_CLAMAV_ADDR` at a compose
service the same way production points at the clamav accessory.

## Deploy details that will bite

**Active Record encryption and `secret_key_base`.** Every process that
decrypts SCRAM verifiers or DKIM keys needs the same credentials as
web. Accessories must receive the same Rails encryption init and
Kamal secrets. A missing key looks like "IMAP auth is broken", not
like a config error.

**Postgres connectivity.** Web talks to the db accessory over a Unix
socket at `/postgres/socket`. SMTP and IMAP accessories need that
volume too, or the db accessory must expose TCP on the Kamal network.
Do not assume the socket mount is host-global.

**Pool size.** Each mail process is many connection threads. Size
`pool` (and Postgres `max_connections`) for SMTP and IMAP
independently of `RAILS_MAX_THREADS` on web. Fail-soft open-connection
writes still check out a connection.

**TLS material.** Certbot already renews into `/etc/letsencrypt` on
the host. Mount that read-only into the smtp and imap accessories the
way it is mounted into web today. The listeners already re-read PEMs
on mtime change.

**ClamAV / rspamd.** Already accessories. SMTP (and IMAP APPEND) keep
using `SMTP_CLAMAV_ADDR` / `SMTP_RSPAMD_ADDR` on the Docker network.
Unchanged. Production boot still refuses to start SMTP without a
scanner unless `SMTP_CLAMAV_OPTIONAL=1`.

**Owner-privileged jobs.** Today's deploy comments note that Action
Mailbox routing and outbound delivery need owner-level grants, which
is one reason jobs run in the web container. If outbound moves to the
SMTP accessory, that accessory needs the same grants. Do not split
jobs onto a worker that cannot decrypt or sign.

## Sequence

Do not split git repos while the seams are still moving. Lockstep
versions across three repositories will hurt more than an in-tree
gemspec split.

1. **Inside the current gem, still one package.** Honor `protocols` in
   Puma, the CLI, and `/up`. Persist `open_connections` and
   accept-lockouts. Kick live sockets on denylist reload. Add
   `connection_kicks` for honeypot. Point `/smtp`, `/imap`, and
   `/metrics` at those tables even with the plugin loaded. Prove that
   `MAIL_ON_RAILS_SERVERS=0` still serves the UI, and that banning an
   IP drops a live session within the poll interval.

2. **In-tree gemspecs** (like Rails): `mail_on_rails`,
   `mail_on_rails-smtp`, `mail_on_rails-imap`, protocol
   self-registration. Prove SMTP-only boot, IMAP-only boot, combined
   plugin, and `bin/mail_server --protocols smtp` against this app's
   database.

3. **Kamal.** Move published mail ports off `servers.web` onto
   `accessories.smtp` and `accessories.imap`. Unset
   `MAIL_ON_RAILS_SERVERS` on web. Drop the pre-app-boot port-clash
   hook for web. Share the Postgres socket (or TCP), encryption
   secrets, and Let's Encrypt mount. Give each accessory a TCP
   healthcheck.

4. **Sibling git repos** only after public constants, table names, and
   the store methods used at the gem boundary have stopped churning.

Keep the store interface and memory backends through all of this.
They are the protocol test seam, not a commitment to HTTP.

## Acceptance

The split is done when all of the following are true:

- This app can run with SMTP, IMAP, both, or neither, in development,
  without editing `config/puma.rb` by hand.
- Production can run web / smtp / imap as three containers from one
  image, sharing Postgres, with mail ports off the web container.
- `/smtp` and `/imap` show live connections when the listeners are in
  other containers.
- Banning an IP stops new connections and drops existing ones without
  the web process holding a server handle.
- Honeypot kick drops live connections without writing a `BannedIp`.
- `/up` on web does not wait for mail listeners; SMTP-only still
  refuses to boot in production without TLS and (unless opted out)
  ClamAV.
- A consumer can add `mail_on_rails` + `mail_on_rails-smtp` to a
  Rails app that has no IMAP gem and no admin UI, run
  `bin/mail_server --protocols smtp`, and accept mail into the models
  gem's tables.
- `plugin :mail_on_rails` still runs both listeners in one Puma
  process for operators who want a single container.
