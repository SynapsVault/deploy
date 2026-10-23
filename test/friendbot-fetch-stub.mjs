// Test helper: replaces globalThis.fetch with a scripted Friendbot so the
// CLI scripts can be exercised without network access.
//
// The scenario comes from the FRIENDBOT_STUB env var (JSON):
//   { "status": 200, "json": {...} }   -> ok response with a JSON body
//   { "status": 400, "json": {...} }   -> error response with a JSON body
//   { "status": 502, "text": "..." }   -> response with a non-JSON body
//   { "throw": "message" }             -> fetch rejects
// An array answers the calls in order (the last entry repeats).
//
// Every requested URL is appended to the file named by FRIENDBOT_STUB_LOG,
// so tests can assert whether Friendbot was contacted at all.
import fs from 'node:fs';

const scenarios = Array.isArray(JSON.parse(process.env.FRIENDBOT_STUB ?? '{}'))
  ? JSON.parse(process.env.FRIENDBOT_STUB)
  : [JSON.parse(process.env.FRIENDBOT_STUB ?? '{}')];
const log = process.env.FRIENDBOT_STUB_LOG;

let call = 0;

globalThis.fetch = async (url) => {
  if (log) fs.appendFileSync(log, `${url}\n`);

  const scenario = scenarios[Math.min(call, scenarios.length - 1)];
  call += 1;

  if (scenario.throw) throw new Error(scenario.throw);

  const body = scenario.json ? JSON.stringify(scenario.json) : (scenario.text ?? '');
  return {
    ok: scenario.status >= 200 && scenario.status < 300,
    status: scenario.status,
    text: async () => body,
    json: async () => JSON.parse(body),
  };
};
