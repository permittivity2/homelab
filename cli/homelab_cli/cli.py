"""homelab-cli argument parsing and command dispatch."""

import argparse
import getpass
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
    return Client(cfgmod.load_config()["api_base"])


def _require_session():
    """Returns the saved session dict, or None (after printing a clear
    error) if there isn't one. Every command below that needs to already
    be logged in starts with this, matching cmd_whoami's own existing
    error message so there's exactly one "how do I log in" hint used
    everywhere."""
    session = cfgmod.load_session()
    if not session:
        print("Not logged in. Run: homelab-cli login <email>", file=sys.stderr)
        return None
    return session


def cmd_configure(args):
    config = cfgmod.load_config()
    if args.api_base is None:
        for key, value in config.items():
            print(f"{key} = {value}")
        return 0
    config["api_base"] = args.api_base
    cfgmod.save_config(config)
    print("Configuration updated.")
    return 0


def cmd_register(args):
    password = args.password or getpass.getpass("Password: ")
    try:
        result = _client().register(args.email, password)
    except ApiError as e:
        print(f"Registration failed: {e.message}", file=sys.stderr)
        return 1
    print(f"Registered: {result['email']} (id {result['id']})")
    return 0


def cmd_login(args):
    password = args.password or getpass.getpass("Password: ")
    try:
        result = _client().login(args.email, password)
    except ApiError as e:
        print(f"Login failed: {e.message}", file=sys.stderr)
        return 1
    cfgmod.save_session({
        "email": args.email,
        "token": result["token"],
        "refresh_token": result["refresh_token"],
    })
    print(f"Logged in as {args.email}")
    return 0


def cmd_whoami(args):
    session = _require_session()
    if not session:
        return 1
    try:
        result = _client().introspect(session["token"])
    except ApiError as e:
        if e.status_code == 401:
            print("Session expired. Run: homelab-cli login <email>", file=sys.stderr)
        else:
            print(f"Error: {e.message}", file=sys.stderr)
        return 1
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
    print("Logged out")
    return 0


def cmd_registry_lookup(args):
    try:
        result = _client().registry_lookup(args.feature_name)
    except ApiError as e:
        print(f"Lookup failed: {e.message}", file=sys.stderr)
        return 1
    print(f"{result['feature_name']}: {result['host']}:{result['port']}")
    return 0


def cmd_registry_list(args):
    try:
        results = _client().registry_list()
    except ApiError as e:
        print(f"List failed: {e.message}", file=sys.stderr)
        return 1
    if not results:
        print("(no features registered)")
        return 0
    for entry in results:
        print(f"{entry['feature_name']}: {entry['host']}:{entry['port']}")
    return 0


# --- dns: homelab-api's /api/v1/domains/* gateway -> homelab-domain-admin
# (see ../../domain-admin/README.md). site_admin role required
# server-side (role-gating itself lands once homelab-api's introspect
# response carries roles -- see that package's own README "API"
# section; for now the server just requires any authenticated caller,
# same as every other command below tries and lets the server decide). -

def cmd_dns_domains_list(args):
    session = _require_session()
    if not session:
        return 1
    try:
        domains = _client().dns_list_domains(session["token"])
    except ApiError as e:
        print(f"Could not list domains: {e.message}", file=sys.stderr)
        return 1
    if not domains:
        print("(no domains)")
        return 0
    for d in domains:
        state = "active" if d["active"] else "disabled"
        flags = []
        if d["mail_enabled"]:
            flags.append("mail")
        if d["dns_managed"]:
            flags.append("dns")
        print(f"{d['domain_name']}  ({state}; {', '.join(flags) or 'no flags'})")
    return 0


def cmd_dns_domains_add(args):
    session = _require_session()
    if not session:
        return 1
    try:
        result = _client().dns_add_domain(
            session["token"], args.domain_name,
            mail_enabled=args.mail_enabled, dns_managed=args.dns_managed,
            nameservers=args.ns,
        )
    except ApiError as e:
        print(f"Could not add domain: {e.message}", file=sys.stderr)
        return 1
    print(f"Added: {result['domain_name']} (id {result['id']})")
    return 0


