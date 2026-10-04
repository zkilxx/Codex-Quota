#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const http = require('http');
const path = require('path');

const port = Number(process.env.PORT || 8788);
const host = process.env.HOST || '127.0.0.1';
const dataDirectory = path.resolve(process.env.DATA_DIR || path.join(__dirname, '.data'));
const maxBodyBytes = 512 * 1024;
const recordPattern = /^[a-f0-9]{32}$/;

function json(response, status, value) {
  const body = JSON.stringify(value);
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(body),
  });
  response.end(body);
}

function authorizationToken(request) {
  const value = String(request.headers.authorization || '');
  return value.startsWith('Bearer ') ? value.slice(7).trim() : '';
}

function tokenHash(token) {
  return crypto.createHash('sha256').update(token, 'utf8').digest('hex');
}

function hashesMatch(left, right) {
  if (!left || !right || left.length !== right.length) return false;
  return crypto.timingSafeEqual(Buffer.from(left, 'hex'), Buffer.from(right, 'hex'));
}

function recordFile(recordID) {
  return path.join(dataDirectory, `${recordID}.json`);
}

function readRecord(recordID) {
  try {
    return JSON.parse(fs.readFileSync(recordFile(recordID), 'utf8'));
  } catch (error) {
    if (error && error.code === 'ENOENT') return null;
    throw error;
  }
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    request.on('data', chunk => {
      size += chunk.length;
      if (size > maxBodyBytes) {
        reject(Object.assign(new Error('snapshot is too large'), { status: 413 }));
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on('end', () => resolve(Buffer.concat(chunks)));
    request.on('error', reject);
  });
}

function validateEnvelope(value) {
  if (!value || typeof value !== 'object') return false;
  if (value.schemaVersion !== 1) return false;
  if (!Number.isFinite(Date.parse(value.updatedAt))) return false;
  if (!/^[a-f0-9-]{36}$/i.test(String(value.sourceDeviceID || ''))) return false;
  if (typeof value.ciphertext !== 'string' || value.ciphertext.length < 40 || value.ciphertext.length > maxBodyBytes) return false;
  return /^[A-Za-z0-9+/=]+$/.test(value.ciphertext);
}

function writeRecord(recordID, value) {
  fs.mkdirSync(dataDirectory, { recursive: true, mode: 0o700 });
  const destination = recordFile(recordID);
  const temporary = path.join(dataDirectory, `.${recordID}.${process.pid}.${Date.now()}.tmp`);
  fs.writeFileSync(temporary, `${JSON.stringify(value)}\n`, { encoding: 'utf8', mode: 0o600 });
  fs.renameSync(temporary, destination);
}

async function handleSnapshot(request, response, recordID) {
  const token = authorizationToken(request);
  if (!token) return json(response, 401, { ok: false, message: 'missing bearer token' });
  const incomingHash = tokenHash(token);
  const existing = readRecord(recordID);

  if (existing && !hashesMatch(existing.authorizationHash, incomingHash)) {
    return json(response, 401, { ok: false, message: 'invalid bearer token' });
  }

  if (request.method === 'GET') {
    if (!existing) return json(response, 404, { ok: false, message: 'snapshot not found' });
    return json(response, 200, existing.envelope);
  }

  if (request.method !== 'PUT') {
    return json(response, 405, { ok: false, message: 'method not allowed' });
  }

  const body = await readBody(request);
  let envelope;
  try {
    envelope = JSON.parse(body.toString('utf8'));
  } catch {
    return json(response, 400, { ok: false, message: 'invalid JSON' });
  }
  if (!validateEnvelope(envelope)) {
    return json(response, 400, { ok: false, message: 'invalid snapshot envelope' });
  }

  // Another PUT can finish while this request waits for its body. Re-read and
  // validate immediately before the synchronous write so that ownership and
  // timestamp checks describe the record that is actually being replaced.
  const current = readRecord(recordID);
  if (current && !hashesMatch(current.authorizationHash, incomingHash)) {
    return json(response, 401, { ok: false, message: 'invalid bearer token' });
  }
  if (current && Date.parse(current.envelope.updatedAt) > Date.parse(envelope.updatedAt)) {
    return json(response, 409, { ok: false, message: 'a newer snapshot already exists' });
  }

  writeRecord(recordID, { authorizationHash: incomingHash, envelope });
  return json(response, current ? 200 : 201, { ok: true, updatedAt: envelope.updatedAt });
}

const server = http.createServer(async (request, response) => {
  try {
    if (request.method === 'GET' && request.url === '/health') {
      return json(response, 200, { ok: true, service: 'codex-quota-sync-relay' });
    }
    const url = new URL(request.url, `http://${request.headers.host || 'localhost'}`);
    const match = url.pathname.match(/^\/v1\/snapshots\/([^/]+)$/);
    if (!match || !recordPattern.test(match[1])) {
      return json(response, 404, { ok: false, message: 'not found' });
    }
    await handleSnapshot(request, response, match[1]);
  } catch (error) {
    json(response, error.status || 500, {
      ok: false,
      message: error.status ? error.message : 'internal server error',
    });
  }
});

if (require.main === module) {
  server.listen(port, host, () => {
    console.log(`Codex Quota sync relay listening on http://${host}:${port}`);
  });
}

module.exports = server;
