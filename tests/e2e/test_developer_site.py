"""developer.mailmasker.org, the public API reference (homelab-developer,
post-cutover item 49), as it is really served: through the edge, over
HTTPS, from prod-homelab45's nginx.

Read-only and public, so unlike the rest of this suite it checks the real
site rather than a test fleet (there is no developer.test.mailmasker.org).
DEVELOPER_BASE_URL points it somewhere else.

What it expects comes from ../../developer/reference in this same repo, so
a reference change that was committed but never released shows up here as
a site that is behind.

It needs nothing from the test fleet, so it runs on its own without the
suite's shared setup (which signs in to the test fleet first):

    python3 -m pytest tests/e2e/test_developer_site.py --noconftest
"""

import json
import os
import pathlib
import urllib.error
import urllib.request

import yaml

BASE_URL = os.environ.get("DEVELOPER_BASE_URL", "https://developer.mailmasker.org").rstrip("/")
REFERENCE = pathlib.Path(__file__).resolve().parents[2] / "developer" / "reference"


def _get(path, timeout=15):
    req = urllib.request.Request(f"{BASE_URL}{path}", headers={"User-Agent": "homelab-e2e"})
    try:
        resp = urllib.request.urlopen(req, timeout=timeout)
        return resp.status, resp.headers, resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read().decode("utf-8", "replace")


def _public_ids():
    ids = []
    for path in sorted(REFERENCE.glob("*.yml")):
        for ability in (yaml.safe_load(path.read_text()) or {}).get("abilities") or []:
            if ability.get("who") != "fleet":
                ids.append(ability["id"])
    return ids


def test_getting_started_is_the_home_page():
    status, headers, body = _get("/")
    assert status == 200
    assert "text/html" in headers.get("Content-Type", "")
    assert "<h1>Getting started</h1>" in body
    assert 'class="topbar"' in body, "the shared header is missing"


def test_an_ability_page_and_its_markdown():
    status, _, body = _get("/sign-in")
    assert status == 200 and "<h1>Sign in</h1>" in body
    status, headers, md = _get("/sign-in.md")
    assert status == 200
    assert headers.get("Content-Type", "").startswith("text/markdown"), headers.get("Content-Type")
    assert "charset=utf-8" in headers.get("Content-Type", "").lower()
    assert headers.get("Access-Control-Allow-Origin") == "*"
    assert md.startswith("# Sign in\n")


def test_the_site_is_not_behind_the_repo():
    status, _, body = _get("/reference.json")
    assert status == 200
    served = {a["id"] for area in json.loads(body)["areas"] for a in area["abilities"]}
    missing = sorted(set(_public_ids()) - served)
    assert not missing, f"the repo documents these but the site doesn't yet (release homelab-developer): {missing}"


def test_llms_txt_lists_every_ability():
    status, headers, body = _get("/llms.txt")
    assert status == 200 and headers.get("Content-Type", "").startswith("text/plain")
    assert body.startswith("# The MailMasker API\n")
    for ability_id in _public_ids():
        assert f"{BASE_URL}/{ability_id}.md)" in body.replace("https://developer.mailmasker.org", BASE_URL)


def test_the_claude_code_skill():
    status, _, body = _get("/skill/SKILL.md")
    assert status == 200
    assert body.startswith("---\nname: mailmasker-api\ndescription: ")
    status, _, page = _get("/claude-code")
    assert status == 200 and "name: mailmasker-api" in page


def test_a_wrong_address_is_a_404_page():
    status, _, body = _get("/no-such-page")
    assert status == 404 and "<h1>Not found</h1>" in body
