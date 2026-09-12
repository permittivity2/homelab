"""Unit tests for cli.py's own logic -- not the cmd_* dispatch functions
themselves (thin glue, untested elsewhere in this suite either, see
test_client.py's own module docstring reasoning), but the two pieces of
real, non-trivial logic added alongside them: SPF/DMARC value
construction and the post-domain-creation SPF/DMARC nudge."""

from unittest.mock import MagicMock

from homelab_cli.cli import _build_dmarc_value, _build_mx_value, _build_spf_value, _nudge_missing_dns_records, summarize_user_agent
from homelab_cli.client import ApiError


# --- SPF value building ------------------------------------------------

def test_spf_default_is_softfail_with_no_includes():
    assert _build_spf_value("softfail", None) == "v=spf1 mx ~all"


def test_spf_empty_includes_list_same_as_none():
    assert _build_spf_value("softfail", []) == "v=spf1 mx ~all"


def test_spf_all_qualifiers_map_to_real_spf_characters():
    assert _build_spf_value("pass", None) == "v=spf1 mx +all"
    assert _build_spf_value("neutral", None) == "v=spf1 mx ?all"
    assert _build_spf_value("softfail", None) == "v=spf1 mx ~all"
    assert _build_spf_value("fail", None) == "v=spf1 mx -all"


def test_spf_includes_are_ordered_and_repeated():
    value = _build_spf_value("fail", ["sendgrid.net", "mailgun.org"])
    assert value == "v=spf1 mx include:sendgrid.net include:mailgun.org -all"


# --- DMARC value building -----------------------------------------------

def test_dmarc_default_policy_only():
    assert _build_dmarc_value("none", None, None) == "v=DMARC1; p=none"


def test_dmarc_empty_rua_list_omits_rua_tag():
    assert _build_dmarc_value("none", [], None) == "v=DMARC1; p=none"


def test_dmarc_policy_choices():
    for policy in ("none", "quarantine", "reject"):
        assert _build_dmarc_value(policy, None, None) == f"v=DMARC1; p={policy}"


def test_dmarc_single_rua_address():
    assert _build_dmarc_value("none", ["a@b.com"], None) == "v=DMARC1; p=none; rua=mailto:a@b.com"


def test_dmarc_multiple_rua_addresses_comma_joined_single_tag():
    value = _build_dmarc_value("none", ["a@b.com", "c@d.com"], None)
    assert value == "v=DMARC1; p=none; rua=mailto:a@b.com,mailto:c@d.com"


def test_dmarc_pct_only_included_when_given():
    assert "pct=" not in _build_dmarc_value("none", None, None)
    assert _build_dmarc_value("none", None, 50) == "v=DMARC1; p=none; pct=50"


def test_dmarc_full_combination_tag_order():
    value = _build_dmarc_value("reject", ["a@b.com", "c@d.com"], 50)
    assert value == "v=DMARC1; p=reject; rua=mailto:a@b.com,mailto:c@d.com; pct=50"


# --- MX/SPF/DMARC nudge ---------------------------------------------------
# dns_list_records' real backend (Dns.pm's list_records) passes PowerDNS's
# own rrset names straight through, which always carry a trailing dot
# (confirmed by reading domain-admin/lib/.../PowerDNS.pm's _fqdn) -- every
# fixture below deliberately includes that trailing dot so a regression
# that stops stripping it would actually be caught here.

def _record(name, type_, content):
    return {"name": name, "type": type_, "content": content}


_MX_RECORD = _record("forge.name.", "MX", ["10 mail.test.mailmasker.org."])
_SPF_RECORD = _record("forge.name.", "TXT", ['"v=spf1 mx ~all"'])
_DMARC_RECORD = _record("_dmarc.forge.name.", "TXT", ['"v=DMARC1; p=none"'])


def test_nudge_prints_all_three_when_nothing_present(capsys):
    client = MagicMock()
    client.dns_list_records.return_value = []
    _nudge_missing_dns_records(client, "tok", "forge.name")
    out = capsys.readouterr().out
    assert "no MX record found for forge.name" in out
    assert "dns mx set forge.name" in out
    assert "no SPF record found for forge.name" in out
    assert "dns spf set forge.name" in out
    assert "no DMARC record found for forge.name" in out
    assert "dns dmarc set forge.name" in out


