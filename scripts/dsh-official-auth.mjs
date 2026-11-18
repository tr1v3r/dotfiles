#!/usr/bin/env node
// Thin terminal client for official DSH authorization flows. No OAuth protocol
// implementation, third-party TUI imports, profile edits, or credential migration.
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import { execFileSync } from 'node:child_process';
import { createInterface } from 'node:readline/promises';
import { Writable } from 'node:stream';

const HELP = `Usage: node scripts/dsh-official-auth.mjs [status|list|login] [provider] [--home DIR]

  status [provider]  Show safe flow/record metadata (default: openai-codex).
  list               List available official flows and stored record kinds.
  login [provider]   Run the official OAuth flow (default: openai-codex).
  --home DIR         Harness home (default: $DSH_HOME or ~/.dsh).
  --help             Show this help without loading DSH or reading credentials.

Status/list never resolve or refresh tokens and do not write the credential file.
Login requires an interactive TTY, displays the provider's URL/device code, and
stores the result through official authorization/credentials services. It does
not change provider routing. Stop old clients before switching credential stores.
`;
class CliError extends Error {}

function parseArgs(args) {
  if (args.includes('--help') || args.includes('-h')) return { help: true };
  let home = process.env.DSH_HOME || path.join(os.homedir(), '.dsh');
  const positional = [];
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--home') {
      if (!args[i + 1] || args[i + 1].startsWith('-')) throw new CliError('--home requires a directory.');
      home = args[++i];
    } else if (args[i].startsWith('-')) throw new CliError('Unknown option. Use --help.');
    else positional.push(args[i]);
  }
  const [action = 'status', provider = 'openai-codex'] = positional;
  if (!['status', 'list', 'login'].includes(action) || positional.length > 2 || (action === 'list' && positional.length > 1)) {
    throw new CliError('Expected status [provider], list, or login [provider].');
  }
  if (!/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/.test(provider)) throw new CliError('Invalid provider ID.');
  return { action, provider, home: path.resolve(home) };
}

