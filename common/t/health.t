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

done_testing;
