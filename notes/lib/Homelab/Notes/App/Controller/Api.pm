package Homelab::Notes::App::Controller::Api;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::Util qw(url_escape);
use Homelab::Common::AuditClient qw(enqueue);
use Homelab::Notes::Access qw(may_edit may_manage);
use Homelab::Notes::Render qw(render_body excerpt);

# The JSON the page talks to, and (behind a Bearer check, the i_* twins at
# the bottom) what homelab-cli gets through homelab-api's gateway. Every
# session route: signed in (require_login), and for a write the page's CSRF
# token (csrf_ok). Permission is asked here, once per route, through the
# model's Access-backed helpers; the model trusts us.

sub _model ($c) { return $c->app->model }
sub _fail ($c, $status, $msg) { return $c->render(json => { error => $msg }, status => $status) }
sub _body ($c) { my $b = $c->req->json; return (ref $b eq 'HASH') ? $b : {} }

# A model die()s with a one-line reason meant for the person.
sub _try ($c, $code) {
    my $r = eval { $code->() };
    return $r unless $@;
    my $err = $@;
    $c->app->log->error("notes: $err") if $err =~ /\bat .+ line \d+/;    # a real bug, not a validation message
    $err =~ s/ at \S+ line \d+.*//s;
    _fail($c, 400, $err =~ /\S/ ? $err : 'That did not work.');
    return undef;
}

sub _audit ($c, %a) {
    my $me = $c->session_email;
    eval {
        enqueue($c->app->pg->db,
            actor_email => $me, affected_user => $a{affected_user} // $me, jti => $c->stash('notes.session_jti'),
            action => $a{action}, resource_type => $a{resource_type}, resource_id => "$a{resource_id}",
            source_service => 'homelab-notes', ip_address => $c->tx->remote_address,
            user_agent => $c->req->headers->user_agent, detail => $a{detail} // {},
        );
        1;
    } or $c->app->log->warn("notes: audit enqueue failed ($a{action}): $@");
    return;
}

# ------------------------------------------------------------------ JSON shapes

