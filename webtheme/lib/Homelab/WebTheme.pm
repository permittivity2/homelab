package Homelab::WebTheme;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

our $VERSION = '0.1.1';

# Shared web chrome for the homelab Mojolicious apps.
#
# One line in an app's startup() gets it the shared header, footer and
# stylesheet:
#
#     $self->plugin('Homelab::WebTheme' => {
#         app_name   => 'My Account',
#         user_email => sub ($c) { $c->session('email') },
#         signout_url=> '/logout',
#         menu_links => [ { href => '...', label => '...' } ],   # optional
#     });
#
# and then in a layout:
#
#     %= include 'homelab/head'
#     %= include 'homelab/header'
#     ...
#     %= include 'homelab/footer'
#
# WHY A PLUGIN rather than "add a renderer path yourself": the partials need
# three values to exist on every render (theme_base, app_name, user_email). A
# raw stash value breaks the moment one template forgets to pass it -- which is
# exactly what drive's login page did with $email. A before_render hook fills
# the defaults once, so a partial can never explode on a page that did not
# think about it.
#
# WHY THE CSS IS REMOTE: the stylesheet is served from static.mailmasker.org,
# not shipped in this package, so a theme change restyles every app with no
# rebuild or redeploy. The MARKUP ships here because the header is
# server-rendered (it shows the signed-in address, and rendering it client-side
# would mean an API round trip plus a flash of missing header). So: styling is
# instant, structure needs a package bump. That split is deliberate.

use constant DEFAULT_THEME_BASE => 'https://static.mailmasker.org/theme/v1';

sub register ($self, $app, $conf = {}) {
    my $home = $ENV{HOMELAB_WEBTHEME_HOME} // '/usr/share/homelab-webtheme';

    # Appended, not prepended: an app that ships its own homelab/header.html.ep
    # can deliberately override the shared one. Matches how every homelab app
    # already builds this list additively.
    push @{ $app->renderer->paths }, "$home/templates";

    my $base = $conf->{theme_base} // $ENV{HOMELAB_THEME_BASE} // DEFAULT_THEME_BASE;
    $base =~ s{/\z}{};

    # EVERYTHING the partials need is a HELPER, not a stash value set by a hook.
    # That is deliberate. A before_render hook only populates the stash once
    # rendering has begun, so anything reading the stash earlier sees undef --
    # and a raw stash value breaks outright on a template that forgot to pass
    # it (drive's login page did exactly that with $email). A helper is
    # resolved at the moment the template asks, so the partials can never see a
    # missing value and a caller can still override via the stash.
    $app->helper(theme_base => sub ($c) { $c->stash('theme_base') // $base });

    $app->helper(homelab_app_name => sub ($c) {
        $c->stash('app_name') // $conf->{app_name} // ''
    });
    $app->helper(homelab_signout_url => sub ($c) {
        $c->stash('signout_url') // $conf->{signout_url} // '/logout'
    });
    $app->helper(homelab_nav_links => sub ($c) {
        $c->stash('nav_links') // $conf->{nav_links} // []
    });

    # The account dropdown's cross-app links. Configurable rather than
    # hardcoded in the partial because each app wants a slightly different
    # set -- myaccount has no reason to link to itself -- and because the
    # next app (chat, meetings) should be able to add itself without a
    # change to this package. Defaults to the three that exist today.
    $app->helper(homelab_menu_links => sub ($c) {
        $c->stash('menu_links') // $conf->{menu_links} // [
            { href => 'https://myaccount.mailmasker.org/', label => 'Manage your account' },
            { href => 'https://mail.mailmasker.org/',      label => 'Email' },
            { href => 'https://drive.mailmasker.org/',     label => 'Drive' },
        ]
    });

    # The signed-in address. An app passes a coderef; if it passes nothing, or
    # the resolver dies (no session on a login page is a NORMAL state, not an
    # error), the header simply renders without the account menu.
    my $resolver = $conf->{user_email};
    $app->helper(homelab_user_email => sub ($c) {
        my $v = $c->stash('user_email');
        return $v if defined $v;
        return '' unless $resolver;
        my $r = eval { $resolver->($c) };
        return defined $r ? $r : '';
    });

    return;
}

1;

__END__

=head1 NAME

Homelab::WebTheme - shared header, footer and stylesheet for homelab web apps

=head1 DESCRIPTION

Gives every homelab Mojolicious app the same chrome: the Silver Linings logo
top-left opening an account dropdown, a shared footer, and one stylesheet
served from static.mailmasker.org.

=cut