def cmd_dns_domains_show(args):
    session = _require_session()
    if not session:
        return 1
    try:
        d = _client().dns_get_domain(session["token"], args.domain_name)
    except ApiError as e:
        print(f"Could not show domain: {e.message}", file=sys.stderr)
        return 1
    for key in ("domain_name", "active", "mail_enabled", "dns_managed", "created_by", "created_at"):
        print(f"{key}: {d.get(key)}")
    return 0


def cmd_dns_domains_enable(args):
    session = _require_session()
    if not session:
        return 1
    try:
        _client().dns_set_domain_enabled(session["token"], args.domain_name, True)
    except ApiError as e:
        print(f"Could not enable domain: {e.message}", file=sys.stderr)
        return 1
    print(f"Enabled {args.domain_name}")
    return 0


def cmd_dns_domains_disable(args):
    session = _require_session()
    if not session:
        return 1
    try:
        _client().dns_set_domain_enabled(session["token"], args.domain_name, False)
    except ApiError as e:
        print(f"Could not disable domain: {e.message}", file=sys.stderr)
        return 1
    print(f"Disabled {args.domain_name}")
    return 0


def cmd_dns_records_list(args):
    session = _require_session()
    if not session:
        return 1
    try:
        records = _client().dns_list_records(session["token"], args.domain_name)
    except ApiError as e:
        print(f"Could not list records: {e.message}", file=sys.stderr)
        return 1
    if not records:
        print("(no records)")
        return 0
    for r in records:
        values = ", ".join(r["content"])
        print(f"{r['name']}  {r['type']}  {r['ttl']}  {values}")
    return 0


def cmd_dns_records_add(args):
    session = _require_session()
    if not session:
        return 1
    try:
        _client().dns_add_record(
            session["token"], args.domain_name, args.name, args.type, args.value, ttl=args.ttl,
        )
    except ApiError as e:
        print(f"Could not add record: {e.message}", file=sys.stderr)
        return 1
    print(f"Added {args.name} {args.type}")
    return 0


def cmd_dns_records_delete(args):
    session = _require_session()
    if not session:
        return 1
    try:
        _client().dns_delete_record(session["token"], args.domain_name, args.name, args.type)
    except ApiError as e:
        print(f"Could not delete record: {e.message}", file=sys.stderr)
        return 1
    print(f"Deleted {args.name} {args.type}")
    return 0


def cmd_dns_dkim_list(args):
    session = _require_session()
    if not session:
        return 1
    try:
        selectors = _client().dns_list_dkim(session["token"], args.domain_name)
    except ApiError as e:
        print(f"Could not list DKIM selectors: {e.message}", file=sys.stderr)
        return 1
    if not selectors:
        print("(no selectors)")
        return 0
    for s in selectors:
        extra = f"  retire_after={s['retire_after']}" if s.get("retire_after") else ""
        print(f"{s['selector']}  {s['state']}{extra}")
    return 0


def cmd_dns_dkim_rotate(args):
    session = _require_session()
    if not session:
        return 1
    try:
        result = _client().dns_rotate_dkim(session["token"], args.domain_name)
    except ApiError as e:
        print(f"Could not rotate DKIM key: {e.message}", file=sys.stderr)
        return 1
    print(f"Generated selector {result['selector']} (state: {result['state']}) -- activate it once its DNS TXT record has propagated")
    return 0


def cmd_dns_dkim_activate(args):
    session = _require_session()
    if not session:
        return 1
    try:
        _client().dns_activate_dkim(session["token"], args.domain_name, args.selector)
    except ApiError as e:
        print(f"Could not activate {args.selector}: {e.message}", file=sys.stderr)
        return 1
    print(f"Activated {args.selector} -- now signing outbound mail for {args.domain_name}")
    return 0


def cmd_dns_dkim_retire(args):
    session = _require_session()
    if not session:
        return 1
    try:
        _client().dns_retire_dkim(session["token"], args.domain_name, args.selector)
    except ApiError as e:
        print(f"Could not retire {args.selector}: {e.message}", file=sys.stderr)
        return 1
    print(f"Retired {args.selector}")
    return 0


