-- DB1 hotfix: make rental_account_upsert sync idempotent when a unique
-- (org_id, code) row is already assigned to a different device.
-- Applied directly to DB1 on 2026-10-18 and verified with isolated disposable rows.
CREATE OR REPLACE FUNCTION api.device_sync(p_token text, p_events jsonb DEFAULT '[]'::jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  did uuid;
  oid uuid;
  item jsonb;
  accepted jsonb := '[]'::jsonb;
  sid text;
  inserted_count integer := 0;
  rid uuid;
  tid uuid;
  existing_device_id uuid;
  evtype text;
  c text;
  base_updated timestamptz;
  existing_updated timestamptz;
BEGIN
  IF jsonb_typeof(coalesce(p_events, '[]'::jsonb)) <> 'array' THEN
    RAISE EXCEPTION 'EVENTS_MUST_BE_ARRAY';
  END IF;
  IF jsonb_array_length(coalesce(p_events, '[]'::jsonb)) > 100
     OR pg_column_size(coalesce(p_events, '[]'::jsonb)) > 524288 THEN
    RAISE EXCEPTION 'EVENT_BATCH_TOO_LARGE';
  END IF;

  SELECT d.id, d.org_id INTO did, oid
  FROM public.device_tokens t
  JOIN public.devices d ON d.id = t.device_id
  WHERE t.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    AND t.revoked_at IS NULL;
  IF did IS NULL THEN RAISE EXCEPTION 'INVALID_DEVICE_TOKEN'; END IF;

  FOR item IN SELECT value FROM jsonb_array_elements(coalesce(p_events, '[]'::jsonb)) LOOP
    sid := nullif(trim(item->>'sourceEventId'), '');
    IF sid IS NULL THEN CONTINUE; END IF;

    evtype := coalesce(nullif(item->>'eventType', ''), 'system');
    c := upper(trim(coalesce(item->>'code', '')));

    IF evtype = 'rental_account_upsert' AND c <> '' THEN
      base_updated := nullif(item->'payload'->>'baseUpdatedAt', '')::timestamptz;
      PERFORM pg_advisory_xact_lock(hashtextextended(oid::text || ':' || c, 0));

      SELECT id, theme_id, device_id, updated_at
      INTO rid, tid, existing_device_id, existing_updated
      FROM public.rental_accounts
      WHERE org_id = oid AND code = c
      LIMIT 1
      FOR UPDATE;

      IF base_updated IS NOT NULL AND existing_updated IS NOT NULL
         AND existing_updated > base_updated THEN
        accepted := accepted || jsonb_build_array(sid);
        CONTINUE;
      END IF;

      -- Do not reassign a unique account owned by a different device.
      -- Acknowledge it so a stale PC batch cannot jam all future syncs.
      IF rid IS NOT NULL AND existing_device_id IS NOT NULL
         AND existing_device_id <> did THEN
        accepted := accepted || jsonb_build_array(sid);
        CONTINUE;
      END IF;

      IF tid IS NULL THEN
        SELECT theme_id INTO tid FROM public.organizations WHERE id = oid;
      END IF;

      IF rid IS NULL THEN
        INSERT INTO public.rental_accounts(
          org_id, device_id, code, category, remaining_seconds, expiry_at,
          status, client_label, theme_id, metadata
        )
        VALUES (
          oid, did, c,
          coalesce(nullif(item->>'category', ''), 'reguler'),
          greatest(0, coalesce((item->>'remainingSeconds')::bigint, 0)),
          nullif(item->>'expiryDate', '')::timestamptz,
          'active', nullif(item->>'clientLabel', ''), tid,
          jsonb_build_object('source', 'pc-sync')
        )
        RETURNING id INTO rid;
      ELSE
        UPDATE public.rental_accounts
        SET device_id = did,
            category = coalesce(nullif(item->>'category', ''), category),
            remaining_seconds = greatest(0, coalesce((item->>'remainingSeconds')::bigint, 0)),
            expiry_at = nullif(item->>'expiryDate', '')::timestamptz,
            status = 'active',
            client_label = coalesce(nullif(item->>'clientLabel', ''), client_label),
            updated_at = now()
        WHERE id = rid;
      END IF;

      accepted := accepted || jsonb_build_array(sid);
      inserted_count := inserted_count + 1;
      CONTINUE;
    END IF;

    IF evtype = 'rental_account_delete' AND c <> '' THEN
      UPDATE public.rental_accounts
      SET status = 'disabled', updated_at = now()
      WHERE org_id = oid AND device_id = did AND code = c;
      accepted := accepted || jsonb_build_array(sid);
      inserted_count := inserted_count + 1;
      CONTINUE;
    END IF;

    SELECT id, theme_id INTO rid, tid
    FROM public.rental_accounts
    WHERE org_id = oid AND code = c AND (device_id IS NULL OR device_id = did)
    ORDER BY CASE WHEN device_id = did THEN 0 ELSE 1 END, created_at DESC
    LIMIT 1;
    IF tid IS NULL THEN
      SELECT theme_id INTO tid FROM public.organizations WHERE id = oid;
    END IF;

    INSERT INTO public.usage_events(
      org_id, device_id, rental_session_id, rental_account_id, theme_id,
      event_type, data_class, occurred_at, duration_seconds, category,
      client_label, payload, source_event_id, reseller_org_id
    )
    VALUES (
      oid, did,
      CASE WHEN nullif(item->>'sessionId', '') IS NULL THEN NULL ELSE (item->>'sessionId')::uuid END,
      rid, tid, evtype,
      coalesce(nullif(item->>'dataClass', ''), 'system'),
      coalesce((item->>'occurredAt')::timestamptz, now()),
      greatest(0, coalesce((item->>'durationSeconds')::integer, 0)),
      nullif(item->>'category', ''), nullif(item->>'clientLabel', ''),
      coalesce(item->'payload', '{}'::jsonb), sid, oid
    )
    ON CONFLICT (org_id, source_event_id)
      WHERE source_event_id IS NOT NULL DO NOTHING;

    IF FOUND THEN inserted_count := inserted_count + 1; END IF;
    accepted := accepted || jsonb_build_array(sid);
  END LOOP;

  UPDATE public.devices SET last_seen_at = now(), status = 'online' WHERE id = did;
  RETURN jsonb_build_object(
    'acceptedSourceEventIds', accepted,
    'inserted', inserted_count,
    'serverTime', now()
  );
END
$function$;
