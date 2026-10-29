# homelab-cert-server

Certificate issuance for the whole fleet from **one** host, plus a narrow
endpoint that signs Apple configuration profiles without letting any
private key leave it.

Installed on `prod-homelab46` only.

## Why issuance is centralised

Renewal used to depend on whichever internet-facing edge node happened to
be powered on. Under a manual, one-node-at-a-time edge model that is a
silent failure: the standby holds no ACME account and cannot renew
anything, and nobody finds out until a certificate expires.

So this host owns issuance for every lineage, solves ACME challenges over
**DNS-01** through `homelab-api`'s narrow `system_agent`-gated
`_acme-challenge` endpoint, and needs no inbound `:80`/`:443` at all. It
is never public-facing.

Each certificate is **envelope-encrypted here**, before it leaves, under
`key_encryption_key` from this host's own config, then published to the
certificate store in `homelab-api`. The API stores and serves ciphertext
and can never hand out a usable private key; only a consumer holding the
same KEK can decrypt. Consumers pull with `homelab-certsync`.

| Unit | Type | What it does |
|---|---|---|
| `homelab-cert-server.timer` | timer | twice daily: issue/renew, publish, drain the publish spool |
| `homelab-cert-server.service` | oneshot | `homelab-cert-issue` + `homelab-cert-publish --drain` |
| `homelab-cert-sign.service` | daemon, `:2516` | signs Apple configuration profiles |

## The signing endpoint

An unsigned `.mobileconfig` installs perfectly well; iOS labels it
**"Unverified" in red** on the install screen. Signing turns that green
and names the signer.

**Why the signing happens here.** `homelab-invite` (30/31/32) and
`homelab-accountmanage` (27/28/29) serve the downloads — six hosts.
Signing there would need a publicly-trusted certificate and key on all
six, and the ready-made way to deliver one is `homelab-certsync`, which
decrypts with `key_encryption_key`. That KEK is **fleet-wide**: it opens
every lineage in the store, `mail.mailmasker.org` included. Putting it on
six more app hosts so that one word goes green would mean a compromise of
any one of them yields every certificate the fleet has.

So the key does not move; the bytes do. This host already holds every
plaintext key — it is what issues them — so adding a signing endpoint
here is **net zero new key exposure**. Callers send the profile's
parameters to `:2516` and get signed bytes back.

**It signs parameters, not submitted bytes.** Accepting arbitrary bytes
would make this a general-purpose signing oracle for keys that also
terminate TLS for public hostnames. It takes the fields of a mail
profile, builds the plist itself with the same
`Homelab::Common::AppleProfile` its callers use, validates every field,
and signs that. Everything it can be made to emit is a mail-configuration
plist.

**Authentication** is the fleet's existing `system_agent` mechanism: each
caller presents its own host's `homelab-agent` credential and this
service asks `homelab-api` to introspect it. No new secret is
distributed, and nothing per-host can go wrong — which matters, because
both calling services are three-node pools.

**It runs unprivileged**, as `homelab-certsign`, a user of its own —
deliberately not the fleet-wide `homelab` user, which on this host owns
the group-writable `/etc/homelab/services` and runs `homelab-agent`. It
reads neither `/etc/letsencrypt` nor `cert-server.yml` (0600 root,
because the KEK is in it). It reads a **materialized copy** under
`/var/lib/homelab-cert-sign/<lineage>/`, placed there as `root:homelab-
certsign 0640` by `homelab-cert-sign-materialize`, which runs as root
from `ExecStartPre=+` and again after every renewal. certbot keeps
private keys 0700 root and **resets that on every renewal**, so copying
is the only approach that does not silently undo itself every 60 days.
Config lives in its own file, `cert-sign.yml`, holding nothing secret —
that is what lets a network-facing daemon read its own configuration
without being able to read the KEK.

### One open question, deliberately left open

A Let's Encrypt certificate carries `extendedKeyUsage: serverAuth` and
nothing else. openssl's own S/MIME purpose check **rejects** such a
certificate ("unsuitable certificate purpose"), and whether iOS applies
that same check before printing a green "Verified" is genuinely
unsettled: plenty of people report a plain TLS certificate working, and
at least one signing tool states flatly that `emailProtection` is
required.

Rather than bet on the answer, the hard part — getting signed bytes from
a host that holds a key to hosts that do not — is independent of *which*
identity signs:

- `lineages:` entries may be a **name** (a certbot lineage on this host)
  or a **hash of explicit paths** (`name`, `cert`, `chain`, `privkey`),
  so an S/MIME certificate obtained from any publicly trusted CA can be
  dropped on this host and named instead. No code changes.
- `homelab-cert-sign-materialize` prints a **NOTE** when the signing
  identity has no `emailProtection` EKU, so a profile that still installs
  as "Unverified" has a one-line explanation in the journal rather than
  being a mystery.
- `GET /internal/v1/sign/lineages` reports each identity's subject,
  expiry and EKU.

And throughout, the clients fall back to unsigned profiles, so the worst
case is the behaviour the fleet already shipped with.

### Routes

| Route | Auth | Returns |
|---|---|---|
| `GET /health` | none | `ok`, or 503 when **nothing** is signable — which is the state where every client silently degrades, so it is the state worth a red light |
| `GET /internal/v1/sign/lineages` | `system_agent` | each configured identity: ready, subject, `not_after`, EKU |
| `POST /internal/v1/sign/apple-mail-profile` | `system_agent` | `{ profile_b64, signer, not_after }`; 503 on a signing failure, because the caller's correct response is to serve unsigned and retry later |

## Gotchas learned the hard way

- **The hourly timer silently never re-fired.** A `oneshot` +
  `RemainAfterExit` service with `OnUnitActiveSec` never becomes inactive,
  so the timer never elapses again. Check
  `systemctl show <t>.timer -p NextElapseUSecRealtime`; the fix needs
  `OnCalendar` **and** a one-time `systemctl stop` of the stuck-active
  service, since `enable --now` is a no-op on something already active.
- **A `oneshot` ordered `Before=` a service must `reload --no-block`**, or
  the two deadlock.
- **Certificate identity is `(lineage, serial)`**, not a byte hash.
- **haproxy is pure TCP pass-through** for 25/587/143/993, which is why
  postfix and dovecot each hold the certificate themselves.
- **A CNAME alone does not fix TLS** — the name has to be a SAN. That is
  why `smtp.mailmasker.org` is on the `mail.mailmasker.org` lineage.
- **`api_base` must be the service-plane address**, never
  `https://api.mailmasker.org`: the public name loops back through the
  very nginx whose certificate this host rotates, so publishing the `api`
  lineage would depend on that certificate already being published.