def cmd_dns_recipient_access_list(args):
    session = _require_session()
    if not session:
        return 1
    try:
        entries = _client().dns_list_recipient_access(session["token"])
    except ApiError as e:
        print(f"Could not list recipient-access entries: {e.message}", file=sys.stderr)
        return 1
    if not entries:
        print("(no entries)")
        return 0
    for e in entries:
        reason = f"  ({e['reason']})" if e.get("reason") else ""
        print(f"{e['recipient']}  {e['action']}{reason}")
    return 0


def cmd_dns_recipient_access_block(args):
    session = _require_session()
    if not session:
        return 1
    try:
        _client().dns_set_recipient_access(session["token"], args.recipient, "REJECT", reason=args.reason)
    except ApiError as e:
        print(f"Could not block {args.recipient}: {e.message}", file=sys.stderr)
        return 1
    print(f"Blocked {args.recipient}")
    return 0


def cmd_dns_recipient_access_allow(args):
    session = _require_session()
    if not session:
        return 1
    try:
        _client().dns_set_recipient_access(session["token"], args.recipient, "OK", reason=args.reason)
    except ApiError as e:
        print(f"Could not allow {args.recipient}: {e.message}", file=sys.stderr)
        return 1
    print(f"Allowed {args.recipient}")
    return 0


def cmd_dns_recipient_access_remove(args):
    session = _require_session()
    if not session:
        return 1
    try:
        _client().dns_delete_recipient_access(session["token"], args.recipient)
    except ApiError as e:
        print(f"Could not remove {args.recipient}: {e.message}", file=sys.stderr)
        return 1
    print(f"Removed {args.recipient}")
    return 0


def cmd_dns_mail_aliases_add(args):
    session = _require_session()
    if not session:
        return 1
    try:
        _client().dns_add_mail_alias(session["token"], args.source_pattern, args.destination, send_enabled=args.send_enabled)
    except ApiError as e:
        print(f"Could not add mail alias: {e.message}", file=sys.stderr)
        return 1
    print(f"Added {args.source_pattern} -> {args.destination}")
    return 0


def cmd_dns_mail_aliases_list(args):
    session = _require_session()
    if not session:
        return 1
    try:
        rows = _client().dns_list_mail_aliases(session["token"], destination=args.user)
    except ApiError as e:
        print(f"Could not list mail aliases: {e.message}", file=sys.stderr)
        return 1
    if not rows:
        print("(no entries)")
        return 0
    for r in rows:
        state = "active" if r["active"] else "inactive"
        send = "send+receive" if r["send_enabled"] else "receive-only"
        print(f"{r['source_pattern']}  -> {r['destination']}  {state}  {send}")
    return 0


def cmd_dns_mail_aliases_enable_send(args):
    session = _require_session()
    if not session:
        return 1
    try:
        _client().dns_set_mail_alias_send_enabled(session["token"], args.source_pattern, True)
    except ApiError as e:
        print(f"Could not enable sending for {args.source_pattern}: {e.message}", file=sys.stderr)
        return 1
    print(f"Sending enabled for {args.source_pattern}")
    return 0


def cmd_dns_mail_aliases_disable_send(args):
    session = _require_session()
    if not session:
        return 1
    try:
        _client().dns_set_mail_alias_send_enabled(session["token"], args.source_pattern, False)
    except ApiError as e:
        print(f"Could not disable sending for {args.source_pattern}: {e.message}", file=sys.stderr)
        return 1
    print(f"Sending disabled for {args.source_pattern} (still receiving)")
    return 0


def cmd_dns_mail_aliases_remove(args):
    session = _require_session()
    if not session:
        return 1
    try:
        _client().dns_delete_mail_alias(session["token"], args.source_pattern)
    except ApiError as e:
        print(f"Could not remove {args.source_pattern}: {e.message}", file=sys.stderr)
        return 1
    print(f"Removed {args.source_pattern}")
    return 0


# --- mail: homelab-api's /api/v1/mail/* gateway -> homelab-mailbridge
# (see ../../mailbridge/README.md). No IMAP/SMTP client code here at
# all any more -- just HTTP, same as every other command. ---------------

def cmd_mail_list(args):
    session = _require_session()
    if not session:
        return 1
    try:
        messages = _client().mail_list(session["token"], mailbox=args.mailbox, limit=args.limit)
    except ApiError as e:
        print(f"Could not list messages: {e.message}", file=sys.stderr)
        return 1
    if not messages:
        print("(no messages)")
        return 0
    for m in messages:
        print(f"[{m['uid']}] {m['date']}  {m['from']}  {m['subject']}")
    return 0


