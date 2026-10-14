// Prepare a catalog-only backport in a disposable copy of the installed package.
// Called by refresh-pi-ai.sh; never pass the live package as the first argument.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const [staged, source] = process.argv.slice(2);
assert(staged && source, 'usage: refresh-pi-ai-catalog.mjs <staged-package> <source-package>');
const read = file => JSON.parse(fs.readFileSync(file, 'utf8'));
const dataDir = pkg => path.join(pkg, 'dist/providers/data');
const routes = ['openai-codex', 'anthropic', 'xai', 'openai', 'zai-coding-cn'];
const sourceVersion = read(path.join(source, 'package.json')).version;
const generatedAt = read(path.join(dataDir(source), '.manifest.json')).generatedAt;
const manifestPath = path.join(dataDir(staged), '.manifest.json');
const manifest = read(manifestPath);
// 0.87.1 uses model IDs as keys; 1.x uses operation-prefixed keys and also
// includes classifiers/images. Keep only chat models on APIs the runtime knows.
assert.equal(manifest.schemaVersion, 3, 'catalog-only mode requires the pi-ai 0.87.x data schema');
const expected = {};
for (const route of routes) {
  const filename = `${route}.json`;
  const old = read(path.join(dataDir(staged), filename));
  const latest = read(path.join(dataDir(source), filename));
  const groups = {};
  for (const api of Object.keys(old)) {
    assert(latest[api], `source no longer ships ${route}/${api}`);
    groups[api] = {};
    for (const model of Object.values(latest[api])) {
      if (model.type && model.type !== 'chat') continue;
      assert.equal(model.provider, route);
      assert.equal(model.api, api);
      assert(model.id && model.contextWindow > 0 && model.maxTokens > 0);
      const { type, ...chat } = model;
      groups[api][model.id] = chat;
    }
    assert(Object.keys(groups[api]).length, `empty chat catalog: ${route}/${api}`);
  }
  expected[route] = Object.assign({}, ...Object.values(groups));
  const json = JSON.stringify(groups);
  fs.writeFileSync(path.join(dataDir(staged), filename), json);
  manifest.files[filename] = createHash('sha256').update(json).digest('hex');
}
// Keep the original schema/generation metadata: only these routes were refreshed.
fs.writeFileSync(manifestPath, JSON.stringify(manifest));
fs.writeFileSync(path.join(dataDir(staged), '.dsh-catalog-refresh.json'),
  JSON.stringify({ sourceVersion, generatedAt, routes }, null, 2) + '\n');

// Validate the staged data through the OLD runtime, including keyed lookups used
// by provider construction and modelOverrides (listModels alone misses bad keys).
const catalog = await import(pathToFileURL(path.join(staged, 'dist/providers/all.js')));
for (const route of routes) {
  assert.equal(catalog.getBuiltinModels(route).length, Object.keys(expected[route]).length);
  for (const [id, model] of Object.entries(expected[route])) {
    assert.deepEqual(catalog.getBuiltinModel(route, id), model);
  }
}
assert(catalog.getBuiltinModel('openai-codex', 'gpt-5.6-sol'), 'configured modelOverrides must remain valid');
console.log(`✓ chat catalog staged from pi-ai ${sourceVersion} (${generatedAt}); runtime unchanged`);
