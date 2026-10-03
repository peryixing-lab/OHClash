const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const ts = require(process.env.OHCLASH_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/ohpm/node_modules/typescript');

test('reconnection reuses one native observer and releases each attempt callback', () => {
  let created = 0, callback;
  const observer = {
    onAuthorizationResult(listener) { callback = listener; },
    offAuthorizationResult() { callback = undefined; }
  };
  const exports = {};
  const source = fs.readFileSync(path.join(__dirname,
    '../entry/src/main/ets/data/VpnAuthorization.ets'), 'utf8');
  vm.runInNewContext(ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText, { exports, require: () => ({ vpnExtension: {
    createVpnObserver() { created++; return observer; }
  } }) });
  const auth = exports.VpnAuthorization;
  auth.unsubscribe(); // Page teardown before the first attempt is safe.
  let received = 0;
  for (let attempt = 0; attempt < 20; attempt++) {
    auth.subscribe((allowed) => { assert.equal(allowed, attempt % 2 === 0); received++; });
    callback(attempt % 2 === 0);
    auth.unsubscribe();
    assert.equal(callback, undefined);
    assert.equal(auth.observer, observer);
  }
  assert.equal(created, 1);
  assert.equal(received, 20);
});