def cmd_mail_read(args):
    session = _require_session()
    if not session:
        return 1
    try:
        message = _client().mail_read(session["token"], args.uid, mailbox=args.mailbox)
    except ApiError as e:
        print(f"Could not read message: {e.message}", file=sys.stderr)
        return 1
    if not message:
        print(f"No message with uid {args.uid}", file=sys.stderr)
        return 1
    print(f"From: {message['from']}")
    print(f"Date: {message['date']}")
    print(f"Subject: {message['subject']}")
    print()
    print(message["body"])
    return 0


def cmd_mail_send(args):
    session = _require_session()
    if not session:
        return 1
    body = args.body
    if args.body_file:
        body = Path(args.body_file).read_text()
    if body is None:
        body = sys.stdin.read()
    try:
        _client().mail_send(session["token"], args.to, args.subject, body, from_address=args.from_address)
    except ApiError as e:
        print(f"Could not send message: {e.message}", file=sys.stderr)
        return 1
    print(f"Sent to {args.to}")
    return 0


def cmd_mail_allowed_senders(args):
    session = _require_session()
    if not session:
        return 1
    try:
        result = _client().mail_allowed_senders(session["token"])
    except ApiError as e:
        print(f"Could not list allowed senders: {e.message}", file=sys.stderr)
        return 1
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


# --- drive: homelab-api's /api/v1/drive/* gateway -> homelab-drive's
# own JSON API (see ../../drive/README.md's "JSON API" section). -------

def cmd_drive_list(args):
    session = _require_session()
    if not session:
        return 1
    client = _client()
    try:
        folders = client.drive_list_folders(session["token"], parent_id=args.folder)
        files = client.drive_list_files(session["token"], folder_id=args.folder)
    except ApiError as e:
        print(f"Could not list: {e.message}", file=sys.stderr)
        return 1
    if not folders and not files:
        print("(empty)")
        return 0
    for f in folders:
        print(f"[dir  {f['id']}]  {f['name']}/")
    for f in files:
        print(f"[file {f['id']}]  {f['uploaded_at']}  {f['size_bytes']:>10} bytes  {f['filename']}")
    return 0


def cmd_drive_mkdir(args):
    session = _require_session()
    if not session:
        return 1
    try:
        result = _client().drive_create_folder(session["token"], args.name, parent_folder_id=args.parent)
    except ApiError as e:
        print(f"Could not create folder: {e.message}", file=sys.stderr)
        return 1
    print(f"Created folder: {result['name']} (id {result['id']})")
    return 0


def cmd_drive_rmdir(args):
    session = _require_session()
    if not session:
        return 1
    try:
        _client().drive_delete_folder(session["token"], args.folder_id)
    except ApiError as e:
        print(f"Could not delete folder: {e.message}", file=sys.stderr)
        return 1
    print("Deleted (including everything inside it)")
    return 0


def cmd_drive_upload(args):
    session = _require_session()
    if not session:
        return 1
    path = Path(args.path)
    if not path.is_file():
        print(f"No such file: {path}", file=sys.stderr)
        return 1
    try:
        result = _client().drive_upload_file(session["token"], path, folder_id=args.folder)
    except ApiError as e:
        print(f"Upload failed: {e.message}", file=sys.stderr)
        return 1
    print(f"Uploaded: {result['filename']} (id {result['id']})")
    return 0


def cmd_drive_download(args):
    session = _require_session()
    if not session:
        return 1
    dest = args.output or args.file_id
    try:
        _client().drive_download_file(session["token"], args.file_id, dest)
    except ApiError as e:
        print(f"Download failed: {e.message}", file=sys.stderr)
        return 1
    print(f"Downloaded to {dest}")
    return 0


