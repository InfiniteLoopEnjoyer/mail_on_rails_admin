# The split: core, SMTP and IMAP gems; web, smtp and imap containers

This started as a design document for taking the unified deploy — one
Puma process serving the web UI, Solid Queue, SMTP, and IMAP — and making
each piece independently runnable without giving up the one-container
option. The work landed on 2026-08-21; this page now records what was
built and why, and what an operator needs to know.

## What exists now

Four repositories:

| Repo | Gem / app | Owns |
|---|---|---|
| [mail_on_rails](https://github.com/InfiniteLoopEnjoyer/mail_on_rails) | `mail_on_rails` (core) | models, migrations, jobs, mailroom, outbound delivery, settings schema, `Netserv` listener scaffolding (TLS, caps, lockouts, denylist, ops sync), SPF/DKIM/DMARC/ARC + SCRAM primitives, `Runtime`, Puma plugin, CLI, the `MailOnRails::Testing::Database` harness |
| [mail_on_rails_smtp](https://github.com/InfiniteLoopEnjoyer/mail_on_rails_smtp) | `mail_on_rails_smtp` | `SmtpServer`, `Smtp::Daemon`, `Smtp::Protocol` (runtime adapter), `Store::SmtpBackend`, DNSBL/FCrDNS, memory store + contract, fuzz harness |
| [mail_on_rails_imap](https://github.com/InfiniteLoopEnjoyer/mail_on_rails_imap) | `mail_on_rails_imap` | `ImapServer`, `Imap::Daemon`, `Imap::Protocol`, `Store::ImapBackend`, `Imap::Mime`/UTF-7, memory store + contract, fuzz harness |
| [mail_on_rails_admin](https://github.com/InfiniteLoopEnjoyer/mail_on_rails_admin) | this app | webmail + admin UI, the Kamal deploy |

The protocol gems depend on core. Requiring one (Bundler does it)
registers the protocol with `MailOnRails::Runtime`; that is the only
wiring. A host with core + `mail_on_rails_smtp` is an SMTP server with
no IMAP and no admin UI; core + `mail_on_rails_imap` is an IMAP server
over tables the operator fills themselves.

### Run modes

| Mode | How | Used by |
|---|---|---|
| Standalone process | `bin/mail_server --protocols smtp` / `imap` / both | the production smtp and imap roles; SMTP-only / IMAP-only consumers |
| Inside Puma | `plugin :mail_on_rails` + `MAIL_ON_RAILS_SERVERS=smtp,imap` (or `smtp`, `imap`, `0`) | the all-in-one container; development |
| Web only | `MAIL_ON_RAILS_SERVERS=0` (the production web role) or `config.mail_on_rails.protocols = []` | web behind kamal-proxy with listeners elsewhere |

Unset, `MAIL_ON_RAILS_SERVERS` means every installed protocol in
development and none elsewhere — so `bin/dev` runs everything in one
process, and production opts in explicitly. `bin/mail_server` ignores
that rule: running the mail binary means "serve mail", default every
installed protocol. `/up` on web gates on listener readiness **only**
when `MailOnRails::Runtime.in_process_protocols` is non-empty.

### Production topology

```
Internet --HTTPS--> kamal-proxy --> web role   (Puma + Solid Queue; MAIL_ON_RAILS_SERVERS=0)
Internet --25/587/465--> smtp role  (./bin/mail_server --protocols smtp)
Internet --143/993-->    imap role  (./bin/mail_server --protocols imap)
                                   |
              web, smtp, imap -----+--> PostgreSQL (shared Unix socket volume)
              smtp, imap (+ web mailroom) ---> clamav, rspamd accessories
```

Three **Kamal roles** from one image, not accessories: roles share the
image and ship atomically with `kamal deploy`, so the three gems can
never drift between containers. Mail configuration every role needs
(HELO, TLS material, scanner addresses, the security-posture overlay)
is top-level `env` in `config/deploy.yml`; the roles carry only what
differs (`SOLID_QUEUE_IN_PUMA` and `MAIL_ON_RAILS_SERVERS: 0` on web,
`cmd`, `publish` and `RAILS_MAX_THREADS` on the mail roles).
`.kamal/hooks/pre-app-boot` stops only the old smtp/imap containers (the
host ports can't be shared), so web rolls with zero downtime and the
mail outage per deploy is seconds. `.kamal/hooks/post-deploy` probes
every published mail port and fails the deploy if one never answers —
Kamal itself only health-checks proxied roles. Web may run
`WEB_CONCURRENCY > 1` now.

The mail containers run this same app image (`bin/mail_server` boots
`config/environment`), so they have the initializers, the encryption
keys, Solid Cable, and `LiveConnectionsBroadcaster` — nothing is special
about them except the command.

## Database as the control plane

No HTTP between web and the listeners. Two kinds of rows, all in core:

**State — the daemon writes, the UI reads.** Every `Netserv::Server`
runs a `Netserv::OpsSync` thread. Every `ops_sync_interval` (2 s) it:

1. snapshots `Server#connections` and `#lockouts`; if the picture
   changed it replaces its rows in `mail_on_rails_open_connections` and
   `mail_on_rails_accept_lockouts` and **then** fires
   `config.mail_on_rails.on_connection_activity` (so a Turbo refresh
   never races the rows it announces); unchanged, it only heartbeats;
2. heartbeats its `mail_on_rails_listeners` row (protocol, pid,
   hostname, ports, max connections, readiness);
3. drops live sessions whose peer the denylist (`BannedIp`) now bans —
   a ban row is the whole command, and it works on an idle listener
   too;
4. processes pending `mail_on_rails_connection_kicks` for its protocol
   and acknowledges each with the count;
5. sweeps the rows of any listener whose heartbeat is older than
   `ops_stale_after` (30 s) — a killed container that never ran its
   shutdown.

The accept path and the connection threads never touch these tables;
one thread, a handful of statements bounded by the connection cap,
every call best-effort.

**Commands — the UI writes, the daemon consumes.** Exactly one:
`ConnectionKick.request!(ip)` (honeypot kick), one row per protocol,
expiring after 60 s so a down listener can't accumulate them. The flash
is fire-and-forget on purpose; waiting on `processed_at` inside a web
request would be RPC over the database. Bans insert no kick row.

The UI (`/smtp`, `/imap`, `/metrics`, ban and kick buttons) reads
`Listener.alive`, `OpenConnection.live`, `AcceptLockout.active`,
`ConnectionKick` — identically in every run mode; the in-process
`MailOnRails.server` / `kick_connections` handles are gem-internal now.

Already rows before this work and unchanged: settings (`settings` +
5 s poll, in-process `after_commit` push), bans (`banned_ips` +
denylist poll), the store-level `auth_throttles`, the outbox
(`smtp_outbound_messages`), closed-connection history
(`closed_connections`).

## What moved where (the boundary)

The split's one real obstacle was a circular dependency: core models
and jobs reached into protocol namespaces (the old `Smtp::`-prefixed
sender-auth module for DMARC reports and BIMI, the SMTP outbound-data
helper for delivery, the SMTP send quota for vacation replies, the SMTP
clamd client, and the IMAP SCRAM module in `Store::Base`). Those
primitives now live in core under neutral names —
`MailOnRails::SenderAuth`, `OutboundData`, `SendQuota`, `ClamavClient`,
`Scram` — and `Mime` went to the IMAP gem as `Imap::Mime`. The two
identical per-protocol TLS modules became one `Netserv::Tls`
(`Tls.for(:smtp)` / `(:imap)` own the setting names). The AR store
backends travel with their protocol (`Store::SmtpBackend` in the SMTP
gem, `Store::ImapBackend` in the IMAP gem); core keeps `Store::Base`
and `Store::WithSource`.

Each protocol gem's entry file registers a runtime adapter
(`Smtp::Protocol` / `Imap::Protocol`: `start`, `check_config`,
`preflight!`); `Runtime`, the CLI and the Puma plugin work only through
the registry, and the production boot guards (explicit TLS, a virus
scanner for SMTP) moved into the adapters.

## Jobs, inbound, and who is the MTA

`Store::SmtpBackend#smtp_store` creates `ActionMailbox::InboundEmail`
**in the SMTP process** and the mailroom (`MailroomMailbox`) and outbound
`DeliverSmtpOutboundJob` run on Solid Queue — in this deploy on **web**
(`SOLID_QUEUE_IN_PUMA`), as before. Web never speaks SMTP locally: compose
inserts outbox rows. SMTP-only deployments without this app must run a
job runner themselves. IMAP never needed Action Mailbox.

## Development

```text
bin/dev                                    # web + both listeners in one process (default)
MAIL_ON_RAILS_SERVERS=smtp bin/dev         # web + SMTP only
MAIL_ON_RAILS_SERVERS=0 bin/dev            # web only ...
bin/mail_server --protocols imap           # ... with IMAP as a sibling process
```

Development's `cable.yml` uses the `async` adapter, so a sibling
`bin/mail_server` cannot push Turbo refreshes into the web process (in
production they ride Solid Cable); the live pages' 30 s poll covers it.

## Deploy details that bite

- **Active Record encryption and `secret_key_base`** reach every role
  through the top-level Kamal `env` — a mail container without them
  looks like "IMAP auth is broken", not like a config error.
- **Postgres** is reached over the db accessory's Unix socket; the
  volume is top-level in `deploy.yml`, so every role mounts it.
- **Pool size**: each mail process checks out an AR connection per
  store call across up to `smtp_max_conn` / `imap_max_conn` threads;
  `RAILS_MAX_THREADS` on the mail roles sizes their pools (16), and
  Postgres `max_connections` (default 100) must cover web + jobs + both.
- **TLS material**: `/etc/letsencrypt` is a top-level read-only volume;
  the listeners re-read PEMs on mtime change.
- **Migrations** run on web only (`bin/docker-entrypoint` runs
  `db:prepare` for `rails server` and nothing else). The ops-state
  writes are fail-soft, but keep migrations additive when all roles ship
  together.
- **Lockstep**: the admin `Gemfile.lock` pins all three gem SHAs; bump
  them together (`bundle update mail_on_rails mail_on_rails_smtp
  mail_on_rails_imap`).

## Acceptance (checked 2026-08-21)

- This app runs with SMTP, IMAP, both, or neither in development
  without editing `config/puma.rb`.
- Production runs web / smtp / imap as three containers from one image,
  sharing Postgres, with mail ports off the web container.
- `/smtp` and `/imap` show live connections when the listeners are in
  other containers (seeded-table controller tests; live e2e in
  `test/integration/in_process_servers_test.rb`).
- Banning an IP stops new connections and drops existing ones without
  the web process holding a server handle.
- Honeypot kick drops live connections without writing a `BannedIp`.
- `/up` on web does not wait for mail listeners; SMTP-only still refuses
  to boot in production without TLS and (unless opted out) ClamAV.
- A consumer can add core + `mail_on_rails_smtp` to a Rails app with no
  IMAP gem and no admin UI and run `bin/mail_server --protocols smtp`.
- `plugin :mail_on_rails` still runs both listeners in one Puma process.
