# Security review — remediation status

The original review (kept as `todo.txt`) found no critical application-layer
bugs; the residual risk was account-hardening gaps, a few availability-vs-security
defaults, and deployment config. Every finding was verified against current code
and then resolved, made configurable, or explicitly accepted with its mitigation.

## Aug 12 2026 static audit (27 findings)

A second static audit (also in `todo.txt`) of both the Rails host and the
SMTP/IMAP gem. Gem defaults stay backward-compatible; production opts into the
enforcing posture through `MailOnRails::Settings::Check` warnings plus the
`config/deploy.prod.yml` overlay (see the "Security-audit enforcement overlay"
block there). Highlights:

| ID | Finding | Resolution |
|---|---|---|
| H1 | Password rotation kept the hijacker's session | Rotating your own password now requires step-up and destroys **every** session (this one included), forcing re-login. `UsersController#generate_password`. |
| H2 | Mailroom trusted edge-stamped headers on any InboundEmail | The SMTP edge now HMAC-**seals** the stamped message (`MailOnRails::IngressSeal`); the mailroom verifies it and, under `MAILROOM_REQUIRE_SEAL`, drops unsealed mail. Key derived from `secret_key_base`. |
| H3 | DANE trusted the resolver AD bit blindly | The AD bit counts only from a loopback resolver or one listed in `MAIL_ON_RAILS_DANE_TRUSTED_RESOLVERS`; otherwise DANE downgrades to MTA-STS/opportunistic. `SenderAuth::Dns`. (Superseded 2026-08-17: DNSSEC is now validated in-process by `MailOnRails::Dnssec::Resolver`; no resolver's AD bit is consulted and the setting is retired.) |
| H4 | Self-signed certs minted `CA:TRUE` | Now `CA:FALSE` + `keyUsage`/`extendedKeyUsage=serverAuth`. `smtp/tls.rb`, `imap/tls.rb`. |
| M1 | 2FA enrollment lacked step-up | TOTP `new`/`create` and passkey `options`/`create` are gated; sign-in opens the window so first-run setup is not re-prompted. |
| M2 | Privileged admin writes lacked step-up | `settings#update`, `users` create/update/destroy/generate_password, `domains` create/destroy/publish_dns gated. |
| M3/M4 | Opportunistic outbound TLS; smarthost AUTH over unverified TLS | New `smtp_outbound_require_verified_tls` and `smarthost_tls` (opportunistic/starttls/smtps); Settings::Check warns when smarthost creds ride opportunistic. |
| M5/M6/M7 | DMARC/MTA-STS/rspamd fail-open defaults | Defaults unchanged; Settings::Check warns in production; overlay flips after soak. |
| M8 | Backup wrote plaintext without a key | Production without `DB_BACKUP_ENCRYPTION_KEY` now **fails the job** unless `DB_BACKUP_ALLOW_UNENCRYPTED=1`. |
| M9 | Admin-tunable scanner addresses (SSRF) | `smtp_clamav_addr`/`smtp_rspamd_addr` validate shape and reject link-local/metadata literals. |
| M10 | Throttle knobs could be zeroed | `min: 1` on the four `auth_*` failure/block knobs. |
| M11 | SCRAM username enumeration + salt disclosure | Unknown accounts get deterministic **decoy** verifier material; the exchange is byte-identical and fails only at the proof. |
| M12 | Quarantine FETCHable over IMAP | Quarantine is invisible to every by-name IMAP op (`ImapBackend`), not just LIST. |
| M13 | Spamhaus DROP fetch unbounded | Streamed with timeouts and a 10 MB cap. |
| M14 | Storage-quota TOCTOU | Check + create run under an account row lock (`EmailMessage.deliver_raw`). |
| M15 | Export/download not audited | `mailbox.export`, `message.download`, `message.attachment` audit events. |
| L3 | TOTP burn race | `User#verify_otp` runs verify+burn under a row lock. |
| L4 | Attachment Content-Type from MIME | Served from an allowlist, else `application/octet-stream`. |
| L5 | Filter params gaps | Added `:code`, `:credential`, `:authorization`. |
| L6 | No absolute session cap | `MAIL_ON_RAILS_SESSION_MAX_LIFETIME` (default 30d) bounds a sliding session. |
| L2 | Metrics allowlist optional | Production boot warns when `METRICS_TOKEN` is set without `METRICS_ALLOW_IPS`. |
| L7 | rspamd password over cleartext HTTP | Settings::Check warns. |
| L8 | Bind defaults `0.0.0.0` | Kept (containers need it); Settings::Check warns in production. |
| L1 | CSP `style-src 'unsafe-inline'` | **Deferred, accepted.** Fully removing it means serving the sanitized mail body from a separate origin/endpoint with its own CSP — an architecture change against a low residual (the body already renders in a script-less, same-origin-less sandboxed iframe atop Loofah/CSS sanitization). Tracked for a future pass. |

## High

| Finding | Status |
|---|---|
| 2FA removable with only a session cookie | **Fixed.** Removing TOTP or a passkey now requires step-up re-auth (password or a current second factor) within a 10-minute window — `Reauthentication` concern + `ReauthenticationsController`, gating `TwoFactor::Totp#destroy` and `TwoFactor::Passkeys#destroy`. |
| TLS private key world-readable (0644) | **Fixed.** The certbot deploy-hook now `chmod 0600`s privkeys (certbot runs as the app's uid 1000, so owner-only suffices). `config/deploy.prod.yml`. |

## Medium

| Finding | Status |
|---|---|
| 2FA mandate opt-in | **Enabled.** `MAIL_ON_RAILS_REQUIRE_2FA=1` set in `config/deploy.prod.yml`. |
| Composer CRLF / header injection | **Fixed.** `ComposedEmail` rejects CR/LF in subject/to/cc/message_id/in_reply_to/references (`headers_free_of_crlf`), defense-in-depth over the Mail gem's encoding. |
| rspamd fail-open on submission | **Made configurable.** New dynamic setting `smtp_rspamd_fail_closed` (default off, preserving today's behavior) refuses authenticated submission (SMTP 451 / composer error) when rspamd is unreachable. Inbound stays fail-open (rejecting accepted mail would be backscatter). |
| CSP `style-src 'unsafe-inline'` | **Accepted with mitigations, documented.** Inline styles cannot execute script; `script-src` carries no unsafe-inline (self + nonce), and untrusted mail renders in an iframe sandboxed without `allow-scripts`/`allow-same-origin`. Removing it fully would require serving the mail body from its own `src` endpoint — deferred against a low residual. See `config/initializers/content_security_policy.rb`. |
| WEB_HOST unset → silent localhost | **Fixed.** Production boot now fails fast when `MAIL_ON_RAILS_WEB_HOST` is blank (`config/environments/production.rb`); the localhost fallbacks are gone and host authorization is always pinned. |
| DMARC SMTP rejection off by default | **Now a live toggle.** `smtp_dmarc_enforce` / `mailroom_dmarc_enforce` are dynamic settings — enable from the admin Settings page after monitoring. Off remains the intended rollout default. |
| rspamd over plain HTTP | **Deployment choice.** `smtp_rspamd_addr` accepts `https://…`; use it if rspamd ever leaves loopback. |
| DB backups unencrypted by default | **Enabled.** `DB_BACKUP_ENCRYPTION_KEY` wired as a Kamal secret (generated into the gitignored `.env`); dumps are AES-256-GCM. The key lives on the deploy machine, not the droplet — **escrow it offsite**. |

## Low / Info

| Finding | Status |
|---|---|
| Session cookie no explicit `secure` | **Fixed.** `secure: Rails.env.production?` set explicitly (was relying on `force_ssl`). |
| WebAuthn `user_verification: "preferred"` | **Fixed.** Now `"required"` on registration and login (and step-up). Authenticators without user verification are rejected; password + TOTP remain as recovery. |
| Unscoped `EmailAccount.find` in aliases | **Fixed.** Scoped through `accessible_email_accounts`, matching every other controller. |
| IMAP lacks an absolute session reaper | **Added, off by default.** `imap_session_seconds` (default 0) wires the generic reaper to IMAP; IDLE is long-lived, so operators opt in with a generous cap. |
| Weak dev seed passwords | **Guarded.** `db/seeds.rb` aborts if run in production. |
| Pending TOTP secret in session cookie | **Accepted.** The candidate secret sits in the encrypted, signed, short-lived session and is useless until confirmed; a server-side table adds a migration for negligible gain. |
| Raw SVG QR output | **Accepted (unchanged).** Intentional; Brakeman ignore documents it. |
| Metrics endpoint | **Secure by default (unchanged).** `/metrics` 404s until `METRICS_TOKEN` is set; enabling it is observability, not hardening. Add `METRICS_ALLOW_IPS` alongside a token if scraped. |

## Tests added

- `test/controllers/reauthentications_controller_test.rb` — step-up via password / TOTP / passkey, throttling, and the gate on 2FA removal.
- WebAuthn UV-required cases in the passkeys and challenges controller tests.
- `ComposedEmail` header-injection and rspamd-fail-closed cases.
- Envelope-only routing: a forged To/Cc/Bcc recipient in DATA receives nothing (`test/mailboxes/mailroom_mailbox_test.rb`).
- Gem: IMAP session-lifetime reaper (`test/imap/session_lifetime_test.rb`) and SMTP submission fail-closed (`test/smtp/submission_spam_test.rb`).
