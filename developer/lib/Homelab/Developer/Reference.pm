package Homelab::Developer::Reference;
use Mojo::Base -strict, -signatures;
use Mojo::File qw(path);
# The entries are already characters (YAML::XS decodes them), so JSON goes
# through from_json and to_json, which work on characters: decode_json and
# encode_json work on bytes, and turn an em dash into an error or mojibake.
use Mojo::JSON qw(from_json to_json);
use Mojo::Util qw(url_escape);
use Scalar::Util qw(blessed looks_like_number);
use YAML::XS ();
use Exporter 'import';

our @EXPORT_OK = qw(load_reference problems public_areas entry examples_for who_text fill);

# The API reference developer.mailmasker.org shows (post-cutover item 49):
# one YAML file per area under reference/, described in reference/README.md.
# This module reads and checks those files, and writes each ability's
# examples (cURL, Perl, homelab-cli) from its fields, so every example has
# the same shape and none can drift from the entry it belongs to.
#
# Nothing here touches the database or the network, so t/reference.t and
# the site build run all of it as-is.

my %METHOD = map { $_ => 1 } qw(GET POST PUT PATCH DELETE);
my %IN     = map { $_ => 1 } qw(path query body);
my $ID     = qr/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/;
my $WHO    = qr/\A(?:anyone|signed-in|site-admin|fleet|permission:[a-z][a-z0-9_.]*)\z/;
# What an example may say instead of a real value: the reader's own address
# and domain. The site fills both in with example values the reader swaps
# for their own.
my %PLACEHOLDER = (me => 1, domain => 1);
our %EXAMPLE = (me => 'you@example.com', domain => 'example.com');
our $BASE    = 'https://api.mailmasker.org';

