use Mojo::Base -strict, -signatures;
use Test::More;
use FindBin;
use Mojo::File qw(path);
use Mojolicious;

# Who may open a share link, pinned in the source. No app is started, so this
# runs in CI as-is (t/shares.t needs homelab-webtheme to start the app).
my $src = path("$FindBin::Bin/../lib/Homelab/Drive/App.pm")->slurp;

# Regression (security fix 2026-11-03): a share made for one person opened for
# anyone holding the link, though the email it sends says the recipient must
# sign in. Every handler that serves a share must ask _share_visitor_ok right
# after resolving it, before anything is served.
for my $h (qw(public_share public_download public_thumbnail public_folder_file public_folder_thumb)) {
    my ($body) = $src =~ /(sub \Q$h\E \(.*?\n\})/s;
    ok($body, "found $h");
    like($body // '', qr/_live_share\(.*?_share_visitor_ok\(\$c, \$sh(?:, 1)?\) or return;.*?(?:_note_share_access|reply->file|_serve_share_derivative|render\(template => 'share_)/s,
         "$h checks who is asking before serving anything");
}
like($src, qr/sub _share_visitor_ok .*?shared_with_email.*?owner_email.*?redirect_to\('\/login'\).*?share_not_yours/s,
     '_share_visitor_ok: the named person or the owner, else sign in, else "shared with someone else"');
{
    require Mojolicious::Lite;
    my $app = Mojolicious->new;
    my $c = $app->build_controller;
    my ($after) = $src =~ /(sub _after_login \(\$c\) \{.*?\n\})/s;
    ok($after, 'found _after_login');
    my $code = eval "package Homelab::Drive::App::Controller::Drive::T; use Mojo::Base -strict, -signatures; $after; \\&_after_login";
    ok($code, '_after_login compiles on its own') or diag $@;
    if ($code) {
        my $tok = 'a' x 64;
        $c->session(after_login => "/s/$tok");         is($code->($c), "/s/$tok", 'sign-in returns to the share link');
        $c->session(after_login => "/s/$tok/f/12");    is($code->($c), "/s/$tok/f/12", '... or a folder inside it');
        $c->session(after_login => 'https://evil.example/'); is($code->($c), '/', '... never another site');
        $c->session(after_login => "/s/$tok/../../admin");    is($code->($c), '/', '... nor anywhere else here');
        is($code->($c), '/', 'nothing saved: the front page');
    }
}

# Post-cutover item 52: the account check before a share email was asked with
# the sharer's own token, which the api refuses for anyone but catch-all
# admins, so the email never went out. Drive asks with its own credential.
like($src, qr/sub _share_recipient_exists .*?my \$jwt = eval \{ system_agent_token\(\) \};.*?_current_auth\(\$c\) unless \$jwt;/s,
     'the share account check asks with Drive\'s own credential first');
like($src, qr/use Homelab::Common::Registry qw\(lookup system_agent_token\);/, '... which is imported');

# Post-cutover item 53: a file in Trash isn't served for download.
like($src, qr/sub download \(\$c\) \{.*?FROM drive\.files WHERE id = \? AND user_email = \? AND deleted_at IS NULL/s,
     'download skips a file in Trash');

done_testing;
