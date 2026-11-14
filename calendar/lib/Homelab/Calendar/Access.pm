package Homelab::Calendar::Access;
use Mojo::Base -strict, -signatures;
use Exporter 'import';

our @EXPORT_OK = qw(share_is_live calendar_permission event_permission may_edit may_manage visible_detail);

# Who may do what. Pure functions over rows the model has already fetched, so
# the rules can be tested without a database and the controllers can never
# drift from each other: every route asks one of these.
#
# THE LEVELS, lowest to highest:
#   undef   nothing: the viewer has no relation to the calendar or event
#   read    may see it (full detail, or 'busy' only for a link share so marked)
#   edit    may add, change and remove events; NOT the calendar's settings or
#           its shares -- an editor cannot share something on
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

# calendar_permission($viewer_email, $calendar_row, \@shares) -> level
# @shares: this viewer's live calendar shares (any calendar; filtered here),
# as the model fetched them: { calendar_id, shared_with_email, permission }.
sub calendar_permission ($viewer, $calendar, $shares = []) {
    return undef unless ref $calendar eq 'HASH' && !$calendar->{deleted_at};
    my $me = _norm($viewer);
    return undef unless length $me;
    return 'owner' if _norm($calendar->{owner_email}) eq $me;
    my $best;
    for my $s (@{ $shares // [] }) {
        next unless ref $s eq 'HASH' && share_is_live($s);
        next unless defined $s->{calendar_id} && $s->{calendar_id} == $calendar->{id};
        next unless _norm($s->{shared_with_email}) eq $me;
        $best = 'edit' if ($s->{permission} // '') eq 'edit';
        $best //= 'read';
    }
    return $best;
}

# event_permission($viewer, $event_row, $calendar_row, \@calendar_shares, \@event_shares) -> level
# The calendar's level applies to every event on it; a share of the single
# event adds to that. Owner of the calendar is owner of the event.
sub event_permission ($viewer, $event, $calendar, $cal_shares = [], $event_shares = []) {
    return undef unless ref $event eq 'HASH' && !$event->{deleted_at};
    my $level = calendar_permission($viewer, $calendar, $cal_shares);
    return $level if ($level // '') eq 'owner';
    my $me = _norm($viewer);
    for my $s (@{ $event_shares // [] }) {
        next unless ref $s eq 'HASH' && share_is_live($s);
        next unless defined $s->{event_id} && $s->{event_id} == $event->{id};
        next unless _norm($s->{shared_with_email}) eq $me;
        $level = 'edit' if ($s->{permission} // '') eq 'edit';
        $level //= 'read';
    }
    return $level;
}

sub may_edit ($level)   { return (($level // '') eq 'edit' || ($level // '') eq 'owner') ? 1 : 0 }
sub may_manage ($level) { return (($level // '') eq 'owner') ? 1 : 0 }

# What a link share shows of an event: everything, or only that the time is
# taken. A named share always shows everything.
sub visible_detail ($share) {
    return 'full' unless ref $share eq 'HASH';
    return 'full' if defined $share->{shared_with_email} && length $share->{shared_with_email};
    return (($share->{detail} // 'full') eq 'busy') ? 'busy' : 'full';
}

1;
