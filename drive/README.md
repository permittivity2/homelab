# homelab-drive

A file-storage web UI, built BFF-style: browsers only ever talk to this
app, never directly to `homelab-api`. Login proxies through to
`homelab-api`'s `/api/v1/auth/login`
(`Homelab::Common::AuthClient::login`) and the resulting token is held
in this app's own signed session cookie, re-verified against
`homelab-api`'s `/api/v1/auth/introspect` on every request (a session
cookie surviving doesn't mean the underlying JWT is still valid).

Files are stored on local disk under `/var/lib/homelab/drive-storage`,
named by a random UUID (never the user-supplied filename — that's kept
only as a DB column for display/download purposes), indexed in this
package's own `drive` Postgres schema. No foreign key to `api.users` —
drive's migrate role has no grant on the `api` schema at all; the
user's email (from the JWT) is the only cross-feature identifier used,
consistent with "cross-feature consistency goes through HTTP, not a
shared DB reference" (see `CLAUDE.md`).

Deliberately minimal for the first pass: flat file list per user, no
directories/sharing/trash/versioning — those are straightforward to
add later once the core upload/list/download/delete path is proven.

## Testing

```bash
HOMELAB_DRIVE_CONFIG=/path/to/config.yml \
HOMELAB_DRIVE_TEST_EMAIL=you@test.mailmasker.org \
HOMELAB_DRIVE_TEST_PASSWORD=... \
HOMELAB_DRIVE_HOME=. \
  prove -I lib t/
```

Needs a real config (real runtime DB credentials, migrations already
applied) and a real, already-registered `homelab-api` account —
`t/basic.t` exercises the full flow for real: login failure/success,
upload, list, download (byte-for-byte round-trip check), delete
(including confirming the download link is genuinely gone afterward,
not just hidden from the list), and logout.
