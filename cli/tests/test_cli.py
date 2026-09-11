"""Unit tests for cli.py's own logic -- not the cmd_* dispatch functions
themselves (thin glue, untested elsewhere in this suite either, see
test_client.py's own module docstring reasoning), but the two pieces of
real, non-trivial logic added alongside them: SPF/DMARC value
construction and the post-domain-creation SPF/DMARC nudge."""

from unittest.mock import MagicMock

from homelab_cli.cli import _build_dmarc_value, _build_spf_value, _nudge_spf_dmarc
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


# --- SPF/DMARC nudge -----------------------------------------------------
# dns_list_records' real backend (Dns.pm's list_records) passes PowerDNS's
# own rrset names straight through, which always carry a trailing dot
# (confirmed by reading domain-admin/lib/.../PowerDNS.pm's _fqdn) -- every
# fixture below deliberately includes that trailing dot so a regression
# that stops stripping it would actually be caught here.

def _record(name, type_, content):
    return {"name": name, "type": type_, "content": content}


def test_nudge_prints_both_when_nothing_present(capsys):
    client = MagicMock()
    client.dns_list_records.return_value = []
    _nudge_spf_dmarc(client, "tok", "forge.name")
    out = capsys.readouterr().out
    assert "no SPF record found for forge.name" in out
    assert "dns spf set forge.name" in out
    assert "no DMARC record found for forge.name" in out
    assert "dns dmarc set forge.name" in out


def test_nudge_prints_nothing_when_both_present(capsys):
    # Deliberately using PowerDNS's real wire-format quoting for TXT
    # content (content == ['"v=spf1 mx ~all"'], literal quote chars) --
    # confirmed against a real deployed zone, not just assumed. An
    # earlier version of _nudge_spf_dmarc compared unquoted and always
    # reported both as missing even right after they'd just been set;
    # this fixture shape is what would have caught that.
    client = MagicMock()
    client.dns_list_records.return_value = [
        _record("forge.name.", "TXT", ['"v=spf1 mx ~all"']),
        _record("_dmarc.forge.name.", "TXT", ['"v=DMARC1; p=none"']),
    ]
    _nudge_spf_dmarc(client, "tok", "forge.name")
    assert capsys.readouterr().out == ""


def test_nudge_prints_only_the_missing_one(capsys):
    client = MagicMock()
    client.dns_list_records.return_value = [
        _record("forge.name.", "TXT", ['"v=spf1 mx ~all"']),
    ]
    _nudge_spf_dmarc(client, "tok", "forge.name")
    out = capsys.readouterr().out
    assert "SPF" not in out
    assert "no DMARC record found for forge.name" in out


def test_nudge_ignores_unrelated_txt_records_at_the_same_name(capsys):
    """A TXT record that happens to share the apex name but isn't SPF
    syntax (e.g. a domain-verification token) must not be mistaken for
    an SPF record."""
    client = MagicMock()
    client.dns_list_records.return_value = [
        _record("forge.name.", "TXT", ['"some-other-verification-token"']),
    ]
    _nudge_spf_dmarc(client, "tok", "forge.name")
    out = capsys.readouterr().out
    assert "no SPF record found for forge.name" in out


def test_nudge_swallows_api_error_and_prints_nothing(capsys):
    """A transient failure checking existing records must never look like
    an error to the caller -- this is a UX nicety layered on top of a
    command that already succeeded."""
    client = MagicMock()
    client.dns_list_records.side_effect = ApiError(502, "zone not ready")
    _nudge_spf_dmarc(client, "tok", "forge.name")
    assert capsys.readouterr().out == ""
