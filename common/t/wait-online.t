# homelab-wait-online (post-cutover #108): --any inside a container, the stock
# command anywhere else, own arguments passed through. The virtualisation
# probe and the binary are stand-ins found through PATH / the environment.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;

my $dir = tempdir(CLEANUP => 1);
sub fake { my ($name, $body) = @_; open my $fh, '>', "$dir/$name" or die $!; print $fh $body; close $fh; chmod 0755, "$dir/$name" }
fake('systemd-detect-virt', "#!/bin/sh\nexit \${FAKE_VIRT_RC:-1}\n");
fake('wait-online', "#!/bin/sh\necho \"args:\$*\"\n");
local $ENV{PATH} = "$dir:$ENV{PATH}";
local $ENV{HOMELAB_WAIT_ONLINE_BIN} = "$dir/wait-online";
my $script = "$FindBin::Bin/../script/homelab-wait-online";

{ local $ENV{FAKE_VIRT_RC} = 0; my $out = `$^X $script`;              like $out, qr/^args:--any$/m,              'in a container: --any' }
{ local $ENV{FAKE_VIRT_RC} = 1; my $out = `$^X $script`;              like $out, qr/^args:$/m,                   'not a container: the stock command, no arguments' }
{ local $ENV{FAKE_VIRT_RC} = 0; my $out = `$^X $script --timeout=30`; like $out, qr/^args:--timeout=30 --any$/m, 'own arguments pass through, --any appended once' }
{ local $ENV{FAKE_VIRT_RC} = 0; my $out = `$^X $script --any`;        like $out, qr/^args:--any$/m,              '--any already given: not doubled' }
done_testing;
