package Homelab::Common::Health;
use Mojo::Base -strict;
use Exporter 'import';

our @EXPORT_OK = qw(mount_health_route);

# Mounts a standard GET /health route on a Mojolicious app — the
# one-line-but-copy-pasted-everywhere endpoint every feature used to
# hand-write separately. $check is an optional coderef for a deeper
# check (e.g. "can I reach the database"); returns plain-text 'ok'/200
# or 'unhealthy'/503, matching the existing convention every package
# already used informally.
sub mount_health_route {
    my ($app, %opts) = @_;
    my $check = $opts{check} // sub { 1 };

    $app->routes->get('/health' => sub {
        my $c  = shift;
        my $ok = eval { $check->() };
        return $c->render(text => 'ok') if $ok;
        return $c->render(text => 'unhealthy', status => 503);
    });
}

1;
