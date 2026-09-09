package Homelab::Common::AuthClient;
use Mojo::Base -strict;
use Mojo::UserAgent;
use Exporter 'import';

our @EXPORT_OK = qw(introspect login);

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

# Logs in against homelab-api's /api/v1/auth/login on behalf of a
# browser-facing BFF-style app (homelab-drive, later homelab-roundcube)
# that wants to hold the resulting token/refresh_token in its own
# session cookie rather than making the browser talk to homelab-api
# directly. Returns the decoded JSON body (success/token/refresh_token/...
# on success, error/_status on failure) — callers check `success`
# themselves rather than this module deciding what counts as an error,
# since e.g. a 409 on registration and a 401 on login mean different
# things to different callers.
sub login {
    my ($email, $password, %opts) = @_;
    my $api_base = $opts{api_base} // die "login(): api_base required\n";

    my $tx  = $UA->post("$api_base/api/v1/auth/login", json => { email => $email, password => $password });
    my $err = $tx->error;
    return { success => 0, error => $err->{message} // 'connection error', _status => 0 }
        if $err && !$err->{code};

    my $res  = $tx->result;
    my $body = eval { $res->json } // {};
    $body->{_status} = $res->code;
    $body->{success} = ($res->code == 200) ? 1 : 0;
    return $body;
}

1;
