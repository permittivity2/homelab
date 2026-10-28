use Mojo::Base -strict;
use Test::More;
use Mojo::File qw(path);

# The shipped catch-all. Asserted here because both faults it fixes were
# invisible from inside the fleet -- they only showed up asking an
# unconfigured public domain from off-network -- and because getting the
# :443 half subtly wrong (a cert directive instead of a rejected handshake)
# recreates the exact bug: serving a VALID certificate for the WRONG name.

my $conf = path(__FILE__)->dirname->sibling('nginx', '00-catchall.conf');
ok(-f $conf, 'the catch-all config ships');
my $raw = $conf->slurp;
# Comments carry the rationale at length; match on directives only.
my $c = join "\n", grep { !/^\s*#/ } split /\n/, $raw;

# --- :80 ---
like($c, qr/^\s*listen\s+80\s+default_server\s*;/m, 'claims the :80 default_server');
like($c, qr/^\s*listen\s+\[::\]:80\s+default_server\s*;/m, 'and on IPv6');
like($c, qr/^\s*return\s+404\s*;/m, 'unknown Host gets a flat 404');
like($c, qr/^\s*server_tokens\s+off\s*;/m, 'no nginx version advertised to an accidental caller');
unlike($c, qr/\broot\b|\bindex\b|try_files/, 'serves no files -- that is what produced the Welcome page');

# --- :443 ---
like($c, qr/^\s*listen\s+443\s+ssl\s+default_server\s*;/m, 'claims the :443 default_server');
like($c, qr/^\s*listen\s+\[::\]:443\s+ssl\s+default_server\s*;/m, 'and on IPv6');
like($c, qr/^\s*ssl_reject_handshake\s+on\s*;/m, 'unknown SNI is REJECTED, not answered');

# This is the assertion that matters most. A ssl_certificate here would mean
# unconfigured names get a real certificate issued for a different host --
# which is the bug, not the fix.
unlike($c, qr/ssl_certificate/, 'presents no certificate for a name it does not serve');

# --- exactly one default_server per port, or nginx refuses to start ---
for my $port (80, 443) {
    my @v4 = $c =~ /^\s*listen\s+$port(?:\s+ssl)?\s+default_server\s*;/mg;
    is(scalar(@v4), 1, "exactly one IPv4 default_server on :$port");
}

# --- the packaging actually ships and installs it ---
my $rules = path(__FILE__)->dirname->sibling('debian', 'rules')->slurp;
like($rules, qr{nginx/00-catchall\.conf}, 'debian/rules installs it');
my $postinst = path(__FILE__)->dirname->sibling('debian', 'postinst')->slurp;
like($postinst, qr{/etc/nginx/conf\.d/00-catchall\.conf}, 'postinst places it in conf.d');
like($postinst, qr{sites-enabled/default}, "postinst disables nginx's stock default site");
# A broken config here takes down every vhost on the only powered-on edge.
like($postinst, qr{nginx -t}, 'postinst validates before reloading');
like($postinst, qr{rm -f "\$CATCHALL_DST"}, 'and rolls the catch-all back if validation fails');

done_testing;
