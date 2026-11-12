// Тесты session.js: экран входа по ответу `session open`, одноразовый код,
// отклонённый токен возобновления, варианты восстановления GitHub.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { routeReply, openSession, recoveryOptions } from '../assets/js/session.js';

const fail = (code, extra = {}) => ({ ok: false, data: null, error: { code, message: code, ...extra }, sync: null });
const ok = (data = {}) => ({ ok: true, data, error: null, sync: null });

function fakeConnection(replies, resume = null) {
  const calls = [];
  const connection = {
    resume,
    calls,
    forget() { connection.resume = null; },
    async request(argv, options) {
      calls.push({ argv, secrets: options.secrets });
      assert.ok(replies.length > 0, `лишний запрос ${argv.join(' ')}`);
      return replies.shift();
    },
  };
  return connection;
}

test('routeReply: экран входа по коду', () => {
  assert.equal(routeReply(ok()), 'open');
  assert.equal(routeReply(fail('auth_required', { secret: 'script-password' })), 'script-password');
  assert.equal(routeReply(fail('auth_failed', {})), 'script-password');
  assert.equal(routeReply(fail('auth_required', { secret: 'access-token' })), 'access-code');
  assert.equal(routeReply(fail('vault_password_required')), 'vault-password');
  assert.equal(routeReply(fail('vault_password_invalid')), 'vault-password');
  assert.equal(routeReply(fail('not_configured')), 'first-run');
  for (const code of ['github_format_outdated', 'github_format_newer', 'github_format_invalid']) {
    assert.equal(routeReply(fail(code)), 'recovery');
  }
  assert.equal(routeReply(fail('locked')), 'retry');
  assert.equal(routeReply(fail('source_failed')), 'retry');
});

test('openSession: код из ссылки, пароль и --remember-key', async () => {
  const connection = fakeConnection([fail('auth_required', { secret: 'script-password' }), ok()]);
  await openSession(connection, { ticket: 'ab12' });
  await openSession(connection, { secrets: { 'vault-password': 'v' }, remember: true });
  assert.deepEqual(connection.calls, [
    { argv: ['session', 'open'], secrets: { 'access-token': 'ab12' } },
    { argv: ['session', 'open', '--remember-key'], secrets: { 'vault-password': 'v' } },
  ]);
});

test('openSession: отклонённый токен возобновления стирается, вход без него', async () => {
  const connection = fakeConnection([
    fail('auth_failed', { secret: 'access-token' }),
    fail('auth_required', { secret: 'script-password' }),
  ], 'f'.repeat(64));
  const reply = await openSession(connection, { secrets: { 'script-password': 'pw' } });
  assert.equal(reply.error.secret, 'script-password');
  assert.equal(connection.resume, null);
  assert.deepEqual(connection.calls.map((call) => call.secrets), [
    { 'script-password': 'pw', 'access-token': 'f'.repeat(64) },
    { 'script-password': 'pw' },
  ]);
});

test('openSession: отклонённый одноразовый код не повторяется', async () => {
  const connection = fakeConnection([fail('auth_failed', { secret: 'access-token' })]);
  const reply = await openSession(connection, { ticket: 'dead' });
  assert.equal(reply.error.code, 'auth_failed');
  assert.equal(connection.calls.length, 1);
});

test('recoveryOptions: как system.rs::github_recovery', () => {
  assert.deepEqual(recoveryOptions('github_format_outdated').map((o) => o.verb), ['github-migrate-format', 'github-replace-with-local']);
  assert.deepEqual(recoveryOptions('github_format_invalid').map((o) => o.verb), ['github-replace-with-local']);
  assert.deepEqual(recoveryOptions('github_format_newer'), []);
});
