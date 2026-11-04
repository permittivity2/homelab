use Mojo::Base -strict;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Homelab::Worker::JobType::Zip;

# What a zip job may fetch (post-cutover item 53): https to a public name only,
# never an IP address or a fleet-internal name, so a zip job can't be pointed
# at the fleet's own services. Runs in CI.
my $r = \&Homelab::Worker::JobType::Zip::url_refusal;
is($r->('https://drive.mailmasker.org/api/v1/files/42'), '', "Drive's own file address is allowed");
like($r->('http://10.50.2.150:2379/version'), qr/https/, 'plain http is refused');
like($r->('https://10.20.1.8:8006/'), qr/IP address/, 'an IP address is refused');
like($r->('https://[::1]/'), qr/IP address/, '... IPv6 too');
like($r->("https://$_/x"), qr/internal name/, "$_ is refused")
    for qw(localhost api.svc.homelab db.svc.homelab x.internal printer.local router.lan nas.home.arpa intranet);
like($r->('https://user:pw@internal/x'), qr/internal name/, 'credentials in the URL change nothing');
like($r->('ftp://drive.mailmasker.org/x'), qr/https/, 'other schemes are refused');
like($r->('not a url'), qr/not a URL/, 'garbage is refused');
is($r->('https://drive.mailmasker.org/api/v1/files/42', ['https://drive.mailmasker.org/api/v1/files/']), '',
   'with allowed prefixes, a matching address passes');
like($r->('https://example.com/x', ['https://drive.mailmasker.org/api/v1/files/']), qr/allowed/,
     '... and anything else is refused');

# A refused entry fails the job before anything is fetched.
my $err = do { local $@; eval { Homelab::Worker::JobType::Zip::run({ entries => [ { fetch_url => 'http://10.50.2.1/', zip_path => 'x' } ] }, '/nonexistent') }; $@ };
like($err, qr/entry 1 was refused/, 'the job itself refuses, too (for a job made before this rule)');
done_testing;
