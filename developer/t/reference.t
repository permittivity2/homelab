use Mojo::Base -strict, -signatures;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use Mojo::File qw(path);
use Mojo::JSON qw(decode_json);
use RepoRoutes qw(reachable_routes);
use Homelab::Developer::Reference qw(load_reference problems public_areas entry examples_for who_text);

# The API reference (reference/*.yml, published as developer.mailmasker.org)
# against the code. This is what keeps it current: a route with no entry, an
# entry with no route, or an entry that says the wrong people may use it,
# fails here, and so does the package build. See reference/README.md.
#
# REFERENCE_FILES=a.yml,b.yml checks just those files (their entries, and
# that each matches a real route), for drafting one area at a time.

my $root = path($FindBin::Bin)->dirname->dirname;   # the repo
my $dir  = path($FindBin::Bin)->dirname->child('reference');

my $ref = eval { load_reference("$dir") };
ok($ref, 'reference/ loads, with no problems') or diag $@;
$ref //= _load_anyway("$dir");

my %only = map { $_ => 1 } split /,/, $ENV{REFERENCE_FILES} // '';
my @entries = map { my $a = $_; map { { %$_, file => $a->{file} } } @{ $a->{abilities} } }
              grep { !%only || $only{ $_->{file} } } @{ $ref->{areas} };
ok(@entries, scalar(@entries) . ' entries');

# --- every entry is a real route, and says who may really use it ------------
my $routes = reachable_routes("$root");
my %route = map { ("$_->{method} $_->{path}" => $_) } @$routes;
ok(scalar(@$routes) > 100, scalar(@$routes) . ' routes read from the code');

# Where the code's own check cannot say who may call a route, what the entry
# must say instead, and why. Keep this short: every line is checked by hand.
my %BY_HAND = (
    'POST /api/v1/auth/register'      => [ anyone => 'the fleet-caller check in it is optional; anyone may register' ],
    'GET /api/v1/auth/introspect'     => [ 'signed-in' => 'it checks the token you send' ],
    'POST /api/v1/auth/refresh'       => [ anyone => 'it takes a refresh token in the body, not a sign-in' ],
    'POST /api/v1/auth/logout'        => [ anyone => 'it takes a refresh token in the body, not a sign-in' ],
    'POST /api/v1/agent/enroll/redeem' => [ fleet => 'a node redeems its one-time enrolment token; no person calls it' ],
    'GET /api/v1/mail/recipient-exists' => [ 'permission:domains.catchall' => 'fleet services may ask too (Drive, before it emails a share); a person needs the permission' ],
);

