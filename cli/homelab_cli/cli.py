"""homelab-cli argument parsing and command dispatch."""

import argparse
import getpass
import sys

from . import config as cfgmod
from .client import ApiError, Client


def _client():
    return Client(cfgmod.load_config()["api_base"])


def cmd_configure(args):
    config = cfgmod.load_config()
    config["api_base"] = args.api_base
    cfgmod.save_config(config)
    print(f"api_base set to {args.api_base}")


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
    session = cfgmod.load_session()
    if not session:
        print("Not logged in. Run: homelab-cli login <email>", file=sys.stderr)
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


def build_parser():
    parser = argparse.ArgumentParser(prog="homelab-cli", description="Command-line client for homelab-api")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("configure", help="Set the homelab-api base URL")
    p.add_argument("api_base")
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

    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args) or 0


if __name__ == "__main__":
    sys.exit(main())