function terminalInteraction(abort, DeclinedError) {
  return {
    notify(notice) {
      // Official AuthorizationNotice contains only user-facing progress/URL/code.
      for (const value of [notice.message, notice.url, notice.code]) {
        if (typeof value === 'string' && value) process.stdout.write(`${value}\n`);
      }
    },
    async prompt(prompt) {
      const signal = prompt.signal ? AbortSignal.any([abort.signal, prompt.signal]) : abort.signal;
      signal.throwIfAborted();
      if (!process.stdin.isTTY || !process.stdout.isTTY) throw new CliError('Login prompts require an interactive TTY.');
      if (prompt.kind === 'select') {
        process.stdout.write(`${prompt.message}\n`);
        prompt.options.forEach((option, i) => process.stdout.write(`  ${i + 1}. ${option.label}\n`));
      }
      const secret = prompt.kind === 'secret';
      // A separate readline output sink suppresses ALL secret input echo,
      // without relying on readline's private _writeToOutput implementation.
      const sink = secret ? new Writable({ write(_chunk, _encoding, done) { done(); } }) : undefined;
      const rl = createInterface({ input: process.stdin, output: sink ?? process.stdout, terminal: true, historySize: 0 });
      const onInterrupt = () => abort.abort(new DeclinedError('Authorization cancelled.'));
      rl.on('SIGINT', onInterrupt);
      try {
        while (true) {
          const question = prompt.kind === 'select' ? 'Choose a number (blank cancels): '
            : `${prompt.message}${secret ? ' (hidden)' : ''}: `;
          if (secret) process.stdout.write(question);
          let answer;
          try { answer = await rl.question(secret ? '' : question, { signal }); }
          catch (error) {
            if (abort.signal.aborted) throw new DeclinedError('Authorization cancelled.');
            throw error; // A per-prompt callback race is not a user's cancellation.
          }
          if (secret) process.stdout.write('\n');
          if (prompt.kind !== 'select') return answer;
          if (!answer.trim()) throw new DeclinedError('Authorization cancelled.');
          const index = Number(answer.trim()) - 1;
          if (Number.isInteger(index) && index >= 0 && index < prompt.options.length) return prompt.options[index].id;
          process.stdout.write('Choose one of the numbered options.\n');
        }
      } finally {
        rl.off('SIGINT', onInterrupt);
        rl.close();
        sink?.end();
      }
    },
  };
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) { process.stdout.write(HELP); return; }
  if (options.action === 'login' && (!process.stdin.isTTY || !process.stdout.isTTY)) {
    throw new CliError('Login requires an interactive TTY; run this command directly in your terminal.');
  }
  const root = execFileSync('npm', ['root', '-g'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  const require = createRequire(path.join(root, '@deepseek-ai/dsh/package.json'));
  const load = async name => import(pathToFileURL(require.resolve(name)));
  const [cordis, local, authorization, llm, pi, credentials] = await Promise.all([
    load('@deepseek-ai/cordis'), load('@deepseek-ai/dsh-credentials-local'),
    load('@deepseek-ai/dsh-authorization'), load('@deepseek-ai/dsh-llm'),
    load('@deepseek-ai/dsh-llm-pi-ai'), load('@deepseek-ai/dsh-credentials'),
  ]);
  const credentialFile = path.join(options.home, '.credentials.yaml');
  // The local provider auto-migrates legacy flat files on boot. Reject that
  // format beforehand so even status/list remain strictly non-writing.
  try {
    const text = await fs.readFile(credentialFile, 'utf8');
    if (local.renderFlatLayoutMigration(text) !== undefined) {
      throw new CliError('Legacy credential layout detected; refusing implicit migration. Migrate with DSH before using this CLI.');
    }
    try { local.parseCredentialsDocument(text, credentialFile); }
    catch { throw new CliError('Credential document is invalid; refusing to load it. No values are shown.'); }
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }

  const ctx = new cordis.Context();
  const fibers = [];
  const mount = async (module, config) => {
    const fiber = ctx.plugin(module.default ?? module, config);
    fibers.push(fiber);
    await fiber.await();
  };
  try {
    await mount(local, { dshHome: options.home, watch: false });
    await mount(authorization);
    await mount(llm);
    // No real provider routes are registered. The official plugin still
    // registers its available authorization flows even with an empty map.
    await mount(pi, { providers: {} });
    const store = ctx.get('credentials');
    const auth = ctx.get('authorization');
    if (!store || !auth) throw new CliError('Official credential/authorization services did not activate.');
    if (options.action === 'list') {
      const flows = auth.list().map(({ key, label, methods, inFlight }) => ({ key, label, methods, inFlight }));
      const records = await store.listRecords();
      process.stdout.write(`${JSON.stringify({ credentialFile, flows, records }, null, 2)}\n`);
      return;
    }
    const key = credentials.credentialKey('llm-pi-ai', options.provider);
    const flow = auth.describe(key);
    if (options.action === 'status') {
      const record = await store.describeRecord(key);
      process.stdout.write(`${JSON.stringify({ credentialFile, provider: options.provider,
        flow: flow ? { key: flow.key, label: flow.label, methods: flow.methods, inFlight: flow.inFlight } : null,
        record }, null, 2)}\n`);
      return;
    }
    if (!flow?.methods.some(method => method.id === 'oauth')) throw new CliError('This provider has no official OAuth flow. Use list to inspect available methods.');
    const abort = new AbortController();
    const interrupt = () => abort.abort(new authorization.AuthorizationDeclinedError('Authorization cancelled.'));
    process.on('SIGINT', interrupt);
    try {
      const outcome = await auth.begin({ key, method: 'oauth', signal: abort.signal,
        interaction: terminalInteraction(abort, authorization.AuthorizationDeclinedError) });
      process.stdout.write(`Authorization ${outcome.status}.\n`);
      if (outcome.status !== 'authorized') process.exitCode = 1;
    } finally { process.off('SIGINT', interrupt); }
  } finally {
    for (const fiber of fibers.reverse()) await fiber.dispose();
  }
}

main().catch(error => {
  // OAuth exchanges can include sensitive response bodies in error causes.
  // Never dump library messages, stack traces, causes, grants, or token values.
  const message = error instanceof CliError ? error.message : 'Official authorization operation failed; diagnostic details are suppressed to protect credentials.';
  process.stderr.write(`${message}\n`);
  process.exitCode = 1;
});
