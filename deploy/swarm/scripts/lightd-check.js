#!/usr/bin/env node
// Check a public light-wallet endpoint from OUTSIDE the server.
//
//   node scripts/lightd-check.js lwd.swarm.green <expected-genesis-hash>
//
// Asks the endpoint two questions over real TLS and real HTTP/2, the way a
// wallet would:
//
//   GetLightdInfo  -> which chain do you say you are serving?
//   GetBlock(0)    -> what is your genesis block's hash?
//
// and prints the certificate it was served. Both answers have to match the
// network manifest, and the certificate has to verify against the machine's
// own trust store - `--insecure` is not offered, because a check that accepts
// any certificate is a check that something answered, not that the right
// thing did.
//
// Node's built-in http2 and tls only: nothing is installed to run this. curl
// on Git Bash for Windows is built without HTTP/2, which is why this is not a
// shell script.
//
// A unary gRPC message is a five-byte frame - a compression flag, then a
// big-endian length - around a protobuf message, and protobuf field tags are
// stable by definition, so the two messages involved are built and read here
// directly rather than pulling in a protobuf toolchain.

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

function readVarint(buffer, offset) {
  let result = 0n;
  let shift = 0n;
  for (;;) {
    if (offset >= buffer.length) throw new Error('truncated varint');
    const byte = buffer[offset++];
    result |= BigInt(byte & 0x7f) << shift;
    if ((byte & 0x80) === 0) return [result, offset];
    shift += 7n;
    if (shift > 63n) throw new Error('varint too long');
  }
}

// Only the field numbers these two checks need; everything else is skipped by
// wire type, so a server that adds fields still decodes.
function decodeMessage(buffer) {
  const fields = {};
  let offset = 0;
  while (offset < buffer.length) {
    const [key, afterKey] = readVarint(buffer, offset);
    offset = afterKey;
    const number = Number(key >> 3n);
    const wireType = Number(key & 7n);
    if (wireType === 0) {
      const [value, next] = readVarint(buffer, offset);
      offset = next;
      fields[number] = value;
    } else if (wireType === 2) {
      const [length, next] = readVarint(buffer, offset);
      const end = next + Number(length);
      if (end > buffer.length) throw new Error(`truncated field ${number}`);
      fields[number] = buffer.subarray(next, end);
      offset = end;
    } else if (wireType === 5) {
      offset += 4;
    } else if (wireType === 1) {
      offset += 8;
    } else {
      throw new Error(`unsupported wire type ${wireType} on field ${number}`);
    }
  }
  return fields;
}

function frame(message) {
  const header = Buffer.alloc(5);
  header.writeUInt8(0, 0);
  header.writeUInt32BE(message.length, 1);
  return Buffer.concat([header, message]);
}

function unframe(body) {
  if (body.length < 5) throw new Error(`response is ${body.length} bytes, expected a 5-byte frame header at least`);
  if (body[0] !== 0) throw new Error('response is compressed; this check reads identity-encoded frames only');
  const length = body.readUInt32BE(1);
  const message = body.subarray(5, 5 + length);
  if (message.length !== length) throw new Error(`frame claims ${length} bytes but carries ${message.length}`);
  return message;
}

function call(session, method, message) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let status = null;
    let statusMessage = '';
    const stream = session.request({
      ':method': 'POST',
      ':path': `${SERVICE}/${method}`,
      'content-type': 'application/grpc',
      'te': 'trailers',
      'grpc-accept-encoding': 'identity',
    });
    stream.setTimeout(20000, () => stream.destroy(new Error(`${method} timed out`)));
    stream.on('response', (headers) => {
      if (headers['grpc-status'] !== undefined) status = Number(headers['grpc-status']);
      if (headers['grpc-message']) statusMessage = headers['grpc-message'];
    });
    stream.on('trailers', (trailers) => {
      if (trailers['grpc-status'] !== undefined) status = Number(trailers['grpc-status']);
      if (trailers['grpc-message']) statusMessage = trailers['grpc-message'];
    });
    stream.on('data', (chunk) => chunks.push(chunk));
    stream.on('error', reject);
    stream.on('end', () => {
      if (status !== null && status !== 0) {
        reject(new Error(`${method} returned grpc-status ${status} ${decodeURIComponent(statusMessage)}`));
        return;
      }
      try {
        resolve(decodeMessage(unframe(Buffer.concat(chunks))));
      } catch (error) {
        reject(new Error(`${method}: ${error.message}`));
      }
    });
    stream.end(frame(message));
  });
}

