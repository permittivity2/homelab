"""homelab-cli argument parsing and command dispatch."""

import argparse
import getpass
import json
import re
import sys
from pathlib import Path

import argcomplete

from . import config as cfgmod
from .client import ApiError, Client

# Mirrors ../../api/migrations/003-rbac.sql's seed data -- api.roles is
# the real, technical source of truth (grant/revoke-role still just
# sends whatever string the server decides to accept), but a small,
# hardcoded list here gives tab completion and up-front "did you typo
# the role name" validation for free via argparse's own choices=
# handling. Tradeoff: a role added directly via SQL later without also
# updating this list would still work, just without completion/
# validation for it -- worth it for how rarely the role set changes.
KNOWN_ROLES = ["user", "site_admin"]


def _client():
    # Wires up transparent refresh-on-401 (see Client._send in
    # client.py): if the session's JWT has expired mid-command, the
    # Client retries once using this refresh_token and persists whatever
    # it gets back via on_token_refreshed -- so a command started right
    # before a 30-minute JWT expiry still succeeds instead of failing
    # with "not logged in". `session` here is a fresh, separate load from
    # whatever the calling cmd_* function itself loaded (each cmd_*
    # still reads its own session["token"] the same way it always has,
    # per this fix's design -- touching none of those call sites); the
    # only thing this closure needs from it is the refresh_token and a
    # place to write an updated one back to disk. No session at all
    # (never logged in) means refresh_token=None, which makes
    # Client._send's retry branch a no-op -- unchanged prior behavior.
    session = cfgmod.load_session() or {}

    def _on_token_refreshed(new_token, new_refresh_token):
        session["token"] = new_token
        session["refresh_token"] = new_refresh_token
        cfgmod.save_session(session)

    return Client(
        cfgmod.load_config()["api_base"],
        refresh_token=session.get("refresh_token"),
        on_token_refreshed=_on_token_refreshed,
    )


# SPF's real qualifier characters, keyed by the friendly --all value --
# see cmd_dns_spf_set. Default is "softfail" (~all), never "fail"
# (-all) -- a hard fail is the kind of thing that should be a deliberate
# admin choice, not a CLI default.
_SPF_QUALIFIERS = {"pass": "+", "neutral": "?", "softfail": "~", "fail": "-"}


def _build_spf_value(all_qualifier, includes):
    parts = ["v=spf1", "mx"]
    for inc in includes or []:
        parts.append(f"include:{inc}")
    parts.append(f"{_SPF_QUALIFIERS[all_qualifier]}all")
    return " ".join(parts)


def _build_dmarc_value(policy, rua, pct):
    tags = ["v=DMARC1", f"p={policy}"]
    if rua:
        tags.append("rua=" + ",".join(f"mailto:{addr}" for addr in rua))
    if pct is not None:
        tags.append(f"pct={pct}")
    return "; ".join(tags)


def _nudge_spf_dmarc(client, token, domain_name):
    """Best-effort UX nicety, called right after a domain gains a real DNS
    zone (dns domains add / dns mail-aliases add): checks for an existing
    SPF (TXT at the zone apex starting "v=spf1") and DMARC (TXT at
    _dmarc.<domain> starting "v=DMARC1") record, and prints a one-line
    suggestion for whichever is missing -- most admins know they need a
    TXT record for these but not what belongs in it, so pointing at the
    dedicated commands (rather than expecting them to hand-write SPF/
    DMARC syntax via `dns records add`) is the actual point here.
    Deliberately swallows any error: a transient API hiccup or a zone
    that isn't fully queryable in the same instant it was created must
    never make domain/alias creation look like it failed."""
    try:
        records = client.dns_list_records(token, domain_name)
    except ApiError:
        return
    # Two PowerDNS wire-format quirks confirmed against a real deployed
    # zone (not just by reading the code) -- both need normalizing
    # before comparing against the plain values this module builds:
    #   1. rrset names always come back as FQDNs with a trailing dot
    #      (Dns.pm's list_records passes PowerDNS's own response
    #      straight through unmodified).
    #   2. TXT content values come back as the literal wire-format
    #      quoted string, e.g. content == ["\"v=spf1 mx ~all\""] -- a
    #      naive `v.startswith("v=spf1")` against that always fails
    #      (it starts with a literal `"` character), which would make
    #      this nudge claim SPF/DMARC are missing even right after
    #      `dns spf set`/`dns dmarc set` just created them.
    def _unquoted(value):
        return value[1:-1] if value.startswith('"') and value.endswith('"') else value

    dmarc_name = f"_dmarc.{domain_name}"
    has_spf = any(
        r["name"].rstrip(".") == domain_name and r["type"] == "TXT"
        and any(_unquoted(v).startswith("v=spf1") for v in r["content"])
        for r in records
    )
    has_dmarc = any(
        r["name"].rstrip(".") == dmarc_name and r["type"] == "TXT"
        and any(_unquoted(v).startswith("v=DMARC1") for v in r["content"])
        for r in records
    )
    if not has_spf:
        print(f"  tip: no SPF record found for {domain_name} -- run 'homelab-cli dns spf set {domain_name}' to add one")
    if not has_dmarc:
        print(f"  tip: no DMARC record found for {domain_name} -- run 'homelab-cli dns dmarc set {domain_name}' to add one")


def _require_session(args):
    """Returns the saved session dict, or None (after printing a clear
    error, JSON-shaped in -j mode) if there isn't one. Every command
    below that needs to already be logged in starts with this, matching
    cmd_whoami's own existing error message so there's exactly one "how
    do I log in" hint used everywhere."""
    session = cfgmod.load_session()
    if not session:
        _emit_error(args, "Not logged in. Run: homelab-cli login <email>")
        return None
    return session


def _emit(args, data):
    """-j/--json mode: print `data` (whatever the Client call actually
    returned -- real API field names, never a table's derived/friendly
    display strings) as one JSON payload and tell the caller to stop.
    Human mode: no-op, caller proceeds with its normal formatted
    printing. `default=str` covers any non-JSON-native value a client
    method might hand back unchanged from the API (there aren't any
    today, but it's a cheap safety net against a future one)."""
    if getattr(args, "json", False):
        print(json.dumps(data, default=str))
        return True
    return False


def _emit_error(args, message, data=None):
    """The error-path equivalent of _emit -- a script parsing -j output
    needs failures to be valid JSON too, not just successes. `data`, if
    given, is merged into the JSON error object; most call sites just
    pass a message."""
    if getattr(args, "json", False):
        payload = {"error": message}
        if data:
            payload.update(data)
        print(json.dumps(payload), file=sys.stderr)
    else:
        print(message, file=sys.stderr)


def cmd_configure(args):
    config = cfgmod.load_config()
    if args.api_base is None:
        if _emit(args, config):
            return 0
        for key, value in config.items():
            print(f"{key} = {value}")
        return 0
    config["api_base"] = args.api_base
    cfgmod.save_config(config)
    if _emit(args, config):
        return 0
    print("Configuration updated.")
    return 0


def cmd_register(args):
    password = args.password or getpass.getpass("Password: ")
    try:
        result = _client().register(args.email, password)
    except ApiError as e:
        _emit_error(args, f"Registration failed: {e.message}")
        return 1
    if _emit(args, result):
        return 0
    print(f"Registered: {result['email']} (id {result['id']})")
    return 0


def cmd_login(args):
    password = args.password or getpass.getpass("Password: ")
    try:
        result = _client().login(args.email, password)
    except ApiError as e:
        _emit_error(args, f"Login failed: {e.message}")
        return 1
    cfgmod.save_session({
        "email": args.email,
        "token": result["token"],
        "refresh_token": result["refresh_token"],
    })
    # Deliberately NOT the raw result: it carries the token/refresh_token
    # already written to session.yml (0600) -- no reason to also put a
    # live credential on stdout for -j callers to end up in shell
    # history/logs/a captured pipeline.
    if _emit(args, {"success": True, "email": args.email}):
        return 0
    print(f"Logged in as {args.email}")
    return 0


