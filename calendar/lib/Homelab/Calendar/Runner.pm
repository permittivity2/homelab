package Homelab::Calendar::Runner;
use Mojo::Base -base, -signatures;
use Mojo::IOLoop;
use Mojo::Promise;
use Mojo::URL;
use Mojo::UserAgent;
use DateTime;
use Exporter 'import';
use Homelab::Calendar::Recurrence qw(validate_zone);
use Homelab::Calendar::MailExtract ();
use Homelab::Calendar::Consent ();
use Homelab::Calendar::Invite qw(request_message cancel_message reply_notice_message event_ics);

our @EXPORT_OK = qw(looks_like_event reminder_message event_score);

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
# #92: the holidays calendar. The config's holidays: block -- enabled (1),
# years_ahead (10), every (seconds between looks, 3600), check_url (Nager.Date
# with %d for the year; 0 turns the watchdog off).
has holidays        => sub { {} };
has ua              => sub { Mojo::UserAgent->new->connect_timeout(10)->inactivity_timeout(30)->request_timeout(30)->max_redirects(2) };
has _holidays_next  => 0;

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
    $self->_guard('notices'   => sub { $self->run_notices });
    $self->_guard('proposals' => sub { $self->run_proposals });
    $self->_guard('holidays'  => sub { $self->run_holidays });
    return;
}

# ------------------------------------------------------------- holidays (#92)

