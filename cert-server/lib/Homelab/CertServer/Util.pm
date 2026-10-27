package Homelab::CertServer::Util;
use v5.36;

# Shared helpers for the cert server's scripts: config, auth, HTTP to
# homelab-api, zone resolution, logging.

use Exporter 'import';
our @EXPORT_OK = qw(load_config api_token api_request zone_for log_msg
                    CONFIG_FILE);

use YAML::XS qw(LoadFile);
use Mojo::UserAgent;
use Mojo::JSON qw(encode_json);
use Homelab::Common::Registry ();

use constant CONFIG_FILE => $ENV{HOMELAB_CERT_SERVER_CONFIG}
    // '/etc/homelab/cert-server/cert-server.yml';

my $UA = Mojo::UserAgent->new(connect_timeout => 5, request_timeout => 30);

sub log_msg (@msg) {
    my $m = join(' ', @msg);
    print STDERR "[cert-server] $m\n";
    # also to the journal when run from a unit/hook, where STDERR may be lost
    system('logger', '-t', 'homelab-cert-server', $m) == 0 or 1;
    return;
}

sub load_config {
    my $path = CONFIG_FILE;
    die "cert-server: no config at $path\n" unless -f $path;
    my $cfg = eval { LoadFile($path) } or die "cert-server: cannot parse $path: $@\n";
    die "cert-server: $path is not a YAML mapping\n" unless ref $cfg eq 'HASH';
    die "cert-server: api_base is required in $path\n"
        unless $cfg->{api_base} && $cfg->{api_base} =~ m{^https?://};
    return $cfg;
}

# The system_agent token from the local homelab-agent credential. Re-read on
# every call, never cached: the agent rotates it on each 60s heartbeat, so a
# cached copy goes stale and 401s. (Same rule as Homelab::Common::Registry.)
sub api_token {
    return Homelab::Common::Registry::system_agent_token();
}

sub api_request ($cfg, $token, $method, $path, $body = undef) {
    my $url = $cfg->{api_base} . $path;
    my %headers = (Authorization => "Bearer $token");
    my $tx;
    if (defined $body) {
        $headers{'Content-Type'} = 'application/json';
        $tx = $UA->start($UA->build_tx($method => $url => \%headers => encode_json($body)));
    } else {
        $tx = $UA->start($UA->build_tx($method => $url => \%headers));
    }
    my $res = $tx->result;
    my $json = eval { $res->json };
    if ($res->is_error) {
        my $msg = (ref $json eq 'HASH' && $json->{error}) ? $json->{error} : $res->message;
        return { error => sprintf('%s %s -> %s (%s)', $method, $path, $res->code, $msg // 'no detail') };
    }
    return $json // { ok => 1 };
}

# Find which managed zone a name belongs to: LONGEST-SUFFIX match against the
# `zones:` list in the config. mail.mailmasker.org -> mailmasker.org.
#
# This is config-driven rather than discovered from the API on purpose. The
# obvious alternative -- walk the name's suffixes and ask
# /api/v1/domains/<candidate>/dns/records which one exists -- CANNOT work from
# here: that route is site_admin-gated and checks auth BEFORE it checks whether
# the domain exists, so an agent token gets 403 for every candidate, including
# nonsense ones. There is no "is this a managed zone" probe a system_agent may
# call that does not also write something. Listing the zones locally is honest
# and costs one config line per zone.
#
# Longest-suffix (not first-match) so a hypothetical sub-zone would win over
# its parent.
sub zone_for ($cfg, $token, $name) {
    my @zones = @{ $cfg->{zones} // [] };
    unless (@zones) {
        log_msg("ERROR no 'zones:' configured in " . CONFIG_FILE . " -- cannot map '$name' to a zone");
        return undef;
    }
    my $best;
    for my $z (@zones) {
        next unless $name eq $z || $name =~ /\.\Q$z\E\z/;
        $best = $z if !defined $best || length($z) > length($best);
    }
    return $best;
}

1;
