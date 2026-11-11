use strict;
use warnings;
use Test::More;
use FindBin;

# --print-grants needs no database, no Sendmail::PMilter and no
# homelab-common, so it runs everywhere (CI included). It is the text the
# workstation orchestrator pipes into psql on the DB primary, so what it
# prints is a contract: every grant the milter needs, and nothing that
# creates roles or carries a password.
my $script = "$FindBin::Bin/../script/homelab-postfix-block-link-bootstrap-role";
ok(-f $script, 'bootstrap script exists');

my $out = `$^X $script --print-grants --role-suffix 39 2>&1`;
is($? >> 8, 0, '--print-grants exits 0 without a database');
my $role = '"homelab_postfix_block_link_runtime_39"';
like($out, qr/^GRANT SELECT \(email, active\) ON api\.users TO \Q$role\E;/m, 'api.users column grant present');
like($out, qr/^GRANT SELECT ON domainadmin\.mail_aliases TO \Q$role\E;/m, 'mail_aliases grant present');
like($out, qr/^GRANT INSERT ON block_link\.pending_links TO \Q$role\E;/m, 'pending_links insert grant present');
like($out, qr/^GRANT SELECT ON domainadmin\.mail_reply_identity TO \Q$role\E;/m, '#67: mail_reply_identity select grant');
like($out, qr/^GRANT SELECT, INSERT ON domainadmin\.mail_received_via TO \Q$role\E;/m, '#67: mail_received_via select+insert grant');
like($out, qr/^GRANT USAGE ON SEQUENCE domainadmin\.mail_received_via_id_seq TO \Q$role\E;/m, '#67: sequence usage grant');
unlike($out, qr/PASSWORD|CREATE ROLE|ALTER ROLE|SCRAM/, 'grants only: no role creation, no password');
unlike($out, qr/^GRANT[^\n]*\b(?:UPDATE|DELETE)\b/m, 'the milter never gets UPDATE or DELETE on anything');

my $out2 = `$^X $script --print-grants --role homelab_postfix_block_link_runtime_41 2>&1`;
is($? >> 8, 0, '--role form exits 0');
like($out2, qr/"homelab_postfix_block_link_runtime_41"/, '--role names the role outright');

my $bad = `$^X $script --print-grants --role 'evil"; DROP ROLE x; --' 2>&1`;
isnt($? >> 8, 0, 'a role name with anything but [a-z0-9_] is refused');

my $usage = `$^X $script 2>&1`;
isnt($? >> 8, 0, 'no arguments at all still fails with usage');
like($usage, qr/--print-grants/, 'usage mentions the new mode');

done_testing;
