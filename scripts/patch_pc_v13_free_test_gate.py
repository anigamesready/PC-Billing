from pathlib import Path
import re

ROOT = Path(".")
HTML = ROOT / "index.html"
CLOUD = ROOT / "v11-cloud.js"
EDGE = ROOT / "supabase/functions/ani-games-api/index.ts"

BUILD = "V12.3.0-FREE-TEST-GATE-SHUTDOWN-TIMER"
TEST_MARK = "V12.3.0-TEST-POLICY-PREFLIGHT"
PHONE = "082298316902"

def fail(msg):
    raise SystemExit(msg)

def matching_brace(src, open_index):
    depth = 0
    state = "normal"
    quote = ""
    escaped = False
    i = open_index
    while i < len(src):
        ch = src[i]
        nxt = src[i + 1] if i + 1 < len(src) else ""
        if state == "line_comment":
            if ch == "\n":
                state = "normal"
        elif state == "block_comment":
            if ch == "*" and nxt == "/":
                state = "normal"
                i += 1
        elif state == "string":
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == quote:
                state = "normal"
        else:
            if ch == "/" and nxt == "/":
                state = "line_comment"
                i += 1
            elif ch == "/" and nxt == "*":
                state = "block_comment"
                i += 1
            elif ch in ("'", '"'):
                state = "string"
                quote = ch
                escaped = False
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return i
        i += 1
    fail("Could not find the end of startTenMinuteTest(); refusing to patch.")

html = HTML.read_text(encoding="utf-8")
cloud = CLOUD.read_text(encoding="utf-8")
edge = EDGE.read_text(encoding="utf-8")

if TEST_MARK not in html:
    pattern = re.compile(r"(?m)^(?P<indent>[ \t]*)(?P<async>async[ \t]+)?function[ \t]+startTenMinuteTest[ \t]*\([ \t]*\)[ \t]*\{")
    matches = list(pattern.finditer(html))
    if len(matches) != 1:
        fail(f"Expected exactly one live startTenMinuteTest() function, found {len(matches)}")
    m = matches[0]
    declaration = m.group(0)
    if not m.group("async"):
        declaration = m.group("indent") + "async " + declaration[len(m.group("indent")):]
    html = html[:m.start()] + declaration + html[m.end():]

    # The preflight is inside the function itself so both the clickable button and remote command fail closed.
    m = pattern.search(html)
    if not m:
        fail("Async startTenMinuteTest() anchor vanished after update.")
    open_index = m.end() - 1
    guard = f"""
{m.group("indent")}    // {TEST_MARK}: server authorization is required; unknown/offline state blocks the test.
{m.group("indent")}    try {{
{m.group("indent")}        const __freeTestPolicy = await window.v11CheckFreeTestPermission();
{m.group("indent")}        if (__freeTestPolicy?.enabled !== true) {{
{m.group("indent")}            window.alert('Silahkan hubungi admin untuk melakukan tes {PHONE}');
{m.group("indent")}            return {{ok:false, error:'FREE_TEST_DISABLED', message:'Silahkan hubungi admin untuk melakukan tes {PHONE}'}};
{m.group("indent")}        }}
{m.group("indent")}    }} catch (__freeTestError) {{
{m.group("indent")}        window.alert('Izin test 10 menit belum bisa diverifikasi. Test diblokir demi keamanan.\\nSilahkan hubungi admin untuk melakukan tes {PHONE}');
{m.group("indent")}        return {{ok:false, error:'FREE_TEST_POLICY_UNAVAILABLE', message:String(__freeTestError?.message || __freeTestError || 'Status izin test tidak tersedia.')}};
{m.group("indent")}    }}
"""
    html = html[:open_index + 1] + guard + html[open_index + 1:]
    m = pattern.search(html)
    open_index = m.end() - 1
    close_index = matching_brace(html, open_index)
    success = f"\n{m.group('indent')}    return {{ok:true, message:'Test 10 menit dimulai pada PC.', duration_seconds:600}};\n"
    html = html[:close_index] + success + html[close_index:]

