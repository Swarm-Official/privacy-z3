#!/usr/bin/env node
// Replay the light-wallet call sequence that preceded server defect S-1.
//
//   node scripts/lightd-probe.js lwd.swarm.green [rounds]
//
// Everything a light wallet asks is public, so this needs no secret and sends
// none. It is a diagnostic, not a load test: it makes the same handful of
// calls the owner's wallet made in the second before the indexer aborted with
// a Rust stack overflow, and reports whether the endpoint survives them.
//
// The sequence, from the indexer's own log at 2026-09-22T01:24:52Z:
//   GetLightdInfo, GetLatestBlock, GetBlock, GetMempoolStream (skipped here -
//   it is an open stream), GetTaddressTxids x3, GetSubtreeRoots x3, GetBlock
//
// GetSubtreeRoots is the strongest suspect: subtree roots come from walking a
// note-commitment tree, and a recursive walk over a growing tree is the
// classic way to exhaust a thread stack.
//
// Node's built-in http2 only. Bounded by `rounds` so it cannot become a flood
// against a live service.

'use strict';

const http2 = require('node:http2');

const SERVICE = '/cash.z.wallet.sdk.rpc.CompactTxStreamer';

function varint(value) {
  const bytes = [];
  let n = BigInt(value);
  for (;;) {
    const byte = Number(n & 0x7fn);
    n >>= 7n;
    if (n === 0n) { bytes.push(byte); break; }
    bytes.push(byte | 0x80);
  }
  return Buffer.from(bytes);
}

const varintField = (number, value) => Buffer.concat([varint((number << 3) | 0), varint(value)]);
const bytesField = (number, buffer) =>
  Buffer.concat([varint((number << 3) | 2), varint(buffer.length), buffer]);

const blockId = (height) => varintField(1, height);
const blockRange = (from, to) =>
  Buffer.concat([bytesField(1, blockId(from)), bytesField(2, blockId(to))]);
// GetSubtreeRootsArg { startIndex = 1, shieldedProtocol = 2, maxEntries = 3 }
// ShieldedProtocol: sapling = 0, orchard = 1, ironwood = 2.
const subtreeRoots = (startIndex, protocol, maxEntries) =>
  Buffer.concat([varintField(1, startIndex), varintField(2, protocol), varintField(3, maxEntries)]);
// TransparentAddressBlockFilter { address = 1, range = 2 }
const stringField = (number, text) => bytesField(number, Buffer.from(text, 'utf8'));
const taddressFilter = (address, from, to) =>
  Buffer.concat([stringField(1, address), bytesField(2, blockRange(from, to))]);

function frame(message) {
  const header = Buffer.alloc(5);
  header.writeUInt32BE(message.length, 1);
  return Buffer.concat([header, message]);
}

function call(session, method, message, { stream = false } = {}) {
  return new Promise((resolve) => {
    let bytes = 0;
    let messages = 0;
    let status = null;
    let statusMessage = '';
    const request = session.request({
      ':method': 'POST',
      ':path': `${SERVICE}/${method}`,
      'content-type': 'application/grpc',
      'te': 'trailers',
      'grpc-accept-encoding': 'identity',
    });
    request.setTimeout(30000, () => request.close());
    const note = (headers) => {
      if (headers['grpc-status'] !== undefined) status = Number(headers['grpc-status']);
      if (headers['grpc-message']) statusMessage = decodeURIComponent(headers['grpc-message']);
    };
    request.on('response', note);
    request.on('trailers', note);
    request.on('data', (chunk) => { bytes += chunk.length; if (stream) messages += 1; });
    request.on('error', (error) => resolve({ method, error: error.message }));
    request.on('close', () => resolve({ method, status, statusMessage, bytes, messages }));
    request.end(frame(message));
  });
}

async function main() {
  const host = process.argv[2];
  const rounds = Number(process.argv[3] || 3);
  if (!host) {
    console.error('usage: lightd-probe.js <host> [rounds]');
    process.exit(2);
  }

  let aborted = false;

  for (let round = 1; round <= rounds && !aborted; round += 1) {
    console.log(`\n--- round ${round} ---`);
    const session = http2.connect(`https://${host}`, { ALPNProtocols: ['h2'] });
    const failed = await new Promise((resolve) => {
      session.once('connect', () => resolve(null));
      session.once('error', (error) => resolve(error.message));
    });
    if (failed) {
      console.log(`connect failed: ${failed}`);
      aborted = true;
      break;
    }

    const tip = Number(process.env.SWARM_PROBE_TIP || 480);
    // The three allocation destinations. Public addresses, paid in every
    // block, so a transparent-address scan over the whole chain returns a
    // row per block - which is what the wallet was doing.
    const destinations = [
      't2DGVURG5tAyXXSkj85JV5xbvTobYv7H99n',
      't2LVPzRYpZ4QtRRmQMS1zWUmG7TZaYcMjBR',
      't2UHhsicXnapNJrfewHqgwXef5HDwCHd7wk',
    ];

    const plan = [
      ['GetLightdInfo', Buffer.alloc(0), {}],
      ['GetLatestBlock', Buffer.alloc(0), {}],
      ['GetBlock', blockId(1), {}],
      // The owner's blocks: a shielded (ironwood) coinbase.
      ['GetBlock', blockId(99), {}],
      ['GetLatestTreeState', Buffer.alloc(0), {}],
      ['GetTreeState', blockId(99), {}],
      // A whole-chain sync, which is the real work a new wallet asks for.
      ['GetBlockRange', blockRange(1, tip), { stream: true }],
      ...destinations.map((address) =>
        ['GetTaddressTxids', taddressFilter(address, 1, tip), { stream: true }]),
      ['GetSubtreeRoots', subtreeRoots(0, 0, 0), { stream: true }],
      ['GetSubtreeRoots', subtreeRoots(0, 1, 0), { stream: true }],
      ['GetSubtreeRoots', subtreeRoots(0, 2, 0), { stream: true }],
    ];

    const report = (result, options) => {
      const verdict = result.error
        ? `ERROR ${result.error}`
        : `grpc-status ${result.status ?? '-'}${result.statusMessage ? ` (${result.statusMessage})` : ''}` +
          `  ${result.bytes} bytes${options.stream ? `, ${result.messages} frames` : ''}`;
      console.log(`  ${result.method.padEnd(18)} ${verdict}`);
      if (result.error) aborted = true;
    };

    if (process.env.SWARM_PROBE_CONCURRENT === '1') {
      // What the wallet actually did: several calls in flight at the same
      // millisecond on one connection, with a mempool stream held open
      // underneath them. Sequential calls are a different load entirely.
      console.log('  (concurrent, with GetMempoolStream held open)');
      const mempool = call(session, 'GetMempoolStream', Buffer.alloc(0), { stream: true });
      const results = await Promise.all(
        plan.map(([method, message, options]) => call(session, method, message, options)));
      results.forEach((result, index) => report(result, plan[index][2]));
      session.close();
      report(await mempool, { stream: true });
    } else {
      for (const [method, message, options] of plan) {
        report(await call(session, method, message, options), options);
      }
      session.close();
    }
  }

  // The endpoint is expected to be back within seconds even if it did abort,
  // so the useful question is not "is it up now" but "did it drop mid-probe".
  console.log(aborted
    ? '\nthe endpoint dropped the connection during the probe'
    : '\nthe endpoint answered every call without dropping');
  process.exit(aborted ? 1 : 0);
}

main().catch((error) => { console.error(error.message); process.exit(1); });
