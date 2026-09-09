package Homelab::Common::AuthClient;
use Mojo::Base -strict;
use Mojo::UserAgent;
use Exporter 'import';

our @EXPORT_OK = qw(introspect);

# Verifies a bearer JWT against homelab-api's /api/v1/auth/introspect —
# the one place identity actually lives (see CLAUDE.md). Every feature
# that needs "who is this request from" calls this rather than
# verifying JWTs itself, so there's exactly one place that knows how to
# do that, same reasoning as the registry client.
#
# introspect($jwt, api_base => 'http://10.10.0.x:3000') => { email => ..., exp => ... } or undef
my $UA = Mojo::UserAgent->new(connect_timeout => 5, request_timeout => 10);

sub introspect {
    my ($jwt, %opts) = @_;
    my $api_base = $opts{api_base} // die "introspect(): api_base required\n";
    return undef unless $jwt;

    my $tx  = $UA->get("$api_base/api/v1/auth/introspect", { Authorization => "Bearer $jwt" });
    my $err = $tx->error;
    return undef if $err && !$err->{code};    # transport failure — treat as "not authenticated", don't die
    return undef unless $tx->result->code == 200;
    return $tx->result->json;
}

1;