# Add a supported remote command path: old builds previously returned "Perintah tidak didukung".
if "if (cmd === 'start_trial') {" not in html:
    command_anchor = "            const cmd = String(command || '').trim();"
    if html.count(command_anchor) != 1:
        fail("Live Electron remote-command dispatcher anchor mismatch; refusing to modify a non-live renderer.")
    remote_handler = f"""
            if (cmd === 'start_trial') {{
                if (currentActiveCode) return {{ok:false, error:'SESSION_ALREADY_ACTIVE', message:'Selesaikan sesi yang sedang aktif sebelum menjalankan test timer.'}};
                const __testResult = await startTenMinuteTest();
                if (__testResult?.ok === true) return __testResult;
                if (currentActiveCode === TEST_SESSION_CODE) return {{ok:true, message:'Test 10 menit dimulai pada PC.', duration_seconds:600}};
                return __testResult && __testResult.ok === false
                    ? __testResult
                    : {{ok:false, error:'FREE_TEST_NOT_STARTED', message:'Test 10 menit tidak dimulai.'}};
            }}
"""
    html = html.replace(command_anchor, command_anchor + remote_handler, 1)

# Server preflight helper. It calls the active project Edge Function and never trusts a cached toggle.
if "window.v11CheckFreeTestPermission" not in cloud:
    cloud_anchor = "  const fp=u=>JSON.stringify("
    if cloud.count(cloud_anchor) != 1:
        fail("Cloud API helper insertion anchor mismatch; refusing to patch another source.")
    helper = f"""
  window.v11CheckFreeTestPermission=async function(){{
    const c=read();
    if(!c||!c.token)throw new Error('PAIRING_REQUIRED');
    const d=await request('/device/test-policy',{{token:c.token}},{{retries:1,timeoutMs:7000}});
    if(!d||typeof d.enabled!=='boolean')throw new Error(d?.error||d?.message||'FREE_TEST_POLICY_UNAVAILABLE');
    return d;
  }};
"""
    cloud = cloud.replace(cloud_anchor, helper + cloud_anchor, 1)

# Edge route is deployed from this source to both DB projects after the SQL migration is applied.
if 'p==="device/test-policy"' not in edge:
    route_anchor = 'if(p==="device/heartbeat")'
    if edge.count(route_anchor) != 1:
        fail("Edge Function route insertion anchor mismatch.")
    route = 'if(p==="device/test-policy")return out(200,await rpc("device_free_test_policy",{p_token:String(b.token||"")}));\n'
    edge = edge.replace(route_anchor, route + route_anchor, 1)

# Exact version and fail-closed checks. The preceding timer patch must already have applied the V12.3.0 identity.
if "const APP_VERSION = '" + BUILD + "';" not in html:
    fail("V12.3.0 active Electron runtime version marker missing.")
if "APP='" + BUILD + "'" not in cloud:
    fail("V12.3.0 cloud version marker missing.")
for token in [TEST_MARK, "window.v11CheckFreeTestPermission", "FREE_TEST_DISABLED", PHONE, "if (cmd === 'start_trial')"]:
    if token not in html + "\n" + cloud:
        fail("V12.3.0 free-test static assertion missing: " + token)
if 'p==="device/test-policy"' not in edge or 'device_free_test_policy' not in edge:
    fail("Edge Function route device/test-policy is missing.")
if "renderer.js is not loaded by Electron." not in html:
    fail("Expected live Electron index.html runtime marker; refusing to patch the wrong JS file.")

HTML.write_text(html, encoding="utf-8")
CLOUD.write_text(cloud, encoding="utf-8")
EDGE.write_text(edge, encoding="utf-8")
print("PASS: V12.3.0 server-permission preflight, exact disabled popup, remote start_trial command handler, and Edge policy route.")
