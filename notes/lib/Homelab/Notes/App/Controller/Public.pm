package Homelab::Notes::App::Controller::Public;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::Util qw(url_escape);
use Homelab::Notes::Render qw(render_body excerpt);

# A share link: /s/<token> opens the note it is for, or lists the notes of
# the notebook it is for; /s/<token>/n/<id> is one note of that notebook. A
# share made for one account opens only for that account, signed in; a link
# share opens for anyone holding it. Read only here: editing is on the app's
# own page, where the share also appears under "Shared with me".
sub share_page ($c) {
    my $m = $c->app->model;
    my $share = $m->share_by_token($c->stash('token'));
    return $c->render(template => 'notice', status => 404, heading => 'This link is not valid',
        body => 'It may have been withdrawn, have expired, or the note may have been deleted.') unless $share;

    my $me = $c->session_email;
    if (defined $share->{shared_with_email} && length $share->{shared_with_email}) {
        unless (length $me) {
            return $c->render(template => 'notice', status => 401, heading => 'Sign in to open this',
                body => 'This was shared with one account. Sign in as that account to open it.', login_next => $c->req->url->path->to_string);
        }
        return $c->render(template => 'notice', status => 403, heading => 'Not shared with you',
            body => 'This was shared with another account.') unless lc $share->{shared_with_email} eq $me;
    }
    $m->note_share_access($share->{id});

    my $nb = $share->{notebook};
    my $note = $share->{note};
    if (!$note && $c->stash('id')) {
        $note = $m->note($c->stash('id'));
        return $c->render(template => 'notice', status => 404, heading => 'No such note', body => 'That note is not in this notebook.')
            unless $note && !$note->{deleted_at} && $note->{notebook_id} == $nb->{id};
    }
    if ($note) {
        # [[Links]] (#93) resolve only inside a shared notebook, to its other notes.
        my $resolver = $share->{notebook_id} ? sub ($title) { my $r = $m->note_in_notebook_by_title($nb->{id}, $title); return $r ? '/s/' . $share->{token} . '/n/' . $r->{id} : undef } : undef;
        return $c->render(template => 'public_note', share => $share, notebook => $nb, note => $note,
            html => render_body($note->{format}, $note->{body}, $resolver), links => $m->links_for($note->{id}),
            back => ($share->{notebook_id} ? '/s/' . $share->{token} : undef), me => $me,
            open_url => (length $me ? $c->app->public_base_url . '/n/' . $note->{id} : undef));
    }
    my $notes = $m->notes_in(notebook_id => $nb->{id});
    $_->{excerpt} = excerpt($_->{format}, $_->{body_head}) for @$notes;
    my $folders = $m->folders_for($nb->{id});
    my %fname = map { $_->{id} => $_->{name} } @$folders;
    return $c->render(template => 'public_notebook', share => $share, notebook => $nb, notes => $notes, folder_names => \%fname, me => $me);
}

1;
