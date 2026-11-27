# Storage (`QPBX.Storage`)

**Purpose:** every media file (voicemail now; recordings, faxes and prompts later), encrypted
at rest. Each file gets its own random data key (AES-256-GCM); the data key is wrapped by the
master key (`QPBX.Core.Vault`, local key or AWS KMS) and kept in the file's header, so a table
stores only the file key. Plain audio exists only briefly in the temporary folder.

**Public API:** `put(area, binary)` → `{:ok, key}` (areas: voicemail, recordings, faxes,
prompts; key `area/yyyy/mm/uuid`); `get(key)` → `{:ok, binary}` (`{:error, :corrupt}` if the
file was changed, `{:error, :bad_key}` for a key that is not ours); `delete(key)`;
`decrypt_to_temp(key, extension)` → `{:ok, path}` (for FreeSWITCH to play) and `discard(path)`
(removes only files in the temporary folder); `temp_dir/0`.

**Backends:** `QPBX.Storage.Backend` behaviour (`write/2`, `read/1`, `delete/1`);
`QPBX.Storage.Local` (files under the configured root, written whole then renamed). S3 later.
Config: `config :qpbx, QPBX.Storage, backend:, root:, temp_dir:` (production: `QPBX_DATA_DIR`,
default `/var/lib/qpbx`, and `QPBX_MEDIA_TMP`, default `/run/qpbx-media`).

**File format:** `"QPS1"`, 2-byte length, wrapped data key (Cloak), 12-byte IV, 16-byte tag,
ciphertext; "QPS1" is the authenticated additional data.

**Events:** none.

**Gotchas:**
- `/run/qpbx-media` is tmpfs (`/run`), shared by the app and FreeSWITCH through the
  `qpbx-media` group (mode 2770, setgid); leftovers older than a day are removed by
  systemd-tmpfiles.
- Files are not deleted with their rows by the database: whoever deletes the rows deletes
  the files (see Telephony's `delete_mailbox/3`). Deleting a whole tenant leaves its files
  (no tenant deletion in the portal yet).
- Files are read whole into memory (voicemail is small); stream when recordings arrive.
