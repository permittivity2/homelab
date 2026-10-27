package Homelab::CertSync::Util;
use v5.36;

# Shared helpers for homelab-certsync: config, auth, HTTP to homelab-api,
# logging. Intentionally a near-copy of the cert server's equivalent -- the
# producer and the consumer are separate packages so they can be installed and
# versioned independently (the consumer runs on 9 hosts that must NOT have an
# issuer), and a shared module would couple them for ~60 lines of HTTP glue.

use Exporter 'import';
our @EXPORT_OK = qw(load_config api_token api_request log_msg CONFIG_FILE);

use YAML::XS qw(LoadFile);
use Mojo::UserAgent;
use Mojo::JSON qw(encode_json);
use Homelab::Common::Registry ();

use constant CONFIG_FILE => $ENV{HOMELAB_CERTSYNC_CONFIG}
    // '/etc/homelab/certsync/certsync.yml';

my $UA = Mojo::UserAgent->new(connect_timeout => 5, request_timeout => 30);

sub log_msg (@msg) {
    my $m = join(' ', @msg);
    print STDERR "[certsync] $m\n";
    # also to the journal when run from a unit/hook, where STDERR may be lost
    system('logger', '-t', 'homelab-certsync', $m) == 0 or 1;
    return;
}

sub load_config {
    my $path = CONFIG_FILE;
    die "certsync: no config at $path\n" unless -f $path;
    my $cfg = eval { LoadFile($path) } or die "certsync: cannot parse $path: $@\n";
    die "certsync: $path is not a YAML mapping\n" unless ref $cfg eq 'HASH';
    die "certsync: api_base is required in $path\n"
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

1;