sub _notebook_json ($nb) {
    return { id => 0 + $nb->{id}, name => $nb->{name}, color => $nb->{color}, position => 0 + ($nb->{position} // 0),
             owner_email => $nb->{owner_email}, permission => ($nb->{permission} // 'owner'),
             note_count => 0 + ($nb->{note_count} // 0), created_at => $nb->{created_at}, updated_at => $nb->{updated_at} };
}
sub _folder_json ($f) {
    return { id => 0 + $f->{id}, notebook_id => 0 + $f->{notebook_id}, parent_id => (defined $f->{parent_id} ? 0 + $f->{parent_id} : undef),
             name => $f->{name}, position => 0 + ($f->{position} // 0), note_count => 0 + ($f->{note_count} // 0) };
}
sub _row_json ($c, $n, $perm) {
    return { id => 0 + $n->{id}, notebook_id => 0 + $n->{notebook_id}, folder_id => (defined $n->{folder_id} ? 0 + $n->{folder_id} : undef),
             title => $n->{title}, format => $n->{format}, excerpt => excerpt($n->{format}, $n->{body_head} // $n->{body}),
             pinned => ($n->{pinned} ? \1 : \0), revision => 0 + $n->{revision}, owner_email => $n->{owner_email}, edited_by => $n->{edited_by},
             created_at => $n->{created_at}, updated_at => $n->{updated_at}, deleted_at => $n->{deleted_at},
             permission => $perm, url => $c->app->public_base_url . '/n/' . $n->{id},
             (exists $n->{snippet} ? _snippet($n->{snippet}) : ()) };
}
# The search passage: ts_headline marks hits with [[[ and ]]] (never HTML, so the
# body's own angle brackets cannot slip through); here it becomes plain text
# for the CLI and escaped HTML with <mark> for the page.
sub _snippet ($s) {
    return () unless defined $s;
    my $html = $s =~ s/&/&amp;/gr =~ s/</&lt;/gr =~ s/>/&gt;/gr;
    $html =~ s/\[\[\[/<mark>/g; $html =~ s/\]\]\]/<\/mark>/g;
    return (snippet => ($s =~ s/\[\[\[|\]\]\]//gr), snippet_html => $html);
}

# Links between notes (#93): [[Title]] in a body asks this for a URL. The
# note's own notebook first, then what the viewer may see; one query per
# title, remembered for the request.
sub _resolver ($c, $me, $nb) {
    my $m = _model($c);
    my %seen;
    return sub ($title) {
        my $k = lc $title;
        return $seen{$k} if exists $seen{$k};
        my $row = $m->note_by_title($me, $title, $nb ? $nb->{id} : undef);
        return $seen{$k} = $row ? '/n/' . $row->{id} : undef;
    };
}

sub _note_json ($c, $note, $nb, $perm) {
    my $m = _model($c);
    my $j = _row_json($c, $note, $perm);
    $j->{body} = $note->{body};
    $j->{html} = render_body($note->{format}, $note->{body}, _resolver($c, $c->session_email, $nb));
    $j->{notebook} = { id => 0 + $nb->{id}, name => $nb->{name}, color => $nb->{color} };
    $j->{links} = [ map { _link_json($c, $_) } @{ $m->links_for($note->{id}) } ];
    $j->{can_edit} = may_edit($perm) ? \1 : \0;
    $j->{can_manage} = may_manage($perm) ? \1 : \0;
    $j->{share_count} = may_manage($perm) ? scalar @{ $m->shares_for_note($note->{id}) } : 0;
    return $j;
}
sub _share_json ($c, $s) {
    return { id => 0 + $s->{id}, token => $s->{token}, url => $c->app->public_base_url . '/s/' . $s->{token},
             note_id => (defined $s->{note_id} ? 0 + $s->{note_id} : undef), notebook_id => (defined $s->{notebook_id} ? 0 + $s->{notebook_id} : undef),
             shared_with_email => $s->{shared_with_email}, permission => $s->{permission}, expires_at => $s->{expires_at},
             created_at => $s->{created_at}, accessed_at => $s->{accessed_at}, access_count => 0 + ($s->{access_count} // 0) };
}
sub _version_json ($v) {
    return { id => 0 + $v->{id}, note_id => 0 + $v->{note_id}, revision => 0 + $v->{revision}, title => $v->{title}, format => $v->{format},
             body_chars => 0 + ($v->{body_chars} // (defined $v->{body} ? length $v->{body} : 0)), saved_by => $v->{saved_by}, created_at => $v->{created_at},
             (exists $v->{body} ? (body => $v->{body}) : ()) };
}
# Where a link opens: a mail link in the search app (its own id for the
# person who linked it; a search by subject for anyone else), a drive link as
# the file's download, a web link as itself.
sub _link_json ($c, $l) {
    my $t = $l->{target} // {};
    my $open;
    if ($l->{kind} eq 'mail') {
        my $q = length($t->{subject} // '') ? '"' . ($t->{subject} =~ s/"//gr) . '"' : '';
        $open = $c->app->search_url . '/?q=' . url_escape($q) . '&source=mail';
    } elsif ($l->{kind} eq 'drive') {
        $open = $c->app->drive_url . '/files/' . $t->{file_id} . '/download' if ($t->{file_id} // '') =~ /\A\d+\z/;
    } else {
        $open = $t->{url};
    }
    return { id => 0 + $l->{id}, note_id => 0 + $l->{note_id}, kind => $l->{kind}, label => $l->{label}, target => $t,
             added_by => $l->{added_by}, created_at => $l->{created_at}, open_url => $open };
}

# ---------------------------------------------------------- finding and allowing

# The notebook :id, at the level the route needs: 'read', 'edit' or 'owner'.
# A notebook the viewer has nothing to do with is "no such notebook" (404),
# as the calendar does: nobody learns an id exists.
sub _notebook_for ($c, $me, $need, $id = undef) {
    my $m = _model($c);
    my $nb = $m->notebook($id // $c->stash('id'));
    my $perm = $m->permission_for_notebook($me, $nb);
    unless ($perm) { _fail($c, 404, 'No such notebook.'); return }
    if ($need eq 'owner' && !may_manage($perm)) { _fail($c, 403, 'Only the owner of a notebook can do that.'); return }
    if ($need eq 'edit' && !may_edit($perm))    { _fail($c, 403, 'You can see this notebook but not change it.'); return }
    $nb->{permission} = $perm;
    return $nb;
}
sub _note_for ($c, $me, $need, $id = undef) {
    my $m = _model($c);
    my $note = $m->note($id // $c->stash('id'));
    my $nb = $note ? $m->notebook($note->{notebook_id}) : undef;
    my $perm = $m->permission_for_note($me, $note, $nb);
    unless ($perm) { _fail($c, 404, 'No such note.'); return }
    if ($need eq 'owner' && !may_manage($perm)) { _fail($c, 403, 'Only the owner of a note can do that.'); return }
    if ($need eq 'edit' && !may_edit($perm))    { _fail($c, 403, 'You can see this note but not change it.'); return }
    return ($note, $nb, $perm);
}

# ---------------------------------------------------------------------- notebooks

sub notebooks ($c) {
    my $me = $c->require_login or return;
    my $m = _model($c);
    $m->ensure_default_notebook($me);
    return $c->render(json => { notebooks => [ map { _notebook_json($_) } @{ $m->notebooks_for($me) } ], prefs => $m->prefs($me) });
}
sub create_notebook ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    my $b = _body($c);
    my $nb = _try($c, sub { _model($c)->create_notebook($me, name => $b->{name}, color => $b->{color}) }) or return;
    return $c->render(json => _notebook_json({ %$nb, permission => 'owner' }), status => 201);
}
sub update_notebook ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    my $nb = _notebook_for($c, $me, 'owner') or return;
    my $b = _body($c);
    my $row = _try($c, sub { _model($c)->update_notebook($nb->{id}, map { exists $b->{$_} ? ($_ => $b->{$_}) : () } qw(name color position)) }) or return;
    return $c->render(json => _notebook_json({ %$row, permission => 'owner' }));
}
sub delete_notebook ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    my $nb = _notebook_for($c, $me, 'owner') or return;
    my $m = _model($c);
    return _fail($c, 400, 'That is your last notebook; make another before deleting it.') if @{ [ grep { $_->{permission} eq 'owner' } @{ $m->notebooks_for($me) } ] } <= 1;
    $m->delete_notebook($nb);
    _audit($c, action => 'notes.notebook_delete', resource_type => 'notebook', resource_id => $nb->{id}, detail => { name => $nb->{name} });
    return $c->render(json => { ok => \1 });
}
sub notebook_shares ($c) {
    my $me = $c->require_login or return;
    my $nb = _notebook_for($c, $me, 'owner') or return;
    return $c->render(json => { shares => [ map { _share_json($c, $_) } @{ _model($c)->shares_for_notebook($nb->{id}) } ] });
}
sub create_notebook_share ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    my $nb = _notebook_for($c, $me, 'owner') or return;
    my $b = _body($c);
    my $s = _try($c, sub { _model($c)->create_share(owner => $me, notebook_id => $nb->{id}, shared_with_email => ($b->{with} // $b->{shared_with_email}),
        permission => $b->{permission}, expires_days => $b->{expires_days}) }) or return;
    _audit($c, action => 'notes.share_create', resource_type => 'notebook', resource_id => $nb->{id}, affected_user => ($s->{shared_with_email} // $me),
        detail => { permission => $s->{permission}, link => ($s->{shared_with_email} ? \0 : \1) });
    return $c->render(json => _share_json($c, $s), status => 201);
}

# ------------------------------------------------------------------------ folders

sub folders ($c) {
    my $me = $c->require_login or return;
    my $nb = _notebook_for($c, $me, 'read') or return;
    return $c->render(json => { folders => [ map { _folder_json($_) } @{ _model($c)->folders_for($nb->{id}) } ] });
}
sub create_folder ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    my $nb = _notebook_for($c, $me, 'edit') or return;
    my $b = _body($c);
    my $f = _try($c, sub { _model($c)->create_folder($nb->{id}, name => $b->{name}, parent_id => $b->{parent_id}) }) or return;
    return $c->render(json => _folder_json($f), status => 201);
}
sub _folder_for ($c, $me, $need) {
    my $m = _model($c);
    my $f = $m->folder($c->stash('id'));
    unless ($f && !$f->{deleted_at}) { _fail($c, 404, 'No such folder.'); return }
    my $nb = _notebook_for($c, $me, $need, $f->{notebook_id}) or return;
    return ($f, $nb);
}
sub update_folder ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    my ($f) = _folder_for($c, $me, 'edit') or return;
    my $b = _body($c);
    my $row = _try($c, sub { _model($c)->update_folder($f, map { exists $b->{$_} ? ($_ => $b->{$_}) : () } qw(name parent_id position)) }) or return;
    return $c->render(json => _folder_json($row));
}
sub delete_folder ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    my ($f) = _folder_for($c, $me, 'owner') or return;
    my $n = _model($c)->delete_folder($f);
    _audit($c, action => 'notes.folder_delete', resource_type => 'folder', resource_id => $f->{id}, detail => { name => $f->{name}, folders => $n });
    return $c->render(json => { ok => \1 });
}

# -------------------------------------------------------------------------- notes

# GET /api/notes?notebook_id=&folder_id=&q=&limit=&offset=
# With notebook_id: that notebook's notes (folder_id narrows; 0 = the root).
# Without: everything the viewer may see, newest change first. q searches.
sub notes ($c) {
    my $me = $c->require_login or return;
    my $m = _model($c);
    my $q = $c->param('q');
    if (defined $q && $q =~ /\S/) {
        my $rows = $m->search_notes($me, $q, $c->param('limit') // 50);
        return $c->render(json => { notes => [ map { _row_json($c, $_, $m->permission_for_note($me, $_)) } @$rows ], q => $q });
    }
    if (my $nbid = $c->param('notebook_id')) {
        my $nb = _notebook_for($c, $me, 'read', $nbid) or return;
        my $rows = $m->notes_in(notebook_id => $nb->{id}, folder_id => $c->param('folder_id'), limit => $c->param('limit'), offset => $c->param('offset'));
        return $c->render(json => { notes => [ map { _row_json($c, $_, $nb->{permission}) } @$rows ], notebook => _notebook_json($nb) });
    }
    my $rows = $m->notes_for_viewer($me, limit => $c->param('limit'), offset => $c->param('offset'));
    return $c->render(json => { notes => [ map { _row_json($c, $_, $m->permission_for_note($me, $_)) } @$rows ] });
}
sub create_note ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    my $m = _model($c);
    my $b = _body($c);
    my $nb = $b->{notebook_id} ? (_notebook_for($c, $me, 'edit', $b->{notebook_id}) or return) : $m->ensure_default_notebook($me);
    $nb->{permission} //= 'owner';
    $b->{format} //= $m->prefs($me)->{default_format};
    my $note = _try($c, sub { $m->create_note($nb, $me, $b) }) or return;
    $m->set_prefs($me, last_notebook_id => $nb->{id}, last_note_id => $note->{id});
    return $c->render(json => _note_json($c, $note, $nb, $nb->{permission}), status => 201);
}
sub note ($c) {
    my $me = $c->require_login or return;
    my ($note, $nb, $perm) = _note_for($c, $me, 'read') or return;
    _model($c)->set_prefs($me, last_notebook_id => $nb->{id}, last_note_id => $note->{id}) if $perm eq 'owner';
    return $c->render(json => _note_json($c, $note, $nb, $perm));
}
# PATCH: title, body, format, pinned, folder_id; revision = the copy being
# edited. A newer copy on the server answers 409 with it, nothing written.
sub update_note ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    my ($note, $nb, $perm) = _note_for($c, $me, 'edit') or return;
    my $b = _body($c);
    my %in = map { exists $b->{$_} ? ($_ => $b->{$_}) : () } qw(title body format pinned folder_id);
    delete $in{folder_id} unless may_manage($perm);    # an editor changes words, not where the note lives
    my $row = eval { _model($c)->update_note($note, $me, \%in, expected_revision => $b->{revision}) };
    if (my $err = $@) {
        if ($err =~ /\Aconflict/) {
            my $cur = _model($c)->note($note->{id});
            return $c->render(json => { error => 'Someone saved a newer copy of this note; here it is.', note => _note_json($c, $cur, $nb, $perm) }, status => 409);
        }
        $c->app->log->error("notes: $err") if $err =~ /\bat .+ line \d+/;
        $err =~ s/ at \S+ line \d+.*//s;
        return _fail($c, 400, $err =~ /\S/ ? $err : 'That did not work.');
    }
    return $c->render(json => _note_json($c, $row, $nb, $perm));
}
sub delete_note ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    my ($note, $nb) = _note_for($c, $me, 'owner') or return;
    _model($c)->delete_note($note);
    _audit($c, action => 'notes.note_delete', resource_type => 'note', resource_id => $note->{id}, detail => { title => $note->{title}, notebook_id => $nb->{id} });
    return $c->render(json => { ok => \1, id => 0 + $note->{id} });
}
sub restore_note ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    my $m = _model($c);
    my $gone = $m->note($c->stash('id'));
    return _fail($c, 404, 'No such note in the trash.') unless $gone && $gone->{deleted_at} && lc($gone->{owner_email}) eq $me;
    my $row = $m->restore_note($gone->{id}) or return _fail($c, 404, 'No such note in the trash.');
    my $nb = $m->notebook($row->{notebook_id});
    return $c->render(json => _note_json($c, $row, $nb, 'owner'));
}
sub move_note ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    my ($note) = _note_for($c, $me, 'owner') or return;
    my $b = _body($c);
    my $target = _notebook_for($c, $me, 'owner', $b->{notebook_id} // $note->{notebook_id}) or return;
    my $row = _try($c, sub { _model($c)->move_note($note, $target->{id}, $b->{folder_id}) }) or return;
    return $c->render(json => _note_json($c, $row, $target, 'owner'));
}
sub trash ($c) {
    my $me = $c->require_login or return;
    return $c->render(json => { notes => [ map { _row_json($c, $_, 'owner') } @{ _model($c)->trashed_notes($me) } ] });
}
sub empty_trash ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    my $n = _model($c)->purge_trash($me, 0);
    _audit($c, action => 'notes.trash_empty', resource_type => 'trash', resource_id => $me, detail => { notes => $n });
    return $c->render(json => { ok => \1, removed => 0 + $n });
}

# ----------------------------------------------------------------------- versions

sub versions ($c) {
    my $me = $c->require_login or return;
    my ($note) = _note_for($c, $me, 'read') or return;
    return $c->render(json => { versions => [ map { _version_json($_) } @{ _model($c)->versions_for($note->{id}) } ] });
}
sub _version_for ($c, $me, $need) {
    my $v = _model($c)->version($c->stash('id'));
    unless ($v) { _fail($c, 404, 'No such version.'); return }
    my ($note, $nb, $perm) = _note_for($c, $me, $need, $v->{note_id}) or return;
    return ($v, $note, $nb, $perm);
}
sub version ($c) {
    my $me = $c->require_login or return;
    my ($v) = _version_for($c, $me, 'read') or return;
    return $c->render(json => _version_json($v));
}
sub restore_version ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    my ($v, $note, $nb, $perm) = _version_for($c, $me, 'edit') or return;
    my $row = _try($c, sub { _model($c)->restore_version($note, $v, $me) }) or return;
    return $c->render(json => _note_json($c, $row, $nb, $perm));
}

# -------------------------------------------------------------------------- links

sub links ($c) {
    my $me = $c->require_login or return;
    my ($note) = _note_for($c, $me, 'read') or return;
    return $c->render(json => { links => [ map { _link_json($c, $_) } @{ _model($c)->links_for($note->{id}) } ] });
}
sub add_link ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    my ($note) = _note_for($c, $me, 'edit') or return;
    my $b = _body($c);
    my $l = _try($c, sub { _model($c)->add_link($note->{id}, $me, kind => $b->{kind}, target => $b->{target}, label => $b->{label}) }) or return;
    return $c->render(json => _link_json($c, $l), status => 201);
}
sub remove_link ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    my $m = _model($c);
    my $l = $m->link($c->stash('id')) or return _fail($c, 404, 'No such link.');
    my ($note) = _note_for($c, $me, 'edit', $l->{note_id}) or return;
    $m->remove_link($l->{id});
    return $c->render(json => { ok => \1 });
}
# The pickers: the viewer's own mail and drive, through the gateway as them.
sub pick_mail ($c) {
    my $me = $c->require_login or return;
    my $q = $c->param('q') // '';
    return $c->render(json => { hits => [] }) unless $q =~ /\S/;
    my $hits = _try($c, sub { $c->app->gateway->mail_hits($c->viewer_jwt, $q, 20) }) or return;
    return $c->render(json => { hits => $hits });
}
sub pick_drive ($c) {
    my $me = $c->require_login or return;
    my $fid = $c->param('folder_id');
    $fid = undef unless defined $fid && $fid =~ /\A\d+\z/;
    my $level = _try($c, sub { $c->app->gateway->drive_level($c->viewer_jwt, $fid) }) or return;
    return $c->render(json => $level);
}

# ------------------------------------------------------------------------- shares

sub note_shares ($c) {
    my $me = $c->require_login or return;
    my ($note) = _note_for($c, $me, 'owner') or return;
    return $c->render(json => { shares => [ map { _share_json($c, $_) } @{ _model($c)->shares_for_note($note->{id}) } ] });
}
sub create_note_share ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    my ($note) = _note_for($c, $me, 'owner') or return;
    my $b = _body($c);
    my $s = _try($c, sub { _model($c)->create_share(owner => $me, note_id => $note->{id}, shared_with_email => ($b->{with} // $b->{shared_with_email}),
        permission => $b->{permission}, expires_days => $b->{expires_days}) }) or return;
    _audit($c, action => 'notes.share_create', resource_type => 'note', resource_id => $note->{id}, affected_user => ($s->{shared_with_email} // $me),
        detail => { permission => $s->{permission}, link => ($s->{shared_with_email} ? \0 : \1) });
    return $c->render(json => _share_json($c, $s), status => 201);
}
sub revoke_share ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    my $m = _model($c);
    my $s = $m->share($c->stash('id'));
    return _fail($c, 404, 'No such share.') unless $s && lc($s->{owner_email}) eq $me;
    $m->revoke_share($s->{id});
    _audit($c, action => 'notes.share_revoke', resource_type => ($s->{note_id} ? 'note' : 'notebook'), resource_id => ($s->{note_id} // $s->{notebook_id}),
        affected_user => ($s->{shared_with_email} // $me));
    return $c->render(json => { ok => \1 });
}

# ------------------------------------------------------------- search, preview, prefs

sub search ($c) {
    my $me = $c->require_login or return;
    my $m = _model($c);
    my $q = $c->param('q') // '';
    my $rows = $m->search_notes($me, $q, $c->param('limit') // 50);
    return $c->render(json => { q => $q, notes => [ map { _row_json($c, $_, $m->permission_for_note($me, $_)) } @$rows ] });
}
# POST {format, body} -> {html}: the editor's preview, nothing stored.
sub preview ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    my $b = _body($c);
    my $f = eval { Homelab::Notes::Model::_clean_format($b->{format}) } // 'markdown';
    my $nb = ($b->{notebook_id} // '') =~ /\A\d+\z/ ? _model($c)->notebook($b->{notebook_id}) : undef;
    return $c->render(json => { html => render_body($f, $b->{body} // '', _resolver($c, $me, $nb)), format => $f });
}
sub prefs ($c) {
    my $me = $c->require_login or return;
    return $c->render(json => _model($c)->prefs($me));
}
sub save_prefs ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    my $b = _body($c);
    my $p = _try($c, sub { _model($c)->set_prefs($me, map { exists $b->{$_} ? ($_ => $b->{$_}) : () } qw(last_notebook_id last_note_id default_format)) }) or return;
    return $c->render(json => $p);
}

sub metrics ($c) {
    my $m = eval { _model($c)->metrics } // {};
    my @lines = ('# HELP homelab_notes_up 1 when the database answered.', '# TYPE homelab_notes_up gauge', 'homelab_notes_up ' . (%$m ? 1 : 0));
    for my $k (sort keys %$m) {
        my ($name, $labels) = $k =~ /\A([a-z_0-9]+)(\{.*\})?\z/ or next;
        push @lines, "homelab_notes_$name" . ($labels // '') . ' ' . ($m->{$k} // 0);
    }
    $c->res->headers->content_type('text/plain; version=0.0.4; charset=utf-8');
    return $c->render(text => join("\n", @lines) . "\n");
}

# --- the gateway twins: the session handlers above, behind a Bearer check;
# _as_session makes require_login and csrf_ok pass. ---
sub _as_session ($c, $me) {
    $c->stash('notes.session_email' => $me);
    $c->stash('notes.session_jti' => $c->stash('current_jti'));
    $c->stash('notes.bearer' => 1);
    return $me;
}
sub i_notebooks                ($c) { my $me = $c->authenticated_email_any or return; _as_session($c, $me); return notebooks($c) }
sub i_create_notebook          ($c) { my $me = $c->authenticated_email_any or return; _as_session($c, $me); return create_notebook($c) }
sub i_update_notebook          ($c) { my $me = $c->authenticated_email_any or return; _as_session($c, $me); return update_notebook($c) }
sub i_delete_notebook          ($c) { my $me = $c->authenticated_email_any or return; _as_session($c, $me); return delete_notebook($c) }
sub i_folders                  ($c) { my $me = $c->authenticated_email_any or return; _as_session($c, $me); return folders($c) }
sub i_create_folder            ($c) { my $me = $c->authenticated_email_any or return; _as_session($c, $me); return create_folder($c) }
sub i_notebook_shares          ($c) { my $me = $c->authenticated_email_any or return; _as_session($c, $me); return notebook_shares($c) }
sub i_create_notebook_share    ($c) { my $me = $c->authenticated_email_any or return; _as_session($c, $me); return create_notebook_share($c) }
sub i_update_folder            ($c) { my $me = $c->authenticated_email_any or return; _as_session($c, $me); return update_folder($c) }
sub i_delete_folder            ($c) { my $me = $c->authenticated_email_any or return; _as_session($c, $me); return delete_folder($c) }
sub i_notes                    ($c) { my $me = $c->authenticated_email_any or return; _as_session($c, $me); return notes($c) }
sub i_create_note              ($c) { my $me = $c->authenticated_email_any or return; _as_session($c, $me); return create_note($c) }
sub i_note                     ($c) { my $me = $c->authenticated_email_any or return; _as_session($c, $me); return note($c) }
sub i_update_note              ($c) { my $me = $c->authenticated_email_any or return; _as_session($c, $me); return update_note($c) }
sub i_delete_note              ($c) { my $me = $c->authenticated_email_any or return; _as_session($c, $me); return delete_note($c) }
sub i_restore_note             ($c) { my $me = $c->authenticated_email_any or return; _as_session($c, $me); return restore_note($c) }
sub i_move_note                ($c) { my $me = $c->authenticated_email_any or return; _as_session($c, $me); return move_note($c) }
sub i_versions                 ($c) { my $me = $c->authenticated_email_any or return; _as_session($c, $me); return versions($c) }
sub i_links                    ($c) { my $me = $c->authenticated_email_any or return; _as_session($c, $me); return links($c) }
sub i_add_link                 ($c) { my $me = $c->authenticated_email_any or return; _as_session($c, $me); return add_link($c) }
sub i_note_shares              ($c) { my $me = $c->authenticated_email_any or return; _as_session($c, $me); return note_shares($c) }
sub i_create_note_share        ($c) { my $me = $c->authenticated_email_any or return; _as_session($c, $me); return create_note_share($c) }
sub i_version                  ($c) { my $me = $c->authenticated_email_any or return; _as_session($c, $me); return version($c) }
sub i_restore_version          ($c) { my $me = $c->authenticated_email_any or return; _as_session($c, $me); return restore_version($c) }
sub i_remove_link              ($c) { my $me = $c->authenticated_email_any or return; _as_session($c, $me); return remove_link($c) }
sub i_revoke_share             ($c) { my $me = $c->authenticated_email_any or return; _as_session($c, $me); return revoke_share($c) }
sub i_trash                    ($c) { my $me = $c->authenticated_email_any or return; _as_session($c, $me); return trash($c) }
sub i_empty_trash              ($c) { my $me = $c->authenticated_email_any or return; _as_session($c, $me); return empty_trash($c) }
sub i_search                   ($c) { my $me = $c->authenticated_email_any or return; _as_session($c, $me); return search($c) }
sub i_pick_mail                ($c) { my $me = $c->authenticated_email_any or return; _as_session($c, $me); return pick_mail($c) }
sub i_pick_drive               ($c) { my $me = $c->authenticated_email_any or return; _as_session($c, $me); return pick_drive($c) }
sub i_preview                  ($c) { my $me = $c->authenticated_email_any or return; _as_session($c, $me); return preview($c) }
sub i_prefs                    ($c) { my $me = $c->authenticated_email_any or return; _as_session($c, $me); return prefs($c) }
sub i_save_prefs               ($c) { my $me = $c->authenticated_email_any or return; _as_session($c, $me); return save_prefs($c) }

1;
