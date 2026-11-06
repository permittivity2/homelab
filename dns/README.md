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

## Lua records, health checks and geography (item 44)

`homelab-dns` writes `/etc/powerdns/pdns.d/94-homelab-dns-lua.conf`: Lua
records on, EDNS client-subnet processing on, and (when the database file is
present) the `geoip` backend appended with `launch+=geoip`. The database is
DB-IP City Lite (CC BY 4.0, https://db-ip.com), refreshed monthly by
`homelab-dns-geoip.timer` into `/var/lib/homelab-dns/geoip/`. pdns reads it at
start, so a new file is used after the next restart. If pdns will not start
with the geoip backend, the postinst removes the geoip lines and starts again.

Health checks (`ifportup`) run from the DNS node itself. The base firewall lets
a DNS node out on TCP 80/443 only, so the package adds
`/etc/nftables.d/51-homelab-dns-healthcheck.conf`: TCP 25 out to the addresses
in `/etc/homelab/dns/healthcheck-targets` (one per line, seeded with the three
edge addresses).

Writing a LUA record by hand: **use single quotes inside the Lua**, because
`pdnsutil rrset add ... LUA 'A "ifportup(443, {'"'"'1.2.3.4'"'"'})"'` is the
shape the zone data takes and a doubled `\"` inside the content makes the
record answer SERVFAIL. Proven on prod-homelab47 on 2026-11-06 with a private
pdns on port 5300:

    web   LUA A "ifportup(443, {'192.0.2.1','192.0.2.2'}, {selector='all'})"
    near  LUA A "pickclosest({'192.0.2.1','198.51.100.1'})"

- `selector='all'` returns every address that passes its check; an address
  that fails (a timeout) is left out of the answer within one check interval.
- On the very first query, before any check has run, ifportup answers with a
  random element; set `backupSelector='all'` to answer with everything if all
  are down, which is the safer choice for mail.
- `pickclosest` needs an ECS-bearing query or the resolver's own address to
  decide; test with `dig +subnet=...`.
