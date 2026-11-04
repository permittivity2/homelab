package RepoRoutes;
use Mojo::Base -strict, -signatures;
use Mojo::File qw(path);
use Exporter 'import';

our @EXPORT_OK = qw(reachable_routes);

# Every route a person or a fleet service can reach through homelab-api, read
# from the repo's own source: the api's routes, plus each service's routes
# behind the api's forwarding prefixes. Used by t/reference.t to keep
# reference/ complete. Static on purpose: it needs no database, no running
# service and no other package on @INC, so it runs in CI as-is.
#
# Each route comes back as
#   { method, path (public, :name placeholders), service, backend (its path
#     in that service), who (from the handler's own access check, or undef
#     when none of the known checks is found), handler ("package::sub") }

# The services behind the api, and where their code is.
my %SERVICE_DIR = (
    'homelab-domain-admin' => 'domain-admin',
    'homelab-drive'        => 'drive',
    'homelab-search'       => 'search',
    'homelab-mailbridge'   => 'mailbridge',
    'homelab-worker'       => 'worker',
    'homelab-audit'        => 'audit',
    'homelab-invite'       => 'invite',
    'homelab-block-link'   => 'block-link',
);

# Who may call a handler, from the first access check its body makes. Each
# service names its checks differently; the first one found in the body
# decides. Anything with none of these is open to anyone.
my @API_CHECKS = (
    [ qr/_require_system_agent\b/                     => 'fleet' ],
    [ qr/_require_capability\(\s*\$c,\s*'([a-z_.]+)'/ => 'permission' ],
    [ qr/_require_site_admin\b/                       => 'site-admin' ],
    [ qr/_authenticate\b|_authenticated_user\b|_require_bearer\b|verify_jwt\(\s*\$jwt/ => 'signed-in' ],
);
my @SERVICE_CHECKS = (
    [ qr/authenticated_system_agent\b/                               => 'fleet' ],
    [ qr/authenticated_email_with_capability\(\s*'([a-z_.]+)'/       => 'permission' ],
    [ qr/authenticated_site_admin\b|_site_admin_email\b/             => 'site-admin' ],
    [ qr/authenticated_email_any\b|_current_auth\b|session_email\b|_current_email\b|_authenticated_email\b|_authenticated\(\s*\$c|_scope\(\s*\$c/
                                                                     => 'signed-in' ],
);
# authenticated_email means site admin in domain-admin, and signed in
# elsewhere (mailbridge, worker).
my %PLAIN_EMAIL_CHECK = ('domain-admin' => 'site-admin');

sub reachable_routes ($root) {
    $root = path($root);
    my $api_src = $root->child('api/lib/Homelab/API/App.pm')->slurp;
    my $api_subs = _subs($api_src, 'Homelab::API::App');

    my (@routes, @gateways);
    for my $r (_routes($api_src)) {
        if ($r->{body} =~ /_gateway\(\s*\$c,\s*'([^']+)'(.*?)\)\s*\}/s) {
            my ($service, $opts) = ($1, $2);
            my %o = $opts =~ /(strip_prefix|backend_prefix)\s*=>\s*'([^']*)'/g;
            (my $prefix = $r->{path}) =~ s{/\*capture\z}{};
            # A gateway forwards only its own method: $r->get(...) passes GETs
            # alone (the jobs gateway is read-only on purpose), $r->any(...)
            # passes them all.
            push @gateways, { prefix => $prefix, open => ($r->{path} =~ m{/\*capture\z} ? 1 : 0),
                              service => $service, method => $r->{method}, %o };
            next;
        }
        my ($method) = $r->{body} =~ /\$self->(_[a-z0-9_]+)\(\s*\$c/;
        my $body = $method ? ($api_subs->{$method} // '') : $r->{body};
        push @routes, {
            method => $r->{method}, path => $r->{path}, service => 'homelab-api', backend => $r->{path},
            handler => 'Homelab::API::App::' . ($method // '(inline)'),
            who => _who($body, \@API_CHECKS, 'api'),
        };
    }

    for my $service (sort keys %SERVICE_DIR) {
        my $dir = $root->child($SERVICE_DIR{$service}, 'lib');
        my ($app) = grep { $_->basename eq 'App.pm' && $_ !~ m{/blib/} } $dir->list_tree->each;
        next unless $app;
        my %subs;   # "Package::sub" => body, across the service's own modules
        for my $f (grep { /\.pm\z/ && !m{/blib/} } $dir->list_tree->each) {
            my $src = $f->slurp;
            for my $pkg (_packages($src)) {
                my $s = _subs($pkg->{text}, $pkg->{name});
                $subs{"$pkg->{name}::$_"} = $s->{$_} for keys %$s;
            }
        }
        (my $ns = (_packages($app->slurp))[0]{name}) =~ s/::App\z//;
        for my $r (_routes($app->slurp)) {
            my ($public, $gw) = _public_path($r->{path}, $r->{method}, $service, \@gateways);
            next unless $public;
            my ($handler, $body) = ('(inline)', $r->{body});
            if ($r->{body} =~ /->to\(\s*'([a-z_]+)#([a-z_0-9]+)'/) {
                my ($ctrl, $action) = ($1, $2);
                (my $camel = $ctrl) =~ s/(?:^|_)([a-z])/\U$1/g;
                $handler = "${ns}::App::Controller::${camel}::$action";
                $body = $subs{$handler} // '';
            }
            push @routes, {
                method => $r->{method}, path => $public, service => $service, backend => $r->{path},
                handler => $handler,
                who => _who($body, \@SERVICE_CHECKS, $SERVICE_DIR{$service}),
            };
        }
    }
    return \@routes;
}

# Where a service route is reachable from outside, through which gateway, or
# nothing when no gateway leads to it (none for that service, or none that
# forwards that method).
sub _public_path ($backend, $method, $service, $gateways) {
    for my $g (grep { $_->{service} eq $service && ($_->{method} eq 'ANY' || $_->{method} eq $method) } @$gateways) {
        my ($strip, $bp) = ($g->{strip_prefix} // '', $g->{backend_prefix} // '');
        next unless index($backend, $bp) == 0;
        my $public = $strip . substr($backend, length $bp);
        my $ok = $g->{open}
            ? ($public eq $g->{prefix} || index($public, "$g->{prefix}/") == 0)
            : $public eq $g->{prefix};
        return ($public, $g) if $ok;
    }
    return;
}

sub _who ($body, $checks, $service) {
    my ($first, $who, $arg);
    for my $c (@$checks) {
        my ($re, $label) = @$c;
        next unless $body =~ $re;
        my $at = $-[0];
        if (!defined $first || $at < $first) { ($first, $who, $arg) = ($at, $label, $1) }
    }
    if ($body =~ /\bauthenticated_email\b(?!_)/ && (!defined $first || $-[0] < $first)) {
        $who = $PLAIN_EMAIL_CHECK{$service} // 'signed-in';
        $arg = undef;
    }
    return 'anyone' unless defined $who;
    return $who eq 'permission' ? "permission:$arg" : $who;
}

# Route definitions: { method, path, body } where body is the rest of the
# statement (its handler, sub or ->to(...)).
sub _routes ($src) {
    my @out;
    # A statement ends at a semicolon at the end of a line, or before a
    # trailing comment there.
    while ($src =~ /\$r->(get|post|put|patch|delete|any)\(\s*'([^']+)'(.*?);[ \t]*(?:#[^\n]*)?$/gms) {
        push @out, { method => uc $1, path => $2, body => $3 };
    }
    return @out;
}

sub _packages ($src) {
    my @p;
    while ($src =~ /^package\s+([\w:]+)\s*;/gm) { push @p, { name => $1, at => $-[0] } }
    for my $i (0 .. $#p) {
        my $end = $i < $#p ? $p[$i + 1]{at} : length $src;
        $p[$i]{text} = substr($src, $p[$i]{at}, $end - $p[$i]{at});
    }
    return @p;
}

# sub name => body text, up to the next top-level sub.
sub _subs ($src, $pkg) {
    my %s;
    my @at;
    while ($src =~ /^sub\s+(\w+)\b/gm) { push @at, [ $1, $-[0] ] }
    for my $i (0 .. $#at) {
        my $end = $i < $#at ? $at[$i + 1][1] : length $src;
        $s{ $at[$i][0] } = substr($src, $at[$i][1], $end - $at[$i][1]);
    }
    return \%s;
}

1;
