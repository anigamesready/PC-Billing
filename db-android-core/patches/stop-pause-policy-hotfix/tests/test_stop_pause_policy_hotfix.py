from pathlib import Path
import importlib.util
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PATCHER_PATH = ROOT / "apply_stop_pause_policy_api_fix.py"
spec = importlib.util.spec_from_file_location("stop_pause_patcher", PATCHER_PATH)
patcher = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(patcher)

OLD_SERVER = r'''const RPC = {
  admin_get_free_test_policy: { auth: "admin", sql: "SELECT api.admin_get_free_test_policy($1::text) AS result", args: [] },
  admin_set_free_test_policy: { auth: "admin", sql: "SELECT api.admin_set_free_test_policy($1::text,$2::boolean) AS result", args: ["p_enabled"] },
};
async function rpcRequest(req, res, name, body) {
  const spec = RPC[name];
  if (!spec) return send(res, 404, { message: "RPC_NOT_ALLOWED" });
  const token = bearer(req);
}
async function deviceRequest(req, res, path, body) {
  const token = bearer(req) || str(body.token, 512);
  if (path === "/device/test-policy") return send(res,200,await scalar("SELECT api.device_free_test_policy($1::text) AS result",[token]));
  if (path === "/device/rental/lookup") return send(res,200,await scalar("SELECT api.device_rental_lookup($1::text,$2::text) AS result",[token,str(body.code,120)]));
  return send(res,404,{ok:false,error:"not_found",path});
}
'''

