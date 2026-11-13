-- DB1 schema catalog snapshot generated read-only from Supabase Primary (2026-11-14).
-- Contains structure only: no row data, user credentials, tokens, service-role keys, or secret values.
-- This is NOT a Supabase replacement runtime and is NOT approved for production cutover.
-- Review the auth.users stub and all RLS/trigger/function ports before applying to the Redmi server.

BEGIN;
CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS private;
CREATE SCHEMA IF NOT EXISTS reporting_private;

-- Minimal local identity table only; Supabase Auth user/password records are not exported.
CREATE TABLE IF NOT EXISTS auth.users (
  id uuid PRIMARY KEY,
  email text UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS "private"."admin_feature_settings" (
  "feature_key" text NOT NULL,
  "enabled" boolean DEFAULT false NOT NULL,
  "updated_at" timestamptz DEFAULT now() NOT NULL,
  "updated_by" uuid
);
CREATE TABLE IF NOT EXISTS "public"."admin_accounts" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "auth_user_id" uuid NOT NULL,
  "username" text NOT NULL,
  "role" text DEFAULT 'RESELLER_ADMIN'::text NOT NULL,
  "org_id" uuid,
  "status" text DEFAULT 'active'::text NOT NULL,
  "display_name" text,
  "must_change_password" boolean DEFAULT false NOT NULL,
  "created_at" timestamptz DEFAULT now() NOT NULL,
  "updated_at" timestamptz DEFAULT now() NOT NULL,
  "last_login_at" timestamptz,
  "bootstrap_claimed_at" timestamptz
);
CREATE TABLE IF NOT EXISTS "public"."admin_alert_events" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "org_id" uuid NOT NULL,
  "device_id" uuid NOT NULL,
  "source_event_id" text NOT NULL,
  "event_type" text NOT NULL,
  "message" text NOT NULL,
  "payload" jsonb DEFAULT '{}'::jsonb NOT NULL,
  "occurred_at" timestamptz DEFAULT now() NOT NULL,
  "created_at" timestamptz DEFAULT now() NOT NULL
);
CREATE TABLE IF NOT EXISTS "public"."admin_login_rate_limits" (
  "key_hash" text NOT NULL,
  "attempt_count" integer DEFAULT 0 NOT NULL,
  "window_started_at" timestamptz DEFAULT now() NOT NULL,
  "locked_until" timestamptz,
  "updated_at" timestamptz DEFAULT now() NOT NULL
);
CREATE TABLE IF NOT EXISTS "public"."admin_pc_access" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "admin_account_id" uuid NOT NULL,
  "device_id" uuid NOT NULL,
  "created_at" timestamptz DEFAULT now() NOT NULL
);
CREATE TABLE IF NOT EXISTS "public"."audit_logs" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "org_id" uuid NOT NULL,
  "actor_user_id" uuid,
  "actor_device_id" uuid,
  "action" text NOT NULL,
  "data_class" text DEFAULT 'audit'::text NOT NULL,
  "target_type" text,
  "target_id" text,
  "payload" jsonb DEFAULT '{}'::jsonb NOT NULL,
  "created_at" timestamptz DEFAULT now() NOT NULL
);
CREATE TABLE IF NOT EXISTS "public"."billing_control_accounts" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "auth_user_id" uuid,
  "username" text NOT NULL,
  "role" text DEFAULT 'SUPER_ADMIN'::text NOT NULL,
  "org_id" uuid NOT NULL,
  "status" text DEFAULT 'active'::text NOT NULL,
  "display_name" text,
  "must_change_password" boolean DEFAULT true NOT NULL,
  "last_login_at" timestamptz,
  "created_at" timestamptz DEFAULT now() NOT NULL,
  "updated_at" timestamptz DEFAULT now() NOT NULL,
  "password_hash" text,
  "failed_attempts" integer DEFAULT 0 NOT NULL,
  "locked_until" timestamptz
);
CREATE TABLE IF NOT EXISTS "public"."billing_control_sessions" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "billing_account_id" uuid NOT NULL,
  "token_hash" text NOT NULL,
  "created_at" timestamptz DEFAULT now() NOT NULL,
  "expires_at" timestamptz NOT NULL,
  "last_seen_at" timestamptz DEFAULT now() NOT NULL,
  "revoked_at" timestamptz
);
CREATE TABLE IF NOT EXISTS "public"."billing_transactions" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "org_id" uuid NOT NULL,
  "device_id" uuid,
  "rental_account_id" uuid,
  "transaction_type" text NOT NULL,
  "amount" numeric DEFAULT 0 NOT NULL,
  "duration_seconds" bigint DEFAULT 0 NOT NULL,
  "category" text,
  "occurred_at" timestamptz DEFAULT now() NOT NULL,
  "actor_user_id" uuid,
  "client_label" text,
  "reference" text,
  "data_class" text DEFAULT 'transaction'::text NOT NULL,
  "metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
  "source_event_id" text,
  "theme_id" uuid,
  "rental_session_id" uuid
);
CREATE TABLE IF NOT EXISTS "public"."db_route_control" (
  "id" integer NOT NULL,
  "active_target" text NOT NULL,
  "epoch" bigint DEFAULT 1 NOT NULL,
  "updated_at" timestamptz DEFAULT now() NOT NULL,
  "updated_by" uuid,
  "reason" text,
  "primary_ready" boolean DEFAULT true NOT NULL,
  "backup_ready" boolean DEFAULT false NOT NULL,
  "sync_ready" boolean DEFAULT true NOT NULL,
  "schema_version" text,
  "switch_id" uuid,
  "primary_schema_version" text,
  "backup_schema_version" text,
  "last_schema_check_at" timestamptz,
  "last_parity_check_at" timestamptz,
  "last_parity_check_note" text,
  "data_parity_ready" boolean DEFAULT false NOT NULL,
  "routing_gateway_ready" boolean DEFAULT false NOT NULL,
  "last_cutover_test_at" timestamptz,
  "cutover_test_note" text,
  "auth_parity_ready" boolean DEFAULT false NOT NULL,
  "auth_verified_user_ids" uuid[] DEFAULT '{}'::uuid[] NOT NULL,
  "sync_in_progress" boolean DEFAULT false NOT NULL,
  "sync_write_quiesce" boolean DEFAULT false NOT NULL,
  "sync_write_quiesce_at" timestamptz
);
CREATE TABLE IF NOT EXISTS "public"."db_route_coordinator_internal" (
  "id" smallint NOT NULL,
  "peer_shared_secret" text NOT NULL,
  "updated_at" timestamptz DEFAULT now() NOT NULL
);
CREATE TABLE IF NOT EXISTS "public"."db_sync_before_images" (
  "run_id" uuid NOT NULL,
  "table_name" text NOT NULL,
  "row_id" text NOT NULL,
  "project_ref" text NOT NULL,
  "captured_at" timestamptz DEFAULT now() NOT NULL,
  "before_image" jsonb NOT NULL,
  "before_hash" text NOT NULL,
  "incoming_hash" text NOT NULL
);
CREATE TABLE IF NOT EXISTS "public"."db_sync_runs" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "started_by" uuid NOT NULL,
  "started_at" timestamptz DEFAULT now() NOT NULL,
  "completed_at" timestamptz,
  "state" text DEFAULT 'running'::text NOT NULL,
  "source_ref" text DEFAULT 'wzkjpycjizexxcxrfdvr'::text NOT NULL,
  "target_ref" text DEFAULT 'xcdbipgsvohesxhxydep'::text NOT NULL,
  "summary" jsonb DEFAULT '{}'::jsonb NOT NULL
);
CREATE TABLE IF NOT EXISTS "public"."db_sync_verification" (
  "run_id" uuid NOT NULL,
  "table_name" text NOT NULL,
  "source_count" bigint NOT NULL,
  "target_count" bigint NOT NULL,
  "source_hash" text NOT NULL,
  "target_hash" text NOT NULL,
  "matched" boolean NOT NULL,
  "checked_at" timestamptz DEFAULT now() NOT NULL
);
CREATE TABLE IF NOT EXISTS "public"."device_command_logs" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "command_id" uuid NOT NULL,
  "org_id" uuid NOT NULL,
  "device_id" uuid NOT NULL,
  "status" text NOT NULL,
  "result" jsonb DEFAULT '{}'::jsonb NOT NULL,
  "created_at" timestamptz DEFAULT now() NOT NULL
);
CREATE TABLE IF NOT EXISTS "public"."device_commands" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "org_id" uuid NOT NULL,
  "device_id" uuid NOT NULL,
  "command" text NOT NULL,
  "payload" jsonb DEFAULT '{}'::jsonb NOT NULL,
  "status" text DEFAULT 'queued'::text NOT NULL,
  "created_by" uuid,
  "created_at" timestamptz DEFAULT now() NOT NULL,
  "acknowledged_at" timestamptz,
  "completed_at" timestamptz,
  "result" jsonb,
  "delivered_at" timestamptz,
  "delivery_attempts" integer DEFAULT 0 NOT NULL
);
CREATE TABLE IF NOT EXISTS "public"."device_enrollments" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "org_id" uuid NOT NULL,
  "code_hash" text NOT NULL,
  "label" text,
  "expires_at" timestamptz,
  "used_at" timestamptz,
  "created_at" timestamptz DEFAULT now() NOT NULL,
  "redeemed_device_id" uuid
);
CREATE TABLE IF NOT EXISTS "public"."device_heartbeats" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "device_id" uuid NOT NULL,
  "org_id" uuid NOT NULL,
  "received_at" timestamptz DEFAULT now() NOT NULL,
  "app_version" text,
  "metadata" jsonb DEFAULT '{}'::jsonb NOT NULL
);
CREATE TABLE IF NOT EXISTS "public"."device_pairing_rate_limits" (
  "key_hash" text NOT NULL,
  "attempt_count" integer DEFAULT 0 NOT NULL,
  "window_started_at" timestamptz DEFAULT now() NOT NULL,
  "locked_until" timestamptz,
  "updated_at" timestamptz DEFAULT now() NOT NULL
);
CREATE TABLE IF NOT EXISTS "public"."device_shutdown_schedules" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "org_id" uuid NOT NULL,
  "device_id" uuid NOT NULL,
  "schedule_id" text NOT NULL,
  "deadline_at" timestamptz NOT NULL,
  "target_device_name" text,
  "state" text DEFAULT 'pending'::text NOT NULL,
  "state_before_cancel" text,
  "created_by" uuid,
  "last_command_id" uuid,
  "last_queued_at" timestamptz,
  "retry_count" integer DEFAULT 0 NOT NULL,
  "last_message" text,
  "created_at" timestamptz DEFAULT now() NOT NULL,
  "updated_at" timestamptz DEFAULT now() NOT NULL
);
CREATE TABLE IF NOT EXISTS "public"."device_tokens" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "device_id" uuid NOT NULL,
  "token_hash" text NOT NULL,
  "created_at" timestamptz DEFAULT now() NOT NULL,
  "revoked_at" timestamptz
);
CREATE TABLE IF NOT EXISTS "public"."device_trial_requests" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "org_id" uuid NOT NULL,
  "device_id" uuid NOT NULL,
  "created_by" uuid,
  "status" text DEFAULT 'queued'::text NOT NULL,
  "command_id" uuid,
  "session_id" uuid,
  "created_at" timestamptz DEFAULT now() NOT NULL,
  "started_at" timestamptz,
  "finished_at" timestamptz,
  "result" jsonb DEFAULT '{}'::jsonb NOT NULL
);
CREATE TABLE IF NOT EXISTS "public"."devices" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "org_id" uuid NOT NULL,
  "client_id" text NOT NULL,
  "device_name" text NOT NULL,
  "status" text DEFAULT 'offline'::text NOT NULL,
  "app_version" text,
  "last_seen_at" timestamptz,
  "metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
  "created_at" timestamptz DEFAULT now() NOT NULL,
  "power_state" text DEFAULT 'unknown'::text NOT NULL,
  "last_heartbeat_at" timestamptz
);
CREATE TABLE IF NOT EXISTS "public"."org_members" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "org_id" uuid NOT NULL,
  "auth_user_id" uuid NOT NULL,
  "role" text NOT NULL,
  "created_at" timestamptz DEFAULT now() NOT NULL
);
CREATE TABLE IF NOT EXISTS "public"."organizations" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "parent_org_id" uuid,
  "name" text NOT NULL,
  "slug" text NOT NULL,
  "kind" text DEFAULT 'owner'::text NOT NULL,
  "theme_id" uuid,
  "status" text DEFAULT 'active'::text NOT NULL,
  "created_at" timestamptz DEFAULT now() NOT NULL
);
CREATE TABLE IF NOT EXISTS "public"."rental_accounts" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "org_id" uuid NOT NULL,
  "device_id" uuid,
  "code" text NOT NULL,
  "category" text DEFAULT 'reguler'::text NOT NULL,
  "remaining_seconds" bigint DEFAULT 0 NOT NULL,
  "expiry_at" timestamptz,
  "status" text DEFAULT 'active'::text NOT NULL,
  "client_label" text,
  "metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
  "updated_at" timestamptz DEFAULT now() NOT NULL,
  "created_at" timestamptz DEFAULT now() NOT NULL,
  "theme_id" uuid
);
CREATE TABLE IF NOT EXISTS "public"."rental_offline_leases" (
  "rental_account_id" uuid NOT NULL,
  "org_id" uuid NOT NULL,
  "device_id" uuid NOT NULL,
  "lease_until" timestamptz NOT NULL,
  "created_at" timestamptz DEFAULT now() NOT NULL,
  "updated_at" timestamptz DEFAULT now() NOT NULL
);
CREATE TABLE IF NOT EXISTS "public"."rental_sessions" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "org_id" uuid NOT NULL,
  "device_id" uuid,
  "rental_account_id" uuid,
  "code" text NOT NULL,
  "session_type" text DEFAULT 'rental'::text NOT NULL,
  "started_at" timestamptz NOT NULL,
  "deadline_at" timestamptz,
  "ended_at" timestamptz,
  "status" text DEFAULT 'active'::text NOT NULL,
  "last_client_at" timestamptz,
  "metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
  "source_event_id" text,
  "last_client_remaining_seconds" bigint,
  "recovery_reason" text,
  "theme_id" uuid
);
CREATE TABLE IF NOT EXISTS "public"."rental_sync_conflicts" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "org_id" uuid NOT NULL,
  "device_id" uuid NOT NULL,
  "code" text NOT NULL,
  "source_event_id" text NOT NULL,
  "reason" text NOT NULL,
  "event_payload" jsonb DEFAULT '{}'::jsonb NOT NULL,
  "created_at" timestamptz DEFAULT now() NOT NULL,
  "resolved_at" timestamptz
);
CREATE TABLE IF NOT EXISTS "public"."superadmin_access_codes" (
  "user_id" uuid NOT NULL,
  "code_hash" text NOT NULL,
  "enabled" boolean DEFAULT true NOT NULL,
  "updated_at" timestamptz DEFAULT now() NOT NULL
);
CREATE TABLE IF NOT EXISTS "public"."superadmin_audit" (
  "id" bigint NOT NULL,
  "user_id" uuid,
  "action" text NOT NULL,
  "metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
  "created_at" timestamptz DEFAULT now() NOT NULL
);
CREATE TABLE IF NOT EXISTS "public"."superadmin_sessions" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "user_id" uuid NOT NULL,
  "token_hash" text NOT NULL,
  "created_at" timestamptz DEFAULT now() NOT NULL,
  "expires_at" timestamptz NOT NULL,
  "last_used_at" timestamptz,
  "revoked_at" timestamptz
);
CREATE TABLE IF NOT EXISTS "public"."themes" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "org_id" uuid NOT NULL,
  "name" text NOT NULL,
  "brand_title" text,
  "brand_subtitle" text,
  "primary_color" text,
  "secondary_color" text,
  "card_color" text,
  "media_type" text,
  "media_url" text,
  "wallpaper_url" text,
  "logo_url" text,
  "is_active" boolean DEFAULT false NOT NULL,
  "created_at" timestamptz DEFAULT now() NOT NULL,
  "updated_at" timestamptz DEFAULT now() NOT NULL
);
CREATE TABLE IF NOT EXISTS "public"."usage_events" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "org_id" uuid NOT NULL,
  "device_id" uuid,
  "rental_session_id" uuid,
  "rental_account_id" uuid,
  "event_type" text NOT NULL,
  "data_class" text DEFAULT 'usage'::text NOT NULL,
  "occurred_at" timestamptz NOT NULL,
  "duration_seconds" bigint,
  "category" text,
  "reseller_org_id" uuid,
  "client_label" text,
  "payload" jsonb DEFAULT '{}'::jsonb NOT NULL,
  "source_event_id" text,
  "theme_id" uuid
);
CREATE TABLE IF NOT EXISTS "public"."wol_relay_commands" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "org_id" uuid NOT NULL,
  "relay_id" uuid NOT NULL,
  "target_device_id" uuid NOT NULL,
  "target_mac" text NOT NULL,
  "target_device_name" text NOT NULL,
  "status" text DEFAULT 'queued'::text NOT NULL,
  "expires_at" timestamptz NOT NULL,
  "created_by" uuid,
  "delivered_at" timestamptz,
  "packet_sent_at" timestamptz,
  "result" jsonb DEFAULT '{}'::jsonb NOT NULL,
  "created_at" timestamptz DEFAULT now() NOT NULL
);
CREATE TABLE IF NOT EXISTS "public"."wol_relay_devices" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "org_id" uuid NOT NULL,
  "relay_name" text NOT NULL,
  "installation_id" text NOT NULL,
  "token_hash" text NOT NULL,
  "app_version" text,
  "model" text,
  "status" text DEFAULT 'offline'::text NOT NULL,
  "last_seen_at" timestamptz,
  "battery_percent" integer,
  "battery_temp_c" numeric,
  "charging" boolean,
  "battery_health" text,
  "last_packet_at" timestamptz,
  "last_error" text,
  "revoked_at" timestamptz,
  "created_at" timestamptz DEFAULT now() NOT NULL,
  "updated_at" timestamptz DEFAULT now() NOT NULL,
  "is_primary" boolean DEFAULT false NOT NULL
);
CREATE TABLE IF NOT EXISTS "public"."wol_relay_enrollments" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "org_id" uuid NOT NULL,
  "code_hash" text NOT NULL,
  "expires_at" timestamptz NOT NULL,
  "used_at" timestamptz,
  "created_by" uuid,
  "created_at" timestamptz DEFAULT now() NOT NULL
);
CREATE TABLE IF NOT EXISTS "public"."wol_relay_probes" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "org_id" uuid NOT NULL,
  "relay_id" uuid NOT NULL,
  "nonce" uuid DEFAULT gen_random_uuid() NOT NULL,
  "status" text DEFAULT 'pending'::text NOT NULL,
  "requested_by" uuid,
  "requested_at" timestamptz DEFAULT now() NOT NULL,
  "expires_at" timestamptz NOT NULL,
  "responded_at" timestamptz
);
CREATE TABLE IF NOT EXISTS "reporting_private"."telegram_device_presence" (
  "device_id" uuid NOT NULL,
  "is_offline" boolean NOT NULL,
  "transition_seq" bigint DEFAULT 0 NOT NULL,
  "last_heartbeat_at" timestamptz,
  "last_transition_at" timestamptz DEFAULT now() NOT NULL,
  "last_checked_at" timestamptz DEFAULT now() NOT NULL
);
CREATE TABLE IF NOT EXISTS "reporting_private"."telegram_notification_outbox" (
  "id" bigint NOT NULL,
  "event_key" text NOT NULL,
  "event_type" text NOT NULL,
  "org_id" uuid,
  "device_id" uuid,
  "session_id" uuid,
  "occurred_at" timestamptz DEFAULT now() NOT NULL,
  "payload" jsonb DEFAULT '{}'::jsonb NOT NULL,
  "status" text DEFAULT 'pending'::text NOT NULL,
  "attempts" integer DEFAULT 0 NOT NULL,
  "next_attempt_at" timestamptz DEFAULT now() NOT NULL,
  "claimed_at" timestamptz,
  "sent_at" timestamptz,
  "last_error" text,
  "created_at" timestamptz DEFAULT now() NOT NULL
);
CREATE TABLE IF NOT EXISTS "reporting_private"."telegram_settings" (
  "id" integer NOT NULL,
  "enabled" boolean DEFAULT false NOT NULL,
  "offline_after_seconds" integer DEFAULT 180 NOT NULL,
  "daily_report_time" time without time zone DEFAULT '08:00:00'::time without time zone NOT NULL,
  "last_daily_report_date" date NOT NULL,
  "updated_at" timestamptz DEFAULT now() NOT NULL
);

