use Mojo::Base -strict, -signatures;
use Test::More;
use FindBin;
use Mojo::File qw(path);

# Post-cutover item 53: an invite past its expiry stopped counting only when
# someone opened its link, so it held the sender's pending limit and blocked
# re-inviting that person. Pinned in the source; runs in CI.
my $ctl = path("$FindBin::Bin/../lib/Homelab/Invite/App/Controller/Invites.pm")->slurp;
my $app = path("$FindBin::Bin/../lib/Homelab/Invite/App.pm")->slurp;
sub body { my ($n) = @_; my ($b) = $ctl =~ /(sub \Q$n\E \(.*?\n\})/s; return $b // '' }

like(body('expire_stale'), qr/SET status = 'expired' WHERE status = 'pending' AND expires_at <= NOW\(\)/, 'expire_stale marks past-expiry pending invites expired');
like(body('create'), qr/expire_stale\(.*?pending_count/s, 'creating an invite sweeps before counting pending ones');
like(body('list'), qr/expire_stale\(/, 'listing sweeps first');
like(body('quota_show_mine'), qr/expire_stale\(/, 'showing your quota sweeps first');
like($app, qr/Mojo::IOLoop->recurring\(600 => sub \{.*?expire_stale/s, 'and a timer sweeps every 10 minutes');
like($app, qr/require Homelab::Invite::App::Controller::Invites;/, '... with the controller loaded before the timer needs it');

like(body('list'), qr/length \$all && \$all ne '0' && lc \$all ne 'false'/, '?all= takes any value but empty, 0 or false, like the job list');
unlike(body('list'), qr/\$all eq 'true'/, '... not only the exact word "true"');
done_testing;
