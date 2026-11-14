package Homelab::Calendar::Runner;
use Mojo::Base -base, -signatures;
use Mojo::IOLoop;
use DateTime;
use Exporter 'import';
use Homelab::Calendar::Recurrence qw(validate_zone);
use Homelab::Calendar::MailExtract ();
use Homelab::Calendar::Consent ();

our @EXPORT_OK = qw(looks_like_event reminder_message);

# The calendar's background work (#79, #80), run from a timer inside every
# hypnotoad worker -- the same recurring-timer + FOR UPDATE SKIP LOCKED shape
# as homelab-worker's job runner and homelab-domain-admin's timers, so the six
# processes on the three pool nodes share one queue in Postgres and nothing
# runs twice. Three duties each tick, each in its own eval so one failing
# never stops the others:
#
#   1. reminders: queue the next 48 h of occurrences for events that have a
#      reminder (owner + everyone the calendar or event is shared with), then
#      send what is due -- by email, through the fleet's submission VIP
#      (Homelab::Common::Mailer), a few per tick so a slow SMTP server cannot
#      hold the event loop for long.
#   2. proposals at arrival: links whose email came for an account with
#      consent #3 get the AI proposal (and, when entitled and switched on,
#      the research step) WITHOUT blocking: the AI calls are promises, the
#      row is the job record, a small in-flight cap keeps a burst of mail
#      from queueing dozens of calls in one process.
#
# Not homelab-worker: that would need three new credentials (the worker
# calling the AI service, the calendar submitting jobs, the worker writing
# results back) for a call that is an outbound HTTP request the calendar
# can already make without blocking. The row-as-job pattern here is the
# worker's own; if the load ever grows past one process's comfort, the
# claim/complete methods in Model.pm are the seam to move it across.

has 'model';
has 'ai';
has 'mailer';            # the config hash (email, smtp_host, smtp_port, smtp_password) or undef
has 'log';
has public_base_url => 'https://calendar.example';
has default_zone    => 'America/Chicago';
has interval        => 30;
has reminder_batch  => 3;        # sends per tick per process
has horizon_hours   => 48;       # how far ahead occurrences are queued
has propose_max     => 2;        # AI calls in flight per process
has in_flight       => 0;
has _last_err       => sub { {} };

sub start ($self) {
    # A little jitter so six processes do not all wake on the same second.
    Mojo::IOLoop->timer(10 + rand(10) => sub {
        $self->tick;
        Mojo::IOLoop->recurring($self->interval => sub { $self->tick });
    });
    return $self;
}

sub tick ($self) {
    $self->_guard('reminders' => sub { $self->run_reminders });
    $self->_guard('proposals' => sub { $self->run_proposals });
    return;
}

# One line per failure kind per five minutes: a database outage must not
# fill the journal at two lines a second across six processes.
sub _guard ($self, $what, $code) {
    my $ok = eval { $code->(); 1 };
    return 1 if $ok;
    my $err = $@ =~ s/\s+\z//r;
    my $last = $self->_last_err->{$what} // 0;
    if (time - $last > 300) {
        $self->log->warn("calendar runner: $what failed (quiet for 5 min): $err") if $self->log;
        $self->_last_err->{$what} = time;
    }
    return 0;
}

# ----------------------------------------------------------------- reminders

sub run_reminders ($self) {
    my $m = $self->model;
    $m->reclaim_stale_reminders;
    $self->queue_upcoming;
    return unless $self->mailer;      # nothing to send with: rows wait in the queue
    for my $row (@{ $m->claim_due_reminders($self->reminder_batch) }) {
        my $ok = eval { $self->send_reminder($row); 1 };
        if ($ok) { $m->reminder_sent($row->{id}) }
        else {
            my $err = $@ =~ s/\s+\z//r;
            $self->log->warn("calendar runner: reminder $row->{id} to $row->{recipient} failed: $err") if $self->log;
            $m->reminder_failed($row->{id}, $err);
        }
    }
    return;
}

