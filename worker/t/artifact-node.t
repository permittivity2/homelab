use Mojo::Base -strict, -signatures;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Mojo::File qw(path);

# Item 51: a job's output is on the disk of the node that ran it. Only that
# node removes it, and a download reaching another node is relayed from it.
# Pure and static, so this runs in CI with no database.

my $app_src = path("$FindBin::Bin/../lib/Homelab/Worker/App.pm")->slurp;
my $ctl_src = path("$FindBin::Bin/../lib/Homelab/Worker/App/Controller/Jobs.pm")->slurp;
my ($fn) = $app_src =~ /(sub expiry_action \(.*?\n\})/s;
ok($fn, 'found expiry_action');
my $act = eval "package T; use Mojo::Base -strict, -signatures; $fn; \\&expiry_action" or diag $@;

my $me = '10.50.2.159:2512';
my %done = (state => 'completed', output_node => $me, week_overdue => 0);
is($act->({ %done }, $me, 1), 'file-and-row', 'our file: remove it and the row');
is($act->({ %done }, $me, 0), 'row', 'ours but the file is already gone: the row');
is($act->({ %done, output_node => '10.50.2.161:2512' }, $me, 0), 'keep', 'another node\'s: leave it to that node');
is($act->({ %done, output_node => '10.50.2.161:2512', week_overdue => 1 }, $me, 0), 'row',
   '... unless a week overdue: its owner must be gone');
is($act->({ %done, output_node => undef }, $me, 0), 'keep', 'from before owners were recorded, not here: keep');
is($act->({ %done, output_node => undef }, $me, 1), 'file-and-row', '... and here: remove it');
is($act->({ state => 'failed', output_node => undef }, $me, 0), 'row', 'a failed job wrote nothing: any node removes the row');
is($act->({ %done }, '', 0), 'keep', 'a node with no address of its own claims nothing');

like($app_src, qr/completed_at = NOW\(\), output_node = \?/, 'completing a job records the node that holds its output');
like($ctl_src, qr/output_node\n\s+FROM worker\.jobs WHERE id = \?/, 'the job lookup reads output_node');
like($ctl_src, qr/unless \(-f \$path\) \{.*?\$c->proxy->get_p\("http:\/\/\$owner\/internal\/v1\/jobs\/\$row->\{id\}\/download"/s,
     'a download for another node\'s file is relayed from that node');
like($ctl_src, qr/!\$c->req->headers->header\('X-Homelab-Worker-Relay'\)/, '... once, never relayed on');
unlike($ctl_src, qr/output_node\s*=>/, 'the owner is never shown to callers');

done_testing;
