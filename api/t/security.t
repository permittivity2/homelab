use strict;
use warnings;
use Test::More;
use FindBin;
use Mojo::File qw(path);

# The security fixes of 2026-11-03, pinned in the source so CI catches a
# regression (the behaviour itself is tested against a real deployment in
# t/sessions.t and t/gateway.t, which CI cannot run).

my $src = path("$FindBin::Bin/../lib/Homelab/API/App.pm")->slurp;
sub body { my ($name) = @_; my ($b) = $src =~ /(sub \Q$name\E \(.*?\n\})/s; return $b // '' }

# 1. Jobs are read-only through the gateway: a zip job fetches the URLs it is
#    given, from inside the fleet, so starting one must not be open to callers.
unlike($src, qr{\$r->(?:any|post|put|patch|delete)\(\s*'/api/v1/jobs}, 'nothing but GET reaches /api/v1/jobs through the gateway');
like($src, qr{\$r->get\(\s*'/api/v1/jobs'\s*=>}, 'listing jobs still goes through');
like($src, qr{\$r->get\(\s*'/api/v1/jobs/\*capture'\s*=>}, '... and following one');

# 2. Registration needs an invite unless a config says otherwise.
like(body('_register'), qr/require_invite\}\s*\/\/\s*1;/, 'register: an unset require_invite means invites are required');

# 3. Ending sessions ends their refresh tokens too, and refresh refuses a
#    suspended account or an ended session.
like(body('_end_sessions'), qr/UPDATE api\.refresh_tokens SET revoked = TRUE.*UPDATE api\.sessions SET revoked = TRUE/s,
     '_end_sessions revokes the refresh tokens and the sessions');
like(body('_change_password'), qr/_end_sessions\(\$user->\{id\}, keep_jti => \$payload->\{jti\}/, 'a password change ends every other session for real');
like(body('_password_reset_confirm'), qr/_end_sessions\(\$row->\{user_id\}\)/, 'a password reset ends every session for real');
like(body('_admin_set_active'), qr/_end_sessions\(\$id\) unless \$active/, 'suspending an account ends its sessions for real');
for my $h (qw(_change_password _password_reset_confirm _admin_set_active)) {
    unlike(body($h), qr/UPDATE api\.sessions SET revoked/, "$h has no sessions-only revoke left");
}
my $refresh = body('_refresh');
like($refresh, qr/u\.active/, 'refresh reads whether the account is active');
like($refresh, qr/unless \$row->\{active\}/, '... and refuses a suspended one');
like($refresh, qr/FILTER \(WHERE NOT revoked\) AS live.*?if \$sess->\{n\} && !\$sess->\{live\}/s, '... and a token whose sessions were all ended');

# The clean-up of what the old behaviour left behind ships as a migration.
my $mig = path("$FindBin::Bin/../migrations/021-end-refresh-tokens-of-ended-sessions.sql")->slurp;
like($mig, qr/UPDATE api\.refresh_tokens rt\s+SET revoked = TRUE\s+WHERE rt\.revoked = FALSE\s+AND EXISTS/, 'migration 021 ends the tokens that outlived their sessions');

done_testing;
