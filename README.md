# mail_on_rails_admin

[![CI](https://github.com/InfiniteLoopEnjoyer/mail_on_rails_admin/actions/workflows/ci.yml/badge.svg?branch=main&event=push)](https://github.com/InfiniteLoopEnjoyer/mail_on_rails_admin/actions/workflows/ci.yml)
[![Security](https://github.com/InfiniteLoopEnjoyer/mail_on_rails_admin/actions/workflows/security.yml/badge.svg?branch=main&event=push)](https://github.com/InfiniteLoopEnjoyer/mail_on_rails_admin/actions/workflows/security.yml)
[![Lint](https://github.com/InfiniteLoopEnjoyer/mail_on_rails_admin/actions/workflows/lint.yml/badge.svg?branch=main&event=push)](https://github.com/InfiniteLoopEnjoyer/mail_on_rails_admin/actions/workflows/lint.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](MIT-LICENSE)

The companion app for the
**[mail_on_rails](https://github.com/InfiniteLoopEnjoyer/mail_on_rails)**
gems — a from-scratch mail server for Rails (SMTP + IMAP, mail stored in
the app's database): the core gem (models, migrations, runtime) plus
[mail_on_rails_smtp](https://github.com/InfiniteLoopEnjoyer/mail_on_rails_smtp)
and [mail_on_rails_imap](https://github.com/InfiniteLoopEnjoyer/mail_on_rails_imap).
This repo is a complete, deployable example of a host application: a
webmail client, a mail-server admin UI, and a Kamal deploy that runs
web, SMTP and IMAP as three containers from one image (or all in one
container, your choice). Use it as a mail server out of the box, or as a
worked example of what building on the gems looks like.

## How the two repos fit together

The **gem** owns everything protocol- and storage-shaped: the SMTP
server (MX + authenticated submission), the IMAP server, the Active
Record models and migrations, outbound delivery (MX resolution, DANE,
MTA-STS, DKIM signing), inbound verification and scanning, DKIM/DNS key
management, vacation auto-replies, and DMARC / TLS-RPT report handling.
This app pulls it in from git
(`bundle update mail_on_rails` to pick up gem changes).

This **app** owns everything a human touches: session auth and
two-factor, the webmail UI, the admin dashboards, role-based access
control, the Prometheus endpoint, and the production deploy config.

## Components

**Webmail**
- Browse, full-text search, and compose (rich-text via Lexxy, plus MIME
  file attachments); drafts autosave; folder management;
  mark/unmark-spam filing to and from Junk.
- Verified/unverified sender badges from the gem's SPF/DKIM/DMARC
  checks; sanitized HTML rendering.
- Per-user themes and a PWA manifest for install-to-homescreen.

**Admin**
- **Domains** — create/remove hosted domains live (no restart); each
  gets a generated DKIM key, the DNS records to publish, and a
  `DnsCheck` that verifies MX/SPF/DKIM/DMARC against public DNS.
  Per-domain DMARC aggregate-report stats with advice on when it is
  safe to tighten the published policy.
- **Email accounts and aliases** — including vacation auto-reply
  settings and honeypot (canary) account designation.
- **Users** — admin/member roles with per-user email-account grants
  (see [Multi-user deployments](#multi-user-deployments)).
- **Settings** — the gem's dynamic settings (limits, rates, timeouts,
  toggles, scanner addresses, retention) edited live from the UI;
  running listeners converge without a restart.
- **Security operations** — banned IPs/CIDRs enforced at every edge; a
  honeypot intelligence dashboard (canary logins and exploit probes,
  with DNS/ASN enrichment, auto-throttle, and manual ban/kick
  escalation); live IMAP and SMTP connection pages with kick; auth
  attempt, tarpit, and lockout visibility; an audit log of admin
  actions.
- **Monitoring** — a bearer-token-gated Prometheus `/metrics` endpoint
  (see [Securing /metrics](#securing-metrics)).

**Authentication**
- Password sign-in with passkeys (WebAuthn, user verification
  required) and TOTP authenticator apps as second factors. 2FA is
  **required by default** (`MAIL_ON_RAILS_REQUIRE_2FA=0` opts out).
- Step-up re-authentication for sensitive admin writes.

## Architecture

In production three containers share one image and one database: the
web role (Puma + Solid Queue behind kamal-proxy), the smtp role
(`bin/mail_server --protocols smtp`: MX + authenticated submission) and
the imap role (`bin/mail_server --protocols imap`). In development -
and in a one-container deploy - the gem's `:mail_on_rails` Puma plugin
boots the same listeners on background threads inside the web process
([config/puma.rb](config/puma.rb); `MAIL_ON_RAILS_SERVERS` picks
`smtp,imap`, one of them, or `0`). The admin UI reads the listeners'
state from the database either way (see [docs/split.md](docs/split.md)).
The listeners
carry the gem's accept-side protections: process-wide and per-IP
connection caps, a per-IP connection-rate tarpit, a per-IP lockout
after repeated failed authentications, the admin IP denylist, and
fail-closed TLS when explicit cert paths are configured.

Inbound mail is SPF/DKIM/DMARC-verified (rspamd) and virus-scanned
(ClamAV) at SMTP DATA time — infected mail is rejected with a 550
before acceptance, scanner-down gets a 451, fail closed — then routed
through Action Mailbox into the database. Spam-flagged mail is filed
into Junk instead of INBOX.

The store contract the gem's servers program against is documented in
[docs/store_contract.md](docs/store_contract.md); this app uses the
gem's Active Record implementations and extends the gem's models via
its `ActiveSupport.on_load` hooks.

## Development

```sh
bin/setup          # bundle install, db:prepare, then boots the server
bin/rails server   # web + Solid Queue + SMTP + IMAP in one process
                   # (bin/dev is the same thing with debug-gem env set)
```

A dev-only Puma plugin (`:clamav_dev`) keeps a local `clamav-dev`
docker container running so virus scanning works in development too —
with no docker it logs a note and leaves scanning off.

## Tests

```sh
bin/rails test         # app suite (controllers, models, jobs, integration)
bin/rails test:system  # browser tests
bin/ci                 # full pipeline: RuboCop, Brakeman, bundler-audit,
                       # importmap audit, tests, seed replant
```

The gem's own Rails-free protocol suites (SMTP/IMAP conformance, CVE
regression classes, store contract) live in the
[gem repo](https://github.com/InfiniteLoopEnjoyer/mail_on_rails) and run
in its CI.

Virus-scanning tests run against a scripted fake clamd, so no ClamAV
install is needed; the real-engine EICAR smoke procedure and the
scanning policy live in [docs/virus_scanning.md](docs/virus_scanning.md).

## Deployment

The deploy is three Kamal roles from one image - web, smtp, imap - plus
PostgreSQL, rspamd, ClamAV and certbot accessories (one all-in-one role
is still supported; see [docs/split.md](docs/split.md)).
[config/deploy.yml](config/deploy.yml) is a sanitized template — real
deploys use a destination file (`bin/kamal deploy -d prod`). The
extraction/deploy runbook is
[docs/gem_extraction_deploy.md](docs/gem_extraction_deploy.md).

Nightly encrypted `pg_dump` backups land on the persistent volume;
restore and offsite-copy procedures are in
[docs/backups.md](docs/backups.md). Pen-testing notes and the deferred
findings list are in [docs/pen_testing.md](docs/pen_testing.md).

## Deliverability

If mail to Outlook/Hotmail/Office365 addresses bounces, Hetzner's
[Microsoft blacklist guide](https://docs.hetzner.com/robot/dedicated-server/troubleshooting/microsoft-blacklist)
is a useful walkthrough regardless of who hosts your server: it covers
the two separate Microsoft blacklists (consumer OLC — bounce codes
S3140/S3150 — versus Office365), the delisting form and escalation path
for each (OLC: <https://olcsupport.office.com/>, Office365:
<https://sender.office.com/>), and how to
enroll your IP in SNDS (reputation monitoring) and
JMRP (Microsoft's junk-mail feedback loop). The per-domain `fbl@` and
`jmrp@` addresses this server provisions are where JMRP/ARF complaint
reports should be pointed — they're ingested automatically and feed the
outbound suppression list.

## Securing /metrics

The Prometheus endpoint is bearer-token gated (`METRICS_TOKEN`; when the
variable is unset the route answers 404). The token alone shouldn't be
the only wall: set `METRICS_ALLOW_IPS` (comma-separated IPs/CIDRs) so the
app itself 404s any caller that isn't your scraper, and additionally
scrape over a private network/VPN or restrict the HTTPS port to the
scraper's address at the droplet/cloud-firewall layer (kamal-proxy has no
per-path ACLs). Rotate `METRICS_TOKEN` periodically — update the deploy
secret and the scraper config, then redeploy.

When rspamd is configured, `/metrics` includes `mail_on_rails_rspamd_up`.
Alert on it: authenticated submission **fails open** when rspamd is down
(deliberately — an outage must not block all outbound mail), so
`rspamd_up == 0` combined with climbing outbound volume is the signature
of a compromised account spamming unchecked.

## Multi-user deployments

Web users have one of two roles. **Admins** see and manage everything —
domains, accounts, users, server settings. **Members** see only the
email accounts an admin has granted them (browse, search, compose,
manage folders); every admin surface redirects them away, and grants are
edited from the user's page. Users existing before the RBAC migration
were made admins; new users default to member.

RBAC governs the web UI only: IMAP/SMTP clients authenticate with the
email account's own password, so protocol-level access to a mailbox is
still decided by who holds that account's mail password.

An admin login can still reach every account and server-wide setting,
which is why 2FA enrollment is required by default: users without a
second factor are parked on 2FA enrollment (authenticator app or
passkey) and can't reach anything else until one is registered. Setting
`MAIL_ON_RAILS_REQUIRE_2FA=0` opts out; don't do that on any deployment
with more than one user.

## Roadmap

Web UI, roughly by value:

- [x] **Roles / authorization (RBAC)** — shipped as a two-tier model
  (simpler than the operator / mail admin / read-only sketch): admins
  keep full control, members are scoped to per-user email-account
  grants, and every destructive/server-wide action (domain delete, user
  delete, DNS publish, settings) is admin-only. See "Multi-user
  deployments" above. Possible follow-ups: a read-only tier.
- [ ] **Per-account server-side filing rules** — inbound filtering is
  global only (rspamd, DMARC); no per-user "file sender X into folder Y"
  (Sieve or a simpler home-grown rule table acted on in the mailroom).
- [ ] **Attachments on draft autosave** — composer file attachments travel
  with the send only; drafts persist the body (including rich HTML) but
  not the attached files, so a draft opened on another device loses them.
- [ ] **Inline images in the composer** — Lexxy's editor attachments are
  disabled; files go through the plain MIME attachment input. Pasting or
  uploading images as `cid:` parts in the HTML body is not supported.
- [ ] **Web Push for new mail** — the PWA service worker skeleton exists
  but is unused; clients must poll / IMAP IDLE.
- [ ] **Substring / prefix full-text search** — FTS matches whole words
  (the Dovecot trade-off — documented in `docs/store_contract.md`);
  queries the index can't express, and stores without `search_text`,
  keep the RFC-exact substring scan.

Protocol/delivery (implemented in the gem, tracked here because this
deploy is where they'd land):

- [ ] **ARC chain validation (RFC 8617)** — `ArcSealer` can seal a
  message as instance 1 (`cv=none`) with the domain's DKIM key, but
  nothing forwards mail today, so it is unwired groundwork for the
  filing-rules roadmap item's forward action. Extending an *existing*
  chain honestly (`cv=pass`, instance N+1) additionally needs an ARC
  chain validator, which does not exist yet.
- [ ] **DANE-TA name checks against TLSA base domain aliases** — DANE
  verification implements both usable usages (DANE-EE(3) ignoring
  name/expiry per RFC 7671 §5.1, DANE-TA(2) with chain, name and
  validity checks), but only matches the MX hostname itself, not the
  full RFC 7672 §3.2.3 candidate-name set (CNAME-expanded names,
  next-hop domain). Rarely load-bearing; noted for completeness.

Operations:

- [ ] **Offsite backups** — nightly `pg_dump` lands on the persistent
  volume; getting copies off the machine is still a manual runbook
  ([docs/backups.md](docs/backups.md)), not an automated push.

Already in place (not TODO):

- **PostgreSQL-backed queuing** — Solid Queue plus the
  `smtp_outbound_messages` retry/backoff table.
- **Verified outbound TLS** — DANE (RFC 7672: DNSSEC-secure TLSA
  records make TLS mandatory and pin the certificate chain, no
  cleartext fallback; needs a DNSSEC-validating resolver,
  `MAIL_ON_RAILS_DANE=0` disables) and MTA-STS (RFC 8461: recipient
  policies are fetched, cached for their `max_age`, and in enforce mode
  restrict delivery to policy-matched MX hosts over WebPKI-verified
  TLS; `MAIL_ON_RAILS_MTA_STS=0` disables), with every attempt's TLS
  outcome recorded.
- **TLS-RPT** (RFC 8460) — daily reports mailed to recipient domains
  that publish a `_smtp._tls` rua; reports for our own domains are
  ingested at `tls-rpt@`.
- **A configurable published MTA-STS mode** —
  `MAIL_ON_RAILS_MTA_STS_MODE`, `testing` by default; flip to `enforce`
  once TLS-RPT comes back clean and the policy id self-bumps on the
  next DNS publish.
- **SPF/DKIM/DMARC verification** of inbound mail (rspamd) and **virus
  scanning** (ClamAV, consulted at SMTP DATA time so infected mail is
  rejected before acceptance; authenticated writes that fail open
  during a scanner outage are swept hourly by
  `RescanUnscannedMessagesJob` until every `unscanned` row has a real
  verdict).
- **Spam-action routing** — rspamd-flagged mail is filed into Junk
  instead of INBOX, with mark/unmark spam in the web UI.
- **Outbound DKIM signing** plus the SMTP-side abuse tripwires: send
  quota, rspamd DATA gate, IP/range bans enforced at every edge.
- **IMAP/SMTP accept-side parity** — per-IP connection caps,
  connection-rate tarpit and auth lockout on both protocols, from the
  gem's shared `netserv` scaffolding.
- **The RFC 3834-hardened vacation responder** — replies go to the
  validated envelope return path with a null envelope sender, claim
  keys are case/`+tag`-normalized, quota-exhausted attempts don't burn
  the correspondent's weekly slot, and the claim table is pruned daily.
- **Dynamic domain management** — the Domains admin UI creates/removes
  hosted domains live with per-domain DKIM keys, published-record
  display, and live `DnsCheck` verification.
- **Two-factor auth** — passkeys + TOTP, required by default.
- **DMARC monitoring** — aggregate reports mailed to each domain's
  auto-created `dmarc@` account are virus-scanned, sender-verified,
  parsed, and summarized into per-domain alignment stats with advice on
  when it is safe to tighten the published policy.

## License

MIT.
