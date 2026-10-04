'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { after, before, test } = require('node:test');

// Preserve the isolated test records for inspection; never touch relay/.data.
const testDirectory = fs.mkdtempSync(path.join('/private/tmp', 'codex-quota-relay-test-'));
const previousDataDirectory = process.env.DATA_DIR;
process.env.DATA_DIR = testDirectory;
const server = require('./server');
if (previousDataDirectory === undefined) delete process.env.DATA_DIR;
else process.env.DATA_DIR = previousDataDirectory;

let address;

before(async () => {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  address = server.address();
});

after(async () => {
  await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
});

function snapshot(updatedAt) {
  return {
    schemaVersion: 1,
    updatedAt,
    sourceDeviceID: '00000000-0000-0000-0000-000000000000',
    ciphertext: Buffer.alloc(32, 7).toString('base64'),
  };
}

function requestOptions(method, recordID, token, body) {
  const headers = { authorization: `Bearer ${token}` };
  if (body) {
    headers['content-type'] = 'application/json';
    headers['content-length'] = Buffer.byteLength(body);
  }
  return {
    hostname: '127.0.0.1',
    port: address.port,
    path: `/v1/snapshots/${recordID}`,
    method,
    headers,
  };
}

function responsePromise(options, write) {
  return new Promise((resolve, reject) => {
    const request = http.request(options, response => {
      const chunks = [];
      response.on('data', chunk => chunks.push(chunk));
      response.on('end', () => resolve({
        status: response.statusCode,
        body: JSON.parse(Buffer.concat(chunks).toString('utf8')),
      }));
      response.on('error', reject);
    });
    request.on('error', reject);
    write(request);
  });
}

function put(recordID, token, envelope) {
  const body = JSON.stringify(envelope);
  return responsePromise(requestOptions('PUT', recordID, token, body), request => request.end(body));
}

function get(recordID, token) {
  return responsePromise(requestOptions('GET', recordID, token), request => request.end());
}

function delayedPut(recordID, token, envelope) {
  const body = JSON.stringify(envelope);
  let outgoing;
  let observer;
  const started = new Promise(resolve => {
    observer = incoming => {
      if (incoming.method === 'PUT' && incoming.url === `/v1/snapshots/${recordID}`) {
        server.off('request', observer);
        resolve();
      }
    };
    // The server's handler runs first and pauses awaiting the remaining body.
    server.on('request', observer);
  });
  const response = responsePromise(requestOptions('PUT', recordID, token, body), request => {
    outgoing = request;
    request.write(body.slice(0, 1));
  });
  return {
    started,
    response,
    finish() { outgoing.end(body.slice(1)); },
  };
}

test('a delayed older PUT cannot overwrite a newer concurrent snapshot', async () => {
  const recordID = '1'.repeat(32);
  const token = 'shared-pairing-token';
  const initial = snapshot('2026-10-04T00:00:00Z');
  const older = snapshot('2026-10-04T00:00:01Z');
  const newer = snapshot('2026-10-04T00:00:02Z');
  assert.equal((await put(recordID, token, initial)).status, 201);

  const delayed = delayedPut(recordID, token, older);
  await delayed.started;
  try {
    assert.equal((await put(recordID, token, newer)).status, 200);
  } finally {
    delayed.finish();
  }

  assert.equal((await delayed.response).status, 409);
  assert.deepEqual((await get(recordID, token)).body, newer);
});

test('a delayed first PUT cannot replace concurrently established record ownership', async () => {
  const recordID = '2'.repeat(32);
  const ownerToken = 'owner-pairing-token';
  const otherToken = 'different-pairing-token';
  const established = snapshot('2026-10-04T00:00:00Z');
  const delayed = delayedPut(recordID, otherToken, snapshot('2026-10-04T00:00:02Z'));
  await delayed.started;
  try {
    assert.equal((await put(recordID, ownerToken, established)).status, 201);
  } finally {
    delayed.finish();
  }

  assert.equal((await delayed.response).status, 401);
  assert.deepEqual((await get(recordID, ownerToken)).body, established);
  assert.equal((await get(recordID, otherToken)).status, 401);
});

test('a newer concurrent PUT still replaces an older snapshot', async () => {
  const recordID = '3'.repeat(32);
  const token = 'shared-pairing-token';
  const older = snapshot('2026-10-04T00:00:01Z');
  const newer = snapshot('2026-10-04T00:00:02Z');
  const delayed = delayedPut(recordID, token, newer);
  await delayed.started;
  try {
    assert.equal((await put(recordID, token, older)).status, 201);
  } finally {
    delayed.finish();
  }

  assert.equal((await delayed.response).status, 200);
  assert.deepEqual((await get(recordID, token)).body, newer);
});