# The built-in holidays calendar: filled from the rules on the first tick
# after an install and looked at hourly after that (one row read when nothing
# changed: the fill skips itself while its window and digest are the same;
# a New Year adds a year and retires the oldest). Then the watchdog.
sub run_holidays ($self) {
    my $h = $self->holidays // {};
    return if defined $h->{enabled} && !$h->{enabled};
    return if time < $self->_holidays_next;
    $self->_holidays_next(time + ($h->{every} // 3600));
    my $r = $self->model->fill_holidays(years_ahead => ($h->{years_ahead} // 10));
    $self->log->info("calendar runner: holidays $r->{from}-$r->{through} filled: $r->{written} written, $r->{removed} retired") if $r->{ran} && $self->log;
    $self->check_holidays;
    return;
}

# Once a year, for this year and the next: Nager.Date's national public
# holidays, compared by name with the rules' federal set
# (Homelab::Calendar::Holidays::unknown_national_names). A name the rules do
# not know is kept on the year's row (Settings shows it, /metrics counts it,
# Prometheus alerts). Asked without blocking; the first process to claim the
# year asks, a failed fetch is retried a day later, and nothing here touches
# the holidays shown. Returns the promises, for the tests to wait on.
sub check_holidays ($self, $year = undef) {
    my $h = $self->holidays // {};
    my $url = exists $h->{check_url} ? $h->{check_url} : 'https://date.nager.at/api/v3/PublicHolidays/%d/US';
    return [] unless defined $url && length $url && $url ne '0';
    my $m = $self->model;
    $year //= DateTime->now(time_zone => $self->default_zone)->year;
    my @p;
    for my $y ($year, $year + 1) {
        next unless $m->claim_holiday_check($y);
        my $u = sprintf $url, $y;
        push @p, $self->ua->get_p($u => { Accept => 'application/json' })->then(sub ($tx) {
            my $res = $tx->res;
            die 'HTTP ' . ($res->code // 'no answer') . ' from ' . Mojo::URL->new($u)->host . "\n" unless $res->is_success;
            my $rows = $res->json;
            die "the answer is not a list of holidays\n" unless ref $rows eq 'ARRAY';
            require Homelab::Calendar::Holidays;
            my $unknown = Homelab::Calendar::Holidays::unknown_national_names($rows);
            $m->holiday_check_done($y, $unknown, scalar(@$rows) . ' rows from ' . Mojo::URL->new($u)->host);
            if ($self->log) {
                $self->log->warn("calendar runner: holidays check $y: national public holidays the rules do not know: " . join(', ', @$unknown)) if @$unknown;
                $self->log->info("calendar runner: holidays check $y: nothing the rules do not know") unless @$unknown;
            }
        })->catch(sub ($err) {
            $err = ($err // 'failed') =~ s/\s+\z//r;
            $m->holiday_check_failed($y, $err);
            $self->log->warn("calendar runner: holidays check $y failed (asked again tomorrow): $err") if $self->log;
        });
    }
    return \@p;
}

# ----------------------------------------------------------- invitations (#85)

# Answers that came by mail are applied first (the milter's inbox rows), so
# the organizer's note about one goes out in the same tick; then the queued
# invitations, cancellations and notes, a few per tick as reminders are.
sub run_notices ($self) {
    my $m = $self->model;
    $m->reclaim_stale_notices;
    for my $row (@{ $m->claim_itip_inbox(10) }) {
        my $res = eval { $m->apply_itip_reply($row) };
        $res = 'failed: ' . ($@ =~ s/\s+\z//r) unless defined $res;
        $m->itip_result($row->{id}, $res);
        $self->log->info("calendar runner: mailed answer $row->{id} from $row->{attendee_email}: $res") if $self->log;
    }
    return unless $self->mailer;
    for my $row (@{ $m->claim_due_notices($self->reminder_batch) }) {
        my $ok = eval { $self->send_notice($row); 1 };
        if ($ok) { $m->notice_sent($row->{id}) }
        else {
            my $err = $@ =~ s/\s+\z//r;
            $self->log->warn("calendar runner: $row->{kind} notice $row->{id} to $row->{recipient} failed: $err") if $self->log;
            $m->notice_failed($row->{id}, $err);
        }
    }
    return;
}

# One queued notice, rendered from the event as it is now.
sub send_notice ($self, $row) {
    my $m = $self->model;
    my $event = $m->db->query('SELECT * FROM calendar.events WHERE id = ?', $row->{event_id})->hash or die "event $row->{event_id} is gone\n";
    my $cal   = $m->db->query('SELECT * FROM calendar.calendars WHERE id = ?', $event->{calendar_id})->hash or die "calendar $event->{calendar_id} is gone\n";
    my $organizer = lc $cal->{owner_email};
    my $base = $self->public_base_url;
    my $attendees = $m->attendees_for($event->{id});
    my %common = (event => $event, start => $m->event_start($event), end => $m->event_end($event), organizer => $organizer,
        base_url => $base, payload => $row->{payload}, now => DateTime->now(time_zone => 'UTC'));
    my $url = "$base/?date=" . $common{start}->ymd . "&event=$event->{id}";

    if ($row->{kind} eq 'reply') {
        # To the organizer: who answered what; the webhook too when they set one.
        die "event is gone\n" if $event->{deleted_at};
        my $msg = reply_notice_message(%common, url => $url, counts => $m->attendee_counts([ $event->{id} ])->{ $event->{id} });
        $self->_send($row->{recipient}, $msg);
        my $prefs = $m->prefs($row->{recipient});
        if (($prefs->{webhook_url} // '') =~ /\S/) {
            my $p = $row->{payload};
            eval { $self->post_webhook($prefs->{webhook_url}, {
                type => 'rsvp', recipient => $row->{recipient}, event_id => $event->{id} + 0, url => $url, title => $event->{title},
                attendee => $p->{attendee}, name => $p->{name}, status => $p->{status}, comment => $p->{comment},
                subject => $msg->{subject}, text => $msg->{body},
            }) } or $self->log->warn("calendar runner: rsvp webhook for $row->{recipient} failed: $@") if $self->log;
        }
        return 1;
    }

    # A request or a cancel, to one attendee. Someone taken off the list has
    # no row any more: the payload carries their name, the mail still goes.
    my $att = $m->attendee_of($event->{id}, $row->{recipient})
           // { email => lc $row->{recipient}, name => $row->{payload}{name}, status => 'needs-action', token => undef };
    my $cancel = $row->{kind} eq 'cancel';
    unless ($cancel) {
        die "no longer invited\n" unless $att->{token};
        die "event is gone\n" if $event->{deleted_at};
    }
    my ($ex, $ov) = $m->series_parts($event);
    my $seq = $cancel ? ($row->{payload}{sequence} // $event->{sequence}) : $event->{sequence};
    my $ics = event_ics(%common, method => ($cancel ? 'CANCEL' : 'REQUEST'), exdates => $ex, overrides => $ov, sequence => $seq,
        attendees => [ map { { email => $_->{email}, name => $_->{name}, status => $_->{status} } } (@$attendees, ($att->{token} ? () : $att)) ],
        url => ($att->{token} ? "$base/i/$att->{token}" : undef),
        created => Homelab::Calendar::Model::_dt($event->{created_at}), updated => Homelab::Calendar::Model::_dt($event->{updated_at}));
    my $msg = $cancel ? cancel_message(%common, attendee => $att, attendees => $attendees)
                      : request_message(%common, attendee => $att, attendees => $attendees);
    $self->_send($att->{email}, $msg, calendar => { method => ($cancel ? 'CANCEL' : 'REQUEST'), ics => $ics }, reply_to => $organizer);
    $m->attendee_mark_sent($event->{id}, $att->{email}, $seq) unless $cancel;
    return 1;
}

sub _send ($self, $to, $msg, %extra) {
    require Homelab::Common::Mailer;
    my $mail = $self->mailer;
    Homelab::Common::Mailer::send_mail(
        smtp_host => $mail->{smtp_host}, smtp_port => $mail->{smtp_port} // 587,
        from_email => $mail->{email}, from_password => $mail->{smtp_password},
        to => $to, subject => $msg->{subject}, body => $msg->{body}, %extra,
    );
    return 1;
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
    my %prefs;    # each account's preferences, read once per tick
    my $pref = sub ($acct) { return $prefs{$acct} //= $m->prefs($acct) };
    for my $e (@{ $m->reminder_candidates($now, $we) }) {
        # The owner always; someone the event is shared with unless they
        # turned reminders for shared events off (0.2.0).
        my @accounts = (lc $e->{calendar_owner}, grep { $pref->($_)->{remind_shared} } @{ $m->shared_with_accounts($e) });
        my %seen; @accounts = grep { !$seen{$_}++ } @accounts;
        for my $inst (@{ $m->instances(events => [$e], window_start => $now, window_end => $we) }) {
            next if $inst->{start} <= $now && !$inst->{all_day};     # already begun: too late to remind
            my $rid = $inst->{recurrence_id} // $inst->{start};
            for my $acct (@accounts) {
                # An all-day event reminds at the hour this account chose (9 AM unless changed).
                my $due = due_at($inst, $e->{minutes_before}, $pref->($acct)->{all_day_reminder_hour});
                next if $inst->{all_day} && $due < $now->clone->subtract(hours => 1);
                $due = $now->clone if $due < $now;                      # created late: send at once
                $m->queue_reminder(reminder_id => $e->{reminder_id}, event_id => $e->{id}, recurrence_id => $rid, recipient => $acct, due_at => $due);
            }
        }
    }
    return;
}

# When a reminder goes out: minutes before the start; for an all-day event,
# minutes before $hour o'clock (9 unless the account chose otherwise) of its
# first day: a "10 minutes before" at midnight would wake nobody usefully.
sub due_at ($inst, $minutes, $hour = 9) {
    $hour = 9 unless defined $hour && $hour =~ /\A\d{1,2}\z/ && $hour <= 23;
    my $base = $inst->{all_day} ? $inst->{start}->clone->set(hour => $hour, minute => 0, second => 0) : $inst->{start}->clone;
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
    # The clock the mail is written in (#88/#89): a pinned event's own zone;
    # otherwise the fixed zone the person chose, else the zone their device
    # last reported (Local), else the event's own.
    my $zone  = $event->{pinned} ? $event->{timezone}
              : (defined $prefs->{timezone} && validate_zone($prefs->{timezone})) ? $prefs->{timezone}
              : (defined $prefs->{device_zone} && validate_zone($prefs->{device_zone})) ? $prefs->{device_zone}
              : $event->{timezone};
    my $rem   = $m->reminder_by_id($row->{reminder_id}) // {};
    my $s_loc = $inst->{start}->clone->set_time_zone($zone);
    # A deep link: the page opens on the day with this event highlighted (0.2.0).
    my $url = $self->public_base_url . '/?date=' . $s_loc->ymd . '&event=' . $event->{id}
            . ($inst->{recurrence_id} ? '&rid=' . $inst->{recurrence_id}->clone->set_time_zone('UTC')->strftime('%Y-%m-%dT%H:%M:%SZ') : '');
    my $msg = reminder_message(
        inst => $inst, zone => $zone, minutes => $rem->{minutes_before},
        owner => $cal->{owner_email}, recipient => $row->{recipient}, base_url => $self->public_base_url, event_url => $url,
        now => DateTime->now(time_zone => $zone),
    );
    # The webhook channel (0.2.0): one JSON POST to the recipient's own URL;
    # without one set, the reminder goes by email after all.
    if (($rem->{channel} // 'email') eq 'webhook' && ($prefs->{webhook_url} // '') =~ /\S/) {
        $self->post_webhook($prefs->{webhook_url}, {
            type => 'reminder', recipient => $row->{recipient}, event_id => $event->{id} + 0, url => $url,
            title => $inst->{title}, location => $inst->{location}, description => $inst->{description},
            all_day => ($inst->{all_day} ? \1 : \0), timezone => $zone,
            start => Homelab::Calendar::Recurrence::wall_string($s_loc, $inst->{all_day}),
            end   => Homelab::Calendar::Recurrence::wall_string($inst->{end}->clone->set_time_zone($zone), $inst->{all_day}),
            minutes_before => (defined $rem->{minutes_before} ? $rem->{minutes_before} + 0 : undef),
            subject => $msg->{subject}, text => $msg->{body},
        });
        return 1;
    }
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
    push @lines, '', 'Open this event: ' . ($a{event_url} // "$a{base_url}/");
    my $mine = lc($a{owner} // '') eq lc($a{recipient} // '');
    push @lines, '', $mine ? "You set a reminder on this event" . ($lead ? " ($lead)." : '.')
                           : "$a{owner} shared this event with you; its reminder" . ($lead ? " ($lead)" : '') . " reaches you too.";
    push @lines, "Where reminders go, and turning them off: $a{base_url}/settings";
    return { subject => $subject, body => join("\n", @lines) . "\n" };
}

# One JSON POST, ten seconds, a 2xx or die (the queue retries three times).
sub post_webhook ($self, $url, $payload) {
    require Mojo::UserAgent;
    my $ua = Mojo::UserAgent->new(connect_timeout => 5, request_timeout => 10, max_redirects => 0);
    my $res = $ua->post($url, { 'User-Agent' => 'homelab-calendar' }, json => $payload)->result;
    die 'webhook answered ' . $res->code . "\n" unless $res->is_success;
    return 1;
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

# Subject words of transactional mail: a weight against, never a veto (#99:
# "Your receipt and tickets for ..." is a game).
my $NOISE_WORDS = qr/\b(?:unsubscribe|newsletter|receipt|invoice|statement|password|verification code|your order|shipped|delivery update)\b/i;
# Machines writing to a person: timestamps everywhere, events seldom.
my $AUTOMATED_FROM = qr/\b(?:no-?reply|donotreply|do-not-reply|notifications?|alerts?|mailer-daemon|systemmessage)\b/i;
# The calendar's own mail about events the person already knows, and the
# fleet's alert mail from the same mailbox: never proposed back.
my $OWN_SUBJECT = qr/^\s*(?:Reminder|Cancelled|No longer invited|Updated invitation):\s/;
my $ALERT_SUBJECT = qr/^\s*\[homelab\]\s+(?:FIRING|RESOLVED)\b/;

# The gate (#80, a score since #99): only email that LOOKS like it carries an
# event is sent anywhere. Weights, not vetoes: a date, a time, an event word
# and a day reference count for; a transactional subject, an automated sender
# and a sender this person keeps dismissing count against. The AI then decides
# for real (the prompt lets it say "not an event"); this only keeps obvious
# noise from costing a call. Returns (score, why). Pure, exported for the tests.
sub event_score ($subject, $text, %o) {
    my $hay = (($subject // '') . "\n" . substr($text // '', 0, 20000)) =~ s/\r//gr;
    return (0, 'empty') if $hay !~ /\S/;
    my $from = lc($o{from} // ''); my $own = lc($o{own_from} // '');
    if (length $own && index($from, $own) >= 0) {
        return (-99, "the calendar's own mail") if ($subject // '') =~ $OWN_SUBJECT;
        return (-99, 'a fleet alert') if ($subject // '') =~ $ALERT_SUBJECT;
    }
    my ($score, @why) = (0);
    my $g = Homelab::Calendar::MailExtract::guess(subject => $subject, text => $text, zone => $o{zone} // 'UTC', now => $o{now});
    my $src = ($g && $g->{source}) // '';
    if ($hay =~ $EVENT_WORDS)                                               { $score += 2; push @why, 'an event word' }
    if ($src =~ /^(?:iso date|numeric date|month name|day month|tomorrow)$/) { $score += 2; push @why, "a date ($src)" }
    if ($hay =~ /\b\d{1,2}(?::\d{2})?\s*(?:a\.?m\.?|p\.?m\.?)\b/i || $hay =~ /\b(?:at|@)\s*\d{1,2}:\d{2}\b/) { $score += 2; push @why, 'a time' }
    if ($hay =~ /\b(?:mon|tue|wed|thu|fri|sat|sun)[a-z]*\b|\btonight\b|\bnext week\b|\bthis week(?:end)?\b/i) { $score += 1; push @why, 'a day' }
    if (($subject // '') =~ $NOISE_WORDS)                                   { $score -= 2; push @why, 'a transactional subject' }
    if ($from =~ $AUTOMATED_FROM)                                           { $score -= 2; push @why, 'an automated sender' }
    if (($o{dismissed_before} // 0) >= 3)                                   { $score -= 2; push @why, "$o{dismissed_before} dismissed from this sender" }
    return ($score, join(', ', @why) || 'nothing date-like');
}

sub looks_like_event ($subject, $text, %o) {
    my ($score) = event_score($subject, $text, %o);
    return $score >= 2 ? 1 : 0;
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
        my $dismissed = $m->dismissed_from_sender($acct->{user_email}, $link->{from_addr});
        my ($score, $why) = event_score($link->{subject}, $link->{text_excerpt}, zone => $zone, now => DateTime->now(time_zone => $zone),
            from => $link->{from_addr}, own_from => ($self->mailer ? $self->mailer->{email} : ''), dismissed_before => $dismissed);
        if ($score < 2) {
            $m->mail_link_skipped($link->{id});
            $self->log->info("calendar runner: link $link->{id} skipped by the gate (score $score: $why)") if $self->log;
            next;
        }
        $self->propose_link($link, $acct, $zone, $sha, $dismissed);
    }
    return;
}

# One link: the proposal, then (entitled, switched on, consented, and worth
# it) the research step; each step writes its result as it lands.
sub propose_link ($self, $link, $acct, $zone, $sha, $dismissed = 0) {
    my $m = $self->model;
    $self->in_flight($self->in_flight + 1);
    my $done = sub { $self->in_flight($self->in_flight - 1) };
    $self->ai->propose_p(
        subject => $link->{subject}, from => $link->{from_addr}, date_header => $link->{date_header}, text => $link->{text_excerpt},
        zone => $zone, now => DateTime->now(time_zone => $zone), consent_sha => $sha, consent_kind => 'auto', account_key => $acct->{user_email},
        dismissed_before => $dismissed,
    )->then(sub ($r) {
        unless ($r->{ok}) {
            $self->log->warn("calendar runner: proposal for link $link->{id} failed: " . ($r->{error} // '?')) if $self->log;
            $m->mail_link_job_failed($link->{id});
            return;
        }
        my $p = $r->{proposal};
        $p->{zone} = $zone;      # the wall clocks' zone, for a later Save
        $m->mail_link_proposed($link->{id}, $p);
        $self->log->info("calendar runner: proposed link $link->{id} (event " . ($p->{event} ? 'yes' : 'no') . ", $p->{confidence}" . ($p->{why} ? ": $p->{why}" : '') . ")") if $self->log;
        # No research for what the model says is not an event (#99).
        my $want = $p->{event} && $acct->{research} && $p->{research} && $p->{research}{worth_it}
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
