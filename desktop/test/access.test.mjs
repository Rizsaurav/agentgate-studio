import { test } from 'node:test';
import assert from 'node:assert/strict';
import { authorized } from '../scripts/access.mjs';
test('private desktop server denies absent, malformed, and wrong tokens', () => {
  const token = 'a'.repeat(64);
  assert.equal(authorized(token, token), true);
  for (const supplied of [
    undefined,
    null,
    [],
    token.slice(1),
    'b'.repeat(64),
    '',
  ])
    assert.equal(authorized(token, supplied), false);
  assert.equal(authorized('', ''), false);
});
