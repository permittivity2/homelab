"""homelab-api is a deliberate public-facing API product, not just an
internal implementation detail (see api/README.md) — this is what
homelab-cli, or anyone's own scripts, actually calls from outside this
network. This test hits the real public HTTPS endpoint directly, the
same way a real CLI user would, no SSH tunnel — same pattern as
test_roundcube_login.py now that api.test.mailmasker.org has a real
Let's Encrypt cert too.

Deliberately does NOT drive the rate limiter to its real 429 threshold
here: the admin workstation running this suite shares one real public
IP for both these requests and any other manual testing against this
same host, and actually triggering the 10-failures/15-minutes lockout
would lock out that IP's OWN further testing for 15 minutes, not just
this test process. The rate-limiter's actual threshold-crossing
behavior is already covered where it can safely be pushed all the way
(api/t/basic.t, which runs in-process against a Postgres it can clean
up after itself) — this file only confirms a couple of ordinary failed
attempts behave normally (401, not something already wrong) over the
real public path.
"""

import time
import urllib.error
import urllib.request

import pytest

BASE_URL = "https://api.test.mailmasker.org"


def _post_json(path, payload, timeout=15):
    import json

    data = json.dumps(payload).encode()
    req = urllib.request.Request(f"{BASE_URL}{path}", data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    try:
        resp = urllib.request.urlopen(req, timeout=timeout)
        return resp.status, json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode())


def test_health_over_real_https():
    resp = urllib.request.urlopen(f"{BASE_URL}/health", timeout=15)
    assert resp.status == 200
    assert resp.read().decode() == "ok"


def test_register_and_login_over_real_https():
    email = f"e2e-api-public-{int(time.time())}@test.mailmasker.org"
    password = "E2eApiPublicTest1Aa"

    status, body = _post_json("/api/v1/auth/register", {"email": email, "password": password})
    assert status == 201, f"registration over the real public endpoint failed: {status} {body}"

    status, body = _post_json("/api/v1/auth/login", {"email": email, "password": "wrong-password"})
    assert status == 401, f"expected a plain rejection, not something already broken: {status} {body}"

    status, body = _post_json("/api/v1/auth/login", {"email": email, "password": password})
    assert status == 200 and "token" in body, f"login over the real public endpoint failed: {status} {body}"

    jwt = body["token"]
    req = urllib.request.Request(f"{BASE_URL}/api/v1/auth/introspect")
    req.add_header("Authorization", f"Bearer {jwt}")
    resp = urllib.request.urlopen(req, timeout=15)
    assert resp.status == 200
