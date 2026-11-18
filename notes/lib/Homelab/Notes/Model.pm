package Homelab::Notes::Model;
use Mojo::Base -base, -signatures;
use Mojo::JSON qw(encode_json decode_json);
use Homelab::Notes::Access qw(notebook_permission note_permission);

has 'pg';
has versions_kept  => 20;
has max_body_bytes => 1048576;

# Everything the app knows about notebooks, folders, notes, their earlier
# bodies, links, shares and preferences (post-cutover #71). Plain SQL through
# Mojo::Pg; every method dies with ONE SENTENCE meant for the person when the
# input is wrong, which the controllers turn into a 400 (Api::_try). Who may
# do what is Access.pm's business; the model trusts its callers.

sub db ($self) { return $self->pg->db }

sub _random_hex ($bytes) {
    open my $fh, '<:raw', '/dev/urandom' or die "cannot open /dev/urandom: $!";
    my $buf;
    read $fh, $buf, $bytes;
    close $fh;
    return unpack 'H*', $buf;
}
sub new_token ($self) { return _random_hex(32) }
sub _norm ($e) { return lc($e // '') }
sub _id_ok ($id) { return defined $id && $id =~ /\A\d+\z/ }

# ------------------------------------------------------------------ notebooks

sub notebook ($self, $id) {
    return undef unless _id_ok($id);
    return $self->db->query('SELECT * FROM notes.notebooks WHERE id = ?', $id)->hash;
}

# The viewer's own notebooks (by position, then name), then the ones shared
# with them, each with its permission.
sub notebooks_for ($self, $email) {
    my $me = _norm($email);
    my $own = $self->db->query(
        q{SELECT *, 'owner' AS permission, (SELECT count(*) FROM notes.notes n WHERE n.notebook_id = b.id AND n.deleted_at IS NULL) AS note_count
          FROM notes.notebooks b WHERE owner_email = ? AND deleted_at IS NULL ORDER BY position, lower(name), id}, $me)->hashes->to_array;
    my $shared = $self->db->query(
        q{SELECT b.*, (CASE WHEN bool_or(s.permission = 'edit') THEN 'edit' ELSE 'read' END) AS permission,
                 (SELECT count(*) FROM notes.notes n WHERE n.notebook_id = b.id AND n.deleted_at IS NULL) AS note_count
          FROM notes.shares s JOIN notes.notebooks b ON b.id = s.notebook_id
          WHERE s.shared_with_email = ? AND s.revoked_at IS NULL AND (s.expires_at IS NULL OR s.expires_at > NOW()) AND b.deleted_at IS NULL
          GROUP BY b.id ORDER BY lower(b.name), b.id}, $me)->hashes->to_array;
    return [@$own, @$shared];
}

sub ensure_default_notebook ($self, $email) {
    my $me = _norm($email);
    my $first = $self->db->query('SELECT * FROM notes.notebooks WHERE owner_email = ? AND deleted_at IS NULL ORDER BY position, id LIMIT 1', $me)->hash;
    return $first if $first;
    return $self->create_notebook($me, name => 'My notes');
}

sub _clean_name ($name, $what) {
    $name = ($name // '') =~ s/\s+/ /gr =~ s/\A\s+|\s+\z//gr;
    die "Give the $what a name.\n" unless length $name;
    die "That name is too long (120 characters at most).\n" if length($name) > 120;
    return $name;
}
sub _clean_color ($c) {
    return '#6f94b8' unless defined $c && length $c;
    die "The colour must be like #6f94b8.\n" unless $c =~ /\A#[0-9a-fA-F]{6}\z/;
    return lc $c;
}

sub create_notebook ($self, $email, %f) {
    my $name = _clean_name($f{name}, 'notebook');
    my $me = _norm($email);
    my $pos = $self->db->query('SELECT coalesce(max(position), 0) + 1 FROM notes.notebooks WHERE owner_email = ? AND deleted_at IS NULL', $me)->array->[0];
    return $self->db->query('INSERT INTO notes.notebooks (owner_email, name, color, position) VALUES (?, ?, ?, ?) RETURNING *',
        $me, $name, _clean_color($f{color}), $pos)->hash;
}

sub update_notebook ($self, $id, %f) {
    my (@set, @v);
    if (exists $f{name})     { push @set, 'name = ?';     push @v, _clean_name($f{name}, 'notebook') }
    if (exists $f{color})    { push @set, 'color = ?';    push @v, _clean_color($f{color}) }
    if (exists $f{position}) { die "The position must be a number.\n" unless ($f{position} // '') =~ /\A-?\d+\z/; push @set, 'position = ?'; push @v, $f{position} }
    return $self->notebook($id) unless @set;
    return $self->db->query('UPDATE notes.notebooks SET ' . join(', ', @set, 'updated_at = NOW()') . ' WHERE id = ? RETURNING *', @v, $id)->hash;
}

# Soft: the notebook and every live note in it go to the trash together.
sub delete_notebook ($self, $nb) {
    my $db = $self->db;    # held: a transaction keeps only a weak reference to its connection
    my $tx = $db->begin;
    $db->query('UPDATE notes.notes SET deleted_at = NOW() WHERE notebook_id = ? AND deleted_at IS NULL', $nb->{id});
    $db->query('UPDATE notes.folders SET deleted_at = NOW() WHERE notebook_id = ? AND deleted_at IS NULL', $nb->{id});
    $db->query('UPDATE notes.notebooks SET deleted_at = NOW() WHERE id = ? AND deleted_at IS NULL', $nb->{id});
    $tx->commit;
    return 1;
}

# This viewer's live shares, with the expiry as an epoch for Access.pm.
my $SHARE_COLS = q{*, CASE WHEN expires_at IS NULL THEN NULL ELSE EXTRACT(EPOCH FROM expires_at)::bigint END AS expires_at_epoch};
sub viewer_notebook_shares ($self, $email) {
    return $self->db->query("SELECT $SHARE_COLS FROM notes.shares WHERE shared_with_email = ? AND notebook_id IS NOT NULL AND revoked_at IS NULL", _norm($email))->hashes->to_array;
}
sub viewer_note_shares ($self, $email) {
    return $self->db->query("SELECT $SHARE_COLS FROM notes.shares WHERE shared_with_email = ? AND note_id IS NOT NULL AND revoked_at IS NULL", _norm($email))->hashes->to_array;
}
sub permission_for_notebook ($self, $email, $nb) {
    return undef unless $nb;
    return 'owner' if _norm($nb->{owner_email}) eq _norm($email) && !$nb->{deleted_at};
    return notebook_permission($email, $nb, $self->viewer_notebook_shares($email));
}
sub permission_for_note ($self, $email, $note, $nb = undef) {
    return undef unless $note;
    $nb //= $self->notebook($note->{notebook_id}) or return undef;
    return 'owner' if _norm($nb->{owner_email}) eq _norm($email) && !$note->{deleted_at} && !$nb->{deleted_at};
    return note_permission($email, $note, $nb, $self->viewer_notebook_shares($email), $self->viewer_note_shares($email));
}

# -------------------------------------------------------------------- folders

sub folder ($self, $id) {
    return undef unless _id_ok($id);
    return $self->db->query('SELECT * FROM notes.folders WHERE id = ?', $id)->hash;
}
sub folders_for ($self, $notebook_id) {
    return $self->db->query(
        q{SELECT f.*, (SELECT count(*) FROM notes.notes n WHERE n.folder_id = f.id AND n.deleted_at IS NULL) AS note_count
          FROM notes.folders f WHERE notebook_id = ? AND deleted_at IS NULL ORDER BY position, lower(name), id}, $notebook_id)->hashes->to_array;
}
sub _folder_in ($self, $folder_id, $notebook_id) {
    return undef unless defined $folder_id && length $folder_id && $folder_id ne '0';
    my $f = $self->folder($folder_id);
    die "No such folder.\n" unless $f && !$f->{deleted_at} && $f->{notebook_id} == $notebook_id;
    return $f->{id};
}
sub create_folder ($self, $notebook_id, %f) {
    my $name = _clean_name($f{name}, 'folder');
    my $parent = $self->_folder_in($f{parent_id}, $notebook_id);
    return $self->db->query('INSERT INTO notes.folders (notebook_id, parent_id, name) VALUES (?, ?, ?) RETURNING *', $notebook_id, $parent, $name)->hash;
}
sub update_folder ($self, $folder, %f) {
    my (@set, @v);
    if (exists $f{name}) { push @set, 'name = ?'; push @v, _clean_name($f{name}, 'folder') }
    if (exists $f{parent_id}) {
        my $parent = $self->_folder_in($f{parent_id}, $folder->{notebook_id});
        die "A folder cannot be inside itself.\n" if defined $parent && $parent == $folder->{id};
        push @set, 'parent_id = ?'; push @v, $parent;
    }
    if (exists $f{position}) { die "The position must be a number.\n" unless ($f{position} // '') =~ /\A-?\d+\z/; push @set, 'position = ?'; push @v, $f{position} }
    return $folder unless @set;
    return $self->db->query('UPDATE notes.folders SET ' . join(', ', @set, 'updated_at = NOW()') . ' WHERE id = ? RETURNING *', @v, $folder->{id})->hash;
}
# Soft: the folder, the folders inside it and the notes in all of them.
sub delete_folder ($self, $folder) {
    my $db = $self->db;    # held: a transaction keeps only a weak reference to its connection
    my $tx = $db->begin;
    my $ids = $db->query(q{WITH RECURSIVE t AS (SELECT id FROM notes.folders WHERE id = ? UNION SELECT f.id FROM notes.folders f JOIN t ON f.parent_id = t.id)
                           SELECT array_agg(id) FROM t}, $folder->{id})->array->[0];
    $db->query('UPDATE notes.notes SET deleted_at = NOW() WHERE folder_id = ANY(?::bigint[]) AND deleted_at IS NULL', $ids);
    $db->query('UPDATE notes.folders SET deleted_at = NOW() WHERE id = ANY(?::bigint[]) AND deleted_at IS NULL', $ids);
    $tx->commit;
    return scalar @$ids;
}

# ---------------------------------------------------------------------- notes

my @FORMATS = qw(markdown wiki html text);
sub _clean_format ($f, $default = 'markdown') {
    return $default unless defined $f && length $f;
    $f = lc $f;
    $f = 'markdown' if $f eq 'md';
    $f = 'html' if $f eq 'htm';
    $f = 'text' if $f eq 'txt' || $f eq 'plain';
    $f = 'wiki' if $f eq 'wikitext' || $f eq 'mediawiki';
    die "The format must be markdown, wiki, html or text.\n" unless grep { $_ eq $f } @FORMATS;
    return $f;
}
sub _clean_title ($t) {
    $t = ($t // '') =~ s/[\r\n]+/ /gr =~ s/\s+/ /gr =~ s/\A\s+|\s+\z//gr;
    die "That title is too long (300 characters at most).\n" if length($t) > 300;
    return $t;
}
sub _clean_body ($self, $b) {
    $b //= '';
    $b =~ s/\r\n?/\n/g;
    die sprintf("That note is too big (%d bytes; %d at most).\n", length $b, $self->max_body_bytes) if length($b) > $self->max_body_bytes;
    return $b;
}

sub note ($self, $id) {
    return undef unless _id_ok($id);
    return $self->db->query('SELECT * FROM notes.notes WHERE id = ?', $id)->hash;
}

# The list columns: no body, a head of it for the excerpt.
my $LIST_COLS = q{n.id, n.notebook_id, n.folder_id, n.owner_email, n.title, n.format, left(n.body, 400) AS body_head, n.pinned, n.revision,
                  n.edited_by, n.created_at, n.updated_at, n.deleted_at};

# The notes of one notebook: all of them, or those in one folder, or those at
# the root (folder_id => 0). Pinned first, then newest change first.
sub notes_in ($self, %w) {
    my @where = ('n.notebook_id = ?', 'n.deleted_at IS NULL');
    my @v = ($w{notebook_id});
    if (defined $w{folder_id} && length $w{folder_id}) {
        if ($w{folder_id} eq '0' || $w{folder_id} eq 'root') { push @where, 'n.folder_id IS NULL' }
        else { push @where, 'n.folder_id = ?'; push @v, $w{folder_id} }
    }
    my $limit = ($w{limit} // 200) =~ /\A\d+\z/ ? $w{limit} // 200 : 200;
    $limit = 500 if $limit > 500;
    my $offset = ($w{offset} // 0) =~ /\A\d+\z/ ? $w{offset} : 0;
    return $self->db->query("SELECT $LIST_COLS FROM notes.notes n WHERE " . join(' AND ', @where) . ' ORDER BY n.pinned DESC, n.updated_at DESC, n.id DESC LIMIT ? OFFSET ?',
        @v, $limit, $offset)->hashes->to_array;
}

# What the viewer may see, across every notebook: their own notes, the notes
# of notebooks shared with them, the notes shared with them one by one.
sub _scope_sql { return q{(n.owner_email = ? OR n.notebook_id IN (SELECT notebook_id FROM notes.shares WHERE shared_with_email = ? AND notebook_id IS NOT NULL AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > NOW()))
                                               OR n.id IN (SELECT note_id FROM notes.shares WHERE shared_with_email = ? AND note_id IS NOT NULL AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > NOW())))} }

sub notes_for_viewer ($self, $email, %w) {
    my $me = _norm($email);
    my $limit = ($w{limit} // 100) =~ /\A\d+\z/ ? $w{limit} // 100 : 100;
    $limit = 500 if $limit > 500;
    my $offset = ($w{offset} // 0) =~ /\A\d+\z/ ? $w{offset} : 0;
    my @where = (_scope_sql(), 'n.deleted_at IS NULL');
    my @v = ($me, $me, $me);
    if ($w{notebook_id}) { push @where, 'n.notebook_id = ?'; push @v, $w{notebook_id} }
    return $self->db->query("SELECT $LIST_COLS FROM notes.notes n WHERE " . join(' AND ', @where) . ' ORDER BY n.updated_at DESC, n.id DESC LIMIT ? OFFSET ?', @v, $limit, $offset)->hashes->to_array;
}

# The note a [[Title]] link means (#93): a live note with that title (case
# ignored) among what the viewer may see, the given notebook's first.
sub note_by_title ($self, $email, $title, $notebook_id = undef) {
    my $me = _norm($email);
    $title = ($title // '') =~ s/\s+/ /gr =~ s/\A\s+|\s+\z//gr;
    return undef unless length $title;
    return $self->db->query('SELECT n.id, n.notebook_id, n.title FROM notes.notes n WHERE ' . _scope_sql()
        . ' AND n.deleted_at IS NULL AND lower(n.title) = lower(?) ORDER BY (n.notebook_id = ?) DESC, n.updated_at DESC LIMIT 1',
        $me, $me, $me, $title, ($notebook_id // 0))->hash;
}
# The same within one notebook only (a share link's public page).
sub note_in_notebook_by_title ($self, $notebook_id, $title) {
    $title = ($title // '') =~ s/\s+/ /gr =~ s/\A\s+|\s+\z//gr;
    return undef unless length $title;
    return $self->db->query('SELECT id, notebook_id, title FROM notes.notes WHERE notebook_id = ? AND deleted_at IS NULL AND lower(title) = lower(?) ORDER BY updated_at DESC LIMIT 1',
        $notebook_id, $title)->hash;
}

sub create_note ($self, $nb, $email, $input) {
    my $title  = _clean_title($input->{title});
    my $format = _clean_format($input->{format});
    my $body   = $self->_clean_body($input->{body});
    my $folder = $self->_folder_in($input->{folder_id}, $nb->{id});
    my $pinned = $input->{pinned} ? 1 : 0;
    return $self->db->query(
        q{INSERT INTO notes.notes (notebook_id, folder_id, owner_email, title, format, body, pinned, edited_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?) RETURNING *},
        $nb->{id}, $folder, _norm($nb->{owner_email}), $title, $format, $body, $pinned, _norm($email))->hash;
}

# Change a note. %o: expected_revision -- when the caller's copy is older than
# the row, nothing is written and this dies with 'conflict' (the controller
# answers 409 with the newer note). The content before the change is kept as
# a version when title, body or format changed.
sub update_note ($self, $note, $email, $input, %o) {
    my (@set, @v);
    my $content_changed = 0;
    if (exists $input->{title})  { my $t = _clean_title($input->{title});   if ($t ne $note->{title})  { push @set, 'title = ?';  push @v, $t; $content_changed = 1 } }
    if (exists $input->{format}) { my $f = _clean_format($input->{format}); if ($f ne $note->{format}) { push @set, 'format = ?'; push @v, $f; $content_changed = 1 } }
    if (exists $input->{body})   { my $b = $self->_clean_body($input->{body}); if ($b ne $note->{body}) { push @set, 'body = ?'; push @v, $b; $content_changed = 1 } }
    if (exists $input->{pinned}) { push @set, 'pinned = ?'; push @v, ($input->{pinned} ? 1 : 0) }
    if (exists $input->{folder_id}) { push @set, 'folder_id = ?'; push @v, $self->_folder_in($input->{folder_id}, $note->{notebook_id}) }
    return $note unless @set;

    my $db = $self->db;    # held: a transaction keeps only a weak reference to its connection
    my $tx = $db->begin;
    my $cur = $db->query('SELECT * FROM notes.notes WHERE id = ? FOR UPDATE', $note->{id})->hash or die "That note is gone.\n";
    die "conflict\n" if defined $o{expected_revision} && $o{expected_revision} =~ /\A\d+\z/ && $o{expected_revision} != $cur->{revision};
    if ($content_changed) {
        $db->query(q{INSERT INTO notes.note_versions (note_id, revision, title, format, body, saved_by) VALUES (?, ?, ?, ?, ?, ?)},
            $cur->{id}, $cur->{revision}, $cur->{title}, $cur->{format}, $cur->{body}, $cur->{edited_by});
        $db->query(q{DELETE FROM notes.note_versions WHERE note_id = ? AND id NOT IN (SELECT id FROM notes.note_versions WHERE note_id = ? ORDER BY id DESC LIMIT ?)},
            $cur->{id}, $cur->{id}, $self->versions_kept);
        push @set, 'revision = revision + 1', 'edited_by = ?';
        push @v, _norm($email);
    }
    my $row = $db->query('UPDATE notes.notes SET ' . join(', ', @set, 'updated_at = NOW()') . ' WHERE id = ? RETURNING *', @v, $cur->{id})->hash;
    $tx->commit;
    return $row;
}

sub delete_note ($self, $note) {
    $self->db->query('UPDATE notes.notes SET deleted_at = NOW() WHERE id = ? AND deleted_at IS NULL', $note->{id});
    return 1;
}
sub restore_note ($self, $id) {
    return undef unless _id_ok($id);
    my $db = $self->db;    # held: a transaction keeps only a weak reference to its connection
    my $tx = $db->begin;
    my $row = $db->query('UPDATE notes.notes SET deleted_at = NULL, updated_at = NOW() WHERE id = ? AND deleted_at IS NOT NULL RETURNING *', $id)->hash or do { $tx->rollback; return undef };
    # Its notebook comes back if it was trashed with it; a trashed folder lets go of the note.
    $db->query('UPDATE notes.notebooks SET deleted_at = NULL WHERE id = ? AND deleted_at IS NOT NULL', $row->{notebook_id});
    if ($row->{folder_id}) {
        my $f = $db->query('SELECT deleted_at FROM notes.folders WHERE id = ?', $row->{folder_id})->hash;
        $row = $db->query('UPDATE notes.notes SET folder_id = NULL WHERE id = ? RETURNING *', $row->{id})->hash if !$f || $f->{deleted_at};
    }
    $tx->commit;
    return $row;
}
sub trashed_notes ($self, $email) {
    return $self->db->query("SELECT $LIST_COLS FROM notes.notes n WHERE n.owner_email = ? AND n.deleted_at IS NOT NULL ORDER BY n.deleted_at DESC LIMIT 500", _norm($email))->hashes->to_array;
}
# Empty the trash: rows deleted more than $days ago (or all with 0) are gone for good.
sub purge_trash ($self, $email, $days = 0) {
    my $r = $self->db->query(q{DELETE FROM notes.notes WHERE owner_email = ? AND deleted_at IS NOT NULL AND deleted_at < NOW() - (?::int * INTERVAL '1 day')}, _norm($email), $days);
    return $r->rows;
}

sub move_note ($self, $note, $notebook_id, $folder_id = undef) {
    my $nb = $self->notebook($notebook_id);
    die "No such notebook.\n" unless $nb && !$nb->{deleted_at};
    my $folder = $self->_folder_in($folder_id, $nb->{id});
    return $self->db->query('UPDATE notes.notes SET notebook_id = ?, folder_id = ?, owner_email = ?, updated_at = NOW() WHERE id = ? RETURNING *',
        $nb->{id}, $folder, _norm($nb->{owner_email}), $note->{id})->hash;
}

# ------------------------------------------------------------------- versions

sub versions_for ($self, $note_id) {
    return $self->db->query(q{SELECT id, note_id, revision, title, format, length(body) AS body_chars, saved_by, created_at
                              FROM notes.note_versions WHERE note_id = ? ORDER BY id DESC}, $note_id)->hashes->to_array;
}
sub version ($self, $id) {
    return undef unless _id_ok($id);
    return $self->db->query('SELECT * FROM notes.note_versions WHERE id = ?', $id)->hash;
}
# Bring an earlier body back: the current one becomes a version in its turn.
sub restore_version ($self, $note, $version, $email) {
    return $self->update_note($note, $email, { title => $version->{title}, format => $version->{format}, body => $version->{body} });
}

# --------------------------------------------------------------------- search

# Full text over what the viewer may see; a short highlighted passage with
# each hit. Falls back to a substring match when the words make no query
# (one letter, punctuation).
sub search_notes ($self, $email, $q, $limit = 50) {
    my $me = _norm($email);
    $q = ($q // '') =~ s/\A\s+|\s+\z//gr;
    return [] unless length $q;
    $limit = 50 unless ($limit // '') =~ /\A\d+\z/;
    $limit = 200 if $limit > 200;
    my $scope = _scope_sql();
    my $rows = $self->db->query(
        qq{SELECT $LIST_COLS, ts_rank(n.search_tsv, websearch_to_tsquery('english', ?)) AS rank,
                  ts_headline('english', left(n.body, 20000), websearch_to_tsquery('english', ?), 'MaxFragments=2, MaxWords=18, MinWords=6, StartSel=[[[, StopSel=]]]') AS snippet
           FROM notes.notes n WHERE $scope AND n.deleted_at IS NULL AND n.search_tsv @@ websearch_to_tsquery('english', ?)
           ORDER BY rank DESC, n.updated_at DESC LIMIT ?}, $q, $q, $me, $me, $me, $q, $limit)->hashes->to_array;
    return $rows if @$rows;
    return $self->db->query(
        qq{SELECT $LIST_COLS, 0 AS rank, NULL AS snippet FROM notes.notes n
           WHERE $scope AND n.deleted_at IS NULL AND (n.title ILIKE ? OR n.body ILIKE ?) ORDER BY n.updated_at DESC LIMIT ?},
        $me, $me, $me, '%' . $q . '%', '%' . $q . '%', $limit)->hashes->to_array;
}

# ---------------------------------------------------------------------- links

my @LINK_KINDS = qw(mail drive url);
sub _link_row ($row) {
    return undef unless $row;
    $row->{target} = eval { decode_json($row->{target}) } // {} unless ref $row->{target};
    return $row;
}
sub links_for ($self, $note_id) {
    return [ map { _link_row($_) } @{ $self->db->query('SELECT * FROM notes.links WHERE note_id = ? ORDER BY position, id', $note_id)->hashes->to_array } ];
}
sub link ($self, $id) {
    return undef unless _id_ok($id);
    return _link_row($self->db->query('SELECT * FROM notes.links WHERE id = ?', $id)->hash);
}
# add_link(note_id, email, kind => mail|drive|url, target => {...}, label => '')
# A mail target: message_id (search's id for the person who linked it), subject,
# from_addr, from_name, sent_at, mailbox. A drive target: file_id, filename,
# size_bytes, mime_type. A url target: url.
sub add_link ($self, $note_id, $email, %f) {
    my $kind = lc($f{kind} // '');
    die "The link must be to mail, a drive file or a web address.\n" unless grep { $_ eq $kind } @LINK_KINDS;
    my $t = ref $f{target} eq 'HASH' ? $f{target} : {};
    my %keep;
    if ($kind eq 'mail') {
        die "A mail link needs the message's subject or id.\n" unless length($t->{subject} // '') || length($t->{message_id} // '');
        %keep = map { $_ => $t->{$_} } grep { defined $t->{$_} } qw(message_id subject from_addr from_name sent_at mailbox);
    } elsif ($kind eq 'drive') {
        die "A drive link needs the file's id.\n" unless ($t->{file_id} // '') =~ /\A\d+\z/;
        %keep = map { $_ => $t->{$_} } grep { defined $t->{$_} } qw(file_id filename size_bytes mime_type folder_path);
    } else {
        my $u = ($t->{url} // '') =~ s/\A\s+|\s+\z//gr;
        die "A web link needs an http or https address.\n" unless $u =~ m{\Ahttps?://\S+\z}i;
        %keep = (url => $u);
    }
    for (values %keep) { $_ = substr($_, 0, 500) if defined && !ref && length > 500 }
    my $label = substr(($f{label} // '') =~ s/\s+/ /gr =~ s/\A\s+|\s+\z//gr, 0, 200);
    my $pos = $self->db->query('SELECT coalesce(max(position), 0) + 1 FROM notes.links WHERE note_id = ?', $note_id)->array->[0];
    return _link_row($self->db->query('INSERT INTO notes.links (note_id, kind, target, label, added_by, position) VALUES (?, ?, ?::jsonb, ?, ?, ?) RETURNING *',
        $note_id, $kind, encode_json(\%keep), $label, _norm($email), $pos)->hash);
}
sub remove_link ($self, $id) {
    $self->db->query('DELETE FROM notes.links WHERE id = ?', $id);
    return 1;
}

# --------------------------------------------------------------------- shares

sub shares_for_note     ($self, $id) { return $self->db->query("SELECT $SHARE_COLS FROM notes.shares WHERE note_id = ? AND revoked_at IS NULL ORDER BY created_at", $id)->hashes->to_array }
sub shares_for_notebook ($self, $id) { return $self->db->query("SELECT $SHARE_COLS FROM notes.shares WHERE notebook_id = ? AND revoked_at IS NULL ORDER BY created_at", $id)->hashes->to_array }
sub share ($self, $id) {
    return undef unless _id_ok($id);
    return $self->db->query("SELECT $SHARE_COLS FROM notes.shares WHERE id = ?", $id)->hash;
}

# create_share(owner => $email, note_id => | notebook_id =>, shared_with_email => undef|addr,
#              permission => read|edit, expires_days => N|undef)
sub create_share ($self, %f) {
    my $with = defined $f{shared_with_email} && length $f{shared_with_email} ? _norm($f{shared_with_email}) : undef;
    die "That does not look like an address.\n" if defined $with && $with !~ /\A[^\s@]+@[^\s@]+\.[^\s@]+\z/;
    my $perm = ($f{permission} // 'read') eq 'edit' ? 'edit' : 'read';
    $perm = 'read' unless $with;    # a link is never an edit share
    my $days = $f{expires_days};
    $days = undef unless defined $days && $days =~ /\A\d+\z/ && $days > 0;
    die "A share is on a note or a notebook.\n" unless ($f{note_id} xor $f{notebook_id});
    return $self->db->query(
        qq{INSERT INTO notes.shares (token, owner_email, note_id, notebook_id, shared_with_email, permission, expires_at)
           VALUES (?, ?, ?, ?, ?, ?, CASE WHEN ?::int IS NULL THEN NULL ELSE NOW() + (?::int * INTERVAL '1 day') END) RETURNING $SHARE_COLS},
        $self->new_token, _norm($f{owner}), $f{note_id}, $f{notebook_id}, $with, $perm, $days, $days)->hash;
}
sub revoke_share ($self, $id) {
    $self->db->query('UPDATE notes.shares SET revoked_at = NOW() WHERE id = ? AND revoked_at IS NULL', $id);
    return 1;
}
# A link's share row if it still works, with the note or notebook it opens.
sub share_by_token ($self, $token) {
    return undef unless defined $token && $token =~ /\A[0-9a-f]{64}\z/;
    my $row = $self->db->query("SELECT $SHARE_COLS FROM notes.shares WHERE token = ? AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > NOW())", $token)->hash or return undef;
    if ($row->{note_id}) {
        $row->{note} = $self->note($row->{note_id});
        return undef unless $row->{note} && !$row->{note}{deleted_at};
        $row->{notebook} = $self->notebook($row->{note}{notebook_id});
    } else {
        $row->{notebook} = $self->notebook($row->{notebook_id});
    }
    return undef unless $row->{notebook} && !$row->{notebook}{deleted_at};
    return $row;
}
sub note_share_access ($self, $id) {
    eval { $self->db->query('UPDATE notes.shares SET accessed_at = NOW(), access_count = access_count + 1 WHERE id = ?', $id) };
    return 1;
}

# ---------------------------------------------------------------------- prefs

sub prefs ($self, $email) {
    my $row = $self->db->query('SELECT * FROM notes.user_prefs WHERE user_email = ?', _norm($email))->hash;
    return { last_notebook_id => undef, last_note_id => undef, default_format => 'markdown', %{ $row // {} } };
}
sub set_prefs ($self, $email, %f) {
    my %set;
    for my $k (qw(last_notebook_id last_note_id)) {
        next unless exists $f{$k};
        $set{$k} = (defined $f{$k} && $f{$k} =~ /\A\d+\z/) ? $f{$k} : undef;
    }
    $set{default_format} = _clean_format($f{default_format}) if exists $f{default_format};
    return $self->prefs($email) unless %set;
    my @k = sort keys %set;
    $self->db->query('INSERT INTO notes.user_prefs (user_email, ' . join(', ', @k) . ') VALUES (?' . (', ?' x @k) . ') ON CONFLICT (user_email) DO UPDATE SET '
        . join(', ', map { "$_ = EXCLUDED.$_" } @k) . ', updated_at = NOW()', _norm($email), @set{@k});
    return $self->prefs($email);
}

# -------------------------------------------------------------------- metrics

sub metrics ($self) {
    my $db = $self->db;
    my %m;
    $m{notebooks}     = $db->query('SELECT count(*) FROM notes.notebooks WHERE deleted_at IS NULL')->array->[0];
    $m{notes}         = $db->query('SELECT count(*) FROM notes.notes WHERE deleted_at IS NULL')->array->[0];
    $m{notes_trashed} = $db->query('SELECT count(*) FROM notes.notes WHERE deleted_at IS NOT NULL')->array->[0];
    $m{"notes_by_format{format=\"$_->{format}\"}"} = $_->{n} for @{ $db->query('SELECT format, count(*) AS n FROM notes.notes WHERE deleted_at IS NULL GROUP BY format')->hashes->to_array };
    $m{versions}      = $db->query('SELECT count(*) FROM notes.note_versions')->array->[0];
    $m{links}         = $db->query('SELECT count(*) FROM notes.links')->array->[0];
    $m{shares}        = $db->query('SELECT count(*) FROM notes.shares WHERE revoked_at IS NULL AND (expires_at IS NULL OR expires_at > NOW())')->array->[0];
    $m{shares_public} = $db->query('SELECT count(*) FROM notes.shares WHERE revoked_at IS NULL AND shared_with_email IS NULL AND (expires_at IS NULL OR expires_at > NOW())')->array->[0];
    $m{saves_1h}      = $db->query(q{SELECT count(*) FROM notes.note_versions WHERE created_at > NOW() - INTERVAL '1 hour'})->array->[0];
    $m{accounts}      = $db->query('SELECT count(DISTINCT owner_email) FROM notes.notebooks WHERE deleted_at IS NULL')->array->[0];
    return \%m;
}

1;
