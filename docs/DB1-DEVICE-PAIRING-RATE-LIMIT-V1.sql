-- DB1 device pairing rate limit ledger (already applied as device_pairing_rate_limit_ledger_v1).
CREATE TABLE IF NOT EXISTS public.device_pairing_rate_limits (
  key_hash text PRIMARY KEY CHECK (key_hash ~ '^[0-9a-f]{64}$'),
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0 AND attempt_count <= 100),
  window_started_at timestamptz NOT NULL DEFAULT now(),
  locked_until timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.device_pairing_rate_limits ENABLE ROW LEVEL SECURITY;
REVOKE ALL PRIVILEGES ON TABLE public.device_pairing_rate_limits FROM PUBLIC, anon, authenticated;
GRANT ALL PRIVILEGES ON TABLE public.device_pairing_rate_limits TO service_role;

CREATE OR REPLACE FUNCTION api.device_pairing_rate_limit_consume(
  p_key_hash text, p_max_attempts integer DEFAULT 5
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v public.device_pairing_rate_limits%ROWTYPE;
  v_next integer;
  v_locked_until timestamptz;
BEGIN
  IF p_key_hash IS NULL OR p_key_hash !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'RATE_LIMIT_KEY_INVALID'; END IF;
  IF p_max_attempts IS NULL OR p_max_attempts < 1 OR p_max_attempts > 100 THEN RAISE EXCEPTION 'RATE_LIMIT_MAX_ATTEMPTS_INVALID'; END IF;
  INSERT INTO public.device_pairing_rate_limits(key_hash,attempt_count,window_started_at,updated_at)
  VALUES (p_key_hash,0,now(),now()) ON CONFLICT (key_hash) DO NOTHING;
  SELECT * INTO v FROM public.device_pairing_rate_limits WHERE key_hash=p_key_hash FOR UPDATE;
  IF v.locked_until IS NOT NULL AND v.locked_until>now() THEN
    RETURN jsonb_build_object('allowed',false,'retry_after_seconds',greatest(1,ceil(extract(epoch FROM (v.locked_until-now())))::integer));
  END IF;
  IF v.window_started_at<=now()-interval '15 minutes' OR (v.locked_until IS NOT NULL AND v.locked_until<=now()) THEN
    UPDATE public.device_pairing_rate_limits SET attempt_count=1,window_started_at=now(),locked_until=NULL,updated_at=now() WHERE key_hash=p_key_hash;
    RETURN jsonb_build_object('allowed',true,'remaining_attempts',p_max_attempts-1);
  END IF;
  v_next:=least(p_max_attempts,v.attempt_count+1);
  v_locked_until:=CASE WHEN v_next>=p_max_attempts THEN now()+interval '15 minutes' ELSE NULL END;
  UPDATE public.device_pairing_rate_limits SET attempt_count=v_next,locked_until=v_locked_until,updated_at=now() WHERE key_hash=p_key_hash;
  RETURN jsonb_build_object('allowed',true,'remaining_attempts',greatest(0,p_max_attempts-v_next));
END
$function$;

CREATE OR REPLACE FUNCTION api.device_pairing_rate_limit_clear(p_key_hashes text[])
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE v_deleted integer:=0;
BEGIN
  IF p_key_hashes IS NULL OR cardinality(p_key_hashes)<1 OR cardinality(p_key_hashes)>4
     OR EXISTS (SELECT 1 FROM unnest(p_key_hashes) AS x(k) WHERE x.k IS NULL OR x.k !~ '^[0-9a-f]{64}$') THEN
    RAISE EXCEPTION 'RATE_LIMIT_KEYS_INVALID';
  END IF;
  DELETE FROM public.device_pairing_rate_limits WHERE key_hash=ANY(p_key_hashes);
  GET DIAGNOSTICS v_deleted=ROW_COUNT;
  RETURN jsonb_build_object('ok',true,'cleared',v_deleted);
END
$function$;

REVOKE ALL PRIVILEGES ON FUNCTION api.device_pairing_rate_limit_consume(text,integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL PRIVILEGES ON FUNCTION api.device_pairing_rate_limit_clear(text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION api.device_pairing_rate_limit_consume(text,integer) TO service_role;
GRANT EXECUTE ON FUNCTION api.device_pairing_rate_limit_clear(text[]) TO service_role;

DO $cleanup_job$
BEGIN
 IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname='device-pairing-rate-limit-cleanup') THEN
  PERFORM cron.schedule('device-pairing-rate-limit-cleanup','48 18 * * *',
    'DELETE FROM public.device_pairing_rate_limits WHERE updated_at < now() - interval ''7 days'';');
 END IF;
END
$cleanup_job$;
