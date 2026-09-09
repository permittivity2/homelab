# homelab-dns

Wires PowerDNS's `gpgsql` backend via a native `pdns.d` drop-in. See the
repo root `README.md` and `CLAUDE.md` (local, unpublished) for the full
architecture.

## Gotcha: PowerDNS caches its zone list at startup

Creating a **brand-new zone** (e.g. via `pdnsutil create-zone`) while
`pdns_server` is already running does **not** make it servable —
queries for it return `REFUSED`, even though `pdns_control list-zones`
correctly shows it and `pdns_server --config=check` passes. Existing
zones' *records* update live through the `gpgsql` backend as expected
(that's the whole point of a SQL backend over static zonefiles) — it's
specifically the zone list itself that's fixed at process start.
`systemctl restart pdns` picks it up immediately. There's no
lighter-weight fix — PowerDNS's own service unit ships with no
`ExecReload=` at all (confirmed: `systemctl reload pdns` fails with
"Job type reload is not applicable for unit pdns.service"), so a
restart is the only option regardless.

Verified end-to-end on `test-static-internet-ip` (2026-09-09):
`pdnsutil create-zone`/`add-record` for `test.mailmasker.org` all
succeeded and `list-zones` showed it immediately, but `dig` (even from
`127.0.0.1`, ruling out any network/firewall cause) returned `REFUSED`
until `pdns` was restarted — after which it resolved correctly both
locally and via a real external public resolver (`8.8.8.8`).

**Practical implication**: any tooling that creates new zones on an
already-running `homelab-dns` host must restart `pdns` afterward, not
just add the zone and expect it to appear.

**Update (2026-09-09)**: this isn't limited to whole new zones — adding
a brand-new **name** to an *already-served* zone (e.g. `pdnsutil
add-record test.mailmasker.org api.test.mailmasker.org A ...` for a
domain that already has other records) showed the identical symptom:
`add-record` reports success, `dig` against the authoritative server
itself returns nothing until `pdns` is restarted, then resolves
correctly both locally and externally. Existing names' *record values*
still update live (confirmed separately) — it's specifically
introducing a name PowerDNS hasn't served before, whether via a new
zone or a new name within an existing one, that needs the restart.
Also note `pdnsutil add-record`'s `NAME` argument wants the **fully
qualified** name (`api.test.mailmasker.org`), not the bare relative
label (`api`) — the latter fails with `Name "api." to add is not part
of zone ...` since it gets treated as an absolute name in its own
right, not "api" *within* the given zone.

## Testing

See `tests/e2e/test_dns_delegation.py` for the external-resolution
regression test this gotcha is captured in.
