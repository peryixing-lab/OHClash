// Execute the production extension with mocked platform boundaries. No device,
// profile secrets, network service, or VPN permissions are needed.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const ts = require(process.env.OHCLASH_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/ohpm/node_modules/typescript');
const source = fs.readFileSync(path.join(__dirname,
  '../entry/src/main/ets/vpnextension/FlClashVpnExtension.ets'), 'utf8');
const compiled = ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText;

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
async function flush() { await new Promise((resolve) => setImmediate(resolve)); }

function harness(overrides = {}) {
  const files = new Map();
  const descriptors = new Map();
  const timers = new Map();
  const calls = { launch: 0, create: 0, tun: 0, stop: 0, destroy: 0, closed: [] };
  let nextFd = 100;
  let now = 1000;
  const commandPath = '/files/vpn-command.json';
  files.set(commandPath, JSON.stringify({ sessionId: 'session-a', action: 'start',
    requestedAt: now, secret: 'synthetic-test-secret' }));
  const fileIo = {
    OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
    readTextSync(file) { if (!files.has(file)) throw new Error('missing'); return files.get(file); },
    openSync(file) { const fd = nextFd++; descriptors.set(fd, file); return { fd }; },
    writeSync(fd, text) { files.set(descriptors.get(fd), text); },
    closeSync(fd) { calls.closed.push(typeof fd === 'object' ? fd.fd : fd); },
    renameSync(from, to) { files.set(to, files.get(from)); files.delete(from); },
    unlinkSync(file) { files.delete(file); }
  };
  const core = {
    async launchAsync() { calls.launch++; return overrides.launch ? overrides.launch() : ''; },
    async startTunAsync(fd) { calls.tun++; return overrides.tun ? overrides.tun(fd) : true; },
    async stopAsync() { calls.stop++; if (overrides.stop) await overrides.stop(); },
    getTunError() { return 'synthetic TUN failure'; }
  };
  const connection = {
    async create() { calls.create++; return overrides.create ? overrides.create() : 42; },
    async destroy() { calls.destroy++; if (overrides.destroy) await overrides.destroy(); }
  };
  const modules = {
    '@kit.NetworkKit': { VpnExtensionAbility: class {},
      vpnExtension: { createVpnConnection: () => connection } },
    '@kit.BasicServicesKit': {},
    '@kit.CoreFileKit': { fileIo },
    '@kit.PerformanceAnalysisKit': { hilog: { info() {}, error() {}, warn() {} } },
    '../data/RuntimeDiagnostics': { RuntimeDiagnostics: { watch() {}, record() {} } },
    'libflclash_napi.so': core
  };
  const exports = {};
  vm.runInNewContext(compiled, { exports, require: (name) => modules[name],
    setInterval(callback) { const id = timers.size; timers.set(id, callback); return id; },
    clearInterval(id) { timers.delete(id); }, Date: { now: () => now } });
  const ability = new exports.default();
  ability.context = { filesDir: '/files' };
  return { ability, calls, files, timers,
    state() { return JSON.parse(files.get('/files/vpn-status.json')); },
    command(action, sessionId = 'session-a') {
      files.set(commandPath, JSON.stringify({ sessionId, action, secret: 'synthetic-test-secret', requestedAt: now }));
    },
    tick() { now += 250; [...timers.values()].forEach((callback) => callback()); },
    advance(ms) { now += ms; [...timers.values()].forEach((callback) => callback()); }
  };
}

test('stop acknowledgement waits for native stop and VPN destruction', async () => {
  const stopped = deferred(), destroyed = deferred();
  const h = harness({ stop: () => stopped.promise, destroy: () => destroyed.promise });
  h.ability.onCreate(); await flush();
  assert.equal(h.state().status, 'running');
  h.command('stop'); h.tick(); await flush();
  assert.equal(h.state().status, 'stopping');
  assert.equal(h.calls.destroy, 0);
  stopped.resolve(); await flush();
  assert.equal(h.calls.destroy, 1);
  assert.equal(h.state().status, 'stopping');
  h.ability.onDestroy(); destroyed.resolve(); await flush();
  assert.equal(h.state().status, 'stopped');
  assert.equal(h.state().cleanupComplete, true);
  assert.equal(h.calls.stop, 1);
  assert.equal(h.calls.destroy, 1);
  assert.equal(h.files.has('/files/vpn-session.json'), false);
});

