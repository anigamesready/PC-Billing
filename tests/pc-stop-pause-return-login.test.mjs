import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const html = readFileSync('index.html', 'utf8');
const main = readFileSync('main.js', 'utf8');
const preload = readFileSync('preload.js', 'utf8');
const renderer = readFileSync('renderer.js', 'utf8');
const cloud = readFileSync('v11-cloud.js', 'utf8');
const packageJson = JSON.parse(readFileSync('package.json', 'utf8'));
const lockJson = JSON.parse(readFileSync('package-lock.json', 'utf8'));

test('authorized renter Stop/Pause returns to Login after stopping the session', () => {
  const start = html.indexOf('async function authorizeStopPauseAndStop');
  const end = html.indexOf('function pauseStopSessionFromTimer', start);
  assert.ok(start >= 0 && end > start, 'authorized Stop/Pause handler must exist');
  const handler = html.slice(start, end);
  const stop = handler.indexOf('await Promise.resolve(stopActiveSession())');
  const domLogin = handler.indexOf('ensureBillingLoginViewAfterStopPause()');
  const nativeLogin = handler.indexOf('window.electronAPI.returnBillingToLogin()');
  assert.ok(stop >= 0 && domLogin > stop && nativeLogin > domLogin,
    'order must be stop session -> show Login DOM -> restore native Login kiosk');
  assert.match(handler, /if\s*\(!allowed\)[\s\S]*?Timer rental tetap berjalan\./);
  assert.match(handler, /stopIssued\s*\?\s*'LOGIN BILLING GAGAL DIPULIHKAN'/);
});

test('Login DOM explicitly hides the timer widget and refits the Login box', () => {
  assert.match(html, /function ensureBillingLoginViewAfterStopPause\(\)/);
  assert.match(html, /document\.getElementById\('lock-screen'\)/);
  assert.match(html, /document\.getElementById\('timer-widget'\)/);
  assert.match(html, /loginScreen\.classList\.remove\('hidden'\)/);
  assert.match(html, /timerWidget\.classList\.add\('hidden'\)/);
  assert.match(html, /fitLoginBoxToViewport\(\)/);
  assert.match(html, /focusLoginInput, 120/);
});

test('main-process Login IPC restores the established kiosk mode with sender/readiness guards', () => {
  const start = main.indexOf("ipcMain.handle('return-billing-to-login'");
  const end = main.indexOf("ipcMain.on('resize-timer-window'", start);
  assert.ok(start >= 0 && end > start, 'native Login IPC must exist');
  const handler = main.slice(start, end);
  assert.match(handler, /event\.sender !== mainWindow\?\.webContents/);
  assert.match(handler, /billingUiReady/);
  assert.match(handler, /billingRecoveryMode/);
  assert.match(handler, /applyLoginKioskMode\(mainWindow\)/);
  assert.match(handler, /return \{ok:true,mode:'login'\}/);
});

test('preload exposes only the intended Login transition bridge', () => {
  assert.match(preload, /returnBillingToLogin:\s*\(\)\s*=>\s*ipcRenderer\.invoke\('return-billing-to-login'\)/);
});

test('existing Admin, expiry, pairing and app identity contracts remain present', () => {
  assert.match(html, /function pauseSession\(showNotif = false\)/);
  assert.match(html, /if \(remaining <= 0\)/);
  assert.match(html, /function openAdminAuth\(\)/);
  assert.match(cloud, /billing_v11_outbox/);
  assert.match(cloud, /billing_v11_sync_cursor/);
  assert.match(cloud, /request\('\/device\/session-control-policy'/);
  assert.equal(packageJson.version, '12.5.0');
  assert.equal(lockJson.version, '12.5.0');
  assert.equal(packageJson.build.appId, 'com.anigames.billing.v1249dbandroid');
  assert.equal(packageJson.build.productName, 'AniGames Billing V12.4.9 DB Android');
  assert.match(renderer, /V12\.5\.0-STOP-PAUSE-RETURN-LOGIN/);
  assert.match(html, /V12\.5\.0-STOP-PAUSE-RETURN-LOGIN/);
  assert.match(cloud, /APP='V12\.5\.0-DB-ANDROID'/);
});