async function main() {
  const host = process.argv[2];
  const expectedGenesis = (process.argv[3] || '').toLowerCase();
  const expectedChain = process.argv[4] || 'swarm-testnet';
  if (!host || !expectedGenesis) {
    console.error('usage: lightd-check.js <host> <expected-genesis-hash> [expected-chain-name]');
    process.exit(2);
  }

  const session = http2.connect(`https://${host}`, { ALPNProtocols: ['h2'] });
  session.on('error', (error) => { console.error(`connection: ${error.message}`); process.exit(1); });

  await new Promise((resolve, reject) => {
    session.once('connect', resolve);
    session.once('error', reject);
  });

  const certificate = session.socket.getPeerCertificate();
  const alpn = session.socket.alpnProtocol;
  console.log(`endpoint        https://${host}`);
  console.log(`alpn            ${alpn}`);
  console.log(`certificate     subject ${certificate.subject && certificate.subject.CN}`);
  console.log(`                issuer  ${certificate.issuer && certificate.issuer.O} / ${certificate.issuer && certificate.issuer.CN}`);
  console.log(`                valid   ${certificate.valid_from} .. ${certificate.valid_to}`);
  console.log(`                verified by the system trust store (no --insecure option exists)`);

  let failures = 0;

  const info = await call(session, 'GetLightdInfo', Buffer.alloc(0));
  const chainName = info[4] ? info[4].toString('utf8') : '(none)';
  const blockHeight = info[7] !== undefined ? info[7].toString() : '?';
  console.log(`chain_name      ${chainName}`);
  console.log(`block_height    ${blockHeight}`);
  console.log(`vendor          ${info[2] ? info[2].toString('utf8') : '?'}`);
  console.log(`version         ${info[1] ? info[1].toString('utf8') : '?'}`);
  if (chainName !== expectedChain) {
    console.error(`FAIL  chain_name is '${chainName}', expected '${expectedChain}'`);
    failures += 1;
  }

  // BlockID { height }. Field 1, wire type 0, so the key byte is (1 << 3) | 0.
  // The wire carries block hashes in internal byte order; the displayed hash
  // is that reversed.
  const blockId = (height) => Buffer.concat([varint((1 << 3) | 0), varint(height)]);
  const blockIdHeightZero = blockId(0);
  let genesis;
  try {
    const block = await call(session, 'GetBlock', blockIdHeightZero);
    genesis = block[3] ? Buffer.from(block[3]).reverse().toString('hex') : null;
    console.log(`genesis         ${genesis}  (GetBlock height 0)`);
  } catch (error) {
    // Some servers decline to serve genesis as a compact block. Block 1's
    // prevHash is the same assertion by another route.
    console.log(`GetBlock(0)     ${error.message}; falling back to GetBlock(1).prevHash`);
    const blockIdHeightOne = blockId(1);
    const block = await call(session, 'GetBlock', blockIdHeightOne);
    genesis = block[4] ? Buffer.from(block[4]).reverse().toString('hex') : null;
    console.log(`genesis         ${genesis}  (GetBlock height 1, prevHash)`);
  }
  if (genesis !== expectedGenesis) {
    console.error(`FAIL  genesis is '${genesis}', expected '${expectedGenesis}'`);
    failures += 1;
  }

  session.close();
  if (failures > 0) {
    console.error(`\n${failures} check(s) failed`);
    process.exit(1);
  }
  console.log('\nall checks passed');
}

main().catch((error) => { console.error(error.message); process.exit(1); });
