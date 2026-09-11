package Homelab::Worker::App::Controller::Jobs;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use File::Spec;
use Homelab::Common::AuthClient qw(introspect);

# Returns (email, roles) on success. On failure, has already rendered a
# 401 and returns nothing -- callers use
# `my ($email, $roles) = _authenticated($c) or return;`, same convention
# as homelab-mailbridge's own _authenticated_email. Re-introspects on
# every request (verify-at-every-hop) rather than trusting that
# homelab-api's gateway already did.
sub _authenticated ($c) {
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
    return ($result->{email}, $result->{roles} // []);
}

sub _is_admin ($roles) {
    return !!(grep { $_ eq 'site_admin' } @$roles);
}

# Never includes the raw `input` JSONB -- for a zip job that holds each
# manifest entry's forwarded Authorization header (see README.md's "the
# auth hand-off" section). An authenticated owner/admin gets to know a
# job ran and how it went, not the literal credential it ran with.
sub _public_row ($row) {
    return {
        id                => $row->{id} + 0,
        type              => $row->{type},
        state             => $row->{state},
        user_email        => $row->{user_email},
        output_name       => $row->{output_name},
        output_size_bytes => defined $row->{output_size_bytes} ? $row->{output_size_bytes} + 0 : undef,
        error_message     => $row->{error_message},
        created_at        => $row->{created_at},
        started_at        => $row->{started_at},
        completed_at      => $row->{completed_at},
    };
}

sub create ($c) {
    my ($email) = _authenticated($c) or return;
    my $params = $c->req->json // {};
    my $type   = $params->{type};
    my $input  = $params->{input};
    return $c->render(json => { error => 'type is required' }, status => 400) unless $type;
    return $c->render(json => { error => 'input must be an object' }, status => 400) unless ref $input eq 'HASH';
    return $c->render(json => { error => "unknown job type '$type'" }, status => 400)
        unless $c->app->job_types->{$type};

    my $row = $c->app->pg->db->query(
        q{INSERT INTO worker.jobs (user_email, type, input, output_name)
          VALUES (?, ?, ?, ?) RETURNING id, type, state, user_email, output_name, created_at},
        $email, $type, { -json => $input }, $input->{output_name},
    )->expand->hash;

    return $c->render(json => _public_row($row), status => 201);
}

sub list ($c) {
    my ($email, $roles) = _authenticated($c) or return;
    my $all = $c->param('all');

    if ($all && !_is_admin($roles)) {
        return $c->render(json => { error => 'site_admin role required for ?all=1' }, status => 403);
    }

    my (@where, @binds);
    unless ($all) {
        push @where, 'user_email = ?';
        push @binds, $email;
    }
    if (my $type = $c->param('type')) {
        push @where, 'type = ?';
        push @binds, $type;
    }
    if (my $state = $c->param('state')) {
        push @where, 'state = ?';
        push @binds, $state;
    }
    my $where_sql = @where ? 'WHERE ' . join(' AND ', @where) : '';

    # No pagination UI in v1 -- a sane cap so this query can't run away
    # (see README.md).
    my $rows = $c->app->pg->db->query(
        qq{SELECT id, type, state, user_email, output_name, output_size_bytes, error_message,
                  created_at, started_at, completed_at
           FROM worker.jobs $where_sql ORDER BY created_at DESC LIMIT 50},
        @binds,
    )->hashes;

    return $c->render(json => [ map { _public_row($_) } @$rows ]);
}

# undef means "doesn't exist OR exists but the caller can't see it" --
# deliberately indistinguishable (matches this codebase's existing
# convention, e.g. homelab-domain-admin's own recipient-access delete),
# so show()/download() both render the same clean 404 either way.
sub _find_visible_job ($c, $email, $roles) {
    my $row = $c->app->pg->db->query(
        q{SELECT id, type, state, user_email, output_name, output_uuid, output_size_bytes,
                 error_message, created_at, started_at, completed_at
          FROM worker.jobs WHERE id = ?},
        $c->stash('id'),
    )->hash;
    return undef unless $row;
    return undef unless $row->{user_email} eq $email || _is_admin($roles);
    return $row;
}

sub show ($c) {
    my ($email, $roles) = _authenticated($c) or return;
    my $row = _find_visible_job($c, $email, $roles);
    return $c->render(json => { error => 'not found' }, status => 404) unless $row;
    return $c->render(json => _public_row($row));
}

sub download ($c) {
    my ($email, $roles) = _authenticated($c) or return;
    my $row = _find_visible_job($c, $email, $roles);
    return $c->render(json => { error => 'not found' }, status => 404) unless $row;

    if ($row->{state} ne 'completed') {
        return $c->render(json => { error => "job is not finished (state: $row->{state})" }, status => 409);
    }

    my $path = File::Spec->catfile($c->app->storage_path, $row->{output_uuid});
    unless (-f $path) {
        $c->app->log->error("worker: job $row->{id} is 'completed' but its output file is missing: $path");
        return $c->render(json => { error => 'output artifact missing' }, status => 500);
    }

    $c->res->headers->content_disposition(
        'attachment; filename="' . ($row->{output_name} // "job-$row->{id}.bin") . '"'
    );
    return $c->reply->file($path);
}

1;
