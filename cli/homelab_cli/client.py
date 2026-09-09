"""Thin HTTP client for homelab-api."""

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

    def _request(self, method, path, **kwargs):
        try:
            resp = requests.request(method, f"{self.api_base}{path}", timeout=self.timeout, **kwargs)
        except requests.exceptions.RequestException as e:
            raise ApiError(0, str(e)) from e

        try:
            body = resp.json()
        except ValueError:
            body = {}

        if not resp.ok:
            raise ApiError(resp.status_code, body.get("error", resp.text))
        return body

    def register(self, email, password):
        return self._request("POST", "/api/v1/auth/register", json={"email": email, "password": password})

    def login(self, email, password):
        return self._request("POST", "/api/v1/auth/login", json={"email": email, "password": password})

    def introspect(self, token):
        return self._request("GET", "/api/v1/auth/introspect", headers={"Authorization": f"Bearer {token}"})

    def refresh(self, refresh_token):
        return self._request("POST", "/api/v1/auth/refresh", json={"refresh_token": refresh_token})

    def logout(self, refresh_token):
        return self._request("POST", "/api/v1/auth/logout", json={"refresh_token": refresh_token})

    def registry_lookup(self, feature_name):
        return self._request("GET", f"/api/v1/registry/{feature_name}")

    # --- Admin (site_admin role required server-side — see
    # api/README.md's "Admin endpoints" section) ---
    def admin_list_users(self, token):
        return self._request("GET", "/api/v1/admin/users", headers={"Authorization": f"Bearer {token}"})

    def admin_grant_role(self, token, user_id, role):
        return self._request(
            "POST", f"/api/v1/admin/users/{user_id}/roles",
            headers={"Authorization": f"Bearer {token}"}, json={"role": role},
        )

    def admin_revoke_role(self, token, user_id, role):
        return self._request(
            "DELETE", f"/api/v1/admin/users/{user_id}/roles/{role}",
            headers={"Authorization": f"Bearer {token}"},
        )


class DriveClient:
    """Thin HTTP client for homelab-drive's Bearer-token-authenticated
    JSON API (see drive/README.md's "JSON API" section) — a separate
    class from Client above since it's a genuinely different upstream
    service with its own base URL, same one-client-per-service shape as
    homelab-common's Perl AuthClient/SSOClient split."""

    def __init__(self, drive_base, token, timeout=15):
        self.drive_base = drive_base.rstrip("/")
        self.token = token
        self.timeout = timeout

    def _headers(self, **extra):
        return {"Authorization": f"Bearer {self.token}", **extra}

    def list_files(self):
        resp = requests.get(f"{self.drive_base}/api/v1/files", headers=self._headers(), timeout=self.timeout)
        if not resp.ok:
            raise ApiError(resp.status_code, _error_message(resp))
        return resp.json()

    def upload_file(self, path):
        with open(path, "rb") as f:
            resp = requests.post(
                f"{self.drive_base}/api/v1/files", headers=self._headers(),
                files={"file": (path.name, f)}, timeout=self.timeout,
            )
        if not resp.ok:
            raise ApiError(resp.status_code, _error_message(resp))
        return resp.json()

    def download_file(self, file_id, dest_path):
        resp = requests.get(
            f"{self.drive_base}/api/v1/files/{file_id}", headers=self._headers(),
            timeout=self.timeout, stream=True,
        )
        if not resp.ok:
            raise ApiError(resp.status_code, _error_message(resp))
        with open(dest_path, "wb") as f:
            for chunk in resp.iter_content(chunk_size=65536):
                f.write(chunk)

    def delete_file(self, file_id):
        resp = requests.delete(f"{self.drive_base}/api/v1/files/{file_id}", headers=self._headers(), timeout=self.timeout)
        if not resp.ok:
            raise ApiError(resp.status_code, _error_message(resp))
        return resp.json()


def _error_message(resp):
    try:
        return resp.json().get("error", resp.text)
    except ValueError:
        return resp.text
