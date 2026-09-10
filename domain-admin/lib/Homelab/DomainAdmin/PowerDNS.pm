package Homelab::DomainAdmin::PowerDNS;
use Mojo::Base -base, -signatures;
use Mojo::UserAgent;
use Mojo::URL;

# Thin client for PowerDNS Authoritative Server's own built-in REST API
# v1 -- see ../../../README.md's "Talking to PowerDNS" section for why
# this is used instead of a direct grant on PowerDNS's separate
# `powerdns` database or shelling out to pdnsutil. All names normalized
# to a trailing dot (PowerDNS's own on-the-wire convention) so callers
# never have to remember to do it themselves.

has 'base_url';   # e.g. http://127.0.0.1:8081
has 'api_key';
has ua => sub { Mojo::UserAgent->new(connect_timeout => 5, request_timeout => 15) };

sub _fqdn ($name) {
    return $name =~ /\.$/ ? $name : "$name.";
}

sub _url ($self, $path) {
    return Mojo::URL->new($self->base_url)->path("/api/v1/servers/localhost$path");
}

sub _tx ($self, $method, $path, %opts) {
    my $headers = { 'X-API-Key' => $self->api_key };
    my $tx = exists $opts{json}
        ? $self->ua->build_tx($method, $self->_url($path), $headers, json => $opts{json})
        : $self->ua->build_tx($method, $self->_url($path), $headers);
    return $self->ua->start($tx);
}

# Returns the zone's full representation (rrsets included), or undef if
# it doesn't exist (404) -- distinct from dying, which is reserved for
# an actually-unreachable/erroring PowerDNS.
sub get_zone ($self, $zone) {
    my $tx = $self->_tx(GET => '/zones/' . _fqdn($zone));
    my $code = $tx->res->code;
    return undef if $code && $code == 404;
    unless ($code && $code == 200) {
        die sprintf("PowerDNS API GET /zones/%s failed: %s\n", $zone, $code // ($tx->error->{message} // 'no response'));
    }
    return $tx->res->json;
}

sub zone_exists ($self, $zone) {
    return defined $self->get_zone($zone);
}

# Does a given (name, type) rrset already exist in the zone? Used to
# decide whether a write needs the pdns-restart debounce (a genuinely
# NEW name) or not (a value update on an already-served name, which
# PowerDNS's gpgsql backend picks up live) -- see README.md.
sub rrset_exists ($self, $zone, $name, $type) {
    my $z = $self->get_zone($zone) or return 0;
    my $fqdn = _fqdn($name);
    for my $rr (@{ $z->{rrsets} // [] }) {
        return 1 if $rr->{name} eq $fqdn && $rr->{type} eq $type;
    }
    return 0;
}

sub create_zone ($self, $name, %opts) {
    my $nameservers = $opts{nameservers} // ['ns-test.mailmasker.org.'];
    $nameservers = [ map { _fqdn($_) } @$nameservers ];
    my $tx = $self->_tx(POST => '/zones', json => {
        name        => _fqdn($name),
        kind        => $opts{kind} // 'Native',
        nameservers => $nameservers,
    });
    my $code = $tx->res->code;
    unless ($code && $code == 201) {
        die sprintf("PowerDNS API POST /zones failed for %s: %s %s\n",
            $name, $code // 'no response', $tx->res->body // ($tx->error->{message} // ''));
    }
    return $tx->res->json;
}

# TXT (and SPF, its now-deprecated twin) record content is DNS
# master-file *text* syntax, not a bare string -- PowerDNS's API
# rejects an unquoted value outright (a real bug caught by an actual
# `homelab-cli dns records add ... --type TXT` call, not by inspection:
# "Data field in DNS should start with quote"). Wrap in double quotes,
# backslash-escaping any literal backslash or double-quote already in
# the value first so the wire content round-trips exactly -- the same
# escaping RFC 1035 master-file syntax itself requires. A caller that
# already passed a pre-quoted value (starts and ends with an unescaped
# ") is left alone rather than double-wrapped.
sub _format_record_content ($type, $content) {
    return $content unless $type eq 'TXT' || $type eq 'SPF';
    return $content if $content =~ /^"(?:[^"\\]|\\.)*"$/;
    (my $escaped = $content) =~ s/([\\"])/\\$1/g;
    return qq{"$escaped"};
}

# changetype REPLACE -- creates the rrset if absent, replaces its full
# record set if present (PowerDNS has no separate "add one more record
# to an existing rrset" primitive; the caller must send the complete
# desired set).
sub upsert_rrset ($self, $zone, $name, $type, $ttl, $records) {
    my $tx = $self->_tx(PATCH => '/zones/' . _fqdn($zone), json => {
        rrsets => [{
            name       => _fqdn($name),
            type       => $type,
            ttl        => $ttl,
            changetype => 'REPLACE',
            records    => [ map { { content => _format_record_content($type, $_), disabled => \0 } } @$records ],
        }],
    });
    my $code = $tx->res->code;
    unless ($code && $code == 204) {
        die sprintf("PowerDNS API PATCH /zones/%s failed (rrset %s %s): %s %s\n",
            $zone, $name, $type, $code // 'no response', $tx->res->body // ($tx->error->{message} // ''));
    }
    return 1;
}

sub delete_rrset ($self, $zone, $name, $type) {
    my $tx = $self->_tx(PATCH => '/zones/' . _fqdn($zone), json => {
        rrsets => [{ name => _fqdn($name), type => $type, changetype => 'DELETE' }],
    });
    my $code = $tx->res->code;
    unless ($code && $code == 204) {
        die sprintf("PowerDNS API PATCH /zones/%s failed (delete %s %s): %s %s\n",
            $zone, $name, $type, $code // 'no response', $tx->res->body // ($tx->error->{message} // ''));
    }
    return 1;
}

1;
