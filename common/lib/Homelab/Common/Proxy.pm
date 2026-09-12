package Homelab::Common::Proxy;
use Mojo::Base -strict;
use Mojo::UserAgent;
use Mojo::URL;
use Mojo::Transaction::HTTP;
use Exporter 'import';
use Homelab::Common::Registry qw(lookup);

our @EXPORT_OK = qw(forward);

# Separate from Registry.pm's own $UA (different timeouts -- forwarded
# requests may be doing real work on the other end, e.g. a drive
# upload, not just a quick registry read/write).
my $UA = Mojo::UserAgent->new(connect_timeout => 5, request_timeout => 30);

=head1 NAME

Homelab::Common::Proxy - forward a client request to another feature,
resolved via the service registry

=head1 SYNOPSIS

  use Homelab::Common::Proxy qw(forward);

  $r->any('/api/v1/drive/*path' => sub ($c) {
      forward($c, feature_name => 'homelab-drive', api_base => $api_base,
               strip_prefix => '/api/v1/drive', backend_prefix => '/api/v1');
  });

=head1 DESCRIPTION

What makes homelab-api usable as a single client-facing entry point
(see the root CLAUDE.md's "one API" design notes): a client's request
to C</api/v1/drive/...> or C</api/v1/mail/...> arrives here, and this
module looks up the real feature's *internal* address in the registry
(C<Homelab::Common::Registry::lookup>), forwards the request there
unchanged (method, remaining path, query string, Authorization header,
body), and relays the response straight back. The client never learns
that address, and never needs to -- from its perspective, everything
lives at C<api_base>.

Auth is NOT re-checked here -- the C<Authorization> header forwards
through as-is, and every backend this is used with (homelab-drive,
homelab-mailbridge) already re-verifies it independently via its own
C<introspect()> call, matching this codebase's "verify at every hop"
convention throughout. This module's only job is routing, never
authorization.

Renders a clean JSON error itself (502/504), never a raw Mojolicious
exception page, when the registry lookup fails or the backend is
unreachable -- from a client's perspective that's a routing problem it
can't do anything about, not an application error.

=cut

# forward($c, feature_name => ..., api_base => ..., strip_prefix => '')
#   -- looks up feature_name via an HTTP registry call (the normal case:
#      the caller, e.g. homelab-drive or homelab-mailbridge, has no
#      direct DB access to the registry, only homelab-api does).
# forward($c, feature_name => ..., host => ..., port => ..., strip_prefix => '')
#   -- skips the lookup and forwards straight to the given address.
#      For homelab-api's OWN gateway routes specifically: it already
#      has direct in-process DB access to the registry (see
#      Homelab::API::Registry) and would otherwise be making an HTTP
#      round trip to itself just to re-read its own database.
#
# strip_prefix / backend_prefix: strip_prefix is removed from the start
# of the incoming request path, then backend_prefix (if any) is
# prepended to what's left -- e.g. a client request to
# /api/v1/drive/files, with strip_prefix => '/api/v1/drive' and
# backend_prefix => '/api/v1', forwards to /api/v1/files on the
# resolved feature's own address (homelab-drive's real API keeps its
# own /api/v1/... shape; /drive/ exists only in the gateway's
# client-facing namespace, sitting where /api/v1 already was -- so the
# fix isn't a plain prefix strip, it's strip-then-reprepend). Pass
# neither (or '' / omit) when the backend's own paths already match
# the client-facing path exactly (e.g. homelab-mailbridge's routes are
# already /api/v1/mail/... themselves, deliberately, so nothing needs
# rewriting for that case -- a real bug this docblock itself got wrong
# the first time, caught by an actual `homelab-cli drive list` call,
# not by common/t/proxy.t's fake backend, which happened to use paths
# too simple to expose the missing re-prepend step).
sub forward {
    my ($c, %opts) = @_;
    my $feature_name   = $opts{feature_name}   // die "forward(): feature_name required\n";
    my $strip_prefix    = $opts{strip_prefix}    // '';
    my $backend_prefix  = $opts{backend_prefix}  // '';

    my $entry;
    if ($opts{host} && $opts{port}) {
        $entry = { host => $opts{host}, port => $opts{port} };
    }
    else {
        my $api_base = $opts{api_base} // die "forward(): api_base required (unless host+port are given directly)\n";
        $entry = eval { lookup($feature_name, api_base => $api_base) };
    }
    unless ($entry && $entry->{host} && $entry->{port}) {
        $c->render(json => { error => "$feature_name is not currently available" }, status => 502);
        return;
    }

    my $path = $c->req->url->path->to_string;
    $path =~ s/^\Q$strip_prefix\E// if $strip_prefix;
    $path = "$backend_prefix$path" if $backend_prefix;
    $path = "/$path" unless $path =~ m{^/};

    my $target = Mojo::URL->new->scheme('http')->host($entry->{host})->port($entry->{port})
        ->path($path)->query($c->req->url->query);

    # Reusing $c->req->content directly (not $c->req->body) is what makes
    # this work for multipart/form-data uploads (homelab-cli drive
    # upload, forwarded here) -- a real bug caught by an actual upload,
    # not by common/t/proxy.t's earlier, JSON-only test cases.
    # Mojo::Message::body's own GETTER returns '' unconditionally
    # whenever the content is multipart (see its own source: "return
    # $content->is_multipart ? '' : ..."), so building the outgoing
    # request from a body string silently sent an EMPTY body for any
    # upload. Mojo::Message::headers is just `content->headers`
    # (delegation, not a copy), so reusing the same content object also
    # carries every header the original request had -- Authorization,
    # Content-Type with its multipart boundary, Content-Length -- with
    # no separate header-copying code needed at all.
    my $tx = Mojo::Transaction::HTTP->new;
    $tx->req->method($c->req->method);
    $tx->req->url($target);
    $tx->req->content($c->req->content);
    # Explicitly set, not relied on via header reuse from $c->req->content
    # above: $c->tx->remote_address is only correctly resolved to the
    # real originating client in the first place because homelab-api's
    # own systemd unit sets MOJO_REVERSE_PROXY=1 (trusting homelab-
    # webproxy's X-Forwarded-For on THAT hop) -- but this forward() call
    # is itself a SECOND proxy hop, gateway -> backend service, and
    # nothing was setting these headers for it. Every backend this is
    # used with now sets MOJO_REVERSE_PROXY=1 too (see each one's own
    # systemd unit), so this is what makes ITS OWN $c->tx->remote_address
    # resolve correctly in turn -- audit-log entries for gateway-mediated
    # actions (drive deletes, mail sends, domain/DKIM changes) were
    # recording homelab-api's own loopback address before this fix.
    $tx->req->headers->header('X-Forwarded-For' => $c->tx->remote_address);
    $tx->req->headers->header('X-Real-IP'       => $c->tx->remote_address);
    $tx = $UA->start($tx);

    unless ($tx->res->code) {
        my $err = $tx->error;
        $c->render(
            json   => { error => "$feature_name is not reachable: " . ($err->{message} // 'unknown error') },
            status => 504,
        );
        return;
    }

    $c->res->headers->content_type($tx->res->headers->content_type) if $tx->res->headers->content_type;
    $c->render(data => $tx->res->body, status => $tx->res->code);
    return;
}

1;