# Every occurrence inside the horizon of every event with a reminder, for
# the owner and everyone it is shared with. Idempotent: the queue's unique
# key makes a second pass a no-op.
sub queue_upcoming ($self) {
    my $m = $self->model;
    my $now = DateTime->now(time_zone => 'UTC');
    my $we  = $now->clone->add(hours => $self->horizon_hours);
    for my $e (@{ $m->reminder_candidates($now, $we) }) {
        my @accounts = (lc $e->{calendar_owner}, @{ $m->shared_with_accounts($e) });
        my %seen; @accounts = grep { !$seen{$_}++ } @accounts;
        for my $inst (@{ $m->instances(events => [$e], window_start => $now, window_end => $we) }) {
            my $due = due_at($inst, $e->{minutes_before});
            next if $inst->{start} <= $now && !$inst->{all_day};     # already begun: too late to remind
            next if $inst->{all_day} && $due < $now->clone->subtract(hours => 1);
            $due = $now->clone if $due < $now;                          # created late: send at once
            my $rid = $inst->{recurrence_id} // $inst->{start};
            $m->queue_reminder(reminder_id => $e->{reminder_id}, event_id => $e->{id}, recurrence_id => $rid, recipient => $_, due_at => $due) for @accounts;
        }
    }
    return;
}

