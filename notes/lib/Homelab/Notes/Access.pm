package Homelab::Notes::Access;
use Mojo::Base -strict, -signatures;
use Exporter 'import';

our @EXPORT_OK = qw(share_is_live notebook_permission note_permission may_edit may_manage);

# Who may do what. Pure functions over rows the model has already fetched, so
# the rules can be tested without a database and the controllers can never
# drift from each other: every route asks one of these. The calendar's
# Access.pm, with notebooks for calendars and notes for events.
#
# THE LEVELS, lowest to highest:
#   undef   nothing: the viewer has no relation to the notebook or note
#   read    may see it
#   edit    may change the note's title and body and add links; NOT share it
#           on, move it, or delete it
#   owner   everything
#
# Addresses are compared ignoring case: an account is one account however its
# address was typed into a share.

sub _norm ($s) { return lc($s // '') }

# A share row still grants something: not revoked, not past its expiry.
sub share_is_live ($share, $now = time) {
    return 0 unless ref $share eq 'HASH';
    return 0 if $share->{revoked_at};
    return 0 if defined $share->{expires_at_epoch} && $share->{expires_at_epoch} <= $now;
    return 1;
}

# notebook_permission($viewer_email, $notebook_row, \@shares) -> level
# @shares: this viewer's live notebook shares (any notebook; filtered here),
# as the model fetched them: { notebook_id, shared_with_email, permission }.
sub notebook_permission ($viewer, $notebook, $shares = []) {
    return undef unless ref $notebook eq 'HASH' && !$notebook->{deleted_at};
    my $me = _norm($viewer);
    return undef unless length $me;
    return 'owner' if _norm($notebook->{owner_email}) eq $me;
    my $best;
    for my $s (@{ $shares // [] }) {
        next unless ref $s eq 'HASH' && share_is_live($s);
        next unless defined $s->{notebook_id} && $s->{notebook_id} == $notebook->{id};
        next unless _norm($s->{shared_with_email}) eq $me;
        $best = 'edit' if ($s->{permission} // '') eq 'edit';
        $best //= 'read';
    }
    return $best;
}

# note_permission($viewer, $note_row, $notebook_row, \@notebook_shares, \@note_shares) -> level
# The notebook's level applies to every note in it; a share of the single
# note adds to that. The notebook's owner owns the note.
sub note_permission ($viewer, $note, $notebook, $nb_shares = [], $note_shares = []) {
    return undef unless ref $note eq 'HASH' && !$note->{deleted_at};
    my $level = notebook_permission($viewer, $notebook, $nb_shares);
    return $level if ($level // '') eq 'owner';
    my $me = _norm($viewer);
    for my $s (@{ $note_shares // [] }) {
        next unless ref $s eq 'HASH' && share_is_live($s);
        next unless defined $s->{note_id} && $s->{note_id} == $note->{id};
        next unless _norm($s->{shared_with_email}) eq $me;
        $level = 'edit' if ($s->{permission} // '') eq 'edit';
        $level //= 'read';
    }
    return $level;
}

sub may_edit ($level)   { return (($level // '') eq 'edit' || ($level // '') eq 'owner') ? 1 : 0 }
sub may_manage ($level) { return (($level // '') eq 'owner') ? 1 : 0 }

1;
