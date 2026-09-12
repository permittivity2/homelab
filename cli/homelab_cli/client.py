"""Thin HTTP client for homelab-api -- the ONE address homelab-cli ever
needs (see ../README.md). Drive and mail used to be separate upstream
services with their own base URLs (a separate DriveClient class, and
imaplib/smtplib calls straight to dovecot/postfix); both now go through
homelab-api's own /api/v1/drive/* and /api/v1/mail/* gateway routes
instead, which resolve the real backend via the service registry
server-side -- so there's only ever one class, one base URL, here."""

import platform

import requests

from . import __version__

# A real, identifiable User-Agent instead of the requests library's own
# generic default ("python-requests/x.y.z") -- homelab-api's session
# tracking (see api/migrations/007-session-metadata.sql) stores whatever
# User-Agent it receives, so a CLI-originated session should read
# clearly as "this is the CLI" in `homelab-cli sessions list`, not blend
# into whatever a browser's own UA string looks like.
DEFAULT_USER_AGENT = f"homelab-cli/{__version__} ({platform.system()} {platform.release()})"


class ApiError(Exception):
    def __init__(self, status_code, message):
        self.status_code = status_code
        self.message = message
        super().__init__(f"{status_code}: {message}")


class Client:
    # refresh_token/on_token_refreshed are both optional so a Client used
    # only for register/login (no session yet) behaves exactly as before
    # -- a 401 with no refresh_token on hand just raises immediately, the
    # same as prior to this refresh support existing at all.
    def __init__(self, api_base, timeout=10, refresh_token=None, on_token_refreshed=None):
        self.api_base = api_base.rstrip("/")
        self.timeout = timeout
        self.refresh_token = refresh_token
        self.on_token_refreshed = on_token_refreshed

    # Sends one HTTP request. If the server says 401 for a call that
    # actually carried a Bearer Authorization header (i.e. this wasn't
    # already an unauthenticated call like login/register) AND we hold a
    # refresh_token, transparently refresh once and retry the SAME
    # request with the new token -- this is what lets a homelab-cli
    # session outlive a single 30-minute JWT without the user noticing.
    # The refresh call itself (self.refresh(), invoked from
    # _try_refresh() below) never carries an Authorization header, so it
    # can never recursively trigger this same branch -- no separate
    # reentrancy guard needed. Returns the raw requests.Response so both
    # _request() (JSON calls) and the streaming download methods below
    # can share this retry behavior instead of each reimplementing it.
    def _send(self, method, path, timeout=None, **kwargs):
        # setdefault, not a plain assignment -- a caller-supplied
        # User-Agent (none currently exist, but this stays correct if
        # one ever does) is never clobbered.
        headers = dict(kwargs.get("headers") or {})
        headers.setdefault("User-Agent", DEFAULT_USER_AGENT)
        kwargs = dict(kwargs, headers=headers)
        try:
            resp = requests.request(method, f"{self.api_base}{path}", timeout=timeout or self.timeout, **kwargs)
        except requests.exceptions.RequestException as e:
            raise ApiError(0, str(e)) from e

        if resp.status_code == 401 and self.refresh_token:
            headers = kwargs.get("headers") or {}
            if headers.get("Authorization", "").startswith("Bearer "):
                new_token = self._try_refresh()
                if new_token is None:
                    # The refresh_token itself is also invalid/expired/
                    # revoked -- surface a clear, actionable message
                    # instead of whatever the original stale-JWT 401 said
                    # (typically a generic "invalid token").
                    raise ApiError(401, "session expired -- run 'homelab-cli login' again")
                headers = dict(headers)
                headers["Authorization"] = f"Bearer {new_token}"
                kwargs = dict(kwargs, headers=headers)
                try:
                    resp = requests.request(method, f"{self.api_base}{path}", timeout=timeout or self.timeout, **kwargs)
                except requests.exceptions.RequestException as e:
                    raise ApiError(0, str(e)) from e
        return resp

    # Exactly one refresh attempt -- never loops. Returns the new access
    # token on success, or None on any failure (network error, or the
    # refresh_token itself being invalid/expired/revoked), so _send()
    # can fall through to a clear error instead of retrying forever.
    def _try_refresh(self):
        try:
            result = self.refresh(self.refresh_token)
        except ApiError:
            return None
        new_token = result.get("token")
        new_refresh_token = result.get("refresh_token")
        if not new_token:
            return None
        # /auth/refresh rotates the refresh_token on every use (see
        # api/lib/Homelab/API/App.pm's _refresh -- the old one is
        # revoked server-side the instant this response is issued), so
        # the OLD self.refresh_token must never be reused again even if
        # the caller somehow declined to persist the new one.
        if new_refresh_token:
            self.refresh_token = new_refresh_token
        if self.on_token_refreshed:
            self.on_token_refreshed(new_token, self.refresh_token)
        return new_token

    def _request(self, method, path, timeout=None, **kwargs):
        resp = self._send(method, path, timeout=timeout, **kwargs)
        try:
            body = resp.json()
        except ValueError:
            body = {}

        if not resp.ok:
            raise ApiError(resp.status_code, body.get("error", resp.text))
        return body

    def _auth(self, token, **extra):
        return {"Authorization": f"Bearer {token}", **extra}

    # --- Auth -----------------------------------------------------------
    def register(self, email, password):
        return self._request("POST", "/api/v1/auth/register", json={"email": email, "password": password})

    def login(self, email, password):
        return self._request("POST", "/api/v1/auth/login", json={"email": email, "password": password})

    def introspect(self, token):
        return self._request("GET", "/api/v1/auth/introspect", headers=self._auth(token))

    def refresh(self, refresh_token):
        return self._request("POST", "/api/v1/auth/refresh", json={"refresh_token": refresh_token})

    def logout(self, refresh_token):
        return self._request("POST", "/api/v1/auth/logout", json={"refresh_token": refresh_token})

    # Session visibility/revocation -- see api/migrations/007-session-
    # metadata.sql and App.pm's _sessions_* handlers. `user` is honored
    # server-side only for a site_admin caller (a clean 403 otherwise,
    # not a silently-scoped-down result -- same convention as every
    # other ?user=/?destination= admin-visibility param in this CLI).
    def sessions_list(self, token, user=None):
        params = {"user": user} if user else {}
        return self._request("GET", "/api/v1/auth/sessions", headers=self._auth(token), params=params)

    def sessions_revoke(self, token, jti, user=None):
        params = {"user": user} if user else {}
        return self._request("DELETE", f"/api/v1/auth/sessions/{jti}", headers=self._auth(token), params=params)

    def sessions_revoke_others(self, token):
        return self._request(
            "DELETE", "/api/v1/auth/sessions", headers=self._auth(token), params={"except_current": "true"},
        )

    # Self-scoped by default (server-side) -- `user` is only honored for
    # a caller holding the audit.view capability (site_admin always
    # does), same "clean 403, never a silently-narrowed result"
    # convention as sessions_list/dns_list_mail_aliases above.
    def audit_list(self, token, user=None, since=None, until=None, action=None):
        params = {}
        if user:
            params["user"] = user
        if since:
            params["since"] = since
        if until:
            params["until"] = until
        if action:
            params["action"] = action
        return self._request("GET", "/api/v1/audit/log", headers=self._auth(token), params=params)

    def registry_lookup(self, feature_name):
        return self._request("GET", f"/api/v1/registry/{feature_name}")

    def registry_list(self):
        return self._request("GET", "/api/v1/registry")

    # --- Admin (site_admin role required server-side — see
    # api/README.md's "Admin endpoints" section) ---
    def admin_list_users(self, token):
        return self._request("GET", "/api/v1/admin/users", headers=self._auth(token))

    def admin_grant_role(self, token, user_id, role):
        return self._request("POST", f"/api/v1/admin/users/{user_id}/roles", headers=self._auth(token), json={"role": role})

    def admin_revoke_role(self, token, user_id, role):
        return self._request("DELETE", f"/api/v1/admin/users/{user_id}/roles/{role}", headers=self._auth(token))

    def admin_list_roles(self, token):
        return self._request("GET", "/api/v1/admin/roles", headers=self._auth(token))

    def admin_create_role(self, token, name, description=None):
        body = {"name": name}
        if description:
            body["description"] = description
        return self._request("POST", "/api/v1/admin/roles", headers=self._auth(token), json=body)

    def admin_delete_role(self, token, name):
        return self._request("DELETE", f"/api/v1/admin/roles/{name}", headers=self._auth(token))

    def admin_list_permissions(self, token):
        return self._request("GET", "/api/v1/admin/permissions", headers=self._auth(token))

    def admin_grant_permission(self, token, role, permission):
        return self._request(
            "POST", f"/api/v1/admin/roles/{role}/permissions/{permission}", headers=self._auth(token),
        )

    def admin_revoke_permission(self, token, role, permission):
        return self._request(
            "DELETE", f"/api/v1/admin/roles/{role}/permissions/{permission}", headers=self._auth(token),
        )

    # --- Drive, via homelab-api's /api/v1/drive/* gateway (see
    # ../../drive/README.md's own /api/v1/files/folders shape -- these
    # paths are that same API with a /drive/ prefix added by the
    # gateway). Uploads/downloads get a longer timeout than the default;
    # everything else here is a quick JSON call. ---
    def drive_list_files(self, token, folder_id=None):
        params = {"folder_id": folder_id} if folder_id else {}
        return self._request("GET", "/api/v1/drive/files", headers=self._auth(token), params=params)

    def drive_upload_file(self, token, path, folder_id=None):
        data = {"folder_id": folder_id} if folder_id else {}
        with open(path, "rb") as f:
            return self._request(
                "POST", "/api/v1/drive/files", headers=self._auth(token),
                files={"file": (path.name, f)}, data=data, timeout=60,
            )

    def drive_download_file(self, token, file_id, dest_path):
        resp = self._send(
            "GET", f"/api/v1/drive/files/{file_id}", headers=self._auth(token),
            timeout=60, stream=True,
        )
        if not resp.ok:
            raise ApiError(resp.status_code, _error_message(resp))
        with open(dest_path, "wb") as f:
            for chunk in resp.iter_content(chunk_size=65536):
                f.write(chunk)

    def drive_delete_file(self, token, file_id):
        return self._request("DELETE", f"/api/v1/drive/files/{file_id}", headers=self._auth(token))

    def drive_list_folders(self, token, parent_id=None):
        params = {"parent_id": parent_id} if parent_id else {}
        return self._request("GET", "/api/v1/drive/folders", headers=self._auth(token), params=params)

    def drive_create_folder(self, token, name, parent_folder_id=None):
        body = {"name": name}
        if parent_folder_id:
            body["parent_folder_id"] = parent_folder_id
        return self._request("POST", "/api/v1/drive/folders", headers=self._auth(token), json=body)

    def drive_delete_folder(self, token, folder_id):
        return self._request("DELETE", f"/api/v1/drive/folders/{folder_id}", headers=self._auth(token))

    # --- DNS + mail-domain admin, via homelab-api's /api/v1/domains/*
    # gateway -> homelab-domain-admin (see ../../domain-admin/README.md).
    # site_admin role required server-side. ---
    def dns_list_domains(self, token):
        return self._request("GET", "/api/v1/domains", headers=self._auth(token))

    def dns_add_domain(self, token, domain_name, mail_enabled=True, dns_managed=True, nameservers=None):
        body = {"domain_name": domain_name, "mail_enabled": mail_enabled, "dns_managed": dns_managed}
        if nameservers:
            body["nameservers"] = nameservers
        return self._request("POST", "/api/v1/domains", headers=self._auth(token), json=body)

    def dns_get_domain(self, token, domain_name):
        return self._request("GET", f"/api/v1/domains/{domain_name}", headers=self._auth(token))

    def dns_set_domain_enabled(self, token, domain_name, mail_enabled):
        return self._request("PATCH", f"/api/v1/domains/{domain_name}", headers=self._auth(token), json={"mail_enabled": mail_enabled})

    def dns_list_records(self, token, domain_name):
        return self._request("GET", f"/api/v1/domains/{domain_name}/dns/records", headers=self._auth(token))

    def dns_add_record(self, token, domain_name, name, type_, values, ttl=3600):
        return self._request(
            "POST", f"/api/v1/domains/{domain_name}/dns/records", headers=self._auth(token),
            json={"name": name, "type": type_, "content": values, "ttl": ttl},
        )

    def dns_delete_record(self, token, domain_name, name, type_):
        return self._request(
            "DELETE", f"/api/v1/domains/{domain_name}/dns/records", headers=self._auth(token),
            json={"name": name, "type": type_},
        )

    def dns_list_dkim(self, token, domain_name):
        return self._request("GET", f"/api/v1/domains/{domain_name}/dkim/selectors", headers=self._auth(token))

    def dns_rotate_dkim(self, token, domain_name):
        return self._request("POST", f"/api/v1/domains/{domain_name}/dkim/rotate", headers=self._auth(token))

    def dns_activate_dkim(self, token, domain_name, selector):
        return self._request("POST", f"/api/v1/domains/{domain_name}/dkim/{selector}/activate", headers=self._auth(token))

    def dns_retire_dkim(self, token, domain_name, selector):
        return self._request("POST", f"/api/v1/domains/{domain_name}/dkim/{selector}/retire", headers=self._auth(token))

    def dns_list_recipient_access(self, token):
        return self._request("GET", "/api/v1/domains/recipient-access", headers=self._auth(token))

    def dns_set_recipient_access(self, token, recipient, action, reason=None):
        body = {"recipient": recipient, "action": action}
        if reason:
            body["reason"] = reason
        return self._request("POST", "/api/v1/domains/recipient-access", headers=self._auth(token), json=body)

    def dns_delete_recipient_access(self, token, recipient):
        return self._request("DELETE", f"/api/v1/domains/recipient-access/{recipient}", headers=self._auth(token))

    # --- Multi-domain send-as grants, same gateway prefix as the DNS
    # methods above (site_admin required server-side except for the
    # self-service /mine endpoint under "Mail" below). See
    # ../../domain-admin/README.md's "Multi-domain send-as" section. ---
    def dns_add_mail_alias(self, token, source_pattern, destination, send_enabled=True):
        return self._request(
            "POST", "/api/v1/domains/mail-aliases", headers=self._auth(token),
            json={"source_pattern": source_pattern, "destination": destination, "send_enabled": send_enabled},
        )

    def dns_list_mail_aliases(self, token, destination=None):
        params = {"destination": destination} if destination else {}
        return self._request("GET", "/api/v1/domains/mail-aliases", headers=self._auth(token), params=params)

    def dns_set_mail_alias_send_enabled(self, token, source_pattern, send_enabled):
        return self._request(
            "PATCH", f"/api/v1/domains/mail-aliases/{source_pattern}", headers=self._auth(token),
            json={"send_enabled": send_enabled},
        )

    def dns_delete_mail_alias(self, token, source_pattern):
        return self._request("DELETE", f"/api/v1/domains/mail-aliases/{source_pattern}", headers=self._auth(token))

    # --- Mail, via homelab-api's /api/v1/mail/* gateway ->
    # homelab-mailbridge (see ../../mailbridge/README.md). No more
    # imaplib/smtplib here at all -- these are plain HTTP calls, same
    # shape as every other method on this class. ---
    def mail_list(self, token, mailbox="INBOX", limit=20):
        return self._request("GET", "/api/v1/mail/messages", headers=self._auth(token), params={"mailbox": mailbox, "limit": limit})

    def mail_read(self, token, uid, mailbox="INBOX"):
        try:
            return self._request("GET", f"/api/v1/mail/messages/{uid}", headers=self._auth(token), params={"mailbox": mailbox})
        except ApiError as e:
            if e.status_code == 404:
                return None
            raise

    def mail_send(self, token, to, subject, body, from_address=None):
        payload = {"to": to, "subject": subject, "body": body}
        if from_address:
            payload["from"] = from_address
        return self._request("POST", "/api/v1/mail/send", headers=self._auth(token), json=payload)

    # Self-service -- unlike every dns_mail_alias_* method above, this
    # one only ever needs a valid JWT, no site_admin role (see
    # ../../domain-admin/README.md). Still the /api/v1/domains/* gateway
    # prefix under the hood, but named/grouped with "mail" here to match
    # `homelab-cli mail allowed-senders`'s own user-facing grouping.
    def mail_allowed_senders(self, token):
        return self._request("GET", "/api/v1/domains/mail-aliases/mine", headers=self._auth(token))

    # Self-service recipient blocking -- "reject ALL mail to one of MY
    # OWN addresses, regardless of who sends it" (not sender-blocking;
    # see ../../domain-admin/README.md's "Self-service address
    # blocking" section for why). Same /mine self-service tier as
    # mail_allowed_senders above -- server-side enforces both that the
    # address is actually one of the caller's own, and that it isn't
    # their own account address (that would cut off ALL mail there).
    def mail_block(self, token, recipient, reason=None):
        body = {"recipient": recipient, "action": "REJECT"}
        if reason:
            body["reason"] = reason
        return self._request("POST", "/api/v1/domains/recipient-access/mine", headers=self._auth(token), json=body)

    def mail_unblock(self, token, recipient):
        return self._request("DELETE", f"/api/v1/domains/recipient-access/mine/{recipient}", headers=self._auth(token))

    def mail_blocked(self, token, q=None):
        params = {"q": q} if q else {}
        return self._request("GET", "/api/v1/domains/recipient-access/mine", headers=self._auth(token), params=params)

    # --- Jobs, via homelab-api's /api/v1/jobs/* gateway -> homelab-worker
    # (see ../../worker/README.md). A generic background-job engine --
    # zip-and-download (submitted by homelab-drive, not this CLI) is the
    # only job type today, but this client (and the `jobs` command tree
    # in cli.py) is deliberately type-agnostic: list/show/download work
    # the same way regardless of what kind of job it is. ---
    def jobs_list(self, token, all_users=False, type=None, state=None):
        params = {}
        if all_users:
            params["all"] = 1
        if type:
            params["type"] = type
        if state:
            params["state"] = state
        return self._request("GET", "/api/v1/jobs", headers=self._auth(token), params=params)

    def jobs_get(self, token, job_id):
        return self._request("GET", f"/api/v1/jobs/{job_id}", headers=self._auth(token))

    def jobs_download(self, token, job_id, dest_path):
        resp = self._send(
            "GET", f"/api/v1/jobs/{job_id}/download", headers=self._auth(token),
            timeout=60, stream=True,
        )
        if not resp.ok:
            raise ApiError(resp.status_code, _error_message(resp))
        with open(dest_path, "wb") as f:
            for chunk in resp.iter_content(chunk_size=65536):
                f.write(chunk)


def _error_message(resp):
    try:
        return resp.json().get("error", resp.text)
    except ValueError:
        return resp.text