def test_nudge_prints_nothing_when_all_three_present(capsys):
    # Deliberately using PowerDNS's real wire-format quoting for TXT
    # content (content == ['"v=spf1 mx ~all"'], literal quote chars) --
    # confirmed against a real deployed zone, not just assumed. An
    # earlier version of this nudge compared unquoted and always
    # reported both as missing even right after they'd just been set;
    # this fixture shape is what would have caught that. MX content is
    # NOT a quoted character-string type, so no quoting on that one.
    client = MagicMock()
    client.dns_list_records.return_value = [_MX_RECORD, _SPF_RECORD, _DMARC_RECORD]
    _nudge_missing_dns_records(client, "tok", "forge.name")
    assert capsys.readouterr().out == ""


def test_nudge_prints_only_the_missing_one(capsys):
    client = MagicMock()
    client.dns_list_records.return_value = [_MX_RECORD, _SPF_RECORD]
    _nudge_missing_dns_records(client, "tok", "forge.name")
    out = capsys.readouterr().out
    assert "MX" not in out
    assert "SPF" not in out
    assert "no DMARC record found for forge.name" in out


def test_nudge_prints_mx_when_only_mx_missing(capsys):
    """The specific gap that motivated adding this check: SPF/DMARC set
    up correctly, but no MX -- mail silently deferred/timed out with
    nothing about the domain/alias setup itself looking wrong."""
    client = MagicMock()
    client.dns_list_records.return_value = [_SPF_RECORD, _DMARC_RECORD]
    _nudge_missing_dns_records(client, "tok", "forge.name")
    out = capsys.readouterr().out
    assert "no MX record found for forge.name" in out
    assert "dns mx set forge.name" in out
    assert "SPF" not in out
    assert "DMARC" not in out


def test_nudge_ignores_unrelated_txt_records_at_the_same_name(capsys):
    """A TXT record that happens to share the apex name but isn't SPF
    syntax (e.g. a domain-verification token) must not be mistaken for
    an SPF record."""
    client = MagicMock()
    client.dns_list_records.return_value = [
        _MX_RECORD,
        _record("forge.name.", "TXT", ['"some-other-verification-token"']),
    ]
    _nudge_missing_dns_records(client, "tok", "forge.name")
    out = capsys.readouterr().out
    assert "no SPF record found for forge.name" in out


def test_nudge_swallows_api_error_and_prints_nothing(capsys):
    """A transient failure checking existing records must never look like
    an error to the caller -- this is a UX nicety layered on top of a
    command that already succeeded."""
    client = MagicMock()
    client.dns_list_records.side_effect = ApiError(502, "zone not ready")
    _nudge_missing_dns_records(client, "tok", "forge.name")
    assert capsys.readouterr().out == ""


# --- _build_mx_value -------------------------------------------------------

def test_build_mx_value_appends_trailing_dot():
    assert _build_mx_value(10, "mail.test.mailmasker.org") == "10 mail.test.mailmasker.org."


def test_build_mx_value_leaves_existing_trailing_dot_alone():
    assert _build_mx_value(10, "mail.test.mailmasker.org.") == "10 mail.test.mailmasker.org."


# --- summarize_user_agent: display-only heuristic for `sessions list`
# (see api/migrations/007-session-metadata.sql -- the raw UA is always
# what's actually stored; this is purely presentational). ---

def test_summarize_firefox_desktop_linux():
    raw = "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"
    assert summarize_user_agent(raw) == "Firefox / Linux / Desktop"


def test_summarize_safari_macos_desktop():
    raw = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    assert summarize_user_agent(raw) == "Safari / macOS / Desktop"


def test_summarize_mobile_safari_ios():
    raw = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    assert summarize_user_agent(raw) == "Safari / iOS / Mobile"


def test_summarize_edge_not_misreported_as_chrome():
    """Edge's own UA string contains 'Chrome/...' too -- the Edge marker
    must be checked first or every Edge session would misreport as
    Chrome."""
    raw = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36 Edg/120.0"
    assert summarize_user_agent(raw) == "Edge / Windows / Desktop"


def test_summarize_homelab_cli_own_user_agent():
    assert summarize_user_agent("homelab-cli/0.3.16 (Linux 6.8.0)") == "homelab-cli / Linux / Desktop"


def test_summarize_curl_recognized():
    assert summarize_user_agent("curl/8.5.0") == "curl / Desktop"


def test_summarize_unrecognized_string_returned_unchanged():
    assert summarize_user_agent("SomeWeirdBot/1.0") == "SomeWeirdBot/1.0"


def test_summarize_unknown_returned_unchanged():
    """The literal 'unknown' the server stores for a missing/empty
    header (see App.pm's _login) matches no browser/OS pattern, so it
    falls through to the raw-string path -- no special-casing needed."""
    assert summarize_user_agent("unknown") == "unknown"


def test_summarize_empty_or_none_returned_unchanged():
    assert summarize_user_agent("") == ""
    assert summarize_user_agent(None) is None
