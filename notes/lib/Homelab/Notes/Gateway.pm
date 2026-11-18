package Homelab::Notes::Gateway;
use Mojo::Base -base, -signatures;
use Mojo::UserAgent;
use Mojo::URL;

has 'api_base';
has 'log';
has ua => sub { Mojo::UserAgent->new->connect_timeout(5)->inactivity_timeout(15)->request_timeout(20)->max_redirects(0) };

# What the pickers need of the other apps, asked of homelab-api's gateway AS
# THE VIEWER: their own token goes in the Authorization header, so the notes
# app never sees more than the person could see themselves (post-cutover #71).
# Returns the decoded JSON, or dies with one sentence for the person.

sub get ($self, $jwt, $path, %query) {
    die "You are not signed in.\n" unless length($jwt // '');
    my $url = Mojo::URL->new($self->api_base . $path);
    $url->query(map { defined $query{$_} && length $query{$_} ? ($_ => $query{$_}) : () } sort keys %query);
    my $tx = $self->ua->get($url, { Authorization => "Bearer $jwt", Accept => 'application/json' });
    my $res = $tx->result;
    unless ($res->is_success) {
        my $err = eval { $res->json->{error} } // $res->message // 'no answer';
        $self->log->warn("notes gateway: GET $path -> " . $res->code . " $err") if $self->log;
        die "That could not be looked up just now ($err).\n";
    }
    return $res->json // {};
}

# The viewer's mail that matches: what the search service answers, reduced
# to the rows a mail link keeps.
sub mail_hits ($self, $jwt, $q, $limit = 20) {
    my $r = $self->get($jwt, '/api/v1/search', q => $q, source => 'mail', calendar => 0, limit => $limit);
    return [ map { {
        message_id => $_->{message_id}, subject => $_->{subject}, from_addr => $_->{from_addr}, from_name => $_->{from_name},
        sent_at => $_->{sent_at}, mailbox => $_->{mailbox}, snippet => $_->{snippet},
    } } @{ ref $r->{mail} eq 'ARRAY' ? $r->{mail} : [] } ];
}

# One level of the viewer's drive: the folders in a folder and the files in it.
sub drive_level ($self, $jwt, $folder_id = undef) {
    my $folders = $self->get($jwt, '/api/v1/drive/folders', parent_id => $folder_id);
    my $files   = $self->get($jwt, '/api/v1/drive/files', folder_id => $folder_id);
    return {
        folders => [ map { { id => $_->{id}, name => $_->{name} } } @{ ref $folders eq 'ARRAY' ? $folders : [] } ],
        files   => [ map { { file_id => $_->{id}, filename => $_->{filename}, size_bytes => $_->{size_bytes}, mime_type => $_->{mime_type}, uploaded_at => $_->{uploaded_at} } }
                     @{ ref $files eq 'ARRAY' ? $files : [] } ],
    };
}

1;
