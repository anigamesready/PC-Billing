-- ANI GAMES READY REMOTE COIN WALLET — DESIGN DRAFT ONLY.
-- NOT A MIGRATION. DO NOT COPY INTO db-android-core/schema OR APPLY TO THE REDMI.
-- Target is the existing single Android DB PostgreSQL instance and schema remote_play.
-- Reviewed against the Remote Play source line with migrations 013-019.
--
-- Business rules:
--   Rp8,000 = 60 coins.
--   GTX 1050: Rp6,000/hour = 45 coins/hour.
--   GTX 1660: Rp6,000/hour = 45 coins/hour.
--   RTX 3060: Rp7,000/hour = 52.5 coins/hour.
--   RTX 5060: Rp8,000/hour = 60 coins/hour.
--   New lot expiry is calculated at credit approval from the valid balance
--   immediately BEFORE credit + this top-up. Existing lots are never extended.
--   Expiry tiers: <300=3d, <600=7d, <900=10d, <1200=14d, <1500=17d,
--                 <1800=21d, <2100=24d, <2400=28d, >=2400=30d.
--   FIFO spending by earliest expires_at, then created_at, then id.
--
-- IMPORTANT INTEGRATION GUARD:
-- Existing private.remote_play_settle_session() (migration 019) deducts
-- public.rental_accounts.remaining_seconds. Coin-mode MUST NOT call that
-- time-only implementation unchanged. Before activation, make settlement
-- explicitly branch on a session billing_mode, and make stream_connected,
-- heartbeat, end-session and watchdog route through that same safe branch.
-- No SQL below is applied or production-ready.

-- 1) One wallet for each existing rental identity. No copy of User ID/code.
CREATE TABLE remote_play.coin_wallets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rental_account_id uuid NOT NULL UNIQUE
    REFERENCES public.rental_accounts(id) ON DELETE CASCADE,
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  cached_balance numeric(24,12) NOT NULL DEFAULT 0
    CHECK (cached_balance >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- 2) A separate lot per credit/top-up. Old expiry_at is never updated by a new top-up.
CREATE TABLE remote_play.coin_lots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  wallet_id uuid NOT NULL REFERENCES remote_play.coin_wallets(id) ON DELETE RESTRICT,
  rental_account_id uuid NOT NULL REFERENCES public.rental_accounts(id) ON DELETE CASCADE,
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  source_type text NOT NULL CHECK (source_type IN ('topup','admin_credit','refund')),
  source_order_id uuid,
  original_coins numeric(24,12) NOT NULL CHECK (original_coins > 0),
  remaining_coins numeric(24,12) NOT NULL CHECK (remaining_coins >= 0),
  expires_at timestamptz NOT NULL,
  expired_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (remaining_coins <= original_coins)
);
CREATE INDEX coin_lots_wallet_expiry_idx
  ON remote_play.coin_lots(wallet_id, expires_at, created_at, id);

-- 3) QRIS static orders. This order exists BEFORE WhatsApp is opened.
CREATE TABLE remote_play.topup_orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  rental_account_id uuid NOT NULL REFERENCES public.rental_accounts(id) ON DELETE CASCADE,
  amount_rupiah bigint NOT NULL CHECK (amount_rupiah > 0),
  coin_amount numeric(24,12) NOT NULL CHECK (coin_amount > 0),
  payment_method text NOT NULL DEFAULT 'qris_static'
    CHECK (payment_method = 'qris_static'),
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','approved','rejected','cancelled')),
  expiry_days_awarded integer,
  whatsapp_number text NOT NULL DEFAULT '082298316902',
  whatsapp_opened_at timestamptz,
  user_confirmed_at timestamptz,
  admin_note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  approved_at timestamptz,
  approved_by uuid,
  rejected_at timestamptz,
  rejected_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(),
  idempotency_key text NOT NULL UNIQUE,
  CHECK (
    (status='approved' AND approved_at IS NOT NULL AND expiry_days_awarded IS NOT NULL)
    OR status<>'approved'
  )
);
CREATE INDEX topup_orders_org_pending_idx
  ON remote_play.topup_orders(org_id, created_at DESC)
  WHERE status='pending';
CREATE INDEX topup_orders_rental_recent_idx
  ON remote_play.topup_orders(rental_account_id, created_at DESC);

-- Add source_order_id FK after the top-up table exists.
ALTER TABLE remote_play.coin_lots
  ADD CONSTRAINT coin_lots_source_order_fk
  FOREIGN KEY (source_order_id) REFERENCES remote_play.topup_orders(id)
  ON DELETE RESTRICT;

