from pathlib import Path
import json
import sys
R=Path(sys.argv[1]) if len(sys.argv)>1 else Path('.')
mainp,indexp,pkgp,lockp,versionp=[R/x for x in ('main.js','index.html','package.json','package-lock.json','VERSION.txt')]
for p in (mainp,indexp,pkgp,lockp,versionp):
    if not p.is_file(): raise SystemExit('Required PC V12.4.3 source file missing: '+str(p))
main=mainp.read_text(encoding='utf-8'); index=indexp.read_text(encoding='utf-8')
pkg=json.loads(pkgp.read_text(encoding='utf-8')); lock=json.loads(lockp.read_text(encoding='utf-8'))
if 'V12.4.4-ADMIN-WINDOWS-CONTROLS' in index:
    print('PASS: PC V12.4.4 patch already applied'); raise SystemExit(0)
mg="""    // ANI_GAMES_V12_4_3_BLOCK_SHUTDOWN_IPC
    if (String(action || '').toLowerCase() === 'shutdown') {
        console.warn('[AniGames] Shutdown dinonaktifkan pada build emergency V12.4.3.');
        return { ok:false, error:'SHUTDOWN_DISABLED', message:'Shutdown dinonaktifkan pada build emergency.' };
    }

"""
rg="""            if (cmd === 'shutdown') {
                return {ok:false, ignored:true, error:'SHUTDOWN_DISABLED', message:'Perintah shutdown dinonaktifkan pada build emergency.'};
            }
"""
if main.count(mg)!=1: raise SystemExit('Expected exact V12.4.3 main-process Shutdown denial once')
if index.count(rg)!=1: raise SystemExit('Expected exact V12.4.3 renderer Shutdown denial once')
main=main.replace(mg,'',1); index=index.replace(rg,'',1)
if pkg.get('version')!='12.4.3' or lock.get('version')!='12.4.3': raise SystemExit('Unexpected PC package baseline; expected 12.4.3')
pkg['version']='12.4.4'; pkg['description']='AniGames Billing V12.4.4: restore direct Admin Windows shutdown/restart/logoff while keeping scheduled shutdown countdown disabled.'
lock['version']='12.4.4'
if isinstance(lock.get('packages'),dict) and isinstance(lock['packages'].get(''),dict): lock['packages']['']['version']='12.4.4'
old='V12.4.3-EMERGENCY-NO-SHUTDOWN'; new='V12.4.4-ADMIN-WINDOWS-CONTROLS'
if index.count(old)<2: raise SystemExit('Expected two visible/runtime V12.4.3 version markers')
index=index.replace(old,new)
for token in ("const powerCommands = { logoff: ['/l'], restart: ['/r', '/t', '0'], shutdown: ['/s', '/t', '0'] }","execFile('shutdown.exe', args","if (cmd === 'schedule_shutdown')",'SHUTDOWN_TIMER_DISABLED',"localStorage.removeItem('billing_shutdown_timer_v12')",'ANI_GAMES_V12_4_3_CANCEL_PENDING_WINDOWS_SHUTDOWN',"execFile('shutdown.exe', ['/a']"):
    if token not in main+'\n'+index: raise SystemExit('PC control/timer regression marker missing: '+token)
if 'ANI_GAMES_V12_4_3_BLOCK_SHUTDOWN_IPC' in main or 'ANI_GAMES_V12_4_3_BLOCK_SHUTDOWN' in index: raise SystemExit('Old unconditional Shutdown denial remains')
for token in ('function v12CheckScheduledShutdown()','function v12ShutdownScheduleFromAdmin(','function v12CancelScheduledShutdown(','V12_SHUTDOWN_TIMER_KEY'):
    if token in index: raise SystemExit('Scheduled shutdown countdown reintroduced: '+token)
versionp.write_text(new+'\nDirect Admin Windows shutdown/restart/logoff restored. Scheduled shutdown countdown remains removed; startup still aborts any legacy pending Windows shutdown countdown.\n',encoding='utf-8')
mainp.write_text(main,encoding='utf-8'); indexp.write_text(index,encoding='utf-8')
pkgp.write_text(json.dumps(pkg,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
lockp.write_text(json.dumps(lock,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
(R/'ADMIN-WINDOWS-CONTROLS-V12.4.4-AUDIT.md').write_text(
 '# PC Billing V12.4.4 — Admin Windows Controls\n\n'
 '- Restores direct Admin shutdown by removing only the V12.4.3 emergency denial at renderer and main IPC layers.\n'
 '- Preserves the existing Windows logoff, restart and shutdown power-action whitelist.\n'
 '- Keeps schedule_shutdown rejected; no countdown engine or settings are restored.\n'
 '- Keeps startup cancellation of legacy pending Windows shutdown countdown (shutdown.exe /a).\n'
 '- Preserves application ID, pairing/token storage, rental runtime, dual-DB routing, watchdog-after-ready and WOL.\n'
 '- Static checks pass; manual Windows/Stardesk action test remains required on a real PC.\n',
 encoding='utf-8')
print('PASS: PC V12.4.4 direct Windows Shutdown restored; timer remains disabled.')
