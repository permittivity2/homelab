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
        _client().mail_send(session["token"], args.to, args.subject, body)
    except ApiError as e:
        print(f"Could not send message: {e.message}", file=sys.stderr)
        return 1
    print(f"Sent to {args.to}")
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
    p = registry_sub.add_parser("lookup", help="Look up a feature's address")
    p.add_argument("feature_name")
    p.set_defaults(func=cmd_registry_lookup)

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
    p.set_defaults(func=cmd_mail_send)

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