# { areas => [ { slug, area, order, intro, abilities => [ ... ] } ],
#   by_id => { id => ability } }, every ability also carrying its area's
# name and slug. Dies, listing every problem, if any file is not right.
sub load_reference ($dir) {
    my @files = path($dir)->list->grep(sub { /\.yml\z/ })->sort->each;
    die "no reference files in $dir\n" unless @files;
    my @areas;
    for my $f (@files) {
        my $doc = eval { local $YAML::XS::Boolean = 'JSON::PP'; YAML::XS::LoadFile("$f") };
        die "$f: not valid YAML: $@" unless ref $doc eq 'HASH';
        push @areas, { %$doc, slug => $f->basename('.yml'), file => $f->basename };
    }
    @areas = sort { ($a->{order} // 999) <=> ($b->{order} // 999) || $a->{slug} cmp $b->{slug} } @areas;
    my $ref = { areas => \@areas, by_id => {} };
    for my $area (@areas) {
        for my $ab (@{ ref $area->{abilities} eq 'ARRAY' ? $area->{abilities} : [] }) {
            next unless ref $ab eq 'HASH';
            $ab->{area} = $area->{area};
            $ab->{area_slug} = $area->{slug};
            $ref->{by_id}{ $ab->{id} } //= $ab if defined $ab->{id};
        }
    }
    my @p = problems($ref);
    die join('', map { "$_\n" } "the API reference has " . scalar(@p) . " problem(s):", @p) if @p;
    return $ref;
}

# Everything wrong with the loaded files, one line each ("file: id: what").
sub problems ($ref) {
    my (@p, %seen);
    for my $area (@{ $ref->{areas} }) {
        my $f = $area->{file};
        push @p, "$f: 'area' (the menu heading) is missing" unless _str($area->{area});
        push @p, "$f: 'order' must be a whole number" unless ($area->{order} // '') =~ /\A\d+\z/;
        push @p, "$f: 'abilities' must be a list with at least one entry"
            unless ref $area->{abilities} eq 'ARRAY' && @{ $area->{abilities} };
        for my $ab (@{ ref $area->{abilities} eq 'ARRAY' ? $area->{abilities} : [] }) {
            unless (ref $ab eq 'HASH') { push @p, "$f: an ability is not a mapping"; next }
            my $id = $ab->{id} // '(no id)';
            my $at = "$f: $id";
            push @p, "$at: 'id' must be lowercase words joined by hyphens" unless ($ab->{id} // '') =~ $ID;
            push @p, "$at: the same id is used twice" if defined $ab->{id} && $seen{ $ab->{id} }++;
            push @p, "$at: 'method' must be one of GET POST PUT PATCH DELETE" unless $METHOD{ $ab->{method} // '' };
            push @p, "$at: 'path' must start with /api/v1" unless ($ab->{path} // '') =~ m{\A/api/v1(?:/|\z)};
            push @p, "$at: 'who' must be anyone, signed-in, site-admin, fleet or permission:<name>"
                unless ($ab->{who} // '') =~ $WHO;
            push @p, "$at: 'title' is missing"   unless _str($ab->{title});
            push @p, "$at: 'summary' is missing" unless _str($ab->{summary});
            next if ($ab->{who} // '') eq 'fleet';   # never shown: a one-line summary is enough

            push @p, "$at: 'description' is missing" unless _str($ab->{description});
            push @p, "$at: 'response' (an example answer) is missing" unless _str($ab->{response});
            push @p, "$at: 'cli' must be 'none' or start with 'homelab-cli '"
                unless ($ab->{cli} // '') eq 'none' || ($ab->{cli} // '') =~ /\Ahomelab-cli \S/;
            push @p, "$at: 'status' must be a 3-digit HTTP status" if defined $ab->{status} && $ab->{status} !~ /\A[1-5]\d\d\z/;
            push @p, "$at: a written 'curl' example must start with 'curl -s'" if defined $ab->{curl} && $ab->{curl} !~ /\Acurl -s /;
            push @p, "$at: a written 'perl' example must use Mojo::UserAgent" if defined $ab->{perl} && $ab->{perl} !~ /Mojo::UserAgent/;
            push @p, "$at: 'notes' must be a list of sentences"
                if defined $ab->{notes} && !(ref $ab->{notes} eq 'ARRAY' && !grep { !_str($_) } @{ $ab->{notes} });

            my $params = $ab->{params} // [];
            unless (ref $params eq 'ARRAY') { push @p, "$at: 'params' must be a list"; next }
            my %path_param;
            for my $pm (@$params) {
                unless (ref $pm eq 'HASH' && _str($pm->{name})) { push @p, "$at: a param has no name"; next }
                my $pn = "$at: param $pm->{name}";
                push @p, "$pn: 'in' must be path, query or body" unless $IN{ $pm->{in} // '' };
                push @p, "$pn: 'about' is missing" unless _str($pm->{about});
                push @p, "$pn: 'required' must be true or false" unless _is_bool($pm->{required});
                $path_param{ $pm->{name} }++ if ($pm->{in} // '') eq 'path';
                push @p, "$pn: a path param needs an example" if ($pm->{in} // '') eq 'path' && !defined $pm->{example};
            }
            my %in_path = map { $_ => 1 } ($ab->{path} // '') =~ m{/:([a-z_]+)}g;
            push @p, "$at: the path has :$_ but no path param of that name" for grep { !$path_param{$_} } sort keys %in_path;
            push @p, "$at: param $_ is 'in: path' but the path has no :$_" for grep { !$in_path{$_} } sort keys %path_param;

            for my $field (qw(response body)) {
                next unless defined $ab->{$field} && ($ab->{$field} =~ /\A\s*[\[{]/);
                my $json = fill($ab->{$field}, me => 'you@example.com', domain => 'example.com');
                push @p, "$at: '$field' looks like JSON but does not parse" unless eval { from_json($json); 1 };
            }
            for my $text (_texts($ab)) {
                push @p, "$at: unknown placeholder {$_} (only {me} and {domain})"
                    for grep { !$PLACEHOLDER{$_} } $text =~ /\{([a-z_]+)\}/g;
            }
        }
    }
    return @p;
}

# What the site shows: every area with its abilities as whole entries, in
# order. Routes only fleet services call are left out: no person or script
# of theirs can call one. Areas left empty are dropped.
sub public_areas ($ref) {
    my @areas;
    for my $area (@{ $ref->{areas} }) {
        my @ab = map { entry($_) } grep { $_->{who} ne 'fleet' } @{ $area->{abilities} };
        push @areas, { slug => $area->{slug}, area => $area->{area}, intro => $area->{intro}, abilities => \@ab } if @ab;
    }
    return \@areas;
}

# One ability as the site shows it: everything about it, with its examples,
# and {me} and {domain} filled in with the example values.
sub entry ($ab, %o) {
    my %fill = (%EXAMPLE, map { defined $o{$_} ? ($_ => $o{$_}) : () } qw(me domain));
    return {
        (map { $_ => $ab->{$_} } qw(id title method path who summary area area_slug)),
        description => $ab->{description},
        notes       => $ab->{notes} // [],
        status      => $ab->{status} // 200,
        params      => [ map { { %$_, example => _fill_deep($_->{example}, %fill) } } @{ $ab->{params} // [] } ],
        response    => fill($ab->{response}, %fill),
        examples    => examples_for($ab, base => $o{base} // $BASE, %fill),
    };
}

# Who may use an ability, in plain words.
sub who_text ($who) {
    return 'Anyone, with no sign-in'  if $who eq 'anyone';
    return 'Any signed-in account'    if $who eq 'signed-in';
    return 'Site admins'              if $who eq 'site-admin';
    return "Site admins, and accounts granted the $1 permission" if $who =~ /\Apermission:(.+)\z/;
    return 'Fleet services only'      if $who eq 'fleet';
    return $who;
}

# { curl, perl, cli } for one ability.
sub examples_for ($ab, %o) {
    my %fill = (me => $o{me} // $EXAMPLE{me}, domain => $o{domain} // $EXAMPLE{domain});
    my $base = $o{base} // $BASE;
    my @params = map { { %$_, example => _fill_deep($_->{example}, %fill) } } @{ $ab->{params} // [] };

    my $path = $ab->{path};
    for my $pm (grep { $_->{in} eq 'path' } @params) {
        my $v = url_escape(_scalar($pm->{example}));
        $path =~ s{/:\Q$pm->{name}\E(?=/|\z)}{/$v};
    }
    my @query = map { [ $_->{name}, _scalar($_->{example}) ] } grep { $_->{in} eq 'query' && defined $_->{example} } @params;
    my $url = $base . $path;
    my $qs = join '&', map { url_escape($_->[0]) . '=' . url_escape($_->[1]) } @query;

    # The body, as an ordered list of [name, value] (the order the entry gives),
    # or a raw example when the entry has one (nested lists and objects).
    my ($body, $raw);
    if (defined $ab->{body}) {
        $raw = from_json(fill($ab->{body}, %fill));
    } else {
        my @b = map { [ $_->{name}, $_->{example} ] } grep { $_->{in} eq 'body' && defined $_->{example} } @params;
        $body = \@b if @b;
    }
    my $has_body = defined $raw || $body;
    my $auth = $ab->{who} ne 'anyone';
    my $m = $ab->{method};

    # cURL. A value written as $NAME is an environment variable: then the JSON
    # goes in double quotes, so the shell fills it in.
    # Mojo::JSON writes / as \/, valid but hard to read in an example.
    my $json = !$has_body ? '' : ($raw ? to_json($raw) : _pairs_json($body)) =~ s{\\/}{/}gr;
    my $env  = $json =~ /"\$[A-Z_]+"/;
    my @curl = ('curl -s' . ($m eq 'GET' ? '' : " -X $m") . " '" . $url . ($qs ? "?$qs" : '') . "'");
    push @curl, '-H "Authorization: Bearer $TOKEN"' if $auth;
    if ($has_body) {
        push @curl, "-H 'Content-Type: application/json'";
        push @curl, $env ? '-d "' . ($json =~ s/(["\\`])/\\$1/gr) . '"'
                         : "-d '" . ($json =~ s/'/'\\''/gr) . "'";
    }
    my $curl = join(" \\\n  ", @curl);

    # Perl, with Mojo::UserAgent like the rest of the code.
    my $call = lc $m;
    my @args = ("'$url'");
    push @args, '{ Authorization => "Bearer $ENV{TOKEN}" }' if $auth;
    push @args, 'form => ' . _perl({ map { @$_ } @query }, [ map { $_->[0] } @query ]) if @query;
    push @args, 'json => ' . ($raw ? _perl($raw) : _perl({ map { @$_ } @$body }, [ map { $_->[0] } @$body ])) if $has_body;
    my $perl = join "\n",
        'use Mojo::Base -strict;',
        'use Mojo::UserAgent;',
        '',
        'my $ua  = Mojo::UserAgent->new;',
        "my \$res = \$ua->$call(" . join(",\n    ", @args) . ')->result;',
        q{die $res->code, ' ', ($res->json('/error') // $res->message), "\n" unless $res->is_success;},
        'print $res->body, "\n";';

    my $cli = ($ab->{cli} // 'none') eq 'none' ? undef : fill($ab->{cli}, %fill);
    # An entry writes its own example only where these can't work: a file
    # upload, raw bytes, a header of its own (see README.md).
    $curl = fill($ab->{curl}, %fill) if defined $ab->{curl};
    $perl = fill($ab->{perl}, %fill) if defined $ab->{perl};
    return { curl => $curl, perl => $perl, cli => $cli };
}

# {me} and {domain} filled in.
sub fill ($text, %v) {
    return $text unless defined $text;
    $text =~ s/\{(me|domain)\}/$v{$1}/g;
    return $text;
}

sub _fill_deep ($v, %f) {
    return [ map { _fill_deep($_, %f) } @$v ] if ref $v eq 'ARRAY';
    return { map { $_ => _fill_deep($v->{$_}, %f) } keys %$v } if ref $v eq 'HASH';
    return $v if ref $v;
    return fill($v, %f);
}

# Every string an entry shows, for the placeholder check.
sub _texts ($ab) {
    my @t = grep { defined && !ref } @{$ab}{qw(path cli curl perl response body description summary title)};
    for my $pm (@{ ref $ab->{params} eq 'ARRAY' ? $ab->{params} : [] }) {
        push @t, _flat($pm->{example}), grep { defined } $pm->{about};
    }
    return @t;
}
sub _flat ($v) {
    return map { _flat($_) } @$v if ref $v eq 'ARRAY';
    return map { _flat($_) } values %$v if ref $v eq 'HASH';
    return ref $v ? () : defined $v ? ($v) : ();
}

# Compact JSON for a flat body, keys in the entry's order.
sub _pairs_json ($pairs) {
    return '{' . join(',', map { to_json($_->[0]) . ':' . to_json($_->[1]) } @$pairs) . '}';
}

# A Perl literal for a value: hashes in the given key order (else sorted),
# JSON true/false as \1 and \0, an environment variable as $ENV{NAME}.
sub _perl ($v, $order = undef) {
    if (ref $v eq 'HASH') {
        my @k = $order ? @$order : sort keys %$v;
        return '{}' unless @k;
        return '{ ' . join(', ', map { _perl_key($_) . ' => ' . _perl($v->{$_}) } @k) . ' }';
    }
    return '[' . join(', ', map { _perl($_) } @$v) . ']' if ref $v eq 'ARRAY';
    return ($v ? '\1' : '\0') if _is_bool($v) && ref $v;
    return 'undef' unless defined $v;
    return "\$ENV{$1}" if $v =~ /\A\$([A-Z_]+)\z/;
    return $v if looks_like_number($v) && $v !~ /\A0\d/ && $v !~ /\A[+.]/;
    return "'" . ($v =~ s/(['\\])/\\$1/gr) . "'";
}
sub _perl_key ($k) { return $k =~ /\A[A-Za-z_]\w*\z/ ? $k : "'" . ($k =~ s/(['\\])/\\$1/gr) . "'" }

sub _scalar ($v) { return ref $v ? to_json($v) : $v // '' }
sub _str ($v) { return defined $v && !ref $v && $v =~ /\S/ }
sub _is_bool ($v) {
    return 1 if blessed($v) && $v->isa('JSON::PP::Boolean');
    return defined $v && !ref $v && ($v eq '1' || $v eq '0' || $v eq '');
}

1;
