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
    return LoadFile($path);
}

1;