test('cancelling an in-flight native launch never creates VPN or publishes running', async () => {
  const launch = deferred();
  const h = harness({ launch: () => launch.promise });
  h.ability.onCreate(); h.command('stop'); h.tick(); await flush();
  assert.equal(h.state().status, 'stopping');
  launch.resolve(''); await flush();
  assert.equal(h.calls.create, 0);
  assert.equal(h.calls.tun, 0);
  assert.equal(h.calls.stop, 1);
  assert.equal(h.state().status, 'stopped');
});

test('cancelling system VPN creation closes only the acquired untransferred fd', async () => {
  const create = deferred();
  const h = harness({ create: () => create.promise });
  h.ability.onCreate(); await flush();
  h.ability.onDestroy(); create.resolve(42); await flush();
  assert.equal(h.calls.tun, 0);
  assert.equal(h.calls.destroy, 1);
  assert.equal(h.calls.closed.filter((fd) => fd === 42).length, 1);
  assert.equal(h.state().status, 'stopped');
});

test('cancelling native TUN startup does not double-close transferred fd', async () => {
  const tun = deferred();
  const h = harness({ tun: () => tun.promise });
  h.ability.onCreate(); await flush();
  h.command('stop'); h.tick(); tun.resolve(true); await flush();
  assert.equal(h.calls.tun, 1);
  assert.equal(h.calls.closed.includes(42), false);
  assert.equal(h.calls.destroy, 1);
  assert.equal(h.state().status, 'stopped');
});

test('an existing foreign VPN is never destroyed when create fails', async () => {
  const h = harness({ create: () => { throw { code: 2203002, message: 'VPN exists' }; } });
  h.ability.onCreate(); await flush();
  assert.equal(h.calls.destroy, 0);
  assert.equal(h.calls.stop, 1);
  assert.equal(h.state().status, 'error');
  assert.equal(h.state().cleanupComplete, true);
  assert.match(h.state().error, /2203002/);
});

test('invalid profile does not change system routes and partial native launch is cleaned', async () => {
  const h = harness({ launch: () => 'invalid config' });
  h.ability.onCreate(); await flush();
  assert.equal(h.calls.create, 0);
  assert.equal(h.calls.stop, 1);
  assert.equal(h.state().status, 'error');
  assert.equal(h.state().cleanupComplete, true);
});

test('TUN failure releases the owned VPN and permits a new clean session', async () => {
  const h = harness({ tun: () => false });
  h.ability.onCreate(); await flush();
  assert.equal(h.state().status, 'error');
  assert.equal(h.state().cleanupComplete, true);
  assert.equal(h.calls.destroy, 1);
  assert.equal(h.files.has('/files/vpn-session.json'), false);
});

test('cleanup failure cannot falsely acknowledge stopped', async () => {
  const h = harness({ destroy: () => { throw new Error('system destroy failed'); } });
  h.ability.onCreate(); await flush();
  h.command('stop'); h.tick(); await flush();
  assert.equal(h.state().status, 'error');
  assert.equal(h.state().cleanupComplete, false);
});

test('late old-session callbacks cannot overwrite new-session state or timer', async () => {
  const launch = deferred();
  const h = harness({ launch: () => launch.promise });
  h.ability.onCreate();
  h.command('start', 'session-b');
  const newer = JSON.stringify({ sessionId: 'session-b', status: 'starting' });
  h.files.set('/files/vpn-status.json', newer);
  h.files.set('/files/vpn-session.json', JSON.stringify({ sessionId: 'session-b', startedAt: 5000 }));
  h.tick(); launch.resolve(''); await flush();
  assert.equal(h.files.get('/files/vpn-status.json'), newer);
  assert.equal(JSON.parse(h.files.get('/files/vpn-session.json')).sessionId, 'session-b');
  assert.equal(h.calls.create, 0);
});

test('running heartbeat advances independently of UI process state', async () => {
  const h = harness(); h.ability.onCreate(); await flush();
  const previous = h.state().updatedAt;
  h.advance(2200);
  assert.ok(h.state().updatedAt > previous);
  assert.equal(h.state().status, 'running');
  h.ability.onDestroy(); await flush();
  assert.equal(h.timers.size, 0);
});

test('repeated fresh sessions do not retain a stopped session identity', async () => {
  for (let i = 0; i < 6; i++) {
    const h = harness(); h.command('start', `cycle-${i}`);
    h.ability.onCreate(); await flush();
    assert.equal(h.state().sessionId, `cycle-${i}`);
    assert.equal(h.state().status, 'running');
    h.command('stop', `cycle-${i}`); h.tick(); await flush();
    assert.equal(h.state().status, 'stopped');
    assert.equal(h.calls.stop, 1);
    assert.equal(h.calls.destroy, 1);
  }
});
