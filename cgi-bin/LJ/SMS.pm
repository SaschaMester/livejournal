package LJ::SMS;

# LJ::SMS object
#
# wrangles LJ::SMS::Messages and the app logic associated
# with them...
#
# also contains LJ::Worker class for incoming SMS
#

use strict;
use Carp qw(croak);

sub schwartz_capabilities {
    return qw(LJ::Worker::IncomingSMS);
}

# get the userid of a given number from smsusermap
sub num_to_uid {
    my $class = shift;
    my $num  = shift;

    # TODO: optimize
    my $dbr = LJ::get_db_reader();
    return $dbr->selectrow_array
        ("SELECT userid FROM smsusermap WHERE number=? AND verified='Y' LIMIT 1", undef, $num);
}

sub uid_to_num {
    my $class = shift;
    my $uid  = LJ::want_userid(shift);

    # TODO: optimize
    my $dbr = LJ::get_db_reader();
    return $dbr->selectrow_array
        ("SELECT number FROM smsusermap WHERE userid=? AND verified='Y' LIMIT 1", undef, $uid);
}

sub replace_mapping {
    my ($class, $uid, $num, $active) = @_;
    $uid = LJ::want_userid($uid);
    $active = uc($active);
    croak "invalid userid" unless int($uid) > 0;
    if ($num) {
        croak "invalid number" unless $num =~ /^\+\d+$/;
        croak "invalid active flag" unless $active =~ /^[YN]$/;
    }

    my $dbh = LJ::get_db_writer();
    if ($num) {
        return $dbh->do("REPLACE INTO smsusermap SET number=?, userid=?, verified=?, instime=UNIX_TIMESTAMP()",
                        undef, $num, $uid, $active);
    } else {
        return $dbh->do("DELETE FROM smsusermap WHERE userid=?", undef, $uid);
    }
}

# enqueue an incoming SMS for processing
sub enqueue_as_incoming {
    my $class = shift;
    croak "enqueue_as_incoming is a class method"
        unless $class eq __PACKAGE__;

    my $msg = shift;
    die "invalid msg argument"
        unless $msg && $msg->isa("LJ::SMS::Message");

    return unless $msg->should_enqueue;

    my $sclient = LJ::theschwartz();
    die "Unable to contact TheSchwartz!"
        unless $sclient;

    my $shandle = $sclient->insert("LJ::Worker::IncomingSMS", $msg);
    return $shandle ? 1 : 0;
}

# is sms sending configured?
sub configured {
    my $class = shift;

    return %LJ::SMS_GATEWAY_CONFIG && LJ::sms_gateway() ? 1 : 0;
}

sub configured_for_user {
    my $class = shift;
    my $u = shift;

    return $u->sms_number && $u->prop('sms_emabled') eq 'active' ? 1 : 0;
}

sub sms_quota_remaining {
    my ($class, $u, $type) = @_;

    return LJ::run_hook("sms_quota_remaining", $u, $type) || 0;
}

sub add_sms_quota {
    my ($class, $u, $qty, $type) = @_;

    return LJ::run_hook("modify_sms_quota", $u, $qty, type => $type);
}

sub max_sms_bytes {
    my ($class, $u) = @_;

    # for now the max length for all users is 160, but
    # in the future we'll need to modify this to look
    # at their carrier cap and return a max from there
    return '160';
}

sub max_sms_substr {
    my $class = shift;
    my ($u, $text, %opts) = @_;

    my $suffix = delete $opts{suffix} || "";
    my $maxlen = delete $opts{maxlen} || undef;
    croak "invalid parameters to max_sms_substr: " . join(",", keys %opts)
        if %opts;

    $maxlen ||= $u->max_sms_bytes;

    my $gw = LJ::sms_gateway()
        or die "unable to load SMS gateway object";

    # use bytes in here for length/etc
    use bytes;

    # greedily find the largest bit of text that doesn't
    # violate the final byte length of $maxlen, stopping
    # when $maxlen == 2 and --$maxlen == 1 is tried as
    # a length
    my $currlen = $maxlen;
    while ($currlen > 1 && $gw->final_byte_length($text . $suffix) > $maxlen) {
        $text = LJ::text_trim($text, --$currlen);
    }

    return $text . $suffix;
}

sub can_append {
    my $class = shift;
    my ($u, $curr, $append) = @_;
    croak "invalid user object" unless LJ::isu($u);

    my $maxlen = $u->max_sms_bytes;

    my $gw = LJ::sms_gateway()
        or die "unable to load SMS gateway object";

    return $gw->final_byte_length($curr . $append) <= $maxlen;
}

sub subtract_sms_quota {
    my ($class, $u, $qty, $type) = @_;

    return LJ::run_hook("modify_sms_quota", $u, -$qty, type => $type);
}

# Schwartz worker for responding to incoming SMS messages
package LJ::Worker::IncomingSMS;
use base 'TheSchwartz::Worker';

use Class::Autouse qw(LJ::SMS::MessageHandler);

sub work {
    my ($class, $job) = @_;

    my $msg = $job->arg;

    unless ($msg) {
        $job->failed;
        return;
    }

    warn "calling messagehandler";
    LJ::SMS::MessageHandler->handle($msg);

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