my %seen;
for my $e (@entries) {
    my $key = "$e->{method} $e->{path}";
    my $r = $route{$key};
    ok($r, "$e->{file}: $e->{id}: $key is a real route") or next;
    $seen{$key}++;
    my ($want, $why) = @{ $BY_HAND{$key} // [ $r->{who} ] };
    is($e->{who}, $want, "$e->{file}: $e->{id}: who may use it matches the code ($r->{handler})"
        . ($why ? " -- by hand: $why" : ''));
}
is((grep { $seen{$_} > 1 } keys %seen), 0, 'no route has two entries');
unless (%only) {
    my @missing = grep { !$seen{$_} } sort keys %route;
    is(scalar(@missing), 0, 'every route reachable through the api has an entry')
        or diag "no entry yet for:\n" . join('', map { "  $_ ($route{$_}{service}, $route{$_}{who})\n" } @missing);
    is((grep { !$route{$_} } keys %BY_HAND), 0, 'every by-hand exception is still a real route');
}

# --- the examples ---------------------------------------------------------
my $jwtish = qr/eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/;
for my $e (grep { $_->{who} ne 'fleet' } @entries) {
    my $x = eval { examples_for($e, me => 'you@example.com', domain => 'example.com') };
    ok($x, "$e->{id}: examples are generated") or do { diag $@; next };
    like($x->{curl}, qr{\Acurl -s}, "$e->{id}: cURL");
    like($x->{perl}, qr{Mojo::UserAgent}, "$e->{id}: Perl");
    my $all = join "\n", grep { defined } @$x{qw(curl perl cli)}, $e->{response}, $e->{body};
    unlike($all, $jwtish, "$e->{id}: nothing that looks like a real token");
    # Example ids and tokens repeat a short pattern ("f00dfeed" x 8): a
    # random-looking one trips the repo's secret scan, and once pushed, its
    # nightly scan of the whole history stays red.
    my @random = grep { _entropy($_) >= 3 } $all =~ /\b([0-9a-f]{24,})\b/g;
    is(scalar(@random), 0, "$e->{id}: long ids and tokens are visibly made up") or diag "@random";
    my @addr = $all =~ /([A-Za-z0-9._%+-]+\@[A-Za-z0-9.-]+\.[a-z]{2,})/g;
    is((grep { !/\@example\.(?:com|org|net)\z/ } @addr), 0, "$e->{id}: addresses are only examples or your own");
    ok(!grep({ defined && /\{(?:me|domain)\}/ } values %$x), "$e->{id}: placeholders are filled in");
}

unless (%only) {
    # --- what the site shows ---------------------------------------------------
    my @shown = map { @{ $_->{abilities} } } @{ public_areas($ref) };
    my $people = grep { $_->{who} ne 'fleet' } @entries;
    is(scalar(@shown), $people, "the site shows every ability a person can use ($people)");
    ok(!grep({ $_->{who} eq 'fleet' } @shown), 'and no route only fleet services call');
    ok(grep({ $_->{who} eq 'site-admin' } @shown) && grep({ $_->{who} =~ /\Apermission:/ } @shown),
       'admin and permission-only abilities are shown, each saying who may use it');
    my %labels = map { who_text($_->{who}) => 1 } @shown;
    ok(!grep({ /\A(?:anyone|signed-in|site-admin|permission:)/ } keys %labels), 'who may use each is said in words: ' . join('; ', sort keys %labels));
    my ($e) = grep { $_->{id} eq 'sign-in' } @shown;
    ok($e && $e->{examples}{curl} =~ /you\@example\.com/ && $e->{response} =~ /you\@example\.com/,
       'examples are filled in with the example address');
}

# --- the generator itself ---------------------------------------------------
{
    my $ab = { id => 'x', method => 'POST', path => '/api/v1/things/:name', who => 'signed-in', cli => 'homelab-cli things add {me}',
               params => [ { name => 'name', in => 'path', example => 'a b@{domain}' },
                           { name => 'q', in => 'query', example => 'x y' },
                           { name => 'n', in => 'body', example => 3 },
                           { name => 'token', in => 'body', example => '$REFRESH_TOKEN' },
                           { name => 'on', in => 'body', example => Mojo::JSON::true } ] };
    my $x = examples_for($ab, me => 'me@example.org', domain => 'example.org', base => 'https://api.example.test');
    like($x->{curl}, qr{curl -s -X POST 'https://api\.example\.test/api/v1/things/a%20b%40example\.org\?q=x%20y'}, 'path and query filled and escaped');
    like($x->{curl}, qr{-d "\{\\"n\\":3,\\"token\\":\\"\$REFRESH_TOKEN\\",\\"on\\":true\}"}, 'a $NAME value: JSON in double quotes, so the shell fills it in');
    like($x->{perl}, qr{\$ua->post\('https://api\.example\.test/api/v1/things/a%20b%40example\.org',}, 'Perl: the same URL');
    like($x->{perl}, qr{form => \{ q => 'x y' \}}, 'Perl: query as form');
    like($x->{perl}, qr{json => \{ n => 3, token => \$ENV\{REFRESH_TOKEN\}, on => \\1 \}}, 'Perl: body in order, env var, boolean');
    is($x->{cli}, 'homelab-cli things add me@example.org', 'the CLI command, filled in');
    my $open = examples_for({ %$ab, who => 'anyone', params => [] }, me => 'm@example.org', domain => 'example.org');
    unlike($open->{curl} . $open->{perl}, qr/Authorization/, 'an ability open to anyone sends no token');
    my $q = examples_for({ %$ab, method => 'GET', params => [ { name => 'name', in => 'path', example => "o'k" } ] });
    like($q->{curl}, qr{\Acurl -s 'https://api\.mailmasker\.org/api/v1/things/o%27k'}, 'GET has no -X, and a quote is escaped');
}

done_testing;

# Shannon entropy, in bits per character.
sub _entropy ($s) {
    my %n; $n{$_}++ for split //, $s;
    my $len = length $s;
    my $h = 0;
    $h -= ($_ / $len) * log($_ / $len) / log(2) for values %n;
    return $h;
}

# Problems were found: report them all (above) and still check the rest.
sub _load_anyway ($d) {
    no warnings 'redefine';
    local *Homelab::Developer::Reference::problems = sub { () };
    return load_reference($d);
}