-- 4) Immutable transaction journal. Mutations only through audited server-side RPCs.
CREATE TABLE remote_play.coin_ledger (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  rental_account_id uuid NOT NULL REFERENCES public.rental_accounts(id) ON DELETE CASCADE,
  wallet_id uuid NOT NULL REFERENCES remote_play.coin_wallets(id) ON DELETE RESTRICT,
  lot_id uuid REFERENCES remote_play.coin_lots(id) ON DELETE RESTRICT,
  topup_order_id uuid REFERENCES remote_play.topup_orders(id) ON DELETE RESTRICT,
  remote_session_id uuid REFERENCES remote_play.sessions(id) ON DELETE RESTRICT,
  event_type text NOT NULL
    CHECK (event_type IN ('topup_credit','remote_usage_debit','lot_expired','refund','admin_adjustment')),
  coin_delta numeric(24,12) NOT NULL CHECK (coin_delta <> 0),
  wallet_balance_after numeric(24,12) NOT NULL CHECK (wallet_balance_after >= 0),
  idempotency_key text NOT NULL UNIQUE,
  actor_family text NOT NULL CHECK (actor_family IN ('client','admin','host','system')),
  actor_id text,
  note text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX coin_ledger_wallet_recent_idx
  ON remote_play.coin_ledger(wallet_id, created_at DESC, id DESC);
CREATE INDEX coin_ledger_org_recent_idx
  ON remote_play.coin_ledger(org_id, created_at DESC);

-- 5) Price snapshot/config per actual PC, using the existing public.devices.id.
CREATE TABLE remote_play.pc_coin_rates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  device_id uuid NOT NULL UNIQUE REFERENCES public.devices(id) ON DELETE CASCADE,
  gpu_model text NOT NULL
    CHECK (gpu_model IN ('GTX 1050','GTX 1660','RTX 3060','RTX 5060')),
  price_rupiah_per_hour bigint NOT NULL CHECK (price_rupiah_per_hour > 0),
  coins_per_hour numeric(24,12) NOT NULL CHECK (coins_per_hour > 0),
  enabled boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);
-- Initial values to provision through a reviewed Admin RPC, never by APK hardcoding:
-- GTX 1050 | 6000 | 45
-- GTX 1660 | 6000 | 45
-- RTX 3060 | 7000 | 52.5
-- RTX 5060 | 8000 | 60

-- 6) One billing row linked to the already-existing Remote Play control-plane session.
-- Charge is calculated server-side from last_charged_at using server timestamps.
CREATE TABLE remote_play.coin_session_billing (
  session_id uuid PRIMARY KEY REFERENCES remote_play.sessions(id) ON DELETE RESTRICT,
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  rental_account_id uuid NOT NULL REFERENCES public.rental_accounts(id) ON DELETE CASCADE,
  device_id uuid NOT NULL REFERENCES public.devices(id) ON DELETE RESTRICT,
  rate_id uuid REFERENCES remote_play.pc_coin_rates(id) ON DELETE SET NULL,
  gpu_model_snapshot text NOT NULL,
  price_rupiah_per_hour_snapshot bigint NOT NULL CHECK (price_rupiah_per_hour_snapshot > 0),
  coins_per_hour_snapshot numeric(24,12) NOT NULL CHECK (coins_per_hour_snapshot > 0),
  last_charged_at timestamptz,
  charged_seconds bigint NOT NULL DEFAULT 0 CHECK (charged_seconds >= 0),
  charged_coins numeric(24,12) NOT NULL DEFAULT 0 CHECK (charged_coins >= 0),
  settled_at timestamptz,
  settle_idempotency_key text UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Required implementation work BEFORE any of this is applied:
-- A. Add billing_mode='rental_seconds'|'coins' to remote_play.sessions, default rental_seconds.
-- B. Preserve the 019 time-settlement path byte-for-byte for existing rental_seconds rows.
-- C. Add a coin-safe settlement branch that:
--    * locks session, billing row, wallet and coin lots in one transaction;
--    * calculates seconds only from server time since last_charged_at / stream_started_at;
--    * spends valid lots FIFO (expires_at, created_at, id);
--    * writes one unique ledger row per idempotent charge period;
--    * never updates rental_accounts.remaining_seconds, status or expiry_at;
--    * queues the existing stop_stream command and settles exactly once.
-- D. Add a coin-only session-start path that reuses existing host permission, online,
--    Sunshine readiness, account ownership, no-active-PC-rental-session, one-account/
--    one-PC locks, idempotency and cooldown rules, but does NOT gate on old rental
--    expiry_at / remaining_seconds. Keep status disabled/deleted/inactive blocked.
-- E. Change the common stream-connected, heartbeat, end-session and watchdog path to
--    dispatch by billing_mode. A coin session must not call old time-only settlement.
-- F. Run 013-019 and existing PC Billing/Admin/Reseller smoke tests unchanged, then add
--    isolated PostgreSQL coin smoke tests. This draft is a schema blueprint only.
