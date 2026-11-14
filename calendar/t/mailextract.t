use Mojo::Base -strict, -signatures;
use Test::More;
use DateTime;

# The plain parse of an email into a pre-filled event (what the person sees
# without AI). Best effort, but the common shapes must land.

use lib 'lib';
use_ok 'Homelab::Calendar::MailExtract', qw(guess clean_subject);
use_ok 'Homelab::Calendar::Consent', qw(notice_body notice_sha256 record);

my $now = DateTime->new(year => 2026, month => 11, day => 14, hour => 10, time_zone => 'America/Chicago');   # a Saturday
sub g (%a) { return guess(zone => 'America/Chicago', now => $now, %a) }

is clean_subject('Re: Fwd: RE: Lunch Friday'), 'Lunch Friday', 'reply and forward prefixes stripped';
is clean_subject('[team] Standup'), 'Standup', 'a list tag stripped';
is clean_subject("  Spaces   everywhere \n"), 'Spaces everywhere', 'whitespace squeezed';

my $r = g(subject => 'Dentist', text => 'Your appointment is on 11/20/2026 at 3:30 PM at the Main St office.');
is $r->{title}, 'Dentist', 'title from the subject';
is_deeply [ @$r{qw(all_day start end)} ], [0, '2026-11-20T15:30:00', '2026-11-20T16:30:00'], 'numeric date + 12-hour time, one hour long';

$r = g(subject => 'Re: Team offsite', text => 'The offsite is November 20th, 9am-4pm. Location: Lake House');
is_deeply [ @$r{qw(all_day start end)} ], [0, '2026-11-20T09:00:00', '2026-11-20T16:00:00'], 'month name + a time range with one am/pm';
is $r->{location}, 'Lake House', 'a "Location:" line';
is $r->{title}, 'Team offsite', 'the subject without Re:';

$r = g(subject => 'Conference', text => 'See you at the conference 2027-03-02 to 2027-03-04.');
is_deeply [ @$r{qw(all_day start end)} ], [1, '2027-03-02', '2027-03-03'], 'an ISO date with no time: all-day on that day';

$r = g(subject => 'Call', text => 'Can we talk tomorrow at 10?');
is_deeply [ @$r{qw(all_day start end)} ], [0, '2026-11-15T10:00:00', '2026-11-15T11:00:00'], '"tomorrow at 10"';

$r = g(subject => 'Lunch', text => 'Lunch next Friday at noon?');
is_deeply [ @$r{qw(all_day start end)} ], [0, '2026-11-20T12:00:00', '2026-11-20T13:00:00'], 'a weekday name is the next such day; noon';

$r = g(subject => 'Reminder', text => 'Rent is due on the 1st of December.');
is_deeply [ @$r{qw(all_day start)} ], [1, '2026-12-01'], 'day + month name';

$r = g(subject => 'Party', text => 'Party on Jan 5!');
is $r->{start}, '2027-01-05', 'a month/day already well past this year means next year';

$r = g(subject => 'Nothing datey', text => 'Hello there.');
is_deeply [ @$r{qw(all_day start)} ], [1, '2026-11-15'], 'no date at all: an all-day event tomorrow';
like $r->{source}, qr/default/, '... and it says so';

$r = g(subject => '', text => '');
is $r->{title}, 'Event from email', 'no subject: a placeholder title';

$r = g(subject => 'Meeting', text => 'at 25:99 on 2026-11-20');
is $r->{all_day}, 1, 'an impossible clock is ignored';

# --- the consent record ---
like notice_sha256(), qr/\A[0-9a-f]{64}\z/, 'the notice hashes';
like notice_body(), qr/sends one email to Anthropic/, 'the notice says what it sends';
is record(undef, 'x@y', 'not-the-current-sha'), 0, 'a stale or wrong hash is refused before any database is touched';

done_testing;
