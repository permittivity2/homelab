"""Thin HTTP client for homelab-api -- the ONE address homelab-cli ever
needs (see ../README.md). Drive and mail used to be separate upstream
services with their own base URLs (a separate DriveClient class, and
imaplib/smtplib calls straight to dovecot/postfix); both now go through
homelab-api's own /api/v1/drive/* and /api/v1/mail/* gateway routes
instead, which resolve the real backend via the service registry
server-side -- so there's only ever one class, one base URL, here."""

import requests


class ApiError(Exception):
    def __init__(self, status_code, message):
        self.status_code = status_code
        self.message = message
        super().__init__(f"{status_code}: {message}")


class Client:
    def __init__(self, api_base, timeout=10):
        self.api_base = api_base.rstrip("/")
        self.timeout = timeout

    def _request(self, method, path, timeout=None, **kwargs):
        try:
            resp = requests.request(method, f"{self.api_base}{path}", timeout=timeout or self.timeout, **kwargs)
        except requests.exceptions.RequestException as e:
            raise ApiError(0, str(e)) from e

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
        try:
            resp = requests.get(
                f"{self.api_base}/api/v1/drive/files/{file_id}", headers=self._auth(token),
                timeout=60, stream=True,
            )
        except requests.exceptions.RequestException as e:
            raise ApiError(0, str(e)) from e
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
        try:
            resp = requests.get(
                f"{self.api_base}/api/v1/jobs/{job_id}/download", headers=self._auth(token),
                timeout=60, stream=True,
            )
        except requests.exceptions.RequestException as e:
            raise ApiError(0, str(e)) from e
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