-- Constraints are added after table creation so cross-table references resolve.
ALTER TABLE "private"."admin_feature_settings" ADD CONSTRAINT "admin_feature_settings_feature_key_check" CHECK (feature_key = 'free_test_10m_enabled'::text);
ALTER TABLE "private"."admin_feature_settings" ADD CONSTRAINT "admin_feature_settings_pkey" PRIMARY KEY (feature_key);
ALTER TABLE "public"."admin_accounts" ADD CONSTRAINT "admin_accounts_auth_user_id_fkey" FOREIGN KEY (auth_user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
ALTER TABLE "public"."admin_accounts" ADD CONSTRAINT "admin_accounts_auth_user_id_key" UNIQUE (auth_user_id);
ALTER TABLE "public"."admin_accounts" ADD CONSTRAINT "admin_accounts_org_id_fkey" FOREIGN KEY (org_id) REFERENCES organizations(id) ON DELETE SET NULL;
ALTER TABLE "public"."admin_accounts" ADD CONSTRAINT "admin_accounts_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."admin_accounts" ADD CONSTRAINT "admin_accounts_role_check" CHECK (role = ANY (ARRAY['SUPER_ADMIN'::text, 'RESELLER_ADMIN'::text]));
ALTER TABLE "public"."admin_accounts" ADD CONSTRAINT "admin_accounts_status_check" CHECK (status = ANY (ARRAY['active'::text, 'disabled'::text]));
ALTER TABLE "public"."admin_accounts" ADD CONSTRAINT "admin_accounts_username_key" UNIQUE (username);
ALTER TABLE "public"."admin_alert_events" ADD CONSTRAINT "admin_alert_events_device_id_fkey" FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE;
ALTER TABLE "public"."admin_alert_events" ADD CONSTRAINT "admin_alert_events_device_id_source_event_id_key" UNIQUE (device_id, source_event_id);
ALTER TABLE "public"."admin_alert_events" ADD CONSTRAINT "admin_alert_events_event_type_check" CHECK (event_type = ANY (ARRAY['session_expired'::text, 'session_stopped'::text]));
ALTER TABLE "public"."admin_alert_events" ADD CONSTRAINT "admin_alert_events_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."admin_login_rate_limits" ADD CONSTRAINT "admin_login_rate_limits_attempt_count_check" CHECK (attempt_count >= 0 AND attempt_count <= 5);
ALTER TABLE "public"."admin_login_rate_limits" ADD CONSTRAINT "admin_login_rate_limits_key_hash_check" CHECK (key_hash ~ '^[0-9a-f]{64}$'::text);
ALTER TABLE "public"."admin_login_rate_limits" ADD CONSTRAINT "admin_login_rate_limits_pkey" PRIMARY KEY (key_hash);
ALTER TABLE "public"."admin_pc_access" ADD CONSTRAINT "admin_pc_access_admin_account_id_device_id_key" UNIQUE (admin_account_id, device_id);
ALTER TABLE "public"."admin_pc_access" ADD CONSTRAINT "admin_pc_access_admin_account_id_fkey" FOREIGN KEY (admin_account_id) REFERENCES admin_accounts(id) ON DELETE CASCADE;
ALTER TABLE "public"."admin_pc_access" ADD CONSTRAINT "admin_pc_access_device_id_fkey" FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE;
ALTER TABLE "public"."admin_pc_access" ADD CONSTRAINT "admin_pc_access_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."audit_logs" ADD CONSTRAINT "audit_logs_org_id_fkey" FOREIGN KEY (org_id) REFERENCES organizations(id) ON DELETE CASCADE;
ALTER TABLE "public"."audit_logs" ADD CONSTRAINT "audit_logs_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."billing_control_accounts" ADD CONSTRAINT "billing_control_accounts_auth_user_id_fkey" FOREIGN KEY (auth_user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
ALTER TABLE "public"."billing_control_accounts" ADD CONSTRAINT "billing_control_accounts_auth_user_id_key" UNIQUE (auth_user_id);
ALTER TABLE "public"."billing_control_accounts" ADD CONSTRAINT "billing_control_accounts_org_id_fkey" FOREIGN KEY (org_id) REFERENCES organizations(id) ON DELETE CASCADE;
ALTER TABLE "public"."billing_control_accounts" ADD CONSTRAINT "billing_control_accounts_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."billing_control_accounts" ADD CONSTRAINT "billing_control_accounts_role_ck" CHECK (role = ANY (ARRAY['SUPER_ADMIN'::text, 'RESELLER_ADMIN'::text]));
ALTER TABLE "public"."billing_control_accounts" ADD CONSTRAINT "billing_control_accounts_status_ck" CHECK (status = ANY (ARRAY['active'::text, 'disabled'::text]));
ALTER TABLE "public"."billing_control_accounts" ADD CONSTRAINT "billing_control_accounts_username_key" UNIQUE (username);
ALTER TABLE "public"."billing_control_sessions" ADD CONSTRAINT "billing_control_sessions_billing_account_id_fkey" FOREIGN KEY (billing_account_id) REFERENCES billing_control_accounts(id) ON DELETE CASCADE;
ALTER TABLE "public"."billing_control_sessions" ADD CONSTRAINT "billing_control_sessions_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."billing_control_sessions" ADD CONSTRAINT "billing_control_sessions_token_hash_key" UNIQUE (token_hash);
ALTER TABLE "public"."billing_transactions" ADD CONSTRAINT "billing_transactions_data_class_check" CHECK (data_class = 'transaction'::text);
ALTER TABLE "public"."billing_transactions" ADD CONSTRAINT "billing_transactions_device_id_fkey" FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE SET NULL;
ALTER TABLE "public"."billing_transactions" ADD CONSTRAINT "billing_transactions_org_id_fkey" FOREIGN KEY (org_id) REFERENCES organizations(id) ON DELETE CASCADE;
ALTER TABLE "public"."billing_transactions" ADD CONSTRAINT "billing_transactions_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."billing_transactions" ADD CONSTRAINT "billing_transactions_rental_account_id_fkey" FOREIGN KEY (rental_account_id) REFERENCES rental_accounts(id) ON DELETE SET NULL;
ALTER TABLE "public"."billing_transactions" ADD CONSTRAINT "billing_transactions_rental_session_id_fkey" FOREIGN KEY (rental_session_id) REFERENCES rental_sessions(id) ON DELETE SET NULL;
ALTER TABLE "public"."billing_transactions" ADD CONSTRAINT "billing_transactions_theme_id_fkey" FOREIGN KEY (theme_id) REFERENCES themes(id) ON DELETE SET NULL;
ALTER TABLE "public"."billing_transactions" ADD CONSTRAINT "billing_transactions_transaction_type_check" CHECK (transaction_type = ANY (ARRAY['topup'::text, 'time_add'::text, 'refund'::text, 'adjustment'::text, 'free_test'::text, 'purchase'::text, 'other'::text]));
ALTER TABLE "public"."db_route_control" ADD CONSTRAINT "db_route_control_active_target_check" CHECK (active_target = ANY (ARRAY['primary'::text, 'backup'::text]));
ALTER TABLE "public"."db_route_control" ADD CONSTRAINT "db_route_control_epoch_check" CHECK (epoch >= 1);
ALTER TABLE "public"."db_route_control" ADD CONSTRAINT "db_route_control_id_check" CHECK (id = 1);
ALTER TABLE "public"."db_route_control" ADD CONSTRAINT "db_route_control_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."db_route_control" ADD CONSTRAINT "db_route_control_updated_by_fkey" FOREIGN KEY (updated_by) REFERENCES auth.users(id) ON DELETE SET NULL;
ALTER TABLE "public"."db_route_coordinator_internal" ADD CONSTRAINT "db_route_coordinator_internal_id_check" CHECK (id = 1);
ALTER TABLE "public"."db_route_coordinator_internal" ADD CONSTRAINT "db_route_coordinator_internal_peer_shared_secret_check" CHECK (length(peer_shared_secret) >= 64);
ALTER TABLE "public"."db_route_coordinator_internal" ADD CONSTRAINT "db_route_coordinator_internal_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."db_sync_before_images" ADD CONSTRAINT "db_sync_before_images_before_hash_check" CHECK (before_hash ~ '^[0-9a-f]{64}$'::text);
ALTER TABLE "public"."db_sync_before_images" ADD CONSTRAINT "db_sync_before_images_incoming_hash_check" CHECK (incoming_hash ~ '^[0-9a-f]{64}$'::text);
ALTER TABLE "public"."db_sync_before_images" ADD CONSTRAINT "db_sync_before_images_pkey" PRIMARY KEY (run_id, table_name, row_id);
ALTER TABLE "public"."db_sync_before_images" ADD CONSTRAINT "db_sync_before_images_project_ref_check" CHECK (project_ref = ANY (ARRAY['wzkjpycjizexxcxrfdvr'::text, 'xcdbipgsvohesxhxydep'::text]));
ALTER TABLE "public"."db_sync_before_images" ADD CONSTRAINT "db_sync_before_images_run_id_fkey" FOREIGN KEY (run_id) REFERENCES db_sync_runs(id) ON DELETE CASCADE;
ALTER TABLE "public"."db_sync_before_images" ADD CONSTRAINT "db_sync_before_images_table_name_check" CHECK (table_name ~ '^[a-z][a-z0-9_]*$'::text);
ALTER TABLE "public"."db_sync_runs" ADD CONSTRAINT "db_sync_runs_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."db_sync_runs" ADD CONSTRAINT "db_sync_runs_state_check" CHECK (state = ANY (ARRAY['running'::text, 'verified'::text, 'failed'::text]));
ALTER TABLE "public"."db_sync_verification" ADD CONSTRAINT "db_sync_verification_pkey" PRIMARY KEY (run_id, table_name);
ALTER TABLE "public"."db_sync_verification" ADD CONSTRAINT "db_sync_verification_run_id_fkey" FOREIGN KEY (run_id) REFERENCES db_sync_runs(id) ON DELETE CASCADE;
ALTER TABLE "public"."device_command_logs" ADD CONSTRAINT "device_command_logs_command_id_fkey" FOREIGN KEY (command_id) REFERENCES device_commands(id) ON DELETE CASCADE;
ALTER TABLE "public"."device_command_logs" ADD CONSTRAINT "device_command_logs_device_id_fkey" FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE;
ALTER TABLE "public"."device_command_logs" ADD CONSTRAINT "device_command_logs_org_id_fkey" FOREIGN KEY (org_id) REFERENCES organizations(id) ON DELETE CASCADE;
ALTER TABLE "public"."device_command_logs" ADD CONSTRAINT "device_command_logs_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."device_command_logs" ADD CONSTRAINT "device_command_logs_status_check" CHECK (status = ANY (ARRAY['queued'::text, 'acknowledged'::text, 'completed'::text, 'failed'::text, 'expired'::text]));
ALTER TABLE "public"."device_commands" ADD CONSTRAINT "device_commands_command_check" CHECK (command = ANY (ARRAY['restart_billing'::text, 'restart_pc'::text, 'restart'::text, 'logoff'::text, 'logout'::text, 'pause'::text, 'resume'::text, 'stop'::text, 'shutdown'::text, 'add_time'::text, 'set_theme'::text, 'refresh'::text, 'wake'::text, 'upsert_rental'::text, 'start_trial'::text, 'delete_rental'::text, 'show_admin_message'::text, 'schedule_shutdown'::text, 'cancel_shutdown_timer'::text]));
ALTER TABLE "public"."device_commands" ADD CONSTRAINT "device_commands_device_id_fkey" FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE;
ALTER TABLE "public"."device_commands" ADD CONSTRAINT "device_commands_org_id_fkey" FOREIGN KEY (org_id) REFERENCES organizations(id) ON DELETE CASCADE;
ALTER TABLE "public"."device_commands" ADD CONSTRAINT "device_commands_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."device_commands" ADD CONSTRAINT "device_commands_status_check" CHECK (status = ANY (ARRAY['queued'::text, 'acknowledged'::text, 'completed'::text, 'failed'::text, 'expired'::text]));
ALTER TABLE "public"."device_enrollments" ADD CONSTRAINT "device_enrollments_code_hash_key" UNIQUE (code_hash);
ALTER TABLE "public"."device_enrollments" ADD CONSTRAINT "device_enrollments_org_id_fkey" FOREIGN KEY (org_id) REFERENCES organizations(id) ON DELETE CASCADE;
ALTER TABLE "public"."device_enrollments" ADD CONSTRAINT "device_enrollments_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."device_enrollments" ADD CONSTRAINT "device_enrollments_redeemed_device_id_fkey" FOREIGN KEY (redeemed_device_id) REFERENCES devices(id) ON DELETE SET NULL;
ALTER TABLE "public"."device_heartbeats" ADD CONSTRAINT "device_heartbeats_device_id_fkey" FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE;
ALTER TABLE "public"."device_heartbeats" ADD CONSTRAINT "device_heartbeats_org_id_fkey" FOREIGN KEY (org_id) REFERENCES organizations(id) ON DELETE CASCADE;
ALTER TABLE "public"."device_heartbeats" ADD CONSTRAINT "device_heartbeats_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."device_pairing_rate_limits" ADD CONSTRAINT "device_pairing_rate_limits_attempt_count_check" CHECK (attempt_count >= 0 AND attempt_count <= 100);
ALTER TABLE "public"."device_pairing_rate_limits" ADD CONSTRAINT "device_pairing_rate_limits_key_hash_check" CHECK (key_hash ~ '^[0-9a-f]{64}$'::text);
ALTER TABLE "public"."device_pairing_rate_limits" ADD CONSTRAINT "device_pairing_rate_limits_pkey" PRIMARY KEY (key_hash);
ALTER TABLE "public"."device_shutdown_schedules" ADD CONSTRAINT "device_shutdown_schedules_device_id_fkey" FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE;
ALTER TABLE "public"."device_shutdown_schedules" ADD CONSTRAINT "device_shutdown_schedules_device_id_schedule_id_key" UNIQUE (device_id, schedule_id);
ALTER TABLE "public"."device_shutdown_schedules" ADD CONSTRAINT "device_shutdown_schedules_org_id_fkey" FOREIGN KEY (org_id) REFERENCES organizations(id) ON DELETE CASCADE;
ALTER TABLE "public"."device_shutdown_schedules" ADD CONSTRAINT "device_shutdown_schedules_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."device_shutdown_schedules" ADD CONSTRAINT "device_shutdown_schedules_retry_count_check" CHECK (retry_count >= 0);
ALTER TABLE "public"."device_shutdown_schedules" ADD CONSTRAINT "device_shutdown_schedules_state_check" CHECK (state = ANY (ARRAY['pending'::text, 'scheduled'::text, 'waiting_for_rental_end'::text, 'cancel_requested'::text, 'canceled'::text, 'shutdown_requested'::text, 'completed'::text, 'superseded'::text, 'target_mismatch'::text, 'error'::text]));
ALTER TABLE "public"."device_tokens" ADD CONSTRAINT "device_tokens_device_id_fkey" FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE;
ALTER TABLE "public"."device_tokens" ADD CONSTRAINT "device_tokens_device_id_key" UNIQUE (device_id);
ALTER TABLE "public"."device_tokens" ADD CONSTRAINT "device_tokens_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."device_tokens" ADD CONSTRAINT "device_tokens_token_hash_key" UNIQUE (token_hash);
ALTER TABLE "public"."device_trial_requests" ADD CONSTRAINT "device_trial_requests_command_id_fkey" FOREIGN KEY (command_id) REFERENCES device_commands(id) ON DELETE SET NULL;
ALTER TABLE "public"."device_trial_requests" ADD CONSTRAINT "device_trial_requests_created_by_fkey" FOREIGN KEY (created_by) REFERENCES auth.users(id);
ALTER TABLE "public"."device_trial_requests" ADD CONSTRAINT "device_trial_requests_device_id_fkey" FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE;
ALTER TABLE "public"."device_trial_requests" ADD CONSTRAINT "device_trial_requests_org_id_fkey" FOREIGN KEY (org_id) REFERENCES organizations(id) ON DELETE CASCADE;
ALTER TABLE "public"."device_trial_requests" ADD CONSTRAINT "device_trial_requests_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."device_trial_requests" ADD CONSTRAINT "device_trial_requests_session_id_fkey" FOREIGN KEY (session_id) REFERENCES rental_sessions(id) ON DELETE SET NULL;
ALTER TABLE "public"."device_trial_requests" ADD CONSTRAINT "device_trial_requests_status_check" CHECK (status = ANY (ARRAY['queued'::text, 'started'::text, 'failed'::text, 'cancelled'::text, 'expired'::text]));
ALTER TABLE "public"."devices" ADD CONSTRAINT "devices_org_id_client_id_key" UNIQUE (org_id, client_id);
ALTER TABLE "public"."devices" ADD CONSTRAINT "devices_org_id_fkey" FOREIGN KEY (org_id) REFERENCES organizations(id) ON DELETE CASCADE;
ALTER TABLE "public"."devices" ADD CONSTRAINT "devices_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."devices" ADD CONSTRAINT "devices_power_state_check" CHECK (power_state = ANY (ARRAY['unknown'::text, 'online'::text, 'offline'::text, 'booting'::text, 'shutting_down'::text]));
ALTER TABLE "public"."devices" ADD CONSTRAINT "devices_status_check" CHECK (status = ANY (ARRAY['online'::text, 'offline'::text, 'disabled'::text]));
ALTER TABLE "public"."org_members" ADD CONSTRAINT "org_members_org_id_auth_user_id_key" UNIQUE (org_id, auth_user_id);
ALTER TABLE "public"."org_members" ADD CONSTRAINT "org_members_org_id_fkey" FOREIGN KEY (org_id) REFERENCES organizations(id) ON DELETE CASCADE;
ALTER TABLE "public"."org_members" ADD CONSTRAINT "org_members_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."org_members" ADD CONSTRAINT "org_members_role_check" CHECK (role = ANY (ARRAY['owner'::text, 'reseller_admin'::text, 'admin'::text, 'operator'::text, 'viewer'::text]));
ALTER TABLE "public"."organizations" ADD CONSTRAINT "organizations_kind_check" CHECK (kind = ANY (ARRAY['owner'::text, 'reseller'::text]));
ALTER TABLE "public"."organizations" ADD CONSTRAINT "organizations_parent_org_id_fkey" FOREIGN KEY (parent_org_id) REFERENCES organizations(id) ON DELETE RESTRICT;
ALTER TABLE "public"."organizations" ADD CONSTRAINT "organizations_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."organizations" ADD CONSTRAINT "organizations_slug_key" UNIQUE (slug);
ALTER TABLE "public"."organizations" ADD CONSTRAINT "organizations_status_check" CHECK (status = ANY (ARRAY['active'::text, 'suspended'::text]));
ALTER TABLE "public"."rental_accounts" ADD CONSTRAINT "rental_accounts_device_id_fkey" FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE SET NULL;
ALTER TABLE "public"."rental_accounts" ADD CONSTRAINT "rental_accounts_org_id_code_key" UNIQUE (org_id, code);
ALTER TABLE "public"."rental_accounts" ADD CONSTRAINT "rental_accounts_org_id_fkey" FOREIGN KEY (org_id) REFERENCES organizations(id) ON DELETE CASCADE;
ALTER TABLE "public"."rental_accounts" ADD CONSTRAINT "rental_accounts_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."rental_accounts" ADD CONSTRAINT "rental_accounts_remaining_seconds_check" CHECK (remaining_seconds >= 0);
ALTER TABLE "public"."rental_accounts" ADD CONSTRAINT "rental_accounts_status_check" CHECK (status = ANY (ARRAY['active'::text, 'expired'::text, 'disabled'::text]));
ALTER TABLE "public"."rental_accounts" ADD CONSTRAINT "rental_accounts_theme_id_fkey" FOREIGN KEY (theme_id) REFERENCES themes(id) ON DELETE SET NULL;
ALTER TABLE "public"."rental_offline_leases" ADD CONSTRAINT "rental_offline_leases_device_id_fkey" FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE;
ALTER TABLE "public"."rental_offline_leases" ADD CONSTRAINT "rental_offline_leases_org_id_fkey" FOREIGN KEY (org_id) REFERENCES organizations(id) ON DELETE CASCADE;
ALTER TABLE "public"."rental_offline_leases" ADD CONSTRAINT "rental_offline_leases_pkey" PRIMARY KEY (rental_account_id);
ALTER TABLE "public"."rental_offline_leases" ADD CONSTRAINT "rental_offline_leases_rental_account_id_fkey" FOREIGN KEY (rental_account_id) REFERENCES rental_accounts(id) ON DELETE CASCADE;
ALTER TABLE "public"."rental_sessions" ADD CONSTRAINT "rental_sessions_device_id_fkey" FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE SET NULL;
ALTER TABLE "public"."rental_sessions" ADD CONSTRAINT "rental_sessions_org_id_fkey" FOREIGN KEY (org_id) REFERENCES organizations(id) ON DELETE CASCADE;
ALTER TABLE "public"."rental_sessions" ADD CONSTRAINT "rental_sessions_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."rental_sessions" ADD CONSTRAINT "rental_sessions_rental_account_id_fkey" FOREIGN KEY (rental_account_id) REFERENCES rental_accounts(id) ON DELETE SET NULL;
ALTER TABLE "public"."rental_sessions" ADD CONSTRAINT "rental_sessions_session_type_check" CHECK (session_type = ANY (ARRAY['rental'::text, 'free_test'::text]));
ALTER TABLE "public"."rental_sessions" ADD CONSTRAINT "rental_sessions_status_check" CHECK (status = ANY (ARRAY['active'::text, 'paused'::text, 'ended'::text, 'expired'::text]));
ALTER TABLE "public"."rental_sessions" ADD CONSTRAINT "rental_sessions_theme_id_fkey" FOREIGN KEY (theme_id) REFERENCES themes(id) ON DELETE SET NULL;
ALTER TABLE "public"."rental_sync_conflicts" ADD CONSTRAINT "rental_sync_conflicts_device_id_fkey" FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE;
ALTER TABLE "public"."rental_sync_conflicts" ADD CONSTRAINT "rental_sync_conflicts_org_id_fkey" FOREIGN KEY (org_id) REFERENCES organizations(id) ON DELETE CASCADE;
ALTER TABLE "public"."rental_sync_conflicts" ADD CONSTRAINT "rental_sync_conflicts_org_id_source_event_id_key" UNIQUE (org_id, source_event_id);
ALTER TABLE "public"."rental_sync_conflicts" ADD CONSTRAINT "rental_sync_conflicts_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."superadmin_access_codes" ADD CONSTRAINT "superadmin_access_codes_pkey" PRIMARY KEY (user_id);
ALTER TABLE "public"."superadmin_access_codes" ADD CONSTRAINT "superadmin_access_codes_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
ALTER TABLE "public"."superadmin_audit" ADD CONSTRAINT "superadmin_audit_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."superadmin_audit" ADD CONSTRAINT "superadmin_audit_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;
ALTER TABLE "public"."superadmin_sessions" ADD CONSTRAINT "superadmin_sessions_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."superadmin_sessions" ADD CONSTRAINT "superadmin_sessions_token_hash_key" UNIQUE (token_hash);
ALTER TABLE "public"."superadmin_sessions" ADD CONSTRAINT "superadmin_sessions_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
ALTER TABLE "public"."themes" ADD CONSTRAINT "themes_org_id_fkey" FOREIGN KEY (org_id) REFERENCES organizations(id) ON DELETE CASCADE;
ALTER TABLE "public"."themes" ADD CONSTRAINT "themes_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."usage_events" ADD CONSTRAINT "usage_events_data_class_check" CHECK (data_class = ANY (ARRAY['usage'::text, 'transaction'::text, 'configuration'::text, 'audit'::text, 'telemetry'::text, 'system'::text]));
ALTER TABLE "public"."usage_events" ADD CONSTRAINT "usage_events_device_id_fkey" FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE SET NULL;
ALTER TABLE "public"."usage_events" ADD CONSTRAINT "usage_events_org_id_fkey" FOREIGN KEY (org_id) REFERENCES organizations(id) ON DELETE CASCADE;
ALTER TABLE "public"."usage_events" ADD CONSTRAINT "usage_events_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."usage_events" ADD CONSTRAINT "usage_events_rental_account_id_fkey" FOREIGN KEY (rental_account_id) REFERENCES rental_accounts(id) ON DELETE SET NULL;
ALTER TABLE "public"."usage_events" ADD CONSTRAINT "usage_events_rental_session_id_fkey" FOREIGN KEY (rental_session_id) REFERENCES rental_sessions(id) ON DELETE SET NULL;
ALTER TABLE "public"."usage_events" ADD CONSTRAINT "usage_events_reseller_org_id_fkey" FOREIGN KEY (reseller_org_id) REFERENCES organizations(id) ON DELETE SET NULL;
ALTER TABLE "public"."usage_events" ADD CONSTRAINT "usage_events_theme_id_fkey" FOREIGN KEY (theme_id) REFERENCES themes(id) ON DELETE SET NULL;
ALTER TABLE "public"."wol_relay_commands" ADD CONSTRAINT "wol_relay_commands_org_id_fkey" FOREIGN KEY (org_id) REFERENCES organizations(id) ON DELETE CASCADE;
ALTER TABLE "public"."wol_relay_commands" ADD CONSTRAINT "wol_relay_commands_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."wol_relay_commands" ADD CONSTRAINT "wol_relay_commands_relay_id_fkey" FOREIGN KEY (relay_id) REFERENCES wol_relay_devices(id) ON DELETE CASCADE;
ALTER TABLE "public"."wol_relay_commands" ADD CONSTRAINT "wol_relay_commands_status_check" CHECK (status = ANY (ARRAY['queued'::text, 'delivered'::text, 'packet_sent'::text, 'failed'::text, 'expired'::text, 'confirmed'::text]));
ALTER TABLE "public"."wol_relay_commands" ADD CONSTRAINT "wol_relay_commands_target_device_id_fkey" FOREIGN KEY (target_device_id) REFERENCES devices(id) ON DELETE CASCADE;
ALTER TABLE "public"."wol_relay_commands" ADD CONSTRAINT "wol_relay_commands_target_mac_check" CHECK (target_mac ~ '^([0-9A-F]{2}:){5}[0-9A-F]{2}$'::text);
ALTER TABLE "public"."wol_relay_devices" ADD CONSTRAINT "wol_relay_devices_battery_percent_check" CHECK (battery_percent >= 0 AND battery_percent <= 100);
ALTER TABLE "public"."wol_relay_devices" ADD CONSTRAINT "wol_relay_devices_installation_id_check" CHECK (length(btrim(installation_id)) >= 8 AND length(btrim(installation_id)) <= 128);
ALTER TABLE "public"."wol_relay_devices" ADD CONSTRAINT "wol_relay_devices_org_id_fkey" FOREIGN KEY (org_id) REFERENCES organizations(id) ON DELETE CASCADE;
ALTER TABLE "public"."wol_relay_devices" ADD CONSTRAINT "wol_relay_devices_org_id_installation_id_key" UNIQUE (org_id, installation_id);
ALTER TABLE "public"."wol_relay_devices" ADD CONSTRAINT "wol_relay_devices_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."wol_relay_devices" ADD CONSTRAINT "wol_relay_devices_relay_name_check" CHECK (length(btrim(relay_name)) >= 1 AND length(btrim(relay_name)) <= 100);
ALTER TABLE "public"."wol_relay_devices" ADD CONSTRAINT "wol_relay_devices_status_check" CHECK (status = ANY (ARRAY['online'::text, 'offline'::text, 'revoked'::text]));
ALTER TABLE "public"."wol_relay_devices" ADD CONSTRAINT "wol_relay_devices_token_hash_check" CHECK (token_hash ~ '^[0-9a-f]{64}$'::text);
ALTER TABLE "public"."wol_relay_devices" ADD CONSTRAINT "wol_relay_devices_token_hash_key" UNIQUE (token_hash);
ALTER TABLE "public"."wol_relay_enrollments" ADD CONSTRAINT "wol_relay_enrollments_code_hash_check" CHECK (code_hash ~ '^[0-9a-f]{64}$'::text);
ALTER TABLE "public"."wol_relay_enrollments" ADD CONSTRAINT "wol_relay_enrollments_code_hash_key" UNIQUE (code_hash);
ALTER TABLE "public"."wol_relay_enrollments" ADD CONSTRAINT "wol_relay_enrollments_org_id_fkey" FOREIGN KEY (org_id) REFERENCES organizations(id) ON DELETE CASCADE;
ALTER TABLE "public"."wol_relay_enrollments" ADD CONSTRAINT "wol_relay_enrollments_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."wol_relay_probes" ADD CONSTRAINT "wol_relay_probes_org_id_fkey" FOREIGN KEY (org_id) REFERENCES organizations(id) ON DELETE CASCADE;
ALTER TABLE "public"."wol_relay_probes" ADD CONSTRAINT "wol_relay_probes_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."wol_relay_probes" ADD CONSTRAINT "wol_relay_probes_relay_id_fkey" FOREIGN KEY (relay_id) REFERENCES wol_relay_devices(id) ON DELETE CASCADE;
ALTER TABLE "public"."wol_relay_probes" ADD CONSTRAINT "wol_relay_probes_status_check" CHECK (status = ANY (ARRAY['pending'::text, 'online'::text, 'expired'::text]));
ALTER TABLE "reporting_private"."telegram_device_presence" ADD CONSTRAINT "telegram_device_presence_device_id_fkey" FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE;
ALTER TABLE "reporting_private"."telegram_device_presence" ADD CONSTRAINT "telegram_device_presence_pkey" PRIMARY KEY (device_id);
ALTER TABLE "reporting_private"."telegram_notification_outbox" ADD CONSTRAINT "telegram_notification_outbox_attempts_check" CHECK (attempts >= 0);
ALTER TABLE "reporting_private"."telegram_notification_outbox" ADD CONSTRAINT "telegram_notification_outbox_event_key_key" UNIQUE (event_key);
ALTER TABLE "reporting_private"."telegram_notification_outbox" ADD CONSTRAINT "telegram_notification_outbox_event_type_check" CHECK (event_type = ANY (ARRAY['rental_started'::text, 'rental_finished'::text, 'pc_standby'::text, 'pc_offline'::text, 'pc_online'::text, 'daily_recap'::text, 'test_message'::text]));
ALTER TABLE "reporting_private"."telegram_notification_outbox" ADD CONSTRAINT "telegram_notification_outbox_pkey" PRIMARY KEY (id);
ALTER TABLE "reporting_private"."telegram_notification_outbox" ADD CONSTRAINT "telegram_notification_outbox_status_check" CHECK (status = ANY (ARRAY['pending'::text, 'processing'::text, 'sent'::text, 'failed'::text, 'skipped'::text]));
ALTER TABLE "reporting_private"."telegram_settings" ADD CONSTRAINT "telegram_settings_id_check" CHECK (id = 1);
ALTER TABLE "reporting_private"."telegram_settings" ADD CONSTRAINT "telegram_settings_offline_after_seconds_check" CHECK (offline_after_seconds >= 60 AND offline_after_seconds <= 900);
ALTER TABLE "reporting_private"."telegram_settings" ADD CONSTRAINT "telegram_settings_pkey" PRIMARY KEY (id);

-- Non-constraint indexes. Duplicate names created by PRIMARY KEY/UNIQUE constraints are skipped safely.
CREATE INDEX IF NOT EXISTS admin_accounts_org_idx ON public.admin_accounts USING btree (org_id);
CREATE INDEX IF NOT EXISTS admin_accounts_status_idx ON public.admin_accounts USING btree (status);
CREATE UNIQUE INDEX IF NOT EXISTS admin_accounts_username_lower_key ON public.admin_accounts USING btree (lower(TRIM(BOTH FROM username)));
CREATE INDEX IF NOT EXISTS admin_alert_events_device_created_idx ON public.admin_alert_events USING btree (device_id, created_at DESC);
CREATE INDEX IF NOT EXISTS admin_alert_events_org_created_idx ON public.admin_alert_events USING btree (org_id, created_at DESC);
CREATE INDEX IF NOT EXISTS admin_pc_access_device_idx ON public.admin_pc_access USING btree (device_id);
CREATE INDEX IF NOT EXISTS idx_audit_org_time ON public.audit_logs USING btree (org_id, created_at DESC);
CREATE INDEX IF NOT EXISTS billing_control_accounts_auth_idx ON public.billing_control_accounts USING btree (auth_user_id);
CREATE INDEX IF NOT EXISTS billing_control_accounts_org_idx ON public.billing_control_accounts USING btree (org_id);
CREATE INDEX IF NOT EXISTS billing_control_sessions_account_idx ON public.billing_control_sessions USING btree (billing_account_id);
CREATE INDEX IF NOT EXISTS billing_control_sessions_active_idx ON public.billing_control_sessions USING btree (token_hash, expires_at) WHERE (revoked_at IS NULL);
CREATE UNIQUE INDEX IF NOT EXISTS billing_transactions_free_test_session_unique ON public.billing_transactions USING btree (rental_session_id) WHERE ((transaction_type = 'free_test'::text) AND (rental_session_id IS NOT NULL));
CREATE INDEX IF NOT EXISTS idx_billing_transactions_device ON public.billing_transactions USING btree (device_id);
CREATE INDEX IF NOT EXISTS idx_billing_transactions_org_account_theme ON public.billing_transactions USING btree (org_id, rental_account_id, theme_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_billing_transactions_org_occurred ON public.billing_transactions USING btree (org_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_billing_transactions_org_time_account_theme ON public.billing_transactions USING btree (org_id, occurred_at, rental_account_id, theme_id);
CREATE INDEX IF NOT EXISTS idx_billing_transactions_rental_account ON public.billing_transactions USING btree (rental_account_id);
CREATE INDEX IF NOT EXISTS idx_billing_transactions_rental_session ON public.billing_transactions USING btree (rental_session_id);
CREATE INDEX IF NOT EXISTS idx_billing_transactions_theme ON public.billing_transactions USING btree (theme_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_billing_transactions_org_source_event ON public.billing_transactions USING btree (org_id, source_event_id) WHERE (source_event_id IS NOT NULL);
CREATE INDEX IF NOT EXISTS idx_db_route_control_updated_by ON public.db_route_control USING btree (updated_by);
CREATE INDEX IF NOT EXISTS idx_db_route_control_write_quiesce ON public.db_route_control USING btree (sync_write_quiesce) WHERE sync_write_quiesce;
CREATE UNIQUE INDEX IF NOT EXISTS db_sync_runs_single_running_uidx ON public.db_sync_runs USING btree (state) WHERE (state = 'running'::text);
CREATE INDEX IF NOT EXISTS idx_db_sync_runs_state_started_at ON public.db_sync_runs USING btree (state, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_device_command_logs_command_created ON public.device_command_logs USING btree (command_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_device_command_logs_device ON public.device_command_logs USING btree (device_id);
CREATE INDEX IF NOT EXISTS idx_device_command_logs_org ON public.device_command_logs USING btree (org_id);
CREATE INDEX IF NOT EXISTS idx_commands_device_status ON public.device_commands USING btree (device_id, status, created_at);
CREATE INDEX IF NOT EXISTS idx_device_commands_org ON public.device_commands USING btree (org_id);
CREATE INDEX IF NOT EXISTS idx_device_enrollments_org ON public.device_enrollments USING btree (org_id);
CREATE INDEX IF NOT EXISTS idx_device_enrollments_redeemed_device_id ON public.device_enrollments USING btree (redeemed_device_id);
CREATE INDEX IF NOT EXISTS idx_device_heartbeats_device_received ON public.device_heartbeats USING btree (device_id, received_at DESC);
CREATE INDEX IF NOT EXISTS idx_device_heartbeats_org ON public.device_heartbeats USING btree (org_id);
CREATE INDEX IF NOT EXISTS device_shutdown_schedules_device_state_idx ON public.device_shutdown_schedules USING btree (device_id, state, updated_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS device_shutdown_schedules_one_live_per_device_idx ON public.device_shutdown_schedules USING btree (device_id) WHERE (state = ANY (ARRAY['pending'::text, 'scheduled'::text, 'waiting_for_rental_end'::text, 'cancel_requested'::text]));
CREATE INDEX IF NOT EXISTS device_trial_requests_command_idx ON public.device_trial_requests USING btree (command_id);
CREATE INDEX IF NOT EXISTS device_trial_requests_created_by_idx ON public.device_trial_requests USING btree (created_by);
CREATE UNIQUE INDEX IF NOT EXISTS device_trial_requests_one_open ON public.device_trial_requests USING btree (device_id) WHERE (status = ANY (ARRAY['queued'::text, 'started'::text]));
CREATE INDEX IF NOT EXISTS device_trial_requests_org_idx ON public.device_trial_requests USING btree (org_id);
CREATE INDEX IF NOT EXISTS device_trial_requests_session_idx ON public.device_trial_requests USING btree (session_id);
CREATE INDEX IF NOT EXISTS idx_devices_last_seen ON public.devices USING btree (last_seen_at DESC);
CREATE INDEX IF NOT EXISTS idx_devices_org ON public.devices USING btree (org_id);
CREATE INDEX IF NOT EXISTS idx_devices_org_status ON public.devices USING btree (org_id, status);
CREATE INDEX IF NOT EXISTS idx_organizations_parent_org ON public.organizations USING btree (parent_org_id);
CREATE INDEX IF NOT EXISTS idx_accounts_org ON public.rental_accounts USING btree (org_id);
CREATE INDEX IF NOT EXISTS idx_rental_accounts_device ON public.rental_accounts USING btree (device_id);
CREATE INDEX IF NOT EXISTS idx_rental_accounts_org_theme ON public.rental_accounts USING btree (org_id, theme_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_rental_accounts_theme ON public.rental_accounts USING btree (theme_id);
CREATE UNIQUE INDEX IF NOT EXISTS rental_accounts_org_upper_code_key ON public.rental_accounts USING btree (org_id, upper(TRIM(BOTH FROM code)));
CREATE INDEX IF NOT EXISTS rental_offline_leases_device_until_idx ON public.rental_offline_leases USING btree (device_id, lease_until);
CREATE INDEX IF NOT EXISTS idx_rental_sessions_account ON public.rental_sessions USING btree (rental_account_id);
CREATE INDEX IF NOT EXISTS idx_rental_sessions_device ON public.rental_sessions USING btree (device_id);
CREATE INDEX IF NOT EXISTS idx_rental_sessions_device_status ON public.rental_sessions USING btree (device_id, status, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_rental_sessions_org_account_theme ON public.rental_sessions USING btree (org_id, rental_account_id, theme_id, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_rental_sessions_theme ON public.rental_sessions USING btree (theme_id);
CREATE INDEX IF NOT EXISTS idx_sessions_org_time ON public.rental_sessions USING btree (org_id, started_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS rental_sessions_one_open_per_device ON public.rental_sessions USING btree (device_id) WHERE (status = ANY (ARRAY['active'::text, 'paused'::text]));
CREATE UNIQUE INDEX IF NOT EXISTS rental_sessions_one_open_per_rental_account ON public.rental_sessions USING btree (rental_account_id) WHERE ((rental_account_id IS NOT NULL) AND (status = ANY (ARRAY['active'::text, 'paused'::text])));
CREATE UNIQUE INDEX IF NOT EXISTS uq_rental_sessions_org_source_event ON public.rental_sessions USING btree (org_id, source_event_id) WHERE (source_event_id IS NOT NULL);
CREATE INDEX IF NOT EXISTS idx_superadmin_audit_user_time ON public.superadmin_audit USING btree (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_superadmin_sessions_user_expiry ON public.superadmin_sessions USING btree (user_id, expires_at);
CREATE INDEX IF NOT EXISTS idx_themes_org ON public.themes USING btree (org_id);
CREATE INDEX IF NOT EXISTS idx_usage_events_account ON public.usage_events USING btree (rental_account_id);
CREATE INDEX IF NOT EXISTS idx_usage_events_device ON public.usage_events USING btree (device_id);
CREATE INDEX IF NOT EXISTS idx_usage_events_org_account_theme ON public.usage_events USING btree (org_id, rental_account_id, theme_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_usage_events_org_time_account_theme ON public.usage_events USING btree (org_id, occurred_at, rental_account_id, theme_id);
CREATE INDEX IF NOT EXISTS idx_usage_events_reseller ON public.usage_events USING btree (reseller_org_id);
CREATE INDEX IF NOT EXISTS idx_usage_events_session ON public.usage_events USING btree (rental_session_id);
CREATE INDEX IF NOT EXISTS idx_usage_events_theme ON public.usage_events USING btree (theme_id);
CREATE INDEX IF NOT EXISTS idx_usage_org_class ON public.usage_events USING btree (org_id, data_class, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_usage_org_time ON public.usage_events USING btree (org_id, occurred_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS uq_usage_source_event ON public.usage_events USING btree (org_id, source_event_id) WHERE (source_event_id IS NOT NULL);
CREATE INDEX IF NOT EXISTS wol_relay_commands_relay_queue_idx ON public.wol_relay_commands USING btree (relay_id, status, created_at);
CREATE INDEX IF NOT EXISTS wol_relay_commands_target_recent_idx ON public.wol_relay_commands USING btree (target_device_id, created_at DESC);
CREATE INDEX IF NOT EXISTS wol_relay_devices_org_seen_idx ON public.wol_relay_devices USING btree (org_id, last_seen_at DESC) WHERE (revoked_at IS NULL);
CREATE UNIQUE INDEX IF NOT EXISTS wol_relay_one_primary_per_org_idx ON public.wol_relay_devices USING btree (org_id) WHERE ((is_primary = true) AND (revoked_at IS NULL));
CREATE INDEX IF NOT EXISTS wol_relay_probes_pending_idx ON public.wol_relay_probes USING btree (relay_id, requested_at DESC) WHERE (status = 'pending'::text);
CREATE INDEX IF NOT EXISTS telegram_reporting_device_idx ON reporting_private.telegram_notification_outbox USING btree (device_id, created_at DESC);
CREATE INDEX IF NOT EXISTS telegram_reporting_pending_idx ON reporting_private.telegram_notification_outbox USING btree (status, next_attempt_at, created_at);

COMMIT;