def cmd_drive_delete(args):
    session = _require_session()
    if not session:
        return 1
    try:
        _client().drive_delete_file(session["token"], args.file_id)
    except ApiError as e:
        print(f"Delete failed: {e.message}", file=sys.stderr)
        return 1
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
    session = _require_session()
    if not session:
        return 1
    try:
        jobs = _client().jobs_list(session["token"], all_users=args.all, type=args.type, state=args.state)
    except ApiError as e:
        print(f"Could not list jobs: {e.message}", file=sys.stderr)
        return 1
    if not jobs:
        print("(no jobs)")
        return 0
    for j in jobs:
        size = f"  {j['output_size_bytes']} bytes" if j.get("output_size_bytes") else ""
        extra = f"  ({j['error_message']})" if j.get("error_message") else ""
        print(f"[{j['id']}] {j['type']}  {j['state']}  {j['user_email']}  {j['created_at']}{size}{extra}")
    return 0


def cmd_jobs_show(args):
    session = _require_session()
    if not session:
        return 1
    try:
        j = _client().jobs_get(session["token"], args.job_id)
    except ApiError as e:
        print(f"Could not show job: {e.message}", file=sys.stderr)
        return 1
    for key in ("id", "type", "state", "user_email", "output_name", "output_size_bytes",
                "error_message", "created_at", "started_at", "completed_at"):
        print(f"{key}: {j.get(key)}")
    return 0


def cmd_jobs_download(args):
    session = _require_session()
    if not session:
        return 1
    client = _client()
    try:
        job = client.jobs_get(session["token"], args.job_id)
    except ApiError as e:
        print(f"Could not look up job: {e.message}", file=sys.stderr)
        return 1
    dest = args.output or job.get("output_name") or f"job-{args.job_id}.bin"
    try:
        client.jobs_download(session["token"], args.job_id, dest)
    except ApiError as e:
        print(f"Download failed: {e.message}", file=sys.stderr)
        return 1
    print(f"Downloaded to {dest}")
    return 0


# --- admin: homelab-api's site_admin-gated endpoints (api/README.md's
# "Admin endpoints" section). No client-side role check here on
# purpose — these just attempt the call and surface whatever the server
# decides (a non-admin gets a clean 403, not a confusing local guess). ---

def cmd_admin_users_list(args):
    session = _require_session()
    if not session:
        return 1
    try:
        users = _client().admin_list_users(session["token"])
    except ApiError as e:
        print(f"Could not list users: {e.message}", file=sys.stderr)
        return 1
    for u in users:
        roles = ", ".join(u["roles"])
        active = "active" if u["active"] else "inactive"
        print(f"[{u['id']}] {u['email']}  ({active})  roles: {roles}")
    return 0


def cmd_admin_grant_role(args):
    session = _require_session()
    if not session:
        return 1
    try:
        _client().admin_grant_role(session["token"], args.user_id, args.role)
    except ApiError as e:
        print(f"Could not grant role: {e.message}", file=sys.stderr)
        return 1
    print(f"Granted '{args.role}' to user {args.user_id}")
    return 0


def cmd_admin_revoke_role(args):
    session = _require_session()
    if not session:
        return 1
    try:
        _client().admin_revoke_role(session["token"], args.user_id, args.role)
    except ApiError as e:
        print(f"Could not revoke role: {e.message}", file=sys.stderr)
        return 1
    print(f"Revoked '{args.role}' from user {args.user_id}")
    return 0


def build_parser():
    parser = argparse.ArgumentParser(prog="homelab-cli", description="Command-line client for the homelab-* ecosystem")
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

    admin = sub.add_parser("admin", help="Administrative commands (site_admin role required)")
    admin_sub = admin.add_subparsers(dest="admin_command", required=True)
    users = admin_sub.add_parser("users", help="User/role management")
    users_sub = users.add_subparsers(dest="admin_users_command", required=True)

    p = users_sub.add_parser("list", help="List every user and their roles")
    p.set_defaults(func=cmd_admin_users_list)

    p = users_sub.add_parser("grant-role", help="Grant a role to a user")
    p.add_argument("user_id")
    p.add_argument("role", choices=KNOWN_ROLES)
    p.set_defaults(func=cmd_admin_grant_role)

    p = users_sub.add_parser("revoke-role", help="Revoke a role from a user")
    p.add_argument("user_id")
    p.add_argument("role", choices=KNOWN_ROLES)
    p.set_defaults(func=cmd_admin_revoke_role)

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
    return args.func(args) or 0


if __name__ == "__main__":
    sys.exit(main())
