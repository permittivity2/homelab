use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojolicious;

use lib 'lib';
use Homelab::Common::Health qw(mount_health_route);

# Default check (always ok) — separate Mojolicious instances per case so
# each app only ever has the one /health route it's meant to test.
my $ok_app = Mojolicious->new;
mount_health_route($ok_app);
Test::Mojo->new($ok_app)->get_ok('/health')->status_is(200)->content_is('ok');

# A failing check reports unhealthy/503, not a silent 200.
my $bad_app = Mojolicious->new;
mount_health_route($bad_app, check => sub { die "db unreachable\n" });
Test::Mojo->new($bad_app)->get_ok('/health')->status_is(503)->content_is('unhealthy');

# A check that returns false (not just dies) is treated the same way.
my $false_app = Mojolicious->new;
mount_health_route($false_app, check => sub { 0 });
Test::Mojo->new($false_app)->get_ok('/health')->status_is(503)->content_is('unhealthy');

# --- the request log -----------------------------------------------------------
# One line per request that came from outside (X-Forwarded-For present),
# naming the real visitor; nothing for internal calls or health checks.
# Must work on a host with no metrics textfile directory (mount_metrics_route
# returns early there) -- so point it at one that does not exist.
{
    local $ENV{MOJO_REVERSE_PROXY} = 1;
    my $app = Mojolicious->new;
    $app->log->level('info');
    my @lines;
    $app->log->unsubscribe('message')->on(message => sub { my ($l, $level, @m) = @_; push @lines, "$level: @m" });
    $app->routes->get('/thing' => sub { $_[0]->render(text => 'x') });
    mount_health_route($app, textfile_dir => '/nonexistent/textfile/dir');
    my $t = Test::Mojo->new($app);

    $t->get_ok('/thing' => { 'X-Forwarded-For' => '198.51.100.7' })->status_is(200);
    my @req = grep { /request / } @lines;
    is scalar @req, 1, 'a request from outside is logged once';
    like $req[0], qr{^info: request 198\.51\.100\.7 GET /thing 200 \d+ms$}, 'with the real visitor address, method, path, status, time';

    @lines = ();
    $t->get_ok('/thing')->status_is(200);
    ok !(grep { /request / } @lines), 'an internal call (no X-Forwarded-For) is not logged';

    @lines = ();
    $t->get_ok('/health' => { 'X-Forwarded-For' => '198.51.100.7' })->status_is(200);
    ok !(grep { /request / } @lines), 'health checks are not logged';

    @lines = ();
    $t->get_ok('/nope?secret=1' => { 'X-Forwarded-For' => '198.51.100.8' })->status_is(404);
    my ($nf) = grep { /request / } @lines;
    like $nf, qr{request 198\.51\.100\.8 GET /nope 404}, 'misses are logged too, without the query string';
}

done_testing;
