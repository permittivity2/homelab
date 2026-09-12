package Homelab::MailBridge::App;
use Mojo::Base 'Mojolicious', -signatures;

use Homelab::Common::Config qw(load_config);
use Homelab::Common::DB qw(runtime_pg);
use Homelab::Common::Health qw(mount_health_route);
use Homelab::Common::Registry qw(register);
use Homelab::Common::AuditClient qw(enqueue);

has 'api_base';
has 'mail_config';
has 'pg';

# Stateless, internal-only relay between homelab-api's gateway routes
# (/api/v1/mail/*, see ../../api/README.md) and dovecot/postfix's real
# IMAP/SMTP ports -- moved here from homelab-cli's own client-side
# imaplib/smtplib code (see README.md) so a script never needs to know
# mail's address at all, only homelab-api's. Still no mail-related
# database of its own -- every mail request is a fresh IMAP/SMTP round
# trip, nothing persisted. The one exception, added for the audit
# trail: a minimal Postgres connection whose ONLY grant is INSERT on
# audit.queue (see homelab-audit-grant-queue-insert) -- an otherwise-
# unused, empty `mailbridge` schema exists purely because the standard
# two-role bootstrap always pairs a role with one, not because this
# app has any tables of its own.
sub startup ($self) {
    my $config = load_config('HOMELAB_MAILBRIDGE_CONFIG', '/etc/homelab/mailbridge/config.yml');
    $self->config($config);

    my $srv = $config->{server} // {};
    $self->config(hypnotoad => {
        listen   => [$srv->{listen} // 'http://127.0.0.1:2510'],
        pid_file => $srv->{pid_file} // '/var/lib/homelab/mailbridge-hypnotoad.pid',
        workers  => $srv->{workers} // 2,
    });

    $self->api_base($config->{homelab_api}{base_url} // die "config: homelab_api.base_url is required\n");
    $self->pg(runtime_pg(%{ $config->{database} // die "config: database.* is required (see config/mailbridge.example.yml)\n" }));

    my $mail = $config->{mail} // die "config: mail.* is required (see config/mailbridge.example.yml)\n";
    for my $key (qw(imap_host imap_port smtp_host smtp_port)) {
        die "config: mail.$key is required\n" unless defined $mail->{$key};
    }
    $self->mail_config($mail);

    mount_health_route($self, check => sub {
        $self->pg->db->query('SELECT 1');
        return 1;
    });

    my $me = $config->{registry} // {};
    if ($me->{host} && $me->{port}) {
        eval {
            register(
                api_base => $self->api_base, feature_name => 'homelab-mailbridge',
                host => $me->{host}, port => $me->{port}, health_check_url => '/health',
            );
        };
        $self->log->warn("registry registration failed (continuing anyway): $@") if $@;
    }

    # Paths match homelab-api's own /api/v1/mail/* gateway paths exactly
    # (see api/lib/Homelab/API/App.pm and Homelab::Common::Proxy) -- the
    # gateway just strips nothing and forwards the request straight
    # through to this app's internal address, no path rewriting needed
    # in either direction.
    my $r = $self->routes;
    $r->get('/api/v1/mail/messages')     ->to('mail#list_messages');
    $r->get('/api/v1/mail/messages/:uid')->to('mail#read_message');
    $r->post('/api/v1/mail/send')        ->to('mail#send_message');

    return;
}

package Homelab::MailBridge::App::Controller::Mail;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use MIME::Base64 qw(encode_base64);
use Mail::IMAPClient;
use Net::SMTP;
use Email::MIME;
use Mojo::Date;
use Mojo::UserAgent;
use Mojo::Util qw(sha1_sum);
use Homelab::Common::AuthClient qw(introspect);
use Homelab::Common::AuditClient qw(enqueue);

# Reused across requests, matching Homelab::Common::AuthClient's own
# module-level $UA convention.
my $MAIL_ALIASES_UA = Mojo::UserAgent->new(connect_timeout => 5, request_timeout => 10);

# Returns (email, jwt) on success. On failure, has already rendered a
# 401 and returns nothing -- callers use `my ($email, $jwt) =
# _authenticated_email($c) or return;`. The raw JWT itself doubles as
# the XOAUTH2 bearer token handed to dovecot/postfix below -- the same
# token the CLI already holds, and the same mechanism
# homelab-roundcube's SSO login already uses against homelab-dovecot
# (see ../../dovecot/README.md and ../../sso/README.md). Re-introspecting
# it here (rather than trusting that homelab-api's gateway already did)
# matches this project's "verify at every hop" convention -- see
# homelab-drive's own _current_email for the same reasoning.
sub _authenticated_email ($c) {
    my ($jwt) = ($c->req->headers->authorization // '') =~ /^Bearer\s+(.+)$/;
    unless ($jwt) {
        $c->render(json => { error => 'not logged in' }, status => 401);
        return;
    }
    my $result = introspect($jwt, api_base => $c->app->api_base);
    unless ($result) {
        $c->render(json => { error => 'not logged in' }, status => 401);
        return;
    }
    # Third value (jti) is new, for the audit trail (see send_message) --
    # every existing 2-variable caller silently ignores it, same
    # additive-return-list precedent used throughout this codebase.
    return ($result->{email}, $jwt, $result->{jti});
}

sub _xoauth2_string ($email, $token) {
    return "user=$email\x01auth=Bearer $token\x01\x01";
}

# Mail::IMAPClient::authenticate()'s callback must return an ALREADY
# base64-encoded string (confirmed by reading the module's own source
# for its other mechanisms, e.g. CRAM-MD5, which do the same) -- unlike
# Python's imaplib, which base64-encodes the callback's return value
# for you. Getting this wrong silently sends garbage and fails auth
# with a confusing error, not an obviously-wrong-encoding one.
sub _imap_connect ($c, $email, $token) {
    my $cfg = $c->app->mail_config;
    my $imap = Mail::IMAPClient->new(
        Server => $cfg->{imap_host},
        Port   => $cfg->{imap_port},
        # Known gap, carried over unchanged from the old client-side
        # implementation: dovecot/postfix still serve their default
        # self-signed cert on the real IMAP/SMTP ports (unlike the
        # HTTPS domains, which have real Let's Encrypt certs via
        # homelab-webproxy) -- see README.md. Connection is still
        # encrypted, just not verified against a CA.
        Ssl  => [ SSL_verify_mode => 0 ],
        # Real, stable UIDs throughout (not session-scoped sequence
        # numbers) -- a message's id stays valid across separate
        # requests, which the old client-side version didn't
        # guarantee (it used imaplib's default SEQUENCE-number search).
        Uid  => 1,
    ) or die "IMAP connect failed: $!\n";
    $imap->authenticate('XOAUTH2', sub {
        my ($challenge, $client) = @_;
        return encode_base64(_xoauth2_string($email, $token), '');
    }) or die 'IMAP XOAUTH2 auth failed: ' . $imap->LastError . "\n";
    return $imap;
}

sub list_messages ($c) {
    my ($email, $token) = _authenticated_email($c) or return;
    my $mailbox = $c->param('mailbox') // 'INBOX';
    my $limit   = $c->param('limit')   // 20;

    my @messages;
    eval {
        my $imap = _imap_connect($c, $email, $token);
        $imap->select($mailbox) or die 'select failed: ' . $imap->LastError . "\n";
        my @uids = $imap->search('ALL');
        @uids = @uids[-$limit .. -1] if @uids > $limit;
        my $headers = @uids ? $imap->parse_headers(\@uids, qw(FROM SUBJECT DATE)) : {};
        for my $uid (@uids) {
            my $h = $headers->{$uid} // {};
            # Mail::IMAPClient::parse_headers() keys its result hash by
            # whatever case the field names were requested in above
            # (FROM/SUBJECT/DATE, not From/Subject/Date) -- it builds
            # %fieldmap from the exact @fields list passed in and uses
            # THAT casing as the stored key, not the server response's
            # own casing. Reading $h->{From} here was a real, silent
            # bug: the hash entry for the uid existed (parse_headers
            # still successfully identified the message), but every
            # individual field lookup missed and fell through to the
            # '' default -- caught by an actual `homelab-cli mail list`
            # call against a real mailbox, not by any test, since a
            # mocked/fake IMAP response would have needed to reproduce
            # this exact case-key behavior to catch it.
            push @messages, {
                uid     => "$uid",
                from    => $h->{FROM}[0]    // '',
                subject => $h->{SUBJECT}[0] // '',
                date    => $h->{DATE}[0]    // '',
            };
        }
        $imap->logout;
    };
    if ($@) {
        $c->app->log->warn("mailbridge list_messages failed: $@");
        return $c->render(json => { error => 'could not list messages' }, status => 502);
    }
    return $c->render(json => \@messages);
}

sub read_message ($c) {
    my ($email, $token) = _authenticated_email($c) or return;
    my $uid     = $c->stash('uid');
    my $mailbox = $c->param('mailbox') // 'INBOX';

    my $result;
    eval {
        my $imap = _imap_connect($c, $email, $token);
        $imap->select($mailbox) or die 'select failed: ' . $imap->LastError . "\n";
        my $raw = $imap->message_string($uid);
        if (defined $raw) {
            my $msg = Email::MIME->new($raw);
            my ($body, $found) = ('', 0);
            $msg->walk_parts(sub {
                my ($part) = @_;
                return if $found || $part->subparts;
                if (($part->content_type // '') =~ m{^text/plain} && !$part->filename) {
                    $body = $part->body_str;
                    $found = 1;
                }
            });
            $result = {
                from    => $msg->header('From')    // '',
                subject => $msg->header('Subject') // '',
                date    => $msg->header('Date')    // '',
                body    => $body,
            };
        }
        $imap->logout;
    };
    if ($@) {
        $c->app->log->warn("mailbridge read_message failed: $@");
        return $c->render(json => { error => 'could not read message' }, status => 502);
    }
    return $c->render(json => { error => 'not found' }, status => 404) unless $result;
    return $c->render(json => $result);
}

sub send_message ($c) {
    my ($email, $token, $jti) = _authenticated_email($c) or return;
    my $params  = $c->req->json // {};
    my $to      = $params->{to};
    my $subject = $params->{subject};
    my $body    = $params->{body};
    # Optional -- defaults to the authenticated user's own address
    # (fully backward compatible with every caller that predates this
    # field). See ../../domain-admin/README.md's "Multi-domain send-as"
    # section for the full design.
    my $from    = $params->{from} // $email;
    unless ($to && $subject && defined $body) {
        return $c->render(json => { error => 'to, subject, and body are required' }, status => 400);
    }

    unless (_from_address_authorized($c, $email, $token, $from)) {
        return $c->render(json => { error => "not authorized to send as $from" }, status => 403);
    }

    eval {
        my $cfg = $c->app->mail_config;
        my $smtp = Net::SMTP->new($cfg->{smtp_host}, Port => $cfg->{smtp_port}, Timeout => 15)
            or die "SMTP connect failed\n";
        $smtp->hello('homelab-mailbridge');
        # Same known TLS gap as _imap_connect above.
        $smtp->starttls(SSL_verify_mode => 0) or die "STARTTLS failed\n";
        $smtp->hello('homelab-mailbridge');

        my $auth_b64 = encode_base64(_xoauth2_string($email, $token), '');
        $smtp->command('AUTH', "XOAUTH2 $auth_b64");
        $smtp->response;
        die 'SMTP XOAUTH2 auth failed: ' . $smtp->message . "\n" unless $smtp->code == 235;

        # EmailMessage-equivalent by hand: Date/Message-ID don't come
        # for free from anything here, and a message missing a Date
        # header is a real bug the old client-side version hit once
        # (found by reading a sent message back, not by inspection) --
        # see README.md.
        my $date  = Mojo::Date->new(time)->to_string;
        my $msgid = '<' . sha1_sum(time . $$ . rand()) . '@homelab-mailbridge>';
        my $raw   = "From: $from\r\nTo: $to\r\nSubject: $subject\r\nDate: $date\r\n"
                  . "Message-ID: $msgid\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n$body";

        $smtp->mail($from) or die "MAIL FROM failed\n";
        $smtp->to($to)      or die "RCPT TO failed\n";
        $smtp->data         or die "DATA failed\n";
        $smtp->datasend($raw) or die "datasend failed\n";
        $smtp->dataend      or die "dataend failed\n";
        $smtp->quit;
    };
    if ($@) {
        $c->app->log->warn("mailbridge send_message failed: $@");
        return $c->render(json => { error => 'could not send message' }, status => 502);
    }

    # Enqueued only on real success -- a failed send above already
    # returned. No eval/best-effort wrapper: per the audit trail's own
    # design, a failed enqueue here means the API call itself now fails
    # (502), even though the mail already left the building. Accepted
    # tradeoff, same as everywhere else this pattern is used.
    enqueue(
        $c->app->pg->db, actor_email => $email, affected_user => $email, jti => $jti, action => 'mail.send',
        resource_type => 'mail.message', source_service => 'homelab-mailbridge',
        ip_address => $c->tx->remote_address, user_agent => $c->req->headers->user_agent,
        detail => { to => $to, from => $from, subject => $subject },
    );
    return $c->render(json => { ok => \1 });
}

# Defense in depth only -- Postfix's own
# reject_authenticated_sender_login_mismatch (see
# ../../postfix/README.md and ../../domain-admin/README.md's
# "Multi-domain send-as" section) is the actual enforcement boundary;
# this just means a request this app rejects never even reaches an
# SMTP connection that Postfix would refuse anyway. Fails CLOSED: any
# failure to positively confirm authorization (domain-admin
# unreachable, malformed response, transport error) returns false,
# never "assume authorized" -- same convention as the old homelab-api
# repo's own _from_address_authorized, which this is modeled on.
sub _from_address_authorized ($c, $email, $token, $from) {
    my ($from_addr) = $from =~ /<([^>]+)>/ ? ($1) : ($from);
    return 1 if lc($from_addr) eq lc($email);

    my $tx = $MAIL_ALIASES_UA->get(
        $c->app->api_base . '/api/v1/domains/mail-aliases/mine' => { Authorization => "Bearer $token" },
    );
    my $err = $tx->error;
    return 0 if $err && !$err->{code};    # transport failure -- fail closed
    return 0 unless $tx->result->code == 200;
    my $body = eval { $tx->result->json } // {};
    my $send = $body->{send} // {};

    return 1 if grep { lc($_) eq lc($from_addr) } @{ $send->{addresses} // [] };
    my ($domain) = $from_addr =~ /\@(.+)$/;
    return 0 unless $domain;
    return 1 if grep { lc($_) eq '@' . lc($domain) } @{ $send->{domains} // [] };
    return 0;
}

1;
