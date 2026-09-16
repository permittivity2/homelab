package Homelab::Common::Registry;
use Mojo::Base -strict;
use Mojo::UserAgent;
use YAML::XS qw(LoadFile);
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

# Both registry HTTP routes require a system_agent-role JWT (see the
# incident writeup on the commit that added this): the POST is the live
# gateway-routing table homelab-api's own forwarding trusts, so it used
# to let anyone on the network silently hijack a feature's backend
# address. Every register()/lookup() caller already runs as the same
# 'homelab' OS user as homelab-agent, which is Recommends:-installed
# alongside it and already maintains a live, auto-refreshing
# system_agent credential right here — reusing that file avoids standing
# up a second, parallel credential system for every registering package.
# Deliberately NOT cached/held in memory across calls: this module is
# used by long-lived services whose local agent rotates the token on
# every heartbeat, so re-reading the file each call is the only way to
# always have a live token, and it's a local stat+read, not a network
# call, so the cost is negligible next to the HTTP round trip it feeds.
my $CREDENTIAL_FILE = '/etc/homelab/agent/credential.yml';

sub _system_agent_token {
    my (%opts) = @_;
    my $path = $opts{credential_file} // $CREDENTIAL_FILE;
    die "no homelab-agent credential found at $path -- install and enroll "
        . "homelab-agent on this host first (homelab-cli admin agent enroll "
        . "<hostname>, then 'dpkg-reconfigure homelab-agent')\n"
        unless -f $path;
    my $credential = LoadFile($path);
    die "credential file $path has no token\n" unless $credential->{token};
    return $credential->{token};
}

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

    my $token = _system_agent_token(credential_file => $opts{credential_file});
    my $tx = $UA->post("$api_base/api/v1/registry/register",
        { Authorization => "Bearer $token" },
        json => {
            feature_name     => $feature_name,
            host             => $host,
            port             => $port,
            health_check_url => $opts{health_check_url},
            description      => $opts{description},
        },
    );
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

    my $token = _system_agent_token(credential_file => $opts{credential_file});
    my $tx = $UA->get("$api_base/api/v1/registry/$feature_name", { Authorization => "Bearer $token" });
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
