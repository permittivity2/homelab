package Homelab::PostfixBlockLink::Milter;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(
    resolve_recipient effective_setting is_signed_mime
    generate_token build_header_value insert_pending_link
);

# Replicates Postfix's OWN exact-then-catch-all virtual_alias_maps
# lookup (postfix/config/pgsql-virtual-alias-maps.cf.template's query,
# reused verbatim) -- Postfix does this fallback automatically inside
# its own map-lookup code when IT queries mail_aliases directly for
# routing, but this milter is a separate program and gets no such
# behavior for free; it has to replicate the same two-step lookup
# itself to resolve an envelope address to the same destination
# account Postfix will actually deliver to. Single-hop only (an alias
# resolving to another alias is not re-resolved), matching Postfix's
# own virtual_alias_maps behavior, not a shortcut taken here.
#
# Returns the destination account email, or undef if this address
# isn't a valid, active local mailbox at all (should be rare in
# practice -- Postfix's own recipient restrictions normally reject an
# invalid RCPT TO before this milter ever sees it -- but never assumed).
sub resolve_recipient {
    my ($db, $address) = @_;
    my $lc = lc($address);

    my $alias = $db->query(
        q{SELECT destination FROM domainadmin.mail_aliases WHERE source_pattern = ? AND active = true},
        $lc,
    )->hash;
    unless ($alias) {
        my ($domain) = $lc =~ /\@(.+)$/;
        $alias = $db->query(
            q{SELECT destination FROM domainadmin.mail_aliases WHERE source_pattern = ? AND active = true},
            '@' . ($domain // ''),
        )->hash if defined $domain;
    }
    my $account = $alias ? $alias->{destination} : $lc;

    my $user = $db->query('SELECT email FROM api.users WHERE email = ? AND active = true', $account)->hash;
    return $user ? $user->{email} : undef;
}

# Account override wins if set; else the account's own home domain's
# default; else off/header (a domain that's never touched this feature
# has no row at all, matching domain_settings' own DEFAULT FALSE).
# Same precedence logic as homelab-block-link's own
# Controller::BlockLink::_effective_setting -- kept in sync by hand
# (two different packages/languages can't share one Perl sub here),
# not by accident.
sub effective_setting {
    my ($db, $account_email) = @_;
    my ($domain) = $account_email =~ /\@(.+)$/;

    my $account = $db->query(
        'SELECT enabled FROM block_link.account_settings WHERE user_email = ?', $account_email,
    )->hash;
    my $domain_row = $db->query(
        'SELECT enabled, mode FROM block_link.domain_settings WHERE domain_name = ?', $domain // '',
    )->hash // { enabled => 0, mode => 'header' };

    my $enabled = (defined $account && defined $account->{enabled}) ? $account->{enabled} : $domain_row->{enabled};
    return { enabled => ($enabled ? 1 : 0), mode => $domain_row->{mode} };
}

# PGP/S-MIME-signed inbound mail silently falls back to header-only
# regardless of the domain's configured mode -- appending plaintext to
# a cryptographically signed body either corrupts it or sits
# untrustworthy outside the signed envelope either way; the header is
# unaffected by the signature and stays useful. Checked against the
# raw Content-Type header VALUE (not just the content-type, since the
# boundary/protocol params on multipart/signed are what actually
# identify it, but the type/subtype alone is enough to decide "don't
# touch the body").
sub is_signed_mime {
    my ($content_type) = @_;
    return 0 unless defined $content_type;
    my $lc = lc($content_type);
    return 1 if $lc =~ m{^\s*multipart/signed};
    return 1 if $lc =~ m{^\s*application/(x-)?pkcs7-mime};
    return 1 if $lc =~ m{^\s*application/pkcs7-signature};
    return 0;
}

# 32 random bytes, hex-encoded -- same /dev/urandom-backed idiom as
# every other token in this ecosystem (homelab-api's own
# Auth::generate_jti, homelab-invite's own _generate_token).
sub generate_token {
    open(my $fh, '<', '/dev/urandom') or die "cannot open /dev/urandom: $!";
    read($fh, my $bytes, 32) == 32 or die 'short read from /dev/urandom';
    close($fh);
    return unpack('H*', $bytes);
}

sub build_header_value {
    my ($public_base_url, $token) = @_;
    return "<$public_base_url/l/$token>";
}

sub insert_pending_link {
    my ($db, %opts) = @_;
    return $db->query(
        q{INSERT INTO block_link.pending_links (token, candidates, message_id, expires_at)
          VALUES (?, ?, ?, NOW() + (? || ' days')::INTERVAL)},
        $opts{token}, $opts{candidates_json}, $opts{message_id}, $opts{ttl_days},
    );
}

1;