# When a reminder goes out: minutes before the start; for an all-day event,
# minutes before 9 in the morning of its first day (a "10 minutes before"
# at midnight would wake nobody usefully).
sub due_at ($inst, $minutes) {
    my $base = $inst->{all_day} ? $inst->{start}->clone->set(hour => 9, minute => 0, second => 0) : $inst->{start}->clone;
    return $base->subtract(minutes => $minutes // 0);
}

sub send_reminder ($self, $row) {
    my $m = $self->model;
    my $event = $m->event($row->{event_id}) or die "event $row->{event_id} is gone\n";
    my $cal = $m->calendar($event->{calendar_id}) or die "calendar $event->{calendar_id} is gone\n";
    my $rid = Homelab::Calendar::Model::_dt($row->{recurrence_id});
    # The occurrence as it is NOW (it may have moved since it was queued).
    my ($inst) = grep { ($_->{recurrence_id} // $_->{start})->epoch == $rid->epoch }
        @{ $m->instances(events => [$event], window_start => $rid->clone->subtract(days => 2), window_end => $rid->clone->add(days => 2)) };
    die "occurrence no longer exists\n" unless $inst;
    my $prefs = $m->prefs($row->{recipient});
    my $zone  = (defined $prefs->{timezone} && validate_zone($prefs->{timezone})) ? $prefs->{timezone} : $event->{timezone};
    my $msg = reminder_message(
        inst => $inst, zone => $zone, minutes => $row->{minutes_before} // ($m->reminder_for($event->{id}) // {})->{minutes_before},
        owner => $cal->{owner_email}, recipient => $row->{recipient}, base_url => $self->public_base_url,
        now => DateTime->now(time_zone => $zone),
    );
    require Homelab::Common::Mailer;
    my $mail = $self->mailer;
    for my $to (@{ $m->reminder_recipients($row->{recipient}) }) {
        Homelab::Common::Mailer::send_mail(
            smtp_host => $mail->{smtp_host}, smtp_port => $mail->{smtp_port} // 587,
            from_email => $mail->{email}, from_password => $mail->{smtp_password},
            to => $to, subject => $msg->{subject}, body => $msg->{body},
        );
    }
    return 1;
}

# The plain-text reminder, as one subject and one body. Pure, so t/runner.t
# can read it.
#   inst (start, end DateTime; all_day; title; location; description), zone,
#   minutes, owner, recipient, base_url, now (DateTime in zone)
sub reminder_message (%a) {
    my $inst = $a{inst};
    my $zone = $a{zone} // 'UTC';
    my $s = $inst->{start}->clone->set_time_zone($zone);
    my $e = $inst->{end}->clone->set_time_zone($zone);
    my $now = $a{now} ? $a{now}->clone->set_time_zone($zone) : DateTime->now(time_zone => $zone);
    my $title = $inst->{title} // '(no title)';

    my $when;
    my $day = $s->ymd eq $now->ymd ? 'today' : $s->ymd eq $now->clone->add(days => 1)->ymd ? 'tomorrow' : $s->strftime('%a, %b ') . $s->day;
    if ($inst->{all_day}) {
        my $last = $e->clone->subtract(days => 1);
        $when = $last->ymd gt $s->ymd ? $s->strftime('%A, %B ') . $s->day . ' to ' . $last->strftime('%A, %B ') . $last->day . ', ' . $last->year
                                      : $s->strftime('%A, %B ') . $s->day . ', ' . $s->year . ' (all day)';
    }
    else {
        my $same = $s->ymd eq $e->ymd;
        $when = $s->strftime('%A, %B ') . $s->day . ', ' . $s->year . ' ' . _clock($s) . ' to ' . ($same ? '' : $e->strftime('%A, %B ') . $e->day . ' ') . _clock($e)
              . ' (' . ($zone =~ s/_/ /gr) . ')';
    }
    my $subject = $inst->{all_day} ? "Reminder: $title $day" : "Reminder: $title at " . _clock($s) . " $day";

    my $lead = defined $a{minutes} ? ($a{minutes} == 0 ? 'at the time it starts' : _lead($a{minutes}) . ' before') : '';
    my @lines = ($title, $when);
    if (defined $inst->{location} && length $inst->{location}) {
        push @lines, "Where: $inst->{location}";
        my $q = $inst->{location} =~ s/\s+/ /gr =~ s/^\s+|\s+$//gr;
        $q =~ s/([^A-Za-z0-9\-._~ ])/sprintf('%%%02X', ord $1)/ge; $q =~ tr/ /+/;
        push @lines, "Map: https://www.google.com/maps/search/?api=1&query=$q";
    }
    push @lines, '', substr($inst->{description} =~ s/\r//gr, 0, 1000) if defined $inst->{description} && $inst->{description} =~ /\S/;
    push @lines, '', "Open your calendar: $a{base_url}/";
    my $mine = lc($a{owner} // '') eq lc($a{recipient} // '');
    push @lines, '', $mine ? "You set a reminder on this event" . ($lead ? " ($lead)." : '.')
                           : "$a{owner} shared this event with you; its reminder" . ($lead ? " ($lead)" : '') . " reaches you too.";
    push @lines, "Where reminders go, and turning them off: $a{base_url}/settings";
    return { subject => $subject, body => join("\n", @lines) . "\n" };
}

sub _clock ($dt) { my $h = $dt->hour % 12 || 12; return sprintf('%d:%02d %s', $h, $dt->minute, $dt->hour < 12 ? 'AM' : 'PM') }
sub _lead ($min) {
    return "$min minute" . ($min == 1 ? '' : 's') if $min < 60;
    return int($min / 60) . ' hour' . ($min == 60 ? '' : 's') if $min < 1440 && $min % 60 == 0;
    return int($min / 1440) . ' day' . ($min == 1440 ? '' : 's') if $min % 1440 == 0;
    return "$min minutes";
}

# ------------------------------------------------------ proposals at arrival

my $EVENT_WORDS = qr/\b(?:meeting|meet(?:ing)?\s+up|appointment|appt|game|match|tournament|practice|rehearsal|recital|concert|show|performance|
    conference|webinar|seminar|workshop|class|lesson|session|training|interview|call|zoom|teams|hangout|invite|invitation|invited|
    rsvp|save\s+the\s+date|reservation|booking|booked|tickets?|party|dinner|lunch|brunch|breakfast|happy\s+hour|reunion|wedding|
    birthday|anniversary|ceremony|graduation|service|visit|tour|open\s+house|deadline|due\s+(?:on|by)|schedule[ds]?|reschedule[ds]?|
    calendar|agenda|event|kick-?off|launch|flight|departs?|arriv(?:es|al)|check-?in|pickup|pick\s+up|drop-?off)\b/ix;

# The plain-parse gate (#80): only email that LOOKS like it carries an event
# is sent anywhere. A date or a time in the text, or one of the words above.
# Pure, exported for the tests.
sub looks_like_event ($subject, $text, %o) {
    my $hay = (($subject // '') . "\n" . substr($text // '', 0, 20000)) =~ s/\r//gr;
    return 0 if $hay !~ /\S/;
    # Bulk and transactional noise rarely carries an event worth proposing.
    return 0 if ($subject // '') =~ /\b(?:unsubscribe|newsletter|receipt|invoice|statement|password|verification code|your order|shipped|delivery update)\b/i;
    my $g = Homelab::Calendar::MailExtract::guess(subject => $subject, text => $text, zone => $o{zone} // 'UTC', now => $o{now});
    my $src = ($g && $g->{source}) // '';
    return 1 if $src =~ /^(?:iso date|numeric date|month name|day month|tomorrow)$/;
    return 1 if $src eq 'weekday' && $hay =~ $EVENT_WORDS;
    return 1 if $hay =~ /\b\d{1,2}(?::\d{2})?\s*(?:a\.?m\.?|p\.?m\.?)\b/i;
    return 1 if $hay =~ /\b(?:at|@)\s*\d{1,2}(?::\d{2})\b/;
    return 1 if $hay =~ $EVENT_WORDS && $hay =~ /\b(?:mon|tue|wed|thu|fri|sat|sun)[a-z]*\b|\btomorrow\b|\btonight\b|\bnext week\b|\bthis week(?:end)?\b|\b\d{1,2}\/\d{1,2}\b/i;
    return 0;
}

sub run_proposals ($self) {
    return unless $self->ai && $self->ai->configured;
    my $m = $self->model;
    $m->reclaim_stale_mail_link_jobs;
    my $room = $self->propose_max - $self->in_flight;
    return if $room <= 0;
    my $sha = Homelab::Calendar::Consent::auto_notice_sha256();
    for my $link (@{ $m->claim_mail_links_for_proposal($sha, $room) }) {
        my $accounts = $m->auto_propose_accounts($link, $sha);
        unless (@$accounts) { $m->mail_link_skipped($link->{id}); next }
        my $acct = $accounts->[0];
        my $zone = (defined $acct->{timezone} && validate_zone($acct->{timezone})) ? $acct->{timezone} : $self->default_zone;
        unless (looks_like_event($link->{subject}, $link->{text_excerpt}, zone => $zone, now => DateTime->now(time_zone => $zone))) {
            $m->mail_link_skipped($link->{id});
            next;
        }
        $self->propose_link($link, $acct, $zone, $sha);
    }
    return;
}

# One link: the proposal, then (entitled, switched on, consented, and worth
# it) the research step; each step writes its result as it lands.
sub propose_link ($self, $link, $acct, $zone, $sha) {
    my $m = $self->model;
    $self->in_flight($self->in_flight + 1);
    my $done = sub { $self->in_flight($self->in_flight - 1) };
    $self->ai->propose_p(
        subject => $link->{subject}, from => $link->{from_addr}, date_header => $link->{date_header}, text => $link->{text_excerpt},
        zone => $zone, now => DateTime->now(time_zone => $zone), consent_sha => $sha, consent_kind => 'auto', account_key => $acct->{user_email},
    )->then(sub ($r) {
        unless ($r->{ok}) {
            $self->log->warn("calendar runner: proposal for link $link->{id} failed: " . ($r->{error} // '?')) if $self->log;
            $m->mail_link_job_failed($link->{id});
            return;
        }
        my $p = $r->{proposal};
        $p->{zone} = $zone;      # the wall clocks' zone, for a later Save
        $m->mail_link_proposed($link->{id}, $p);
        $self->log->info("calendar runner: proposed link $link->{id} ($p->{confidence})") if $self->log;
        my $want = $acct->{research} && $p->{research} && $p->{research}{worth_it}
            && defined $acct->{research_consent_sha256} && $acct->{research_consent_sha256} eq Homelab::Calendar::Consent::research_notice_sha256();
        return unless $want;
        return $self->ai->research_p(
            subject => $link->{subject}, from => $link->{from_addr}, text => $link->{text_excerpt},
            about => $p->{research}{about}, query => $p->{research}{query},
            zone => $zone, now => DateTime->now(time_zone => $zone), consent_sha => $acct->{research_consent_sha256}, account_key => $acct->{user_email},
        )->then(sub ($rr) {
            if ($rr->{ok}) {
                $m->mail_link_facts($link->{id}, { summary => $rr->{summary}, facts => $rr->{facts}, searches => $rr->{searches} });
                $self->log->info("calendar runner: researched link $link->{id} (" . scalar(@{ $rr->{facts} }) . " facts)") if $self->log;
            }
            else { $self->log->warn("calendar runner: research for link $link->{id} failed: " . ($rr->{error} // '?')) if $self->log }
        });
    })->catch(sub ($e) {
        $self->log->warn("calendar runner: link $link->{id}: $e") if $self->log;
        eval { $m->mail_link_job_failed($link->{id}) };
    })->finally($done);
    return;
}

1;
