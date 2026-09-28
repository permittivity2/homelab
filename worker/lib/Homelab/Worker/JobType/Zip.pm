package Homelab::Worker::JobType::Zip;
use Mojo::Base -strict;

use Archive::Zip qw(:ERROR_CODES);
use File::Spec;
use Mojo::UserAgent;

# Generic "fetch N URLs, each with its own auth header, bundle into one
# zip" -- knows nothing about homelab-drive or any other specific
# caller's schema (see ../../../../README.md's job-type abstraction).
# $input shape:
#   { output_name => "drive-export-20260911.zip",
#     entries => [ { fetch_url, auth_header, zip_path }, ... ] }
# Runs inside Homelab::Worker::App's forked subprocess child -- returns
# the finished archive's local path (inside $workdir) on success, or
# dies with a message that becomes the job's error_message on failure.
sub run {
    my ($input, $workdir, $progress_cb) = @_;

    my $entries = $input->{entries};
    die "zip job: input.entries is required\n" unless ref $entries eq 'ARRAY' && @$entries;

    my $zip = Archive::Zip->new;
    my $ua  = Mojo::UserAgent->new(connect_timeout => 10, request_timeout => 300);

    # Report progress as "entries completed / total". Called at the START
    # of each entry (so the worker's no-progress reclaim clock effectively
    # resets per entry, not per whole job -- a long single-entry fetch
    # aside) and once more at the end for 100%. $progress_cb is optional
    # so run() still works when called without it (e.g. unit tests).
    my $total = scalar @$entries;
    my $n = 0;
    for my $entry (@$entries) {
        $progress_cb->($n, $total) if $progress_cb;
        $n++;
        my $fetch_url = $entry->{fetch_url} // die "zip job: entry $n is missing fetch_url\n";
        my $zip_path  = $entry->{zip_path}  // die "zip job: entry $n is missing zip_path\n";

        my %headers;
        $headers{Authorization} = $entry->{auth_header} if $entry->{auth_header};
        my $tx = $ua->get($fetch_url => \%headers);
        die "zip job: fetch failed for '$zip_path' ($fetch_url): " . _tx_error($tx) . "\n" if $tx->error;

        my $local_path = File::Spec->catfile($workdir, "entry-$n.bin");
        $tx->result->save_to($local_path);

        $zip->addFile($local_path, $zip_path)
            or die "zip job: could not add '$zip_path' to the archive\n";
    }

    my $output_name = $input->{output_name} // 'archive.zip';
    # Basename only -- output_name is caller-supplied and must never be
    # interpreted as a path (e.g. "../../etc/passwd") when joined below.
    (my $safe_name = $output_name) =~ s{.*/}{};
    $safe_name = 'archive.zip' unless length $safe_name;

    my $out_path = File::Spec->catfile($workdir, $safe_name);
    die "zip job: could not write archive\n" unless $zip->writeToFileNamed($out_path) == AZ_OK;

    # Report 100% only AFTER the archive is actually written, so "done"
    # is honest (not "all entries fetched, but still compressing").
    # NOTE: writeToFileNamed itself is a single tickless phase -- Archive::
    # Zip exposes no progress hook -- so a pathologically huge archive
    # (tens of GB) whose compress/write alone exceeds jobs.job_timeout_minutes
    # could still be reclaimed as "no progress"; acceptable given the
    # per-entry ticks cover the fetch phase and such sizes are far beyond
    # normal drive exports. Revisit with an incremental writer if needed.
    $progress_cb->($total, $total) if $progress_cb;

    return $out_path;
}

sub _tx_error {
    my ($tx)  = @_;
    my $err   = $tx->error;
    return $err->{message} // 'unknown error';
}

1;
