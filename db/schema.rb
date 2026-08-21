# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_20_070000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "action_mailbox_inbound_emails", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "message_checksum", null: false
    t.string "message_id", null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["message_id", "message_checksum"], name: "index_action_mailbox_inbound_emails_uniqueness", unique: true
  end

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "audit_events", force: :cascade do |t|
    t.string "action", null: false
    t.datetime "created_at", null: false
    t.jsonb "details", default: {}, null: false
    t.string "ip"
    t.bigint "subject_id"
    t.string "subject_label"
    t.string "subject_type"
    t.string "user_email", null: false
    t.bigint "user_id"
    t.index ["created_at"], name: "index_audit_events_on_created_at"
    t.index ["subject_type", "subject_id"], name: "index_audit_events_on_subject_type_and_subject_id"
    t.index ["user_id"], name: "index_audit_events_on_user_id"
  end

  create_table "email_account_users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "email_account_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["email_account_id"], name: "index_email_account_users_on_email_account_id"
    t.index ["user_id", "email_account_id"], name: "index_email_account_users_on_user_id_and_email_account_id", unique: true
    t.index ["user_id"], name: "index_email_account_users_on_user_id"
  end

  create_table "mail_on_rails_auth_attempts", force: :cascade do |t|
    t.boolean "account_exists", default: false, null: false
    t.integer "attempt_count", default: 1, null: false
    t.datetime "created_at", null: false
    t.string "ip"
    t.datetime "occurred_at", null: false
    t.string "outcome", null: false
    t.boolean "rollup", default: false, null: false
    t.string "source", null: false
    t.datetime "updated_at", null: false
    t.string "username"
    t.index ["account_exists", "occurred_at"], name: "idx_on_account_exists_occurred_at_4c65b55b3c"
    t.index ["ip", "occurred_at"], name: "index_mail_on_rails_auth_attempts_on_ip_and_occurred_at"
    t.index ["ip", "source", "occurred_at"], name: "index_auth_attempts_on_rollup_key", unique: true, where: "rollup"
    t.index ["occurred_at"], name: "index_mail_on_rails_auth_attempts_on_occurred_at"
    t.index ["username"], name: "index_mail_on_rails_auth_attempts_on_username"
  end

  create_table "mail_on_rails_auth_throttles", force: :cascade do |t|
    t.datetime "blocked_until"
    t.datetime "created_at", null: false
    t.integer "failure_count", default: 0, null: false
    t.string "key", null: false
    t.string "scope", null: false
    t.datetime "updated_at", null: false
    t.datetime "window_started_at", null: false
    t.index ["scope", "key"], name: "index_mail_on_rails_auth_throttles_on_scope_and_key", unique: true
    t.index ["window_started_at"], name: "index_mail_on_rails_auth_throttles_on_window_started_at"
  end

  create_table "mail_on_rails_banned_ips", force: :cascade do |t|
    t.string "cidr", null: false
    t.datetime "created_at", null: false
    t.string "note"
    t.string "source", default: "manual", null: false
    t.datetime "updated_at", null: false
    t.index ["cidr"], name: "index_mail_on_rails_banned_ips_on_cidr", unique: true
    t.index ["source"], name: "index_mail_on_rails_banned_ips_on_source"
  end

  create_table "mail_on_rails_bimi_indicators", force: :cascade do |t|
    t.datetime "checked_at"
    t.datetime "created_at", null: false
    t.string "domain", null: false
    t.string "error"
    t.boolean "evidence", default: false, null: false
    t.string "status", default: "pending", null: false
    t.text "svg"
    t.datetime "updated_at", null: false
    t.index ["checked_at"], name: "index_bimi_indicators_on_checked_at"
    t.index ["domain"], name: "index_bimi_indicators_on_domain", unique: true
  end

  create_table "mail_on_rails_closed_connections", force: :cascade do |t|
    t.datetime "closed_at", null: false
    t.datetime "connected_at"
    t.integer "connection_count", default: 1, null: false
    t.datetime "created_at", null: false
    t.float "duration_seconds"
    t.string "final_state"
    t.string "helo"
    t.string "ip"
    t.integer "messages"
    t.integer "port"
    t.string "protocol", null: false
    t.string "role"
    t.boolean "rollup", default: false, null: false
    t.float "tarpit_seconds"
    t.boolean "tls", default: false, null: false
    t.bigint "transcript_id"
    t.datetime "updated_at", null: false
    t.string "username"
    t.index ["closed_at"], name: "index_mail_on_rails_closed_connections_on_closed_at"
    t.index ["protocol", "closed_at"], name: "idx_on_protocol_closed_at_305bc62ee1"
    t.index ["protocol", "ip", "closed_at"], name: "idx_on_protocol_ip_closed_at_4886299b1c"
    t.index ["protocol", "ip", "closed_at"], name: "index_closed_connections_on_rollup_key", unique: true, where: "rollup"
  end

  create_table "mail_on_rails_dmarc_aggregate_events", force: :cascade do |t|
    t.string "disposition", default: "none", null: false
    t.boolean "dkim_aligned", default: false, null: false
    t.string "dkim_results"
    t.string "envelope_from"
    t.string "from_domain"
    t.datetime "occurred_at", null: false
    t.string "override_reason"
    t.string "policy_adkim"
    t.string "policy_aspf"
    t.string "policy_domain", null: false
    t.string "policy_p"
    t.integer "policy_pct"
    t.string "policy_sp"
    t.string "source_ip"
    t.boolean "spf_aligned", default: false, null: false
    t.string "spf_domain"
    t.string "spf_result"
    t.index ["occurred_at"], name: "index_dmarc_aggregate_events_on_occurred_at"
    t.index ["policy_domain", "occurred_at"], name: "index_dmarc_aggregate_events_on_domain_and_time"
  end

  create_table "mail_on_rails_dmarc_reports", force: :cascade do |t|
    t.datetime "begin_at", null: false
    t.integer "count", default: 1, null: false
    t.datetime "created_at", null: false
    t.string "disposition"
    t.string "dkim"
    t.bigint "domain_id", null: false
    t.datetime "end_at", null: false
    t.string "report_id", null: false
    t.string "reporter", null: false
    t.string "source_ip", null: false
    t.string "spf"
    t.datetime "updated_at", null: false
    t.index ["domain_id", "begin_at"], name: "index_mail_on_rails_dmarc_reports_on_domain_id_and_begin_at"
    t.index ["domain_id", "reporter", "report_id"], name: "idx_on_domain_id_reporter_report_id_7b06aee09b"
    t.index ["domain_id"], name: "index_mail_on_rails_dmarc_reports_on_domain_id"
  end

  create_table "mail_on_rails_domains", force: :cascade do |t|
    t.text "bimi_svg"
    t.datetime "created_at", null: false
    t.text "dkim_next_private_key"
    t.string "dkim_next_selector"
    t.text "dkim_private_key"
    t.datetime "dkim_retired_at"
    t.string "dkim_retired_selector"
    t.datetime "dkim_rotated_at"
    t.string "dkim_selector"
    t.datetime "dns_checked_at"
    t.jsonb "dns_checks"
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_mail_on_rails_domains_on_name", unique: true
  end

  create_table "mail_on_rails_email_accounts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.boolean "honeypot", default: false, null: false
    t.boolean "mailing_list", default: false, null: false
    t.string "name"
    t.string "password_digest", null: false
    t.bigint "quota_bytes"
    t.integer "scram_iterations"
    t.string "scram_salt"
    t.string "scram_server_key"
    t.string "scram_stored_key"
    t.datetime "updated_at", null: false
    t.bigint "used_bytes", default: 0, null: false
    t.text "vacation_body"
    t.boolean "vacation_enabled", default: false, null: false
    t.date "vacation_ends_on"
    t.date "vacation_starts_on"
    t.string "vacation_subject"
    t.index ["email"], name: "index_mail_on_rails_email_accounts_on_email", unique: true
  end

  create_table "mail_on_rails_email_aliases", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.bigint "email_account_id", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_mail_on_rails_email_aliases_on_email", unique: true
    t.index ["email_account_id"], name: "index_mail_on_rails_email_aliases_on_email_account_id"
  end

  create_table "mail_on_rails_email_messages", force: :cascade do |t|
    t.string "auth_results"
    t.string "authenticated_as"
    t.text "body_text"
    t.datetime "created_at", null: false
    t.string "email_object_id"
    t.text "flags", default: "[]", null: false
    t.string "from_address"
    t.string "in_reply_to"
    t.datetime "internal_date", null: false
    t.integer "mailbox_id", null: false
    t.string "message_id"
    t.bigint "modseq", default: 1, null: false
    t.binary "raw", null: false
    t.text "references_ids"
    t.string "scan_status"
    t.virtual "search_vector", type: :tsvector, as: "to_tsvector('simple'::regconfig, ((((((\"left\"((COALESCE(subject, ''::character varying))::text, 10000) || ' '::text) || \"left\"((COALESCE(from_address, ''::character varying))::text, 1000)) || ' '::text) || \"left\"(COALESCE(to_addresses, ''::text), 10000)) || ' '::text) || \"left\"(COALESCE(body_text, ''::text), 200000)))", stored: true
    t.integer "size", default: 0, null: false
    t.string "spam_action"
    t.float "spam_score"
    t.float "spam_threshold"
    t.string "subject"
    t.string "thread_id"
    t.text "to_addresses"
    t.integer "uid", null: false
    t.datetime "updated_at", null: false
    t.string "virus_name"
    t.index ["mailbox_id", "internal_date"], name: "idx_on_mailbox_id_internal_date_0cee64626d"
    t.index ["mailbox_id", "message_id"], name: "idx_on_mailbox_id_message_id_78c24fbb92"
    t.index ["mailbox_id", "thread_id"], name: "index_mail_on_rails_email_messages_on_mailbox_id_and_thread_id"
    t.index ["mailbox_id", "uid"], name: "index_mail_on_rails_email_messages_on_mailbox_id_and_uid", unique: true
    t.index ["mailbox_id"], name: "index_mail_on_rails_email_messages_on_mailbox_id"
    t.index ["message_id"], name: "index_mail_on_rails_email_messages_on_message_id"
    t.index ["scan_status"], name: "index_email_messages_on_unscanned", where: "((scan_status)::text = 'unscanned'::text)"
    t.index ["search_vector"], name: "index_mail_on_rails_email_messages_on_search_vector", using: :gin
  end

  create_table "mail_on_rails_expunged_messages", force: :cascade do |t|
    t.bigint "mailbox_id", null: false
    t.bigint "modseq", null: false
    t.bigint "uid", null: false
    t.index ["mailbox_id", "modseq"], name: "index_mail_on_rails_expunged_messages_on_mailbox_id_and_modseq"
    t.index ["mailbox_id"], name: "index_mail_on_rails_expunged_messages_on_mailbox_id"
  end

  create_table "mail_on_rails_honeypot_events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "enrichment"
    t.string "helo"
    t.string "ip"
    t.datetime "occurred_at", null: false
    t.integer "port"
    t.string "protocol", null: false
    t.string "response"
    t.string "signature"
    t.text "transcript"
    t.string "trigger", null: false
    t.datetime "updated_at", null: false
    t.string "username"
    t.index ["ip", "occurred_at"], name: "index_honeypot_events_on_ip_and_occurred_at"
    t.index ["occurred_at"], name: "index_honeypot_events_on_occurred_at"
    t.index ["trigger"], name: "index_honeypot_events_on_trigger"
  end

  create_table "mail_on_rails_ip_enrichments", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "enrichment"
    t.string "ip", null: false
    t.datetime "looked_up_at"
    t.datetime "requested_at"
    t.datetime "updated_at", null: false
    t.index ["ip"], name: "index_ip_enrichments_on_ip", unique: true
    t.index ["updated_at"], name: "index_ip_enrichments_on_updated_at"
  end

  create_table "mail_on_rails_mailboxes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "email_account_id", null: false
    t.bigint "highest_modseq", default: 1, null: false
    t.string "name", null: false
    t.bigint "tombstone_floor", default: 0, null: false
    t.integer "uid_next", default: 1, null: false
    t.integer "uid_validity", null: false
    t.datetime "updated_at", null: false
    t.index ["email_account_id", "name"], name: "index_mail_on_rails_mailboxes_on_email_account_id_and_name", unique: true
    t.index ["email_account_id"], name: "index_mail_on_rails_mailboxes_on_email_account_id"
  end

  create_table "mail_on_rails_mta_sts_policies", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "domain", null: false
    t.datetime "fetched_at", null: false
    t.integer "max_age", null: false
    t.string "mode", null: false
    t.text "mx_patterns", null: false
    t.string "sts_id", null: false
    t.datetime "updated_at", null: false
    t.index ["domain"], name: "index_mail_on_rails_mta_sts_policies_on_domain", unique: true
  end

  create_table "mail_on_rails_session_transcripts", force: :cascade do |t|
    t.string "close_reason"
    t.datetime "closed_at", null: false
    t.datetime "connected_at"
    t.datetime "created_at", null: false
    t.string "helo"
    t.string "ip"
    t.integer "port"
    t.string "protocol", null: false
    t.text "transcript"
    t.datetime "updated_at", null: false
    t.string "username"
    t.index ["closed_at"], name: "index_session_transcripts_on_closed_at"
  end

  create_table "mail_on_rails_settings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.string "value"
    t.index ["key"], name: "index_mail_on_rails_settings_on_key", unique: true
  end

  create_table "mail_on_rails_smtp_outbound_messages", force: :cascade do |t|
    t.integer "attempts", default: 0, null: false
    t.datetime "created_at", null: false
    t.binary "data", null: false
    t.datetime "delay_notified_at"
    t.string "dsn_envid"
    t.string "dsn_notify"
    t.string "dsn_orcpt"
    t.string "dsn_ret"
    t.text "last_error"
    t.string "mail_from", null: false
    t.datetime "next_attempt_at", null: false
    t.string "recipient", null: false
    t.boolean "requiretls", default: false, null: false
    t.datetime "sent_at"
    t.boolean "smtputf8", default: false, null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["status", "next_attempt_at"], name: "idx_on_status_next_attempt_at_d338e4cede"
  end

  create_table "mail_on_rails_suppressed_recipients", force: :cascade do |t|
    t.integer "complaints_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "feedback_type"
    t.datetime "last_complaint_at"
    t.string "reporter"
    t.string "sender"
    t.datetime "updated_at", null: false
    t.index ["email", "sender"], name: "index_suppressed_recipients_on_email_and_sender", unique: true
    t.index ["email"], name: "index_suppressed_recipients_on_email"
  end

  create_table "mail_on_rails_tls_rpt_events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "failure_detail"
    t.datetime "occurred_at", null: false
    t.string "policy_domain", null: false
    t.string "policy_type", null: false
    t.string "receiving_mx"
    t.string "result_type"
    t.datetime "updated_at", null: false
    t.index ["occurred_at"], name: "index_mail_on_rails_tls_rpt_events_on_occurred_at"
    t.index ["policy_domain", "occurred_at"], name: "idx_on_policy_domain_occurred_at_00cb91e4bc"
  end

  create_table "mail_on_rails_tls_rpt_reports", force: :cascade do |t|
    t.datetime "begin_at", null: false
    t.datetime "created_at", null: false
    t.bigint "domain_id", null: false
    t.datetime "end_at", null: false
    t.integer "failure_count", default: 0, null: false
    t.jsonb "failure_details", default: [], null: false
    t.string "policy_type", null: false
    t.string "report_id", null: false
    t.string "reporter", null: false
    t.integer "success_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["domain_id", "begin_at"], name: "index_mail_on_rails_tls_rpt_reports_on_domain_id_and_begin_at"
    t.index ["domain_id", "reporter", "report_id"], name: "idx_on_domain_id_reporter_report_id_deaa9d0ef1"
    t.index ["domain_id"], name: "index_mail_on_rails_tls_rpt_reports_on_domain_id"
    t.index ["end_at"], name: "index_mail_on_rails_tls_rpt_reports_on_end_at"
  end

  create_table "mail_on_rails_vacation_replies", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "email_account_id", null: false
    t.datetime "last_sent_at", null: false
    t.string "sender", null: false
    t.datetime "updated_at", null: false
    t.index ["email_account_id", "sender"], name: "idx_on_email_account_id_sender_79ef9997f7", unique: true
    t.index ["email_account_id"], name: "index_mail_on_rails_vacation_replies_on_email_account_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "last_active_at", null: false
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.integer "user_id", null: false
    t.index ["last_active_at"], name: "index_sessions_on_last_active_at"
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "accent", default: "crimson", null: false
    t.string "appearance", default: "system", null: false
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.bigint "otp_last_used_at"
    t.string "otp_secret"
    t.string "password_digest", null: false
    t.string "role", default: "member", null: false
    t.datetime "updated_at", null: false
    t.string "webauthn_id"
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
    t.check_constraint "role::text = ANY (ARRAY['admin'::character varying::text, 'member'::character varying::text])", name: "users_role_check"
  end

  create_table "webauthn_credentials", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "external_id", null: false
    t.string "nickname", null: false
    t.string "public_key", null: false
    t.bigint "sign_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["external_id"], name: "index_webauthn_credentials_on_external_id", unique: true
    t.index ["user_id"], name: "index_webauthn_credentials_on_user_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "audit_events", "users", on_delete: :nullify
  add_foreign_key "email_account_users", "mail_on_rails_email_accounts", column: "email_account_id"
  add_foreign_key "email_account_users", "users"
  add_foreign_key "mail_on_rails_dmarc_reports", "mail_on_rails_domains", column: "domain_id"
  add_foreign_key "mail_on_rails_email_aliases", "mail_on_rails_email_accounts", column: "email_account_id"
  add_foreign_key "mail_on_rails_email_messages", "mail_on_rails_mailboxes", column: "mailbox_id"
  add_foreign_key "mail_on_rails_expunged_messages", "mail_on_rails_mailboxes", column: "mailbox_id"
  add_foreign_key "mail_on_rails_mailboxes", "mail_on_rails_email_accounts", column: "email_account_id"
  add_foreign_key "mail_on_rails_tls_rpt_reports", "mail_on_rails_domains", column: "domain_id"
  add_foreign_key "mail_on_rails_vacation_replies", "mail_on_rails_email_accounts", column: "email_account_id"
  add_foreign_key "sessions", "users"
  add_foreign_key "webauthn_credentials", "users"
end