class StopPauseApiHotfixTests(unittest.TestCase):
    def test_old_stage_server_receives_only_three_required_entries(self):
        patched, changes = patcher.patch_server_text(OLD_SERVER)
        self.assertEqual(
            changes,
            [
                "admin_get_billing_stop_pause_policy",
                "admin_set_billing_stop_pause_policy",
                "/device/session-control-policy",
            ],
        )
        self.assertIn(patcher.GET_ENTRY, patched)
        self.assertIn(patcher.SET_ENTRY, patched)
        self.assertIn(patcher.DEVICE_ENTRY, patched)
        self.assertEqual(patched.count('if (!spec) return send(res, 404, { message: "RPC_NOT_ALLOWED" });'), 1)

    def test_patch_is_idempotent(self):
        patched, first = patcher.patch_server_text(OLD_SERVER)
        again, second = patcher.patch_server_text(patched)
        self.assertEqual(len(first), 3)
        self.assertEqual(second, [])
        self.assertEqual(again, patched)

    def test_latest_server_source_is_left_unchanged(self):
        current = OLD_SERVER.replace(
            patcher.GET_ANCHOR,
            patcher.GET_ANCHOR + "\n" + patcher.GET_ENTRY,
        ).replace(
            patcher.SET_ANCHOR,
            patcher.SET_ANCHOR + "\n" + patcher.SET_ENTRY,
        ).replace(
            patcher.DEVICE_ANCHOR,
            patcher.DEVICE_ANCHOR + "\n" + patcher.DEVICE_ENTRY,
        )
        updated, changes = patcher.patch_server_text(current)
        self.assertEqual(changes, [])
        self.assertEqual(updated, current)

    def test_duplicate_rpc_is_refused(self):
        duplicate = OLD_SERVER.replace(
            patcher.GET_ANCHOR,
            patcher.GET_ANCHOR + "\n" + patcher.GET_ENTRY + "\n" + patcher.GET_ENTRY,
        )
        with self.assertRaisesRegex(ValueError, "DUPLICATE_RPC_ENTRY"):
            patcher.patch_server_text(duplicate)

    def test_unknown_server_layout_is_refused(self):
        with self.assertRaisesRegex(ValueError, "EXPECTED_SINGLE_RPC_MAP"):
            patcher.patch_server_text("export default {};")

    def test_device_route_contract_mismatch_is_refused(self):
        malformed = OLD_SERVER.replace(
            patcher.DEVICE_ANCHOR,
            '  if (path === "/device/session-control-policy") return send(res,200,{enabled:true});',
        )
        with self.assertRaisesRegex(ValueError, "DEVICE_SESSION_CONTROL_POLICY_CONTRACT_MISMATCH"):
            patcher.patch_server_text(malformed)

    def test_migration_is_additive_and_defaults_off(self):
        sql = (ROOT / "sql/012_billing_stop_pause_policy.sql").read_text(encoding="utf-8")
        self.assertIn("BEGIN;", sql)
        self.assertIn("VALUES ('billing_stop_pause_enabled', false)", sql)
        self.assertIn("ON CONFLICT (feature_key) DO NOTHING", sql)
        self.assertIn("api.admin_get_billing_stop_pause_policy(p_session_token text)", sql)
        self.assertIn("api.admin_set_billing_stop_pause_policy(p_session_token text, p_enabled boolean)", sql)
        self.assertIn("api.device_session_control_policy(p_token text)", sql)
        self.assertIn("REVOKE ALL ON FUNCTION api.admin_get_billing_stop_pause_policy(text) FROM PUBLIC", sql)
        self.assertIn("GRANT EXECUTE ON FUNCTION api.admin_set_billing_stop_pause_policy(text, boolean) TO ani_api_runtime", sql)
        for forbidden in ("DROP TABLE", "TRUNCATE TABLE", "DELETE FROM PUBLIC.RENTAL_ACCOUNTS", "DELETE FROM PUBLIC.RENTAL_SESSIONS"):
            self.assertNotIn(forbidden, sql.upper())

    def test_termux_installer_is_stage_only_and_checks_backups(self):
        shell = (ROOT / "APPLY-STOP-PAUSE-FIX.sh").read_text(encoding="utf-8")
        self.assertIn("ani_games_ready_stage", shell)
        self.assertIn('/proc/$PID/environ', shell)
        self.assertIn('decodeURIComponent(u.username) !== "ani_api_stage_login"', shell)
        self.assertIn('u.hostname !== "127.0.0.1"', shell)
        self.assertIn('vars.PORT !== expectedPort', shell)
        self.assertIn('pg_postmaster_start_time()', shell)
        self.assertIn('[ "$RUNTIME_DB_ID" = "$LOCAL_DB_ID" ]', shell)
        self.assertLess(shell.index("RUNTIME_DB_ID="), shell.index("pg_dump --format=custom"))
        self.assertIn(r'API_PORT="${ANI_DB_STAGE_PORT:-8788}"', shell)
        self.assertIn("pg_dump --format=custom", shell)
        self.assertIn("pg_restore --list", shell)
        self.assertIn("AUTH_REQUIRED", shell)
        self.assertIn('bash "$STOP_SCRIPT"', shell)
        self.assertIn('bash "$START_SCRIPT"', shell)
        self.assertIn("RPC_NOT_ALLOWED", shell)
        self.assertNotIn("ANI_DB_NAME=ani_games_ready", shell)


    def _run_runtime_db_guard(self, file_db="ani_games_ready_stage", live_db="ani_games_ready_stage"):
        shell = (ROOT / "APPLY-STOP-PAUSE-FIX.sh").read_text(encoding="utf-8")
        marker = """node --input-type=module - "$ENV_FILE" "/proc/$PID/environ" "$DB_NAME" "$API_PORT" <<'NODE'
"""
        start = shell.index(marker) + len(marker)
        end = shell.index("\nNODE\n", start)
        node_source = shell[start:end]

        with tempfile.TemporaryDirectory() as temp:
            server = Path(temp)
            package = server / "node_modules" / "pg"
            package.mkdir(parents=True)
            (package / "package.json").write_text(
                '{"type":"module","exports":"./index.js"}', encoding="utf-8"
            )
            (package / "index.js").write_text(
                "export class Client { async connect() {} "
                "async query() { return { rows: [{ db: 'ani_games_ready_stage', started: 123 }] }; } "
                "async end() {} }",
                encoding="utf-8",
            )
            file_env = server / ".env"
            proc_env = server / "process-environ"
            def url(db):
                return f"postgresql://ani_api_stage_login:abcdef@127.0.0.1:5432/{db}?sslmode=disable"
            file_env.write_text(
                f"DATABASE_URL={url(file_db)}\nANI_BIND=127.0.0.1\nPORT=8788\n",
                encoding="utf-8",
            )
            proc_env.write_bytes(
                f"DATABASE_URL={url(live_db)}\0ANI_BIND=127.0.0.1\0PORT=8788\0".encode()
            )
            return subprocess.run(
                ["node", "--input-type=module", "-", str(file_env), str(proc_env),
                 "ani_games_ready_stage", "8788"],
                input=node_source, text=True, capture_output=True, cwd=server, check=False,
            )

    def test_runtime_db_guard_accepts_exact_stage_target(self):
        result = self._run_runtime_db_guard()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "ani_games_ready_stage|123")

    def test_runtime_db_guard_rejects_wrong_database_or_live_env_drift(self):
        wrong_db = self._run_runtime_db_guard(file_db="ani_games_ready")
        self.assertNotEqual(wrong_db.returncode, 0)
        self.assertIn("STAGE_DATABASE_IDENTITY_CHECK_FAILED", wrong_db.stderr)

        drift = self._run_runtime_db_guard(live_db="ani_games_ready")
        self.assertNotEqual(drift.returncode, 0)
        self.assertIn("STAGE_DATABASE_IDENTITY_CHECK_FAILED", drift.stderr)

if __name__ == "__main__":
    unittest.main(verbosity=2)
