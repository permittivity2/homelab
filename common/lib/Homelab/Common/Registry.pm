package Homelab::Common::Registry;
use Mojo::Base -strict;
use Mojo::UserAgent;
use Exporter 'import';

our @EXPORT_OK = qw(register lookup);

# The registry table itself lives inside homelab-api's own schema —
# every other feature reaches it over HTTP (these two endpoints), never
# via a direct cross-schema DB grant. This keeps the same schema
# isolation every feature's own data already has. homelab-api's own
# address is never looked up this way — every feature gets it from its
# own local bootstrap config (api_base below), same as DB credentials.
my $UA = Mojo::UserAgent->new(connect_timeout => 5, request_timeout => 10);
my %CACHE;              # feature_name => { data => {...}, expires => $epoch }
my $CACHE_TTL = 60;     # seconds

# Registers this feature's own address. Call once at startup, and again
# on a periodic keep-alive (e.g. a recurring Mojo::IOLoop timer) so a
# restarted homelab-api's registry gets repopulated without requiring
# every other feature to also restart.
#
# %opts: api_base, feature_name, host, port, health_check_url
sub register {
    my (%opts) = @_;
    # Validated as separate statements, not inline inside the hashref
    # literal below — `key => $x // die "...", key2 => ...` is a real
    # Perl trap: die() is a list operator with no parens here, so its
    # argument list silently swallows every subsequent key/value pair
    # (even though it never actually runs), leaving the hash missing
    # everything after the first `// die`. Caught by t/registry.t.
    my $api_base     = $opts{api_base}     // die "register(): api_base required\n";
    my $feature_name = $opts{feature_name} // die "register(): feature_name required\n";
    my $host         = $opts{host}         // die "register(): host required\n";
    my $port         = $opts{port}         // die "register(): port required\n";

    my $tx = $UA->post("$api_base/api/v1/registry/register", json => {
        feature_name     => $feature_name,
        host             => $host,
        port             => $port,
        health_check_url => $opts{health_check_url},
    });
    die 'Registry registration failed: ' . _tx_error($tx) . "\n" if $tx->error;
    return 1;
}

# Looks up another feature's address, cached for $CACHE_TTL seconds so
# a hot code path isn't hitting homelab-api on every single call.
#
# lookup('homelab-sso', api_base => $api_base) => { host, port, health_check_url }
sub lookup {
    my ($feature_name, %opts) = @_;
    my $api_base = $opts{api_base} // die "lookup(): api_base required\n";

    if (my $cached = $CACHE{$feature_name}) {
        return $cached->{data} if $cached->{expires} > time;
    }

    my $tx = $UA->get("$api_base/api/v1/registry/$feature_name");
    die "Registry lookup for '$feature_name' failed: " . _tx_error($tx) . "\n" if $tx->error;

    my $data = $tx->result->json;
    $CACHE{$feature_name} = { data => $data, expires => time + $CACHE_TTL };
    return $data;
}

sub _tx_error {
    my $tx  = shift;
    my $err = $tx->error;
    return $err->{message} // 'unknown error';
}

1;
