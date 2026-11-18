package Homelab::WebTheme;
use Mojo::Base 'Mojolicious::Plugin', -signatures;
use Mojo::ByteStream;

our $VERSION = '0.2.0';

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

    # The app's own settings page, shown as "Settings" directly under the
    # signed-in address in the account dropdown (post-cutover #77). Optional:
    # an app with nothing to set passes nothing and shows no line. A page, not
    # a pop-up, so it has a URL and the phone's back button works.
    $app->helper(homelab_settings_url => sub ($c) {
        $c->stash('settings_url') // $conf->{settings_url} // ''
    });

    # The account dropdown's cross-app links. Configurable rather than
    # hardcoded in the partial because each app wants a slightly different
    # set -- myaccount has no reason to link to itself -- and because the
    # next app (chat, meetings) should be able to add itself without a
    # change to this package. Defaults to the four that exist today.
    # The app launcher (post-cutover #94): every mailmasker site, alphabetical,
    # as tiles behind the dotted button left of the account name. The default
    # is the fleet's public apps; an app may pass its own `sites` (or set the
    # stash). Whatever the source, the list comes back sorted by label.
    my @default_sites = (
        { href => 'https://myaccount.mailmasker.org/', label => 'Account',  icon => 'account' },
        { href => 'https://calendar.mailmasker.org/',  label => 'Calendar', icon => 'calendar' },
        { href => 'https://drive.mailmasker.org/',     label => 'Drive',    icon => 'drive' },
        { href => 'https://mail.mailmasker.org/',      label => 'Email',    icon => 'mail' },
        { href => 'https://notes.mailmasker.org/',     label => 'Notes',    icon => 'notes' },
        { href => 'https://search.mailmasker.org/',    label => 'Search',   icon => 'search' },
    );
    $app->helper(homelab_sites => sub ($c) {
        my $list = $c->stash('sites') // $conf->{sites} // \@default_sites;
        return [ sort { lc($a->{label} // '') cmp lc($b->{label} // '') } grep { ref $_ eq 'HASH' } @$list ];
    });
    # The tiles' icons: small line drawings in the text colour, inline (no
    # image files, nothing from a CDN). An unknown name gets the generic one.
    my %ICON = (
        account  => '<circle cx="12" cy="8" r="4"/><path d="M4 20c0-4 3.6-6 8-6s8 2 8 6"/>',
        calendar => '<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/>',
        drive    => '<path d="M9 4h6l6 10-3 6H6l-3-6z"/><path d="M3 14h18M9 4l-3 10M15 4l3 10"/>',
        mail     => '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M3 7l9 6 9-6"/>',
        notes    => '<path d="M6 3h9l5 5v13H6z"/><path d="M14 3v6h6M9 13h6M9 17h6"/>',
        search   => '<circle cx="11" cy="11" r="6"/><path d="M20 20l-4.5-4.5"/>',
        generic  => '<circle cx="12" cy="12" r="8"/><path d="M4 12h16M12 4c3 3 3 13 0 16M12 4c-3 3-3 13 0 16"/>',
    );
    $app->helper(homelab_site_icon => sub ($c, $name = '') {
        my $d = $ICON{ $name // '' } // $ICON{generic};
        return Mojo::ByteStream->new(qq{<svg class="launcher__icon" viewBox="0 0 24 24" width="28" height="28" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">$d</svg>});
    });

    $app->helper(homelab_menu_links => sub ($c) {
        $c->stash('menu_links') // $conf->{menu_links} // [
            { href => 'https://myaccount.mailmasker.org/', label => 'Manage your account' },
            { href => 'https://mail.mailmasker.org/',      label => 'Email' },
            { href => 'https://drive.mailmasker.org/',     label => 'Drive' },
            { href => 'https://search.mailmasker.org/',    label => 'Search' },
            { href => 'https://calendar.mailmasker.org/',  label => 'Calendar' },
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
