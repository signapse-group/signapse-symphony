'use strict';

const { spawn } = require('node:child_process');
const { once } = require('node:events');
const { createRequire } = require('node:module');
const { dirname, join, resolve } = require('node:path');
const { createInterface } = require('node:readline');

// The deployed Playwright Test Agents release runs every heavy tool through global setup.
// Node forks the test loader and workers with the parent execArgv.
if (process.argv[2] !== 'run-test-mcp-server') return;
const cli = resolve(process.argv[1]);
if (!cli.endsWith('/playwright/cli.js')) throw new Error('Unexpected Playwright MCP entry point');
const requirePlaywright = createRequire(cli);
const pkg = requirePlaywright('./package.json');
if (pkg.name !== 'playwright' || pkg.version !== '1.63.0') {
  throw new Error('Browser lease requires Playwright Test Agents 1.63.0');
}

const lib = join(dirname(cli), 'lib');
const { testRunner: { TestRunner } } = require(join(lib, 'runner'));
const { TestServerBackend } = require(join(lib, 'mcp/test/testBackend'));
const { SYMPHONY_BROWSER_LEASE: helper, SYMPHONY_BROWSER_LOCK: lock } = process.env;
if (!helper || !lock) throw new Error('Missing host browser lease configuration');

const busy = 'resource_busy: host browser slot occupied; retry_after_seconds=30';
const held = new WeakMap();
const loadingSetup = new WeakSet();
const toolQueues = new WeakMap();

async function acquire() {
  const process = spawn('/usr/bin/python3', [helper, 'hold', lock], {
    stdio: ['pipe', 'pipe', 'ignore'],
  });
  // Closing the input leaves the durable fence if clean release was not sent.
  process.stdin.on('error', () => {});
  const exited = once(process, 'exit');
  const output = createInterface({ input: process.stdout, crlfDelay: Infinity });
  try {
    await Promise.race([
      once(output, 'line').then(([line]) => {
        if (line !== 'ready') throw new Error('Invalid browser lease readiness');
      }),
      exited.then(([code]) => {
        throw new Error(code === 73 ? busy : 'Host browser lease unavailable');
      }),
    ]);
  } catch (error) {
    process.stdin.end();
    throw error;
  } finally {
    output.close();
  }
  return { process, exited };
}

async function release(lease, clean) {
  if (clean) lease.process.stdin.end('release\n');
  else lease.process.stdin.end();
  const [code] = await lease.exited;
  if (clean && code !== 0) throw new Error('Host browser lease cleanup could not be confirmed');
}

const setup = TestRunner.prototype.runGlobalSetup;
const teardown = TestRunner.prototype.runGlobalTeardown;
const loadConfig = TestRunner.prototype._loadConfigOrReportError;
const callTool = TestServerBackend.prototype.callTool;
const dispose = TestServerBackend.prototype.dispose;
if (![setup, teardown, loadConfig, TestRunner.prototype.stopTests, callTool, dispose]
  .every(method => typeof method === 'function')) {
  throw new Error('Browser lease cannot attach to the Playwright runner lifecycle');
}

TestRunner.prototype._loadConfigOrReportError = async function (...args) {
  const config = await loadConfig.apply(this, args);
  // Global setup has accepted the config and has not started any plugins yet.
  if (config && loadingSetup.has(this)) held.set(this, await acquire());
  return config;
};

TestRunner.prototype.runGlobalSetup = async function (...args) {
  loadingSetup.add(this);
  let started = false;
  try {
    const result = await setup.apply(this, args);
    started = result.status === 'passed';
    if (started && !held.has(this)) throw new Error('Playwright started without a browser lease');
    return result;
  } finally {
    loadingSetup.delete(this);
    const lease = held.get(this);
    if (!started && lease) {
      // The pinned runner discards the result of cleanup on failed setup.
      held.delete(this);
      await release(lease, false);
    }
  }
};

TestRunner.prototype.runGlobalTeardown = async function (...args) {
  const lease = held.get(this);
  let clean = false;
  try {
    if (lease) await this.stopTests();
    const result = await teardown.apply(this, args);
    clean = result.status === 'passed';
    return result;
  } finally {
    if (lease) {
      held.delete(this);
      await release(lease, clean);
      if (!clean) throw new Error('Playwright browser cleanup could not be confirmed');
    }
  }
};

function enqueueTool(backend, call) {
  const previous = toolQueues.get(backend) ?? Promise.resolve();
  const next = previous.then(call);
  toolQueues.set(backend, next.catch(() => {}));
  return next;
}

TestServerBackend.prototype.callTool = function (name, ...args) {
  // Seed resolution can replace the runner before Playwright's internal queue.
  return enqueueTool(this, async () => {
    const result = await callTool.call(this, name, ...args);
    // Closing the page alone leaves the paused test and its webServers running.
    if (name === 'browser_close') {
      try {
        const context = this._context;
        await context._enqueue(() => context._cleanupTestRunner());
      } catch (error) {
        return { content: [{ type: 'text', text: String(error) }], isError: true };
      }
    }
    return result;
  });
};

TestServerBackend.prototype.dispose = function () {
  return enqueueTool(this, () => dispose.call(this));
};
