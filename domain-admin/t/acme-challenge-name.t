use v5.36;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

# _acme_name is the security boundary of the system_agent-gated ACME routes:
# it is what stops a leaked agent token from writing arbitrary DNS. The gate
# says WHO may call; this says WHAT they may write. Test it directly.
require Homelab::DomainAdmin::App::Controller::Dns;
my $f = \&Homelab::DomainAdmin::App::Controller::Dns::_acme_name;

my $D = 'mailmasker.org';

# --- accepted: the legitimate shapes certbot asks for ---
is($f->($D, '_acme-challenge'),                      "_acme-challenge.$D", 'bare label is qualified into the zone');
is($f->($D, "_acme-challenge.$D"),                   "_acme-challenge.$D", 'already-qualified name passes through');
is($f->($D, "_acme-challenge.$D."),                  "_acme-challenge.$D", 'trailing dot tolerated');
is($f->($D, '_acme-challenge.www'),                  "_acme-challenge.www.$D", 'sub-name is qualified');
is($f->($D, "_acme-challenge.www.$D"),               "_acme-challenge.www.$D", 'qualified sub-name passes');

# --- REFUSED: anything that is not an _acme-challenge record ---
ok(!defined $f->($D, 'www'),                 'a plain hostname is refused');
ok(!defined $f->($D, "www.$D"),              'a qualified hostname is refused');
ok(!defined $f->($D, '@'),                   'the apex is refused');
ok(!defined $f->($D, $D),                    'the bare zone is refused');
ok(!defined $f->($D, 'mail'),                'MX target name is refused');
ok(!defined $f->($D, '_dmarc'),              'another underscore record is refused');
ok(!defined $f->($D, 'notacme-challenge'),   'a lookalike label is refused');
ok(!defined $f->($D, '_acme-challengex'),    'a prefix-extended label is refused');
ok(!defined $f->($D, ''),                    'empty name is refused');
ok(!defined $f->($D, undef),                 'undef name is refused');

# --- THE security property: the result is ALWAYS inside the target zone.
#     A caller cannot steer a write into another zone. Note these inputs are
#     not rejected -- an unqualified name is QUALIFIED into the zone, so
#     "_acme-challenge.evil.example" becomes a record inside our own zone
#     rather than a write against evil.example. Containment, not refusal.
for my $attempt ('_acme-challenge.evil.example',
                 "_acme-challenge.$D.evil.example",
                 '_acme-challenge.a.b.c.d') {
    my $got = $f->($D, $attempt);
    ok(!defined $got || $got =~ /\.\Q$D\E\z/,
        "'$attempt' can only ever write inside $D (got: " . ($got // 'refused') . ")");
}
# A name from a DIFFERENT managed zone is likewise contained, not honoured
# against that other zone.
my $other = $f->('forge.name', "_acme-challenge.$D");
ok(!defined $other || $other =~ /\.forge\.name\z/,
    'a name from another managed zone is contained within forge.name');

# A lookalike zone suffix must NOT be treated as already-qualified.
ok(!defined $f->($D, '_acme-challenge.not' . $D),
    'a lookalike suffix (not<zone>) is refused, not accepted as qualified');

done_testing;