def cmd_whoami(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        result = _client().introspect(session["token"])
    except ApiError as e:
        if e.status_code == 401:
            _emit_error(args, "Session expired. Run: homelab-cli login <email>")
        else:
            _emit_error(args, f"Error: {e.message}")
        return 1
    if _emit(args, result):
        return 0
    print(result["email"])
    return 0


def cmd_logout(args):
    session = cfgmod.load_session()
    if session:
        try:
            _client().logout(session["refresh_token"])
        except ApiError:
            pass  # best-effort — clear the local session regardless
    cfgmod.clear_session()
    if _emit(args, {"success": True}):
        return 0
    print("Logged out")
    return 0


def cmd_registry_lookup(args):
    try:
        result = _client().registry_lookup(args.feature_name)
    except ApiError as e:
        _emit_error(args, f"Lookup failed: {e.message}")
        return 1
    if _emit(args, result):
        return 0
    print(f"{result['feature_name']}: {result['host']}:{result['port']}")
    return 0


def cmd_registry_list(args):
    try:
        results = _client().registry_list()
    except ApiError as e:
        _emit_error(args, f"List failed: {e.message}")
        return 1
    if _emit(args, results):
        return 0
    if not results:
        print("(no features registered)")
        return 0
    rows = [[r["feature_name"], r["host"], r["port"]] for r in results]
    _print_table(["FEATURE", "HOST", "PORT"], rows)
    return 0


# --- dns: homelab-api's /api/v1/domains/* gateway -> homelab-domain-admin
# (see ../../domain-admin/README.md). site_admin role required
# server-side (role-gating itself lands once homelab-api's introspect
# response carries roles -- see that package's own README "API"
# section; for now the server just requires any authenticated caller,
# same as every other command below tries and lets the server decide). -

def cmd_dns_domains_list(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        domains = _client().dns_list_domains(session["token"])
    except ApiError as e:
        _emit_error(args, f"Could not list domains: {e.message}")
        return 1
    if _emit(args, domains):
        return 0
    if not domains:
        print("(no domains)")
        return 0
    rows = []
    for d in domains:
        state = "active" if d["active"] else "disabled"
        flags = []
        if d["mail_enabled"]:
            flags.append("mail")
        if d["dns_managed"]:
            flags.append("dns")
        rows.append([d["domain_name"], state, ", ".join(flags) or "none"])
    _print_table(["DOMAIN", "STATUS", "FLAGS"], rows)
    return 0


def cmd_dns_domains_add(args):
    session = _require_session(args)
    if not session:
        return 1
    client = _client()
    try:
        result = client.dns_add_domain(
            session["token"], args.domain_name,
            mail_enabled=args.mail_enabled, dns_managed=args.dns_managed,
            nameservers=args.ns,
        )
    except ApiError as e:
        _emit_error(args, f"Could not add domain: {e.message}")
        return 1
    if _emit(args, result):
        return 0
    print(f"Added: {result['domain_name']} (id {result['id']})")
    if args.dns_managed:
        _nudge_spf_dmarc(client, session["token"], args.domain_name)
    return 0


def cmd_dns_domains_show(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        d = _client().dns_get_domain(session["token"], args.domain_name)
    except ApiError as e:
        _emit_error(args, f"Could not show domain: {e.message}")
        return 1
    if _emit(args, d):
        return 0
    for key in ("domain_name", "active", "mail_enabled", "dns_managed", "created_by", "created_at"):
        print(f"{key}: {d.get(key)}")
    return 0


def cmd_dns_domains_enable(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        result = _client().dns_set_domain_enabled(session["token"], args.domain_name, True)
    except ApiError as e:
        _emit_error(args, f"Could not enable domain: {e.message}")
        return 1
    if _emit(args, result):
        return 0
    print(f"Enabled {args.domain_name}")
    return 0


def cmd_dns_domains_disable(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        result = _client().dns_set_domain_enabled(session["token"], args.domain_name, False)
    except ApiError as e:
        _emit_error(args, f"Could not disable domain: {e.message}")
        return 1
    if _emit(args, result):
        return 0
    print(f"Disabled {args.domain_name}")
    return 0


def cmd_dns_records_list(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        records = _client().dns_list_records(session["token"], args.domain_name)
    except ApiError as e:
        _emit_error(args, f"Could not list records: {e.message}")
        return 1
    if _emit(args, records):
        return 0
    if not records:
        print("(no records)")
        return 0
    rows = [[r["name"], r["type"], r["ttl"], ", ".join(r["content"])] for r in records]
    _print_table(["NAME", "TYPE", "TTL", "VALUE"], rows)
    return 0


def cmd_dns_records_add(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        result = _client().dns_add_record(
            session["token"], args.domain_name, args.name, args.type, args.value, ttl=args.ttl,
        )
    except ApiError as e:
        _emit_error(args, f"Could not add record: {e.message}")
        return 1
    if _emit(args, result):
        return 0
    print(f"Added {args.name} {args.type}")
    return 0


def cmd_dns_records_delete(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        result = _client().dns_delete_record(session["token"], args.domain_name, args.name, args.type)
    except ApiError as e:
        _emit_error(args, f"Could not delete record: {e.message}")
        return 1
    if _emit(args, result or {"success": True}):
        return 0
    print(f"Deleted {args.name} {args.type}")
    return 0


def cmd_dns_spf_set(args):
    session = _require_session(args)
    if not session:
        return 1
    value = _build_spf_value(args.all, args.include)
    try:
        result = _client().dns_add_record(session["token"], args.domain_name, args.domain_name, "TXT", [value])
    except ApiError as e:
        _emit_error(args, f"Could not set SPF record: {e.message}")
        return 1
    if _emit(args, result):
        return 0
    print(f"Set SPF for {args.domain_name}: {value}")
    return 0


def cmd_dns_dmarc_set(args):
    session = _require_session(args)
    if not session:
        return 1
    value = _build_dmarc_value(args.policy, args.rua, args.pct)
    record_name = f"_dmarc.{args.domain_name}"
    try:
        result = _client().dns_add_record(session["token"], args.domain_name, record_name, "TXT", [value])
    except ApiError as e:
        _emit_error(args, f"Could not set DMARC record: {e.message}")
        return 1
    if _emit(args, result):
        return 0
    print(f"Set DMARC for {args.domain_name}: {value}")
    return 0


def cmd_dns_dkim_list(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        selectors = _client().dns_list_dkim(session["token"], args.domain_name)
    except ApiError as e:
        _emit_error(args, f"Could not list DKIM selectors: {e.message}")
        return 1
    if _emit(args, selectors):
        return 0
    if not selectors:
        print("(no selectors)")
        return 0
    rows = [[s["selector"], s["state"], s.get("retire_after") or ""] for s in selectors]
    _print_table(["SELECTOR", "STATE", "RETIRE AFTER"], rows)
    return 0


def cmd_dns_dkim_rotate(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        result = _client().dns_rotate_dkim(session["token"], args.domain_name)
    except ApiError as e:
        _emit_error(args, f"Could not rotate DKIM key: {e.message}")
        return 1
    if _emit(args, result):
        return 0
    print(f"Generated selector {result['selector']} (state: {result['state']}) -- activate it once its DNS TXT record has propagated")
    return 0


def cmd_dns_dkim_activate(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        result = _client().dns_activate_dkim(session["token"], args.domain_name, args.selector)
    except ApiError as e:
        _emit_error(args, f"Could not activate {args.selector}: {e.message}")
        return 1
    if _emit(args, result or {"success": True}):
        return 0
    print(f"Activated {args.selector} -- now signing outbound mail for {args.domain_name}")
    return 0


def cmd_dns_dkim_retire(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        result = _client().dns_retire_dkim(session["token"], args.domain_name, args.selector)
    except ApiError as e:
        _emit_error(args, f"Could not retire {args.selector}: {e.message}")
        return 1
    if _emit(args, result or {"success": True}):
        return 0
    print(f"Retired {args.selector}")
    return 0


def cmd_dns_recipient_access_list(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        entries = _client().dns_list_recipient_access(session["token"])
    except ApiError as e:
        _emit_error(args, f"Could not list recipient-access entries: {e.message}")
        return 1
    if _emit(args, entries):
        return 0
    if not entries:
        print("(no entries)")
        return 0
    rows = [[e["recipient"], e["action"], e.get("reason") or ""] for e in entries]
    _print_table(["RECIPIENT", "ACTION", "REASON"], rows)
    return 0


def cmd_dns_recipient_access_block(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        result = _client().dns_set_recipient_access(session["token"], args.recipient, "REJECT", reason=args.reason)
    except ApiError as e:
        _emit_error(args, f"Could not block {args.recipient}: {e.message}")
        return 1
    if _emit(args, result):
        return 0
    print(f"Blocked {args.recipient}")
    return 0


def cmd_dns_recipient_access_allow(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        result = _client().dns_set_recipient_access(session["token"], args.recipient, "OK", reason=args.reason)
    except ApiError as e:
        _emit_error(args, f"Could not allow {args.recipient}: {e.message}")
        return 1
    if _emit(args, result):
        return 0
    print(f"Allowed {args.recipient}")
    return 0


def cmd_dns_recipient_access_remove(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        result = _client().dns_delete_recipient_access(session["token"], args.recipient)
    except ApiError as e:
        _emit_error(args, f"Could not remove {args.recipient}: {e.message}")
        return 1
    if _emit(args, result or {"success": True}):
        return 0
    print(f"Removed {args.recipient}")
    return 0


def cmd_dns_mail_aliases_add(args):
    session = _require_session(args)
    if not session:
        return 1
    client = _client()
    try:
        result = client.dns_add_mail_alias(session["token"], args.source_pattern, args.destination, send_enabled=args.send_enabled)
    except ApiError as e:
        _emit_error(args, f"Could not add mail alias: {e.message}")
        return 1
    if _emit(args, result):
        return 0
    print(f"Added {args.source_pattern} -> {args.destination}")
    # source_pattern is either "@forge.name" (catch-all) or
    # "sales@forge.name" (exact address) -- either way, the bare domain
    # is everything after the last "@". mail-aliases add always creates
    # a real DNS zone for a new domain (dns_managed=true, see
    # MailAliases.pm), so unlike dns_domains_add there's no --no-dns
    # case to skip here.
    domain_name = args.source_pattern.rsplit("@", 1)[-1]
    _nudge_spf_dmarc(client, session["token"], domain_name)
    return 0


def cmd_dns_mail_aliases_list(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        entries = _client().dns_list_mail_aliases(session["token"], destination=args.user)
    except ApiError as e:
        _emit_error(args, f"Could not list mail aliases: {e.message}")
        return 1
    if _emit(args, entries):
        return 0
    if not entries:
        print("(no entries)")
        return 0
    rows = []
    for r in entries:
        state = "active" if r["active"] else "inactive"
        send = "send+receive" if r["send_enabled"] else "receive-only"
        rows.append([r["source_pattern"], r["destination"], state, send])
    _print_table(["SOURCE", "DESTINATION", "STATUS", "SEND"], rows)
    return 0


def cmd_dns_mail_aliases_enable_send(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        result = _client().dns_set_mail_alias_send_enabled(session["token"], args.source_pattern, True)
    except ApiError as e:
        _emit_error(args, f"Could not enable sending for {args.source_pattern}: {e.message}")
        return 1
    if _emit(args, result):
        return 0
    print(f"Sending enabled for {args.source_pattern}")
    return 0


def cmd_dns_mail_aliases_disable_send(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        result = _client().dns_set_mail_alias_send_enabled(session["token"], args.source_pattern, False)
    except ApiError as e:
        _emit_error(args, f"Could not disable sending for {args.source_pattern}: {e.message}")
        return 1
    if _emit(args, result):
        return 0
    print(f"Sending disabled for {args.source_pattern} (still receiving)")
    return 0


def cmd_dns_mail_aliases_remove(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        result = _client().dns_delete_mail_alias(session["token"], args.source_pattern)
    except ApiError as e:
        _emit_error(args, f"Could not remove {args.source_pattern}: {e.message}")
        return 1
    if _emit(args, result or {"success": True}):
        return 0
    print(f"Removed {args.source_pattern}")
    return 0


# --- mail: homelab-api's /api/v1/mail/* gateway -> homelab-mailbridge
# (see ../../mailbridge/README.md). No IMAP/SMTP client code here at
# all any more -- just HTTP, same as every other command. ---------------

def cmd_mail_list(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        messages = _client().mail_list(session["token"], mailbox=args.mailbox, limit=args.limit)
    except ApiError as e:
        _emit_error(args, f"Could not list messages: {e.message}")
        return 1
    if _emit(args, messages):
        return 0
    if not messages:
        print("(no messages)")
        return 0
    rows = [[m["uid"], m["date"], m["from"], m["subject"]] for m in messages]
    _print_table(["UID", "DATE", "FROM", "SUBJECT"], rows)
    return 0


def cmd_mail_read(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        message = _client().mail_read(session["token"], args.uid, mailbox=args.mailbox)
    except ApiError as e:
        _emit_error(args, f"Could not read message: {e.message}")
        return 1
    if not message:
        _emit_error(args, f"No message with uid {args.uid}")
        return 1
    if _emit(args, message):
        return 0
    print(f"From: {message['from']}")
    print(f"Date: {message['date']}")
    print(f"Subject: {message['subject']}")
    print()
    print(message["body"])
    return 0


def cmd_mail_send(args):
    session = _require_session(args)
    if not session:
        return 1
    body = args.body
    if args.body_file:
        body = Path(args.body_file).read_text()
    if body is None:
        body = sys.stdin.read()
    try:
        result = _client().mail_send(session["token"], args.to, args.subject, body, from_address=args.from_address)
    except ApiError as e:
        _emit_error(args, f"Could not send message: {e.message}")
        return 1
    if _emit(args, result or {"success": True}):
        return 0
    print(f"Sent to {args.to}")
    return 0


def cmd_mail_allowed_senders(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        result = _client().mail_allowed_senders(session["token"])
    except ApiError as e:
        _emit_error(args, f"Could not list allowed senders: {e.message}")
        return 1
    if _emit(args, result):
        return 0
    send = result.get("send", {})
    receive_only = result.get("receive_only", {})
    print("Can send as:")
    for a in send.get("addresses", []):
        print(f"  {a}")
    for d in send.get("domains", []):
        print(f"  anything{d}")
    if receive_only.get("addresses") or receive_only.get("domains"):
        print("Receive-only (sending currently disabled):")
        for a in receive_only.get("addresses", []):
            print(f"  {a}")
        for d in receive_only.get("domains", []):
            print(f"  anything{d}")
    return 0


def cmd_mail_block(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        result = _client().mail_block(session["token"], args.recipient, reason=args.reason)
    except ApiError as e:
        _emit_error(args, f"Could not block {args.recipient}: {e.message}")
        return 1
    if _emit(args, result):
        return 0
    print(f"Blocked {args.recipient} -- no mail will be accepted there until unblocked")
    return 0


def cmd_mail_unblock(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        result = _client().mail_unblock(session["token"], args.recipient)
    except ApiError as e:
        _emit_error(args, f"Could not unblock {args.recipient}: {e.message}")
        return 1
    if _emit(args, result or {"success": True}):
        return 0
    print(f"Unblocked {args.recipient}")
    return 0


def cmd_mail_blocked(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        entries = _client().mail_blocked(session["token"], q=args.search)
    except ApiError as e:
        _emit_error(args, f"Could not list blocked addresses: {e.message}")
        return 1
    if _emit(args, entries):
        return 0
    if not entries:
        print("(no blocked addresses)")
        return 0
    rows = [[e["recipient"], e.get("reason") or ""] for e in entries]
    _print_table(["RECIPIENT", "REASON"], rows)
    return 0


# --- drive: homelab-api's /api/v1/drive/* gateway -> homelab-drive's
# own JSON API (see ../../drive/README.md's "JSON API" section). -------

def cmd_drive_list(args):
    session = _require_session(args)
    if not session:
        return 1
    client = _client()
    try:
        folders = client.drive_list_folders(session["token"], parent_id=args.folder)
        files = client.drive_list_files(session["token"], folder_id=args.folder)
    except ApiError as e:
        _emit_error(args, f"Could not list: {e.message}")
        return 1
    if _emit(args, {"folders": folders, "files": files}):
        return 0
    if not folders and not files:
        print("(empty)")
        return 0
    rows = []
    for f in folders:
        rows.append(["dir", f["id"], f["name"] + "/", "", ""])
    for f in files:
        rows.append(["file", f["id"], f["filename"], f"{f['size_bytes']} bytes", f["uploaded_at"]])
    _print_table(["TYPE", "ID", "NAME", "SIZE", "UPLOADED"], rows)
    return 0


def cmd_drive_mkdir(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        result = _client().drive_create_folder(session["token"], args.name, parent_folder_id=args.parent)
    except ApiError as e:
        _emit_error(args, f"Could not create folder: {e.message}")
        return 1
    if _emit(args, result):
        return 0
    print(f"Created folder: {result['name']} (id {result['id']})")
    return 0


def cmd_drive_rmdir(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        result = _client().drive_delete_folder(session["token"], args.folder_id)
    except ApiError as e:
        _emit_error(args, f"Could not delete folder: {e.message}")
        return 1
    if _emit(args, result or {"success": True}):
        return 0
    print("Deleted (including everything inside it)")
    return 0


def cmd_drive_upload(args):
    session = _require_session(args)
    if not session:
        return 1
    path = Path(args.path)
    if not path.is_file():
        _emit_error(args, f"No such file: {path}")
        return 1
    try:
        result = _client().drive_upload_file(session["token"], path, folder_id=args.folder)
    except ApiError as e:
        _emit_error(args, f"Upload failed: {e.message}")
        return 1
    if _emit(args, result):
        return 0
    print(f"Uploaded: {result['filename']} (id {result['id']})")
    return 0


def cmd_drive_download(args):
    session = _require_session(args)
    if not session:
        return 1
    dest = args.output or args.file_id
    try:
        _client().drive_download_file(session["token"], args.file_id, dest)
    except ApiError as e:
        _emit_error(args, f"Download failed: {e.message}")
        return 1
    # The bytes themselves never belong in -j output -- only where they
    # landed and how big the file actually is (stat'd after writing;
    # drive_download_file streams straight to disk and returns nothing).
    if _emit(args, {"downloaded_to": dest, "size_bytes": Path(dest).stat().st_size}):
        return 0
    print(f"Downloaded to {dest}")
    return 0


def cmd_drive_delete(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        result = _client().drive_delete_file(session["token"], args.file_id)
    except ApiError as e:
        _emit_error(args, f"Delete failed: {e.message}")
        return 1
    if _emit(args, result or {"success": True}):
        return 0
    print("Deleted")
    return 0


# --- jobs: homelab-api's /api/v1/jobs/* gateway -> homelab-worker (see
# ../../worker/README.md). Not nested under `drive` even though the
# zip-download feature is what submits jobs today -- homelab-worker is
# deliberately generic, and future job types (SHA1 hashing, image
# resizing, a full-account export bundle, ...) won't be drive-specific
# either. Same "just attempt the call and let the server decide" pattern
# as `admin` below -- `--all` is only honored server-side for a
# site_admin account (a clean 403 for anyone else), never guessed at
# client-side. ---

def cmd_jobs_list(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        jobs = _client().jobs_list(session["token"], all_users=args.all, type=args.type, state=args.state)
    except ApiError as e:
        _emit_error(args, f"Could not list jobs: {e.message}")
        return 1
    if _emit(args, jobs):
        return 0
    if not jobs:
        print("(no jobs)")
        return 0
    rows = []
    for j in jobs:
        size = f"{j['output_size_bytes']} bytes" if j.get("output_size_bytes") else ""
        rows.append([
            j["id"], j["type"], j["state"], j["user_email"], j["created_at"],
            size, j.get("error_message") or "",
        ])
    _print_table(["ID", "TYPE", "STATE", "USER", "CREATED", "SIZE", "ERROR"], rows)
    return 0


def cmd_jobs_show(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        j = _client().jobs_get(session["token"], args.job_id)
    except ApiError as e:
        _emit_error(args, f"Could not show job: {e.message}")
        return 1
    if _emit(args, j):
        return 0
    for key in ("id", "type", "state", "user_email", "output_name", "output_size_bytes",
                "error_message", "created_at", "started_at", "completed_at"):
        print(f"{key}: {j.get(key)}")
    return 0


def cmd_jobs_download(args):
    session = _require_session(args)
    if not session:
        return 1
    client = _client()
    try:
        job = client.jobs_get(session["token"], args.job_id)
    except ApiError as e:
        _emit_error(args, f"Could not look up job: {e.message}")
        return 1
    dest = args.output or job.get("output_name") or f"job-{args.job_id}.bin"
    try:
        client.jobs_download(session["token"], args.job_id, dest)
    except ApiError as e:
        _emit_error(args, f"Download failed: {e.message}")
        return 1
    if _emit(args, {"downloaded_to": dest, "size_bytes": Path(dest).stat().st_size}):
        return 0
    print(f"Downloaded to {dest}")
    return 0


# --- sessions: which devices/locations currently hold a valid login for
# this account, and the ability to kill one (force re-login) -- see
# api/migrations/007-session-metadata.sql and App.pm's _sessions_*
# handlers. `--user` is honored server-side only for a site_admin
# caller, same "attempt the call, let the server decide" convention as
# every other admin-visibility flag in this CLI (no client-side role
# check here either). ---

# Small, dependency-free heuristic for a friendlier "Firefox / macOS /
# Desktop"-style summary of a raw User-Agent string, for `sessions list`
# display only -- the RAW string is what's actually stored server-side
# (see the plan/migration for why: no parsing loss in the data, only in
# what's shown). Order matters within each list: e.g. Edge and OPR both
# contain "Chrome" in their own UA strings, so they must be checked
# before the bare "Chrome" match or they'd misreport as Chrome.
_UA_BROWSERS = [
    ("homelab-cli/", "homelab-cli"), ("Edg/", "Edge"), ("OPR/", "Opera"), ("Firefox/", "Firefox"),
    ("Chrome/", "Chrome"), ("Safari/", "Safari"), ("python-requests/", "python-requests"),
    ("curl/", "curl"),
]
_UA_OSES = [
    ("iPhone", "iOS"), ("iPad", "iPadOS"), ("Android", "Android"),
    ("Windows", "Windows"), ("Mac OS X", "macOS"), ("Linux", "Linux"),
]
_UA_MOBILE_MARKERS = ("Mobile", "iPhone", "Android")


def summarize_user_agent(raw):
    """Best-effort "Browser / OS / Device" summary of a raw User-Agent
    string for display; returns the raw string unchanged when nothing
    recognizable is found. Callers are responsible for the missing-value
    case (None, or the literal 'unknown' the server stores for a missing/
    empty header) -- this function only handles real UA strings."""
    if not raw:
        return raw
    browser = next((name for marker, name in _UA_BROWSERS if marker in raw), None)
    os_name = next((name for marker, name in _UA_OSES if marker in raw), None)
    if not browser and not os_name:
        return raw
    device = "Mobile" if any(m in raw for m in _UA_MOBILE_MARKERS) else "Desktop"
    return " / ".join(part for part in (browser, os_name, device) if part)


_SESSION_ID_LEN = 12
_TIMESTAMP_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2})(?:\.\d+)?(.*)$")


def _short_session_id(jti):
    return jti[:_SESSION_ID_LEN]


def _format_session_timestamp(raw):
    """Drops sub-second precision from a Postgres timestamptz string for
    display (e.g. '2026-09-11 16:24:50.074436-05' -> '2026-09-11
    16:24:50-05') without reinterpreting the timezone -- whatever offset
    the server already reported is kept as-is, not converted."""
    if not raw:
        return "unknown"
    m = _TIMESTAMP_RE.match(raw)
    if not m:
        return raw
    return (m.group(1).replace("T", " ") + m.group(2)).strip()


def _print_table(headers, rows):
    """Minimal aligned-column table printer -- no new dependency, this
    CLI's tables are always small (a user's own session count, a domain's
    DNS records, etc.), so a full library like `tabulate` would be
    overkill for what's really just consistent column padding."""
    widths = [
        max(len(str(h)), max((len(str(r[i])) for r in rows), default=0))
        for i, h in enumerate(headers)
    ]
    def fmt(cells):
        return "  ".join(str(c).ljust(w) for c, w in zip(cells, widths)).rstrip()
    print(fmt(headers))
    for r in rows:
        print(fmt(r))


def cmd_sessions_list(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        sessions = _client().sessions_list(session["token"], user=args.user)
    except ApiError as e:
        _emit_error(args, f"Could not list sessions: {e.message}")
        return 1
    if _emit(args, sessions):
        return 0
    if not sessions:
        print("(no active sessions)")
        return 0
    rows = []
    for s in sessions:
        ua = s.get("user_agent")
        # None (a session created before device/IP tracking existed --
        # _refresh carries a NULL forward indefinitely until a real
        # re-login captures a fresh value) displays the same as the
        # server's own 'unknown' sentinel for a missing header -- never
        # the literal Python "None".
        device = summarize_user_agent(ua) if ua else "unknown"
        rows.append([
            _short_session_id(s["jti"]),
            device,
            s.get("ip_address") or "unknown",
            _format_session_timestamp(s.get("first_seen_at")),
            "*" if s.get("current") else "",
        ])
    _print_table(["ID", "DEVICE", "IP ADDRESS", "SINCE", ""], rows)
    print(f"(* = this session; 'sessions revoke' accepts a unique ID prefix, {_SESSION_ID_LEN} chars shown above is enough)")
    return 0


def cmd_sessions_revoke(args):
    session = _require_session(args)
    if not session:
        return 1

    if args.all_others:
        try:
            result = _client().sessions_revoke_others(session["token"])
        except ApiError as e:
            _emit_error(args, f"Could not revoke other sessions: {e.message}")
            return 1
        if _emit(args, result):
            return 0
        print(f"Revoked {result.get('revoked', 0)} other session(s).")
        return 0

    if not args.jti:
        _emit_error(args, "Either a jti (or a prefix of one) or --all-others is required.")
        return 1

    # Always resolve against a fresh list rather than trusting a
    # possibly-abbreviated jti the caller typed straight from a prior
    # `sessions list` -- this is also how the "you just revoked the
    # session you're using" warning below gets a reliable answer
    # (server-computed `current`, not a second, separately-fetched call
    # to match jtis by hand).
    try:
        sessions = _client().sessions_list(session["token"], user=args.user)
    except ApiError as e:
        _emit_error(args, f"Could not resolve session ID: {e.message}")
        return 1

    matches = [s for s in sessions if s["jti"] == args.jti or s["jti"].startswith(args.jti)]
    exact = [s for s in matches if s["jti"] == args.jti]
    if exact:
        matches = exact  # a full jti always wins, even over an astronomically unlikely prefix collision
    if not matches:
        _emit_error(args, f"No session found matching '{args.jti}'.")
        return 1
    if len(matches) > 1:
        _emit_error(
            args, f"'{args.jti}' matches {len(matches)} sessions -- use more characters.",
            data={"matches": [s["jti"] for s in matches]},
        )
        if not getattr(args, "json", False):
            for s in matches:
                print(f"  {_short_session_id(s['jti'])}", file=sys.stderr)
        return 1

    target = matches[0]
    try:
        result = _client().sessions_revoke(session["token"], target["jti"], user=args.user)
    except ApiError as e:
        _emit_error(args, f"Could not revoke session: {e.message}")
        return 1
    if _emit(args, result or {"success": True, "jti": target["jti"], "was_current": bool(target.get("current"))}):
        return 0
    print(f"Revoked session {_short_session_id(target['jti'])}")
    if target.get("current"):
        print("Note: that was the session this very command just used -- your next command will need to log in again.")
    return 0


# --- audit: homelab-audit's query endpoint, via homelab-api's
# /api/v1/audit/* gateway. Self-scoped by default, same "clean 403,
# never a silently-narrowed result" convention as sessions/mail-aliases
# above -- ?user= is only honored server-side for a caller holding the
# audit.view capability (site_admin always does). ---

def cmd_audit_list(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        entries = _client().audit_list(
            session["token"], user=args.user, since=args.since, until=args.until, action=args.action,
        )
    except ApiError as e:
        _emit_error(args, f"Could not list audit entries: {e.message}")
        return 1
    if _emit(args, entries):
        return 0
    if not entries:
        print("(no audit entries)")
        return 0
    rows = []
    for e in entries:
        rows.append([
            _format_session_timestamp(e.get("occurred_at")),
            e.get("user_email") or "",
            e.get("action") or "",
            e.get("resource_type") or "",
            e.get("resource_id") or "",
            e.get("ip_address") or "unknown",
        ])
    _print_table(["WHEN", "USER", "ACTION", "RESOURCE TYPE", "RESOURCE ID", "IP ADDRESS"], rows)
    return 0


# --- admin: homelab-api's site_admin-gated endpoints (api/README.md's
# "Admin endpoints" section). No client-side role check here on
# purpose — these just attempt the call and surface whatever the server
# decides (a non-admin gets a clean 403, not a confusing local guess). ---

def cmd_admin_users_list(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        users = _client().admin_list_users(session["token"])
    except ApiError as e:
        _emit_error(args, f"Could not list users: {e.message}")
        return 1
    if _emit(args, users):
        return 0
    if not users:
        print("(no users)")
        return 0
    rows = [
        [u["id"], u["email"], "active" if u["active"] else "inactive", ", ".join(u["roles"])]
        for u in users
    ]
    _print_table(["ID", "EMAIL", "STATUS", "ROLES"], rows)
    return 0


def cmd_admin_grant_role(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        result = _client().admin_grant_role(session["token"], args.user_id, args.role)
    except ApiError as e:
        _emit_error(args, f"Could not grant role: {e.message}")
        return 1
    if _emit(args, result or {"success": True}):
        return 0
    print(f"Granted '{args.role}' to user {args.user_id}")
    return 0


def cmd_admin_revoke_role(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        result = _client().admin_revoke_role(session["token"], args.user_id, args.role)
    except ApiError as e:
        _emit_error(args, f"Could not revoke role: {e.message}")
        return 1
    if _emit(args, result or {"success": True}):
        return 0
    print(f"Revoked '{args.role}' from user {args.user_id}")
    return 0


def cmd_admin_roles_list(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        roles = _client().admin_list_roles(session["token"])
    except ApiError as e:
        _emit_error(args, f"Could not list roles: {e.message}")
        return 1
    if _emit(args, roles):
        return 0
    if not roles:
        print("(no roles)")
        return 0
    rows = [
        [r["name"], "yes" if r["protected"] else "no", ", ".join(r["permissions"]) or "(none)"]
        for r in roles
    ]
    _print_table(["NAME", "PROTECTED", "PERMISSIONS"], rows)
    return 0


def cmd_admin_roles_add(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        result = _client().admin_create_role(session["token"], args.name, description=args.description)
    except ApiError as e:
        _emit_error(args, f"Could not create role: {e.message}")
        return 1
    if _emit(args, result):
        return 0
    print(f"Created role '{args.name}'")
    return 0


def cmd_admin_roles_remove(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        result = _client().admin_delete_role(session["token"], args.name)
    except ApiError as e:
        _emit_error(args, f"Could not remove role: {e.message}")
        return 1
    if _emit(args, result or {"success": True}):
        return 0
    print(f"Removed role '{args.name}'")
    return 0


def cmd_admin_permissions_list(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        permissions = _client().admin_list_permissions(session["token"])
    except ApiError as e:
        _emit_error(args, f"Could not list permissions: {e.message}")
        return 1
    if _emit(args, permissions):
        return 0
    if not permissions:
        print("(no permissions)")
        return 0
    rows = [[p["name"], p.get("description") or ""] for p in permissions]
    _print_table(["NAME", "DESCRIPTION"], rows)
    return 0


def cmd_admin_roles_grant_permission(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        result = _client().admin_grant_permission(session["token"], args.role, args.permission)
    except ApiError as e:
        _emit_error(args, f"Could not grant permission: {e.message}")
        return 1
    if _emit(args, result or {"success": True}):
        return 0
    print(f"Granted '{args.permission}' to role '{args.role}'")
    return 0


def cmd_admin_roles_revoke_permission(args):
    session = _require_session(args)
    if not session:
        return 1
    try:
        result = _client().admin_revoke_permission(session["token"], args.role, args.permission)
    except ApiError as e:
        _emit_error(args, f"Could not revoke permission: {e.message}")
        return 1
    if _emit(args, result or {"success": True}):
        return 0
    print(f"Revoked '{args.permission}' from role '{args.role}'")
    return 0


# Both DESCRIPTION and EPILOG below are surfaced twice: directly in
# `homelab-cli --help`, and again in the generated man page's
# DESCRIPTION/EXAMPLES sections (see debian/rules -- argparse-manpage
# is pointed straight at build_parser(), so there's exactly one place
# to keep this prose in sync, not two). Keep additions here short --
# this is a pointer to the full picture, not a copy of README.md.
# RawDescriptionHelpFormatter (below) preserves this text's own line
# breaks rather than re-wrapping it -- needed so the epilog's example
# block keeps its indentation/blank lines, but that means this
# description has to be hand-wrapped too, not left as one long line.
_DESCRIPTION = """\
Command-line client for the homelab-* ecosystem: account/session
management, email, file storage, DNS + mail-domain administration,
background job status, and (site_admin accounts) user administration
-- nearly everything the web UIs can do. --api-base is the only
address this CLI ever needs; homelab-api is the single gateway every
other feature is reached through.

Every command supports -j/--json for machine-readable output (the
real API response, not the human-formatted table/text) -- but it's a
GLOBAL flag, so it goes before the subcommand: `homelab-cli -j dns
domains list`, not `homelab-cli dns domains list -j`. This follows
from how argparse's own parent/subparser split works and isn't worth
fighting with a workaround."""

_EPILOG = """\
examples:
  homelab-cli configure --api-base https://api.test.mailmasker.org
  homelab-cli register you@test.mailmasker.org
  homelab-cli login you@test.mailmasker.org

  homelab-cli mail send --to you@example.com --subject Hi --body "..."
  homelab-cli drive upload ./file.txt
  homelab-cli jobs list

  homelab-cli dns domains add example.org
  homelab-cli dns records add example.org --name example.org --type A --value 203.0.113.10
  homelab-cli dns spf set example.org
  homelab-cli dns dmarc set example.org --policy quarantine --rua you@example.org
  homelab-cli dns dkim rotate example.org
  homelab-cli dns mail-aliases add @example.org you@test.mailmasker.org

  homelab-cli mail allowed-senders
  homelab-cli admin users list

  homelab-cli -j dns domains list | jq -r '.[].domain_name'
  homelab-cli -j sessions list | jq -r '.[] | select(.current) | .jti'

Session (token/refresh_token) is stored 0600 in
~/.config/homelab-cli/session.yml; the non-secret api_base lives in
config.yml in the same directory. Full documentation, including every
command's own gotchas: https://github.com/permittivity2/homelab
"""


def build_parser():
    parser = argparse.ArgumentParser(
        prog="homelab-cli",
        description=_DESCRIPTION,
        epilog=_EPILOG,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    # Global, not per-subcommand -- must come BEFORE the subcommand
    # (`homelab-cli -j dns domains list`) since it's parsed by the TOP
    # parser, not any of the subparsers below. See _DESCRIPTION above.
    parser.add_argument(
        "-j", "--json", action="store_true",
        help="Machine-readable output: print the real API response as JSON instead of a formatted table/message. Must come before the subcommand.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # homelab-api is the ONLY address this CLI ever needs -- drive and
    # mail both go through its own gateway routes now (see
    # ../README.md), resolved server-side via the service registry.
    p = sub.add_parser("configure", help="Set (or show) homelab-api's base URL")
    p.add_argument("--api-base", dest="api_base", help="homelab-api base URL")
    p.set_defaults(func=cmd_configure)

    p = sub.add_parser("register", help="Create a new account")
    p.add_argument("email")
    p.add_argument("--password", help="Prompted for if omitted")
    p.set_defaults(func=cmd_register)

    p = sub.add_parser("login", help="Log in and save a session")
    p.add_argument("email")
    p.add_argument("--password", help="Prompted for if omitted")
    p.set_defaults(func=cmd_login)

    p = sub.add_parser("whoami", help="Show the currently logged-in user")
    p.set_defaults(func=cmd_whoami)

    p = sub.add_parser("logout", help="Log out and clear the saved session")
    p.set_defaults(func=cmd_logout)

    registry = sub.add_parser("registry", help="Service registry commands")
    registry_sub = registry.add_subparsers(dest="registry_command", required=True)
    p = registry_sub.add_parser("list", help="List every registered feature and its address")
    p.set_defaults(func=cmd_registry_list)
    p = registry_sub.add_parser("lookup", help="Look up a feature's address (see 'registry list' for valid names)")
    p.add_argument("feature_name")
    p.set_defaults(func=cmd_registry_lookup)

    dns = sub.add_parser("dns", help="DNS + mail-domain administration (site_admin role required)")
    dns_sub = dns.add_subparsers(dest="dns_command", required=True)

    domains = dns_sub.add_parser("domains", help="Domain management")
    domains_sub = domains.add_subparsers(dest="dns_domains_command", required=True)

    p = domains_sub.add_parser("list", help="List every managed domain")
    p.set_defaults(func=cmd_dns_domains_list)

    p = domains_sub.add_parser("add", help="Add a domain (creates a PowerDNS zone unless --no-dns)")
    p.add_argument("domain_name")
    p.add_argument("--no-dns", dest="dns_managed", action="store_false", default=True, help="Mail-only: don't create/manage a DNS zone")
    p.add_argument("--no-mail", dest="mail_enabled", action="store_false", default=True, help="DNS-only: don't accept mail for this domain")
    p.add_argument("--ns", action="append", help="Nameserver for the new zone (repeatable; server default used if omitted)")
    p.set_defaults(func=cmd_dns_domains_add)

    p = domains_sub.add_parser("show", help="Show one domain's full state")
    p.add_argument("domain_name")
    p.set_defaults(func=cmd_dns_domains_show)

    p = domains_sub.add_parser("enable", help="Re-enable mail acceptance for a domain")
    p.add_argument("domain_name")
    p.set_defaults(func=cmd_dns_domains_enable)

    p = domains_sub.add_parser("disable", help="Stop accepting mail for a domain (soft -- does not delete DNS)")
    p.add_argument("domain_name")
    p.set_defaults(func=cmd_dns_domains_disable)

    records = dns_sub.add_parser("records", help="DNS record management")
    records_sub = records.add_subparsers(dest="dns_records_command", required=True)

    p = records_sub.add_parser("list", help="List a domain's DNS records")
    p.add_argument("domain_name")
    p.set_defaults(func=cmd_dns_records_list)

    p = records_sub.add_parser("add", help="Create or replace a record")
    p.add_argument("domain_name")
    p.add_argument("--name", required=True)
    p.add_argument("--type", required=True)
    p.add_argument("--value", required=True, action="append", help="Record content (repeatable for multi-value records)")
    p.add_argument("--ttl", type=int, default=3600)
    p.set_defaults(func=cmd_dns_records_add)

    p = records_sub.add_parser("delete", help="Delete a record")
    p.add_argument("domain_name")
    p.add_argument("--name", required=True)
    p.add_argument("--type", required=True)
    p.set_defaults(func=cmd_dns_records_delete)

    spf = dns_sub.add_parser("spf", help="SPF record, built for you from a couple of friendly flags")
    spf_sub = spf.add_subparsers(dest="dns_spf_command", required=True)

    p = spf_sub.add_parser("set", help="Create or replace the domain's SPF record")
    p.add_argument("domain_name")
    p.add_argument("--all", choices=sorted(_SPF_QUALIFIERS), default="softfail",
                    help="What to do with mail from a server NOT covered above (default: softfail -- mark suspicious, don't hard-reject)")
    p.add_argument("--include", action="append", help="Also authorize this domain's own SPF senders (repeatable, e.g. a marketing/helpdesk tool)")
    p.set_defaults(func=cmd_dns_spf_set)

    dmarc = dns_sub.add_parser("dmarc", help="DMARC record, built for you from a couple of friendly flags")
    dmarc_sub = dmarc.add_subparsers(dest="dns_dmarc_command", required=True)

    p = dmarc_sub.add_parser("set", help="Create or replace the domain's DMARC record")
    p.add_argument("domain_name")
    p.add_argument("--policy", choices=["none", "quarantine", "reject"], default="none",
                    help="What a receiver should do with mail that fails DMARC (default: none -- monitor only, safest starting point)")
    p.add_argument("--rua", action="append", help="Email address to receive aggregate reports (repeatable)")
    p.add_argument("--pct", type=int, choices=range(1, 101), metavar="1-100", help="Only apply the policy to this percentage of mail (omit to apply to all of it)")
    p.set_defaults(func=cmd_dns_dmarc_set)

    dkim = dns_sub.add_parser("dkim", help="DKIM key rotation")
    dkim_sub = dkim.add_subparsers(dest="dns_dkim_command", required=True)

    p = dkim_sub.add_parser("list", help="List a domain's DKIM selectors and their rotation state")
    p.add_argument("domain_name")
    p.set_defaults(func=cmd_dns_dkim_list)

    p = dkim_sub.add_parser("rotate", help="Generate a new selector and publish its DNS TXT record (state: pending)")
    p.add_argument("domain_name")
    p.set_defaults(func=cmd_dns_dkim_rotate)

    p = dkim_sub.add_parser("activate", help="Start signing with this selector; demotes the previous one to retiring")
    p.add_argument("domain_name")
    p.add_argument("selector")
    p.set_defaults(func=cmd_dns_dkim_activate)

    p = dkim_sub.add_parser("retire", help="Force-retire a selector now (break-glass; normally automatic after the overlap window)")
    p.add_argument("domain_name")
    p.add_argument("selector")
    p.set_defaults(func=cmd_dns_dkim_retire)

    ra = dns_sub.add_parser("recipient-access", help="Per-recipient mail allow/block")
    ra_sub = ra.add_subparsers(dest="dns_recipient_access_command", required=True)

    p = ra_sub.add_parser("list", help="List every allow/block override")
    p.set_defaults(func=cmd_dns_recipient_access_list)

    p = ra_sub.add_parser("block", help="Reject mail to this recipient at RCPT TO")
    p.add_argument("recipient")
    p.add_argument("--reason")
    p.set_defaults(func=cmd_dns_recipient_access_block)

    p = ra_sub.add_parser("allow", help="Explicitly allow this recipient (bypasses other restrictions)")
    p.add_argument("recipient")
    p.add_argument("--reason")
    p.set_defaults(func=cmd_dns_recipient_access_allow)

    p = ra_sub.add_parser("remove", help="Remove an override (revert to default behavior)")
    p.add_argument("recipient")
    p.set_defaults(func=cmd_dns_recipient_access_remove)

    ma = dns_sub.add_parser("mail-aliases", help="Multi-domain send-as/receive-as grants (admin)")
    ma_sub = ma.add_subparsers(dest="dns_mail_aliases_command", required=True)

    p = ma_sub.add_parser("add", help="Grant a domain/address to a user (creates the domain, DKIM-eligible but not mail_enabled, if new)")
    p.add_argument("source_pattern", help="'@forge.name' (catch-all) or 'sales@forge.name' (exact address)")
    p.add_argument("destination", help="The real user email this routes to, e.g. permittivity@mailmasker.org")
    p.add_argument("--no-send", dest="send_enabled", action="store_false", default=True, help="Grant receive-only (sending starts disabled)")
    p.set_defaults(func=cmd_dns_mail_aliases_add)

    p = ma_sub.add_parser("list", help="List every grant, or one user's with --user")
    p.add_argument("--user", help="Filter to this destination email only")
    p.set_defaults(func=cmd_dns_mail_aliases_list)

    p = ma_sub.add_parser("enable-send", help="Re-enable sending for a grant (receiving is unaffected either way)")
    p.add_argument("source_pattern")
    p.set_defaults(func=cmd_dns_mail_aliases_enable_send)

    p = ma_sub.add_parser("disable-send", help="Suspend sending for a grant without affecting receiving -- e.g. non-payment")
    p.add_argument("source_pattern")
    p.set_defaults(func=cmd_dns_mail_aliases_disable_send)

    p = ma_sub.add_parser("remove", help="Fully revoke a grant (stops both routing and sending)")
    p.add_argument("source_pattern")
    p.set_defaults(func=cmd_dns_mail_aliases_remove)

    mail = sub.add_parser("mail", help="Email, via homelab-api's mail gateway")
    mail_sub = mail.add_subparsers(dest="mail_command", required=True)

    p = mail_sub.add_parser("list", help="List recent messages")
    p.add_argument("--mailbox", default="INBOX")
    p.add_argument("--limit", type=int, default=20)
    p.set_defaults(func=cmd_mail_list)

    p = mail_sub.add_parser("read", help="Show one message")
    p.add_argument("uid")
    p.add_argument("--mailbox", default="INBOX")
    p.set_defaults(func=cmd_mail_read)

    p = mail_sub.add_parser("send", help="Send a message")
    p.add_argument("--to", required=True)
    p.add_argument("--subject", required=True)
    p.add_argument("--body", help="Message body (prompted from stdin if omitted and --body-file not given)")
    p.add_argument("--body-file", help="Read the message body from this file")
    p.add_argument("--from", dest="from_address", help="Send as this address instead of your own login (must be an authorized grant -- see 'mail allowed-senders')")
    p.set_defaults(func=cmd_mail_send)

    p = mail_sub.add_parser("allowed-senders", help="List the domains/addresses you're currently authorized to send as")
    p.set_defaults(func=cmd_mail_allowed_senders)

    p = mail_sub.add_parser("block", help="Reject ALL future mail to one of your own addresses (not sender-blocking -- see 'mail blocked')")
    p.add_argument("recipient", help="An address you own (your login address is never allowed here -- see 'mail allowed-senders')")
    p.add_argument("--reason", help="Shown to the sender in the rejection")
    p.set_defaults(func=cmd_mail_block)

    p = mail_sub.add_parser("unblock", help="Undo a previous 'mail block'")
    p.add_argument("recipient")
    p.set_defaults(func=cmd_mail_unblock)

    p = mail_sub.add_parser("blocked", help="List addresses you've blocked")
    p.add_argument("--search", help="Only show addresses containing this substring")
    p.set_defaults(func=cmd_mail_blocked)

    drive = sub.add_parser("drive", help="File storage, via homelab-api's drive gateway")
    drive_sub = drive.add_subparsers(dest="drive_command", required=True)

    p = drive_sub.add_parser("list", help="List folders and files (root, or one folder with --folder)")
    p.add_argument("--folder", help="Folder id to list (omit for the root)")
    p.set_defaults(func=cmd_drive_list)

    p = drive_sub.add_parser("upload", help="Upload a file")
    p.add_argument("path")
    p.add_argument("--folder", help="Folder id to upload into (omit for the root)")
    p.set_defaults(func=cmd_drive_upload)

    p = drive_sub.add_parser("download", help="Download a file by id")
    p.add_argument("file_id")
    p.add_argument("--output", help="Destination path (defaults to the file id in the current directory)")
    p.set_defaults(func=cmd_drive_download)

    p = drive_sub.add_parser("delete", help="Delete a file by id")
    p.add_argument("file_id")
    p.set_defaults(func=cmd_drive_delete)

    p = drive_sub.add_parser("mkdir", help="Create a folder")
    p.add_argument("name")
    p.add_argument("--parent", help="Parent folder id (omit to create at the root)")
    p.set_defaults(func=cmd_drive_mkdir)

    p = drive_sub.add_parser("rmdir", help="Delete a folder, and everything inside it")
    p.add_argument("folder_id")
    p.set_defaults(func=cmd_drive_rmdir)

    jobs = sub.add_parser("jobs", help="Background job status, via homelab-api's jobs gateway -> homelab-worker")
    jobs_sub = jobs.add_subparsers(dest="jobs_command", required=True)

    p = jobs_sub.add_parser("list", help="List jobs (your own by default; --all requires site_admin)")
    p.add_argument("--all", action="store_true", help="List every user's jobs, not just your own (site_admin only)")
    p.add_argument("--type", help="Filter by job type (e.g. zip)")
    p.add_argument("--state", choices=["pending", "running", "completed", "failed"], help="Filter by state")
    p.set_defaults(func=cmd_jobs_list)

    p = jobs_sub.add_parser("show", help="Show one job's full detail")
    p.add_argument("job_id")
    p.set_defaults(func=cmd_jobs_show)

    p = jobs_sub.add_parser("download", help="Download a finished job's output artifact")
    p.add_argument("job_id")
    p.add_argument("--output", help="Destination path (defaults to the job's own output_name)")
    p.set_defaults(func=cmd_jobs_download)

    sessions = sub.add_parser("sessions", help="See and revoke active login sessions (device/IP tracking)")
    sessions_sub = sessions.add_subparsers(dest="sessions_command", required=True)

    p = sessions_sub.add_parser("list", help="List active sessions (your own by default; --user requires site_admin)")
    p.add_argument("--user", help="List this user's sessions instead of your own (site_admin only)")
    p.set_defaults(func=cmd_sessions_list)

    p = sessions_sub.add_parser("revoke", help="Revoke a session (force re-login) -- by jti, or --all-others")
    p.add_argument("jti", nargs="?", help="The session's ID, or a unique prefix of one (see 'sessions list')")
    p.add_argument("--all-others", action="store_true", help="Revoke every OTHER session of yours, keep this one")
    p.add_argument("--user", help="Revoke this user's session instead of your own (site_admin only)")
    p.set_defaults(func=cmd_sessions_revoke)

    audit = sub.add_parser("audit", help="Query the system-wide audit trail")
    audit_sub = audit.add_subparsers(dest="audit_command", required=True)

    p = audit_sub.add_parser("list", help="List audit entries (your own by default; --user requires audit.view/site_admin)")
    p.add_argument("--user", help="List this user's audit entries instead of your own (audit.view/site_admin only)")
    p.add_argument("--since", help="Only entries at/after this timestamp, e.g. '2026-09-11' or '2026-09-11 16:00:00-05' (passed straight to Postgres, so any timestamp it accepts works)")
    p.add_argument("--until", help="Only entries at/before this timestamp -- same format as --since")
    p.add_argument("--action", help="Only entries matching this action name (e.g. file.delete)")
    p.set_defaults(func=cmd_audit_list)

    admin = sub.add_parser("admin", help="Administrative commands (site_admin role required)")
    admin_sub = admin.add_subparsers(dest="admin_command", required=True)
    users = admin_sub.add_parser("users", help="User/role management")
    users_sub = users.add_subparsers(dest="admin_users_command", required=True)

    p = users_sub.add_parser("list", help="List every user and their roles")
    p.set_defaults(func=cmd_admin_users_list)

    # No choices=KNOWN_ROLES here (there used to be one) -- `admin roles
    # add` below means the set of real roles is no longer just the two
    # built-ins, so a hard client-side choices= constraint would reject
    # granting a legitimate custom role before the request ever reaches
    # the server. Same "just attempt the call, let the server decide"
    # philosophy already used everywhere else in this file.
    p = users_sub.add_parser("grant-role", help="Grant a role to a user")
    p.add_argument("user_id")
    p.add_argument("role")
    p.set_defaults(func=cmd_admin_grant_role)

    p = users_sub.add_parser("revoke-role", help="Revoke a role from a user")
    p.add_argument("user_id")
    p.add_argument("role")
    p.set_defaults(func=cmd_admin_revoke_role)

    roles = admin_sub.add_parser("roles", help="Role & permission management")
    roles_sub = roles.add_subparsers(dest="admin_roles_command", required=True)

    p = roles_sub.add_parser("list", help="List every role, whether it's protected, and its granted permissions")
    p.set_defaults(func=cmd_admin_roles_list)

    p = roles_sub.add_parser("add", help="Create a new role")
    p.add_argument("name")
    p.add_argument("--description")
    p.set_defaults(func=cmd_admin_roles_add)

    p = roles_sub.add_parser("remove", help="Delete a role ('user'/'site_admin' are protected and cannot be removed)")
    p.add_argument("name")
    p.set_defaults(func=cmd_admin_roles_remove)

    p = roles_sub.add_parser("grant-permission", help="Grant a capability to a role")
    p.add_argument("role")
    p.add_argument("permission")
    p.set_defaults(func=cmd_admin_roles_grant_permission)

    p = roles_sub.add_parser("revoke-permission", help="Revoke a capability from a role")
    p.add_argument("role")
    p.add_argument("permission")
    p.set_defaults(func=cmd_admin_roles_revoke_permission)

    permissions = admin_sub.add_parser("permissions", help="Capability catalog")
    permissions_sub = permissions.add_subparsers(dest="admin_permissions_command", required=True)
    p = permissions_sub.add_parser("list", help="List the known capability catalog")
    p.set_defaults(func=cmd_admin_permissions_list)

    return parser


def main(argv=None):
    parser = build_parser()
    # A no-op unless the _ARGCOMPLETE env var is set (i.e. unless a shell
    # completion script is actually asking "what comes next" -- see
    # completions/homelab-cli.bash and README.md's Tab completion
    # section) -- normal invocations fall straight through to
    # parse_args() below exactly as before.
    argcomplete.autocomplete(parser)
    args = parser.parse_args(argv)
    try:
        return args.func(args) or 0
    except KeyboardInterrupt:
        # Most commonly hit at a getpass.getpass() password prompt
        # (cmd_login/cmd_register) or mid-network-call -- both would
        # otherwise propagate as a raw traceback all the way through the
        # installed console-script wrapper. 130 is the conventional
        # 128+SIGINT exit code a calling script would expect.
        if not getattr(args, "json", False):
            print(file=sys.stderr)  # visually separate from a half-typed password prompt line
        _emit_error(args, "Aborted.")
        return 130


if __name__ == "__main__":
    sys.exit(main())
