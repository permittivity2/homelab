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
