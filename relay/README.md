# Codex Quota cross-platform sync relay

This relay stores one opaque encrypted quota snapshot per pairing code. It never receives the raw pairing key or plaintext quota data.

## Run locally

```bash
cd relay
npm run check
HOST=127.0.0.1 PORT=8788 npm start
```

For remote use, place it behind an HTTPS reverse proxy and persist `DATA_DIR` on a private volume:

```bash
HOST=127.0.0.1 PORT=8788 DATA_DIR=/var/lib/codex-quota-sync node server.js
```

The macOS client intentionally rejects plaintext remote HTTP. Only loopback HTTP is accepted for development.

## Protocol for Android and other clients

Given the 32-byte raw pairing key decoded from the base64url sync code:

1. `recordID = first16(SHA256(UTF8("codex-quota:record:") || key))`, lowercase hex.
2. `authorization = base64url(SHA256(UTF8("codex-quota:authorization:") || key))`.
3. `encryptionKey = SHA256(UTF8("codex-quota:encryption:") || key)`.
4. Encode the snapshot as UTF-8 JSON with ISO 8601 dates and encrypt it with AES-256-GCM.
5. The `ciphertext` field is standard base64 of `12-byte nonce || ciphertext || 16-byte tag`, matching CryptoKit's combined sealed box representation.
6. Read or write `/v1/snapshots/{recordID}` with `Authorization: Bearer {authorization}`.

Envelope:

```json
{
  "schemaVersion": 1,
  "updatedAt": "2026-07-18T12:34:56Z",
  "sourceDeviceID": "00000000-0000-0000-0000-000000000000",
  "ciphertext": "base64..."
}
```

`PUT` returns `409` when the relay already has a newer envelope. Clients should then `GET`, decrypt, and apply the snapshot only when its `updatedAt` is newer than local state.

The relay must not be treated as an account system. Possession of the sync code grants read/write access to that encrypted record, so the code should be transferred by QR code or another trusted channel.
