package Homelab::Common::Config;
use Mojo::Base -strict;
use YAML::XS qw(LoadFile);
use Exporter 'import';

our @EXPORT_OK = qw(load_config);

# Every feature's config lives at a fixed path, overridable by an
# env var — e.g. load_config('HOMELAB_SSO_CONFIG', '/etc/homelab/sso/config.yml').
# This is the one loader every package used to hand-roll separately.
sub load_config {
    my ($env_var, $default_path) = @_;
    my $path = $ENV{$env_var} // $default_path;
    die "Config file not found: $path\n" unless -f $path;
    my $config = LoadFile($path);
    # The hypnotoad pid file lives in the unit's RuntimeDirectory whenever
    # systemd gives it one (post-cutover #41 J): /run is emptied at boot, so a
    # pid left on disk by a power cut can never make `hypnotoad` signal a
    # stranger that inherited the number and exit 0 with nothing running.
    # Forced, not defaulted: the live configs of several apps pin pid_file to
    # /var/lib/homelab, and every app reads server.pid_file for its hypnotoad
    # block. RUNTIME_DIRECTORY may name several directories; the first is ours.
    if (defined(my $rd = $ENV{RUNTIME_DIRECTORY}) && ref $config eq 'HASH') {
        ($rd) = split /:/, $rd;
        if (length $rd) {
            $config->{server} = {} unless ref $config->{server} eq 'HASH';
            $config->{server}{pid_file} = "$rd/hypnotoad.pid";
        }
    }
    return $config;
}

1;
