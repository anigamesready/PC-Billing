-- CORE BUSINESS SCHEMA — generated from DB1 catalog on 2026-11-14.
-- 24 operational tables only. Supabase DB-route/sync, WoL Relay, Telegram, and
-- automatic shutdown-scheduler tables are intentionally excluded.
-- No row data, credentials, password hashes, tokens or secrets are present.
-- Apply only to an empty staging DB after 000_prerequisites.sql; this is not a production cutover.
BEGIN;
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
CREATE INDEX IF NOT EXISTS idx_device_command_logs_command_created ON public.device_command_logs USING btree (command_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_device_command_logs_device ON public.device_command_logs USING btree (device_id);
CREATE INDEX IF NOT EXISTS idx_device_command_logs_org ON public.device_command_logs USING btree (org_id);
CREATE INDEX IF NOT EXISTS idx_commands_device_status ON public.device_commands USING btree (device_id, status, created_at);
CREATE INDEX IF NOT EXISTS idx_device_commands_org ON public.device_commands USING btree (org_id);
CREATE INDEX IF NOT EXISTS idx_device_enrollments_org ON public.device_enrollments USING btree (org_id);
CREATE INDEX IF NOT EXISTS idx_device_enrollments_redeemed_device_id ON public.device_enrollments USING btree (redeemed_device_id);
CREATE INDEX IF NOT EXISTS idx_device_heartbeats_device_received ON public.device_heartbeats USING btree (device_id, received_at DESC);
CREATE INDEX IF NOT EXISTS idx_device_heartbeats_org ON public.device_heartbeats USING btree (org_id);
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
COMMIT;
