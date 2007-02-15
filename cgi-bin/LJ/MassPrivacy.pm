package LJ::MassPrivacy;

# LJ::MassPrivacy object
#
# Used to handle Schwartz job for updating privacy of posts en masse
#

use strict;
use Carp qw(croak);

sub schwartz_capabilities {
    return qw(LJ::Worker::MassPrivacy);
}

# enqueue job to update privacy
sub enqueue_job {
    my ($class, %opts) = @_;
    croak "enqueue_job is a class method"
        unless $class eq __PACKAGE__;

    croak "missing options argument" unless %opts;

    # Check options
    if (!($opts{s_security} =~ m/[private|usemask|public]/) ||
        !($opts{e_security} =~ m/[private|usemask|public]/) ) {
        croak "invalid privacy option";
    }

    if ($opts{'start_date'} || $opts{'end_date'}) {
        croak "start or end date not defined"
            if (!$opts{'start_date'} || !$opts{'end_date'});

        if (!($opts{'start_date'} >= 0) || !($opts{'end_date'} >= 0) ||
            !($opts{'start_date'} <= $LJ::EndOfTime) ||
            !($opts{'end_date'} <= $LJ::EndOfTime) ) {
            return undef;
        }
    }

    my $sclient = LJ::theschwartz();
    die "Unable to contact TheSchwartz!" unless $sclient;

    my $shandle = $sclient->insert("LJ::Worker::MassPrivacy", \%opts);

    return $shandle;
}

sub handle {
    my ($class, $opts) = @_;

    croak "missing options argument" unless $opts;

    my $u =  LJ::load_userid($opts->{'userid'});
    # we only handle changes to or from friends-only security
    # Allowmask for friends-only is 1, public and private are 0.
    my $s_allowmask = ($opts->{s_security} eq 'usemask') ? 1 :0;
    my $e_allowmask = ($opts->{e_security} eq 'usemask') ? 1 :0;
    my %privacy = ( private => 'private',
                    usemask => 'friends-only',
                    public  => 'public',
                  );

    my @jids;
    my $timeframe = ''; # date range string or empty
    # If there is a date range
    if ($opts->{s_unixtime} && $opts->{e_unixtime}) {
        @jids = $u->get_post_ids(
                             'security' => $opts->{'s_security'},
                            'allowmask' => $s_allowmask,
                           'start_date' => $opts->{'s_unixtime'},
                             'end_date' => $opts->{'e_unixtime'} );
        my (undef,undef,undef,$s_mday,$s_mon,$s_year,undef,undef,undef)
            = gmtime($opts->{s_unixtime});
        my (undef,undef,undef,$e_mday,$e_mon,$e_year,undef,undef,undef)
            = gmtime($opts->{e_unixtime});
        $s_mon++; $e_mon++;
        $s_year += 1900; $e_year += 1900;
        $timeframe = "(between [$s_year-$s_mon-$s_mday] and [$e_year-$e_mon-$e_mday]) ";
    } else {
        @jids = $u->get_post_ids(
                             'security' => $opts->{'s_security'},
                            'allowmask' => $s_allowmask, );
    }

    # check if there are any posts to update
    return 1 unless (scalar @jids);

    my @errs;
    # Update each event using the API
    foreach my $itemid (@jids) {
        my %res = ();
        my %req = ( 'mode' => 'editevent',
                    'ver' => $LJ::PROTOCOL_VER,
                    'user' => $u->{'user'},
                    'itemid' => $itemid,
                    'security' => $opts->{e_security},
                    'allowmask' => $e_allowmask,
                    );

        # do editevent request
        LJ::do_request(\%req, \%res, { 'noauth' => 1, 'u' => $u,
                       'use_old_content' => 1 });

        # check response
        unless ($res{'success'} eq "OK") {
            push @errs, $res{'errmsg'};
        }
    }

    # only print 200 characters  of error message to log
    # allow some space at the end for error location message
    if (@errs) {
        my $errmsg = join(', ', @errs);
        $errmsg = substr($errmsg, 0, 200) . "... ";
        die $errmsg;
    }

    my $subject = "$LJ::SITENAMESHORT: Entry Security Updated";
    my $msg = "Hi " . $u->user . ",\n\n" .
              "All your " . $privacy{$opts->{s_security}} . " entries " .
              $timeframe . "have now " .
              "been changed to be " . $privacy{$opts->{e_security}} . ".\n\n" .
              "If you made this change by mistake, or if you want to change " .
              "the security on more of your entries, you can do so at " .
              "$LJ::SITEROOT/editprivacy.bml\n\n" .
              "Thanks!\n\n" .
              "-- $LJ::SITENAME\n" .
              "$LJ::SITEROOT";

    LJ::send_mail({
        'to' => $u->email_raw,
        'from' => $LJ::BOGUS_EMAIL,
        'fromname' => $LJ::SITENAMESHORT,
        'wrap' => 1,
        'charset' => 'utf-8',
        'subject' => $subject,
        'body' => $msg,
    });

    return 1;
}

# Schwartz job for processing changes to privacy en masse
package LJ::Worker::MassPrivacy;
use base 'TheSchwartz::Worker';

use Class::Autouse qw(LJ::MassPrivacy);

sub work {
    my ($class, $job) = @_;

    my $opts = $job->arg;

    unless ($opts) {
        $job->failed;
        return;
    }

    LJ::MassPrivacy->handle($opts);

    return $job->completed;
}

sub keep_exit_status_for { 0 }
sub grab_for { 300 }
sub max_retries { 5 }
sub retry_delay {
        my ($class, $fails) = @_;
            return (10, 30, 60, 300, 600)[$fails];
}

1;
