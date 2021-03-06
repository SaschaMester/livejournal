#!/usr/bin/perl
#

use strict;

package LJ::Support;

use vars qw(@SUPPORT_PRIVS);

use Digest::MD5 qw(md5_hex);

use lib "$ENV{LJHOME}/cgi-bin";
require "sysban.pl";
use LJ::TimeUtil;
use LJ::Support::Request::Tag;
use LJ::Event::SupportRequest;

# Constants
my $SECONDS_IN_DAY  = 3600 * 24;
@SUPPORT_PRIVS = (qw/supportclose
                     supporthelp
                     supportdelete
                     supportread
                     supportviewinternal
                     supportmakeinternal
                     supportmovetouch
                     supportviewscreened
                     supportviewstocks
                     supportchangesummary/);

# <LJFUNC>
# name: LJ::Support::slow_query_dbh
# des: Retrieve a database handle to be used for support-related
#      slow queries... defaults to 'slow' role but can be
#      overriden by [ljconfig[support_slow_roles]].
# args: none
# returns: master database handle.
# </LJFUNC>
sub slow_query_dbh
{
    return LJ::get_dbh(@LJ::SUPPORT_SLOW_ROLES);
}

## pass $id of zero or blank to get all categories
sub load_cats
{
    my ($id) = @_;
    my $hashref = {};
    $id += 0;
    my $where = $id ? "WHERE spcatid=$id" : "";
    my $dbr = LJ::get_db_reader();
    my $sth = $dbr->prepare("SELECT * FROM supportcat $where");
    $sth->execute;
    $hashref->{$_->{'spcatid'}} = $_ while ($_ = $sth->fetchrow_hashref);
    return $hashref;
}

sub load_email_to_cat_map
{
    my $map = {};
    my $dbr = LJ::get_db_reader();
    my $sth = $dbr->prepare("SELECT * FROM supportcat ORDER BY sortorder DESC");
    $sth->execute;
    while (my $sp = $sth->fetchrow_hashref) {
        next unless ($sp->{'replyaddress'});
        $map->{$sp->{'replyaddress'}} = $sp;
    }
    return $map;
}

sub calc_points
{
    my ($sp, $secs, $spcat) = @_;
    $spcat ||= $sp->{_cat};
    my $base = $spcat->{'basepoints'} || 1;
    $secs = int($secs / (3600*6));
    my $total = ($base + $secs);
    if ($total > 10) { $total = 10; }
    return $total;
}

sub init_remote
{
    my $remote = shift;
    return unless $remote;
    LJ::load_user_privs($remote, @SUPPORT_PRIVS);
}

sub has_any_support_priv {
    my $u = shift;
    return 0 unless $u;
    foreach my $support_priv (@SUPPORT_PRIVS) {
        return 1 if LJ::check_priv($u, $support_priv);
    }
    return 0;
}

# given all the categories, maps a catkey into a cat
sub get_cat_by_key
{
    my ($cats, $cat) = @_;
    foreach (keys %$cats) {
        if ($cats->{$_}->{'catkey'} eq $cat) {
            return $cats->{$_};
        }
    }
    return undef;
}

sub get_cat_by_id
{
    my ($cats, $id) = @_;
    foreach (keys %$cats) {
        if ($cats->{$_}->{'spcatid'} == $id) {
            return $cats->{$_};
        }
    }
    return undef;
}

sub filter_cats
{
    my $remote = shift;
    my $cats = shift;

    return grep {
        can_read_cat($_, $remote);
    } sorted_cats($cats);
}

sub sorted_cats
{
    my $cats = shift;
    return sort { $a->{'catname'} cmp $b->{'catname'} } values %$cats;
}

# takes raw support request record and puts category info in it
# so it can be used in other functions like can_*
sub fill_request_with_cat
{
    my ($sp, $cats) = @_;
    $sp->{_cat} = $cats->{$sp->{'spcatid'}};
}

sub is_poster {
    my ($sp, $remote, $auth) = @_;

    if ($sp->{'reqtype'} eq "user") {
        return 1 if $remote && $remote->id == $sp->{'requserid'};

    } else {
        if ($remote) {
            return 1 if lc($remote->email_raw) eq lc($sp->{'reqemail'});
        } else {
            return 1 if $auth && $auth eq mini_auth($sp);
        }
    }

    return 0;
}

sub can_see_helper
{
    my ($sp, $remote) = @_;
    my $spcat = $sp->{_cat};
    if ($spcat->{'hide_helpers'}) {
        if (can_help($spcat, $remote)) {
            return 1;
        }
        if (LJ::check_priv($remote, "supportviewinternal", $sp->{_cat}->{'catkey'})) {
            return 1;
        }
        if (LJ::check_priv($remote, "supportviewscreened", $sp->{_cat}->{'catkey'})) {
            return 1;
        }
        return 0;
    }
    return 1;
}

sub can_see_response {
    my ($splid, $u) = @_;
    
    my $response = load_response($splid);
    my $type     = $response->{type};
    my $spid     = $response->{spid};
    my $sp       = load_request($spid);
    my $cat      = load_cats()->{ $sp->{spcatid} };
    
    my $PRIVS_BY_TYPE = {
        answer   => can_read_cat($cat, $u),
        comment  => can_read_cat($cat, $u),
        screened => can_read_screened($cat, $u),
        internal => can_read_internal($cat, $u),
    };
    
    return $PRIVS_BY_TYPE->{$type};
}

sub can_read
{
    my ($sp, $remote, $auth) = @_;
    return (is_poster($sp, $remote, $auth) ||
            can_read_cat($sp->{_cat}, $remote));
}

sub can_read_cat
{
    my ($cat, $remote) = @_;
    return unless ($cat);
    return ($cat->{'public_read'} ||
            LJ::check_priv($remote, "supportread", $cat->{'catkey'}));
}

*can_bounce = \&can_close_cat;
*can_lock   = \&can_close_cat;

# if they can close in this category
sub can_close_cat
{
    my ($sp, $remote) = @_;
    return 1 if $sp->{_cat}->{public_read} && LJ::check_priv($remote, 'supportclose', '');
    return 1 if LJ::check_priv($remote, 'supportclose', $sp->{_cat}->{catkey});
    return 0;
}

# if they can close this particular request
sub can_close
{
    my ($sp, $remote, $auth) = @_;
    return 1 if $sp->{_cat}->{user_closeable} && is_poster($sp, $remote, $auth);
    return can_close_cat($sp, $remote);
}

# if they can reopen a request
sub can_reopen {
    my ($sp, $remote, $auth) = @_;
    return 1 if is_poster($sp, $remote, $auth);
    return can_close_cat($sp, $remote);
}

sub can_append
{
    my ($sp, $remote, $auth) = @_;
    my $spcat = $sp->{_cat};
    if (is_poster($sp, $remote, $auth)) { return 1; }
    return 0 unless $remote;
    return 0 unless $remote->{'statusvis'} eq "V";
    if ($spcat->{'allow_screened'}) { return 1; }
    if (can_help($spcat, $remote)) { return 1; }
    return 0;
}

sub is_locked
{
    my $sp = shift;
    my $spid = ref $sp ? $sp->{spid} : $sp+0;
    return undef unless $spid;
    my $props = LJ::Support::load_props($spid);
    return $props->{locked} ? 1 : 0;
}

sub lock
{
    my $sp = shift;
    my $spid = ref $sp ? $sp->{spid} : $sp+0;
    return undef unless $spid;
    my $dbh = LJ::get_db_writer();
    $dbh->do("REPLACE INTO supportprop (spid, prop, value) VALUES (?, 'locked', 1)", undef, $spid);
}

sub unlock
{
    my $sp = shift;
    my $spid = ref $sp ? $sp->{spid} : $sp+0;
    return undef unless $spid;
    my $dbh = LJ::get_db_writer();
    $dbh->do("DELETE FROM supportprop WHERE spid = ? AND prop = 'locked'", undef, $spid);
}

# privilege policy:
#   supporthelp with no argument gives you all abilities in all public_read categories
#   supporthelp with a catkey arg gives you all abilities in that non-public_read category
#   supportread with a catkey arg is required to view requests in a non-public_read category
#   all other privs work like:
#      no argument = global, where category is public_read or user has supportread on that category
#      argument = local, priv applies in that category only if it's public or user has supportread
sub support_check_priv
{
    my ($cat, $remote, $priv) = @_;
    return 0 unless can_read_cat($cat, $remote);
    return 1 if can_help($cat, $remote);
    return 1 if LJ::check_priv($remote, $priv, '') && $cat->{public_read};
    return 1 if LJ::check_priv($remote, $priv, $cat->{catkey});
    return 0;
}

# can they read internal comments?  if they're a helper or have
# extended supportread (with a plus sign at the end of the category key)
sub can_read_internal
{
    my ($cat, $remote) = @_;
    return 1 if LJ::Support::support_check_priv($cat, $remote, 'supportviewinternal');
    return 1 if LJ::check_priv($remote, "supportread", $cat->{catkey}."+");
    return 0;
}

sub can_make_internal
{
    return LJ::Support::support_check_priv(@_, 'supportmakeinternal');
}

sub can_read_screened
{
    return LJ::Support::support_check_priv(@_, 'supportviewscreened');
}

sub can_perform_actions
{
    return LJ::Support::support_check_priv(@_, 'supportmovetouch');
}

sub can_change_summary
{
    return LJ::Support::support_check_priv(@_, 'supportchangesummary');
}

sub can_see_stocks
{
    return LJ::Support::support_check_priv(@_, 'supportviewstocks');
}

sub can_help
{
    my ($cat, $remote) = @_;
    if ($cat->{'public_read'}) {
        if ($cat->{'public_help'}) {
            return 1;
        }
        if (LJ::check_priv($remote, "supporthelp", "")) { return 1; }
    }
    my $catkey = $cat->{'catkey'};
    if (LJ::check_priv($remote, "supporthelp", $catkey)) { return 1; }
    return 0;
}

sub load_props
{
    my $spid = shift;
    return unless $spid;

    my %props = (); # prop => value

    my $dbr = LJ::get_db_reader();
    my $sth = $dbr->prepare("SELECT prop, value FROM supportprop WHERE spid=?");
    $sth->execute($spid);
    while (my ($prop, $value) = $sth->fetchrow_array) {
        $props{$prop} = $value;
    }

    return \%props;
}

sub prop
{
    my ($spid, $propname) = @_;

    my $props = LJ::Support::load_props($spid);

    return $props->{$propname} || undef;
}

sub set_prop
{
    my ($spid, $propname, $propval) = @_;

    # TODO:
    # -- delete on 'undef' propval
    # -- allow setting of multiple

    my $dbh = LJ::get_db_writer()
        or die "couldn't contact global master";

    $dbh->do("REPLACE INTO supportprop (spid, prop, value) VALUES (?,?,?)",
             undef, $spid, $propname, $propval);
    die $dbh->errstr if $dbh->err;

    return 1;
}

# The following 3 subroutines are working with splid' meta-data from
# supportlogprop table.
#
# prop         : value desc
# --------------------------------------------------------------------------
# approved     : splid of approved answer
# moved_from   : catid of a category support request has been moved from
# moved_to     : catid of a category support request has been moved to
# tags_added   : comma separated list of tags being added to the request
# tags_removed : comma separated list of tags being removed from the request
#
sub load_response_props {
    my $splid = shift;
    return unless $splid;

    my %props = (); # prop => value

    my $dbr = LJ::get_db_reader();
    my $sth = $dbr->prepare("SELECT prop, value FROM supportlogprop WHERE splid=?");
    $sth->execute($splid);
    while (my ($prop, $value) = $sth->fetchrow_array) {
        $props{$prop} = $value;
    }

    return \%props;
}

sub response_prop {
    my ($splid, $propname) = @_;

    my $props = LJ::Support::load_response_props($splid);

    return $props->{$propname} || undef;
}


# LJ::Support::set_response_prop($splid,'approved',$appsplid);
sub set_response_prop {
    my ($splid, $propname, $propval) = @_;

    # TODO:
    # -- delete on 'undef' propval
    # -- allow setting of multiple

    my $dbh = LJ::get_db_writer()
        or die "couldn't contact global master";

    $dbh->do("REPLACE INTO supportlogprop (splid, prop, value) VALUES (?,?,?)",
             undef, $splid, $propname, $propval);
    die $dbh->errstr if $dbh->err;

    return 1;
}


# $loadreq is used by /abuse/report.bml and
# ljcmdbuffer.pl to signify that the full request
# should not be loaded.  To simplify code going live,
# Whitaker and I decided to not try and merge it
# into the new $opts hash.

# $opts->{'db_force'} loads the request from a
# global master.  Needed to prevent a race condition
# where the request may not have replicated to slaves
# in the time needed to load an auth code.

sub load_request
{
    my ($spid, $loadreq, $opts) = @_;
    my $sth;

    $spid += 0;

    # load the support request
    my $db = $opts->{'db_force'} ? LJ::get_db_writer() : LJ::get_db_reader();

    $sth = $db->prepare("SELECT * FROM support WHERE spid=$spid");
    $sth->execute;
    my $sp = $sth->fetchrow_hashref;

    return undef unless $sp;

    # load the category the support requst is in
    $sth = $db->prepare("SELECT * FROM supportcat WHERE spcatid=$sp->{'spcatid'}");
    $sth->execute;
    $sp->{_cat} = $sth->fetchrow_hashref;

    # now load the user's request text, if necessary
    if ($loadreq) {
        $sp->{body} = $db->selectrow_array("SELECT message FROM supportlog WHERE spid = ? AND type = 'req'",
                                           undef, $sp->{spid});
    }

    return $sp;
}

# load_requests:
# Given an arrayref, fetches information about the requests
# with these spid's; unlike load_request(), it doesn't fetch information
# about supportcats.

sub load_requests {
    my ($spids, $dbr) = @_;

    $dbr ||= LJ::get_db_reader();

    my $list = join(',', map { $_+0 } @$spids);
    my $requests = $dbr->selectall_arrayref(
        "SELECT * FROM support WHERE spid IN ($list)",
        { Slice => {} }
    );

    return $requests;
}

sub load_response
{
    my $splid = shift;
    my $sth;

    $splid += 0;

    # load the support request. we hit the master because we generally
    # only invoke this when we want the freshest version of the row.
    # (ie, approving a response changes its type from screened to
    # answer ... then we fetch the row again and make decisions on its type.
    # so we want the authoritative version)
    my $dbh = LJ::get_db_writer();
    $sth = $dbh->prepare("SELECT * FROM supportlog WHERE splid=$splid");
    $sth->execute;
    my $res = $sth->fetchrow_hashref;

    return $res;
}

sub get_answer_types
{
    my ($sp, $remote, $auth) = @_;
    my @ans_type;
    my $spcat = $sp->{_cat};

    if (is_poster($sp, $remote, $auth)) {
        push @ans_type, ("comment", "More information");
        return @ans_type;
    }

    if (can_help($spcat, $remote)) {
        push @ans_type, ("screened" => "Screened Response",
                         "answer" => "Answer",
                         "comment" => "Comment or Question");
    } elsif ($spcat->{'allow_screened'}) {
        push @ans_type, ("screened" => "Screened Response");
    }

    if (can_make_internal($spcat, $remote) &&
        ! $spcat->{'public_help'})
    {
        push @ans_type, ("internal" => "Internal Comment / Action");
    }

    if (can_bounce($sp, $remote)) {
        push @ans_type, ("bounce" => "Bounce to Email & Close");
    }

    return @ans_type;
}

sub file_request
{
    my $errors = shift;
    my $o = shift;

    my $email = $o->{'reqtype'} eq "email" ? $o->{'reqemail'} : "";
    my $log = { 'uniq' => $o->{'uniq'},
                'email' => $email };
    my $userid = 0;
    my $html;
    my $u;

    my $fire_event = exists $o->{fire_event}
        ? $o->{fire_event}
        : 1;

    unless ($email) {
        if ($o->{'reqtype'} eq "user") {
            $u = LJ::load_userid($o->{'requserid'});
            $userid = $u->{'userid'};

            $log->{'user'} = $u->user;
            $log->{'email'} = $u->email_raw;

            unless ($u->is_person || $u->is_identity) {
                push @$errors, "You cannot submit support requests from non-user accounts.";
            }

            if (LJ::sysban_check('support_user', $u->{'user'})) {
                return LJ::sysban_block($userid, "Support request blocked based on user", $log);
            }

            $email = $u->email_raw || $o->{'reqemail'};
            $html  = $u->receives_html_emails;
        }
    }

    if (LJ::sysban_check('support_email', $email)) {
        return LJ::sysban_block($userid, "Support request blocked based on email", $log);
    }
    if (LJ::sysban_check('support_uniq', $o->{'uniq'})) {
        return LJ::sysban_block($userid, "Support request blocked based on uniq", $log);
    }

    my $reqsubject = LJ::trim($o->{'subject'});
    my $reqbody = LJ::trim($o->{'body'});
    my $url =  LJ::trim($o->{'url'});

    if ($url) {
        $reqbody = "Url: $url\n" . $reqbody;
    }

    # remove the auth portion of any see_request.bml links
    $reqbody =~ s/(see_request\.bml.+?)\&auth=\w+/$1/ig;

    unless ($reqsubject) {
        push @$errors, "You must enter a problem summary.";
    }
    unless ($reqbody) {
        push @$errors, "You did not enter a support request.";
    }

    my $cats = LJ::Support::load_cats();
    push @$errors, $BML::ML{'error.invalid.support.category'} unless $cats->{$o->{'spcatid'}+0};

    if (@$errors) { return 0; }

    my $lang = $o->{'language'} || $LJ::DEFAULT_LANG;
    my ($username, $ljuser);
    if ($u) {
        if ($u->prop('browselang')) {
            $lang  = $u->prop('browselang');
        }
        $username = $u->display_username;
        $ljuser   = $u->ljuser_display;
    }

    if (LJ::is_enabled("support_request_language")) {
        $o->{'language'} = undef unless grep { $o->{'language'} eq $_ } (@LJ::LANGS, "xx");
        $reqsubject = "[$o->{'language'}] $reqsubject" if $o->{'language'} && $o->{'language'} !~ /^en_/;
    }

    my $dbh = LJ::get_db_writer();

    my $dup_id = 0;
    my $qsubject = $dbh->quote($reqsubject);
    my $qbody = $dbh->quote($reqbody);
    my $qreqtype = $dbh->quote($o->{'reqtype'});
    my $qrequserid = $o->{'requserid'}+0;
    my $qreqname = $dbh->quote($o->{'reqname'});
    my $qreqemail = $dbh->quote($o->{'reqemail'});
    my $qspcatid = $o->{'spcatid'}+0;

    my $scat = $cats->{$qspcatid};

    # make the authcode
    my $authcode = LJ::make_auth_code(15);
    my $qauthcode = $dbh->quote($authcode);

    my $md5 = md5_hex("$qreqname$qreqemail$qsubject$qbody");
    my $sth;

    $dbh->do("LOCK TABLES support WRITE, duplock WRITE");

    unless ($o->{ignore_dup_check}) {
        $sth = $dbh->prepare("SELECT dupid FROM duplock WHERE realm='support' AND reid=0 AND userid=$qrequserid AND digest='$md5'");
        $sth->execute;
        ($dup_id) = $sth->fetchrow_array;
        if ($dup_id) {
            $dbh->do("UNLOCK TABLES");
            return $dup_id;
        }
    }

    my $spid;

    my $sql = "INSERT INTO support (spid, reqtype, requserid, reqname, reqemail, state, authcode, spcatid, subject, timecreate, timetouched, timeclosed, timelasthelp) VALUES (NULL, $qreqtype, $qrequserid, $qreqname, $qreqemail, 'open', $qauthcode, $qspcatid, $qsubject, UNIX_TIMESTAMP(), UNIX_TIMESTAMP(), 0, 0)";
    $sth = $dbh->prepare($sql);
    $sth->execute;

    if ($dbh->err) {
        my $error = $dbh->errstr;
        $dbh->do("UNLOCK TABLES");
        push @$errors, "<b>Database error:</b> (report this)<br>$error";
        return 0;
    }
    $spid = $dbh->{'mysql_insertid'};

    $dbh->do("INSERT INTO duplock (realm, reid, userid, digest, dupid, instime) VALUES ('support', 0, $qrequserid, '$md5', $spid, NOW())")
        unless $o->{ignore_dup_check};
    $dbh->do("UNLOCK TABLES");

    unless ($spid) {
        push @$errors, "<b>Database error:</b> (report this)<br>Didn't get a spid.";
        return 0;
    }

    # save meta-data for this request
    my @data;
    my $add_data = sub {
        my $q = $dbh->quote($_[1]);
        return unless $q && $q ne 'NULL';
        push @data, "($spid, '$_[0]', $q)";
    };
    my @props = qw(uniq useragent ip has_js is_beta);
    push @props, "language" if LJ::is_enabled("support_request_language");
    foreach my $p (@props) {
        $add_data->($p, $o->{$p});
    }

    if (@data) {
        $dbh->do(
            'INSERT INTO supportprop (spid, prop, value) VALUES ' .
            join( q{,}, @data ) );
    }

    $dbh->do("INSERT INTO supportlog (splid, spid, timelogged, type, faqid, userid, message) ".
             "VALUES (NULL, $spid, UNIX_TIMESTAMP(), 'req', 0, $qrequserid, $qbody)");

    # set the flag on the support request and the support request on the flag
    if ($o->{flagid}) {
        LJ::Support::set_prop($spid, "contentflagid", $o->{flagid});
        LJ::ContentFlag->set_supportid($o->{flagid}, $spid);
    }

    LJ::Event::SupportRequest->new($u, $spid)->fire if $fire_event;

    # and we're done
    return $spid;
}

sub append_request
{
    my $sp = shift;  # support request to be appended to.
    my $re = shift;  # hashref of attributes of response to be appended
    my $sth;

    # $re->{'body'}
    # $re->{'type'}    (req, answer, comment, internal, screened)
    # $re->{'faqid'}
    # $re->{'remote'}  (remote if known)
    # $re->{'uniq'}    (uniq of remote)
    # $re->{'tier'}    (tier of response if type is answer or internal)
    # $re->{'props'}   (meta-data for supportlogprop)

    my $remote = $re->{'remote'};
    my $posterid = $remote ? $remote->{'userid'} : 0;

    # check for a sysban
    my $log = { 'uniq' => $re->{'uniq'} };
    if ($remote) {

        $log->{'user'} = $remote->user;
        $log->{'email'} = $remote->email_raw;

        if (LJ::sysban_check('support_user', $remote->{'user'})) {
            return LJ::sysban_block($remote->{'userid'}, "Support request blocked based on user", $log);
        }
        if (LJ::sysban_check('support_email', $remote->email_raw)) {
            return LJ::sysban_block($remote->{'userid'}, "Support request blocked based on email", $log);
        }
    }

    if (LJ::sysban_check('support_uniq', $re->{'uniq'})) {
        my $userid = $remote ? $remote->{'userid'} : 0;
        return LJ::sysban_block($userid, "Support request blocked based on uniq", $log);
    }

    my $message = $re->{'body'};
    $message =~ s/^\s+//;
    $message =~ s/\s+$//;

    my $dbh = LJ::get_db_writer();

    my $qmessage = $dbh->quote($message);
    my $qtype = $dbh->quote($re->{'type'});

    my $qfaqid = $re->{'faqid'}+0;
    my $quserid = $posterid+0;
    my $spid = $sp->{'spid'}+0;
    my $qtier = $re->{'tier'} ? ($re->{'tier'}+0) . "0" : "NULL";

    my $sql;
    if (LJ::is_enabled("support_response_tier")) {
        $sql = "INSERT INTO supportlog (splid, spid, timelogged, type, faqid, userid, message, tier) VALUES (NULL, $spid, UNIX_TIMESTAMP(), $qtype, $qfaqid, $quserid, $qmessage, $qtier)";
    } else {
        $sql = "INSERT INTO supportlog (splid, spid, timelogged, type, faqid, userid, message) VALUES (NULL, $spid, UNIX_TIMESTAMP(), $qtype, $qfaqid, $quserid, $qmessage)";
    }
    $dbh->do($sql);
    my $splid = $dbh->{'mysql_insertid'};
    my $props = $re->{'props'};
    if ($splid) {
        foreach my $prop (keys %$props) {
            if ($prop) {
                LJ::Support::set_response_prop($splid,$prop,$props->{$prop});
            }
            if ($prop eq 'tags_added') {
                LJ::Event::SupportTagAdd->new($remote, $splid)->fire;
            }
        }
        if ($re->{type} eq 'answer') {
            LJ::Support::set_response_prop($splid,'approved', $splid);
            $dbh->do("UPDATE support SET timelasthelp=UNIX_TIMESTAMP() WHERE spid=$spid");
        }
    }

    if ($posterid) {
        # add to our index of recently replied to support requests per-user.
        $dbh->do("INSERT IGNORE INTO support_youreplied (userid, spid) VALUES (?, ?)", undef,
                 $posterid, $spid);
        die $dbh->errstr if $dbh->err;

        # and also lazily clean out old stuff:
        $sth = $dbh->prepare("SELECT s.spid FROM support s, support_youreplied yr ".
                             "WHERE yr.userid=? AND yr.spid=s.spid AND s.state='closed' ".
                             "AND s.timeclosed < UNIX_TIMESTAMP() - 3600*72");
        $sth->execute($posterid);
        my @to_del;
        push @to_del, $_ while ($_) = $sth->fetchrow_array;
        if (@to_del) {
            my $in = join(", ", map { $_ + 0 } @to_del);
            $dbh->do("DELETE FROM support_youreplied WHERE userid=? AND spid IN ($in)",
                     undef, $posterid);
        }
    }

    LJ::Event::SupportResponse->new($remote, $spid, $splid)->fire;

    return $splid;
}

#get a sum of support points for the specified period from now
sub get_sum_points {
    my ($userid, $period) = @_;
    
    my $to   = time() - time()%86400;
    my $from = $to - $period; 
    my $dbh  = LJ::get_db_writer();
    
    
    my ($sum) = $dbh->selectrow_array(
                                    qq{
                                        SELECT sum(points)
                                        FROM   supportpoints
                                        WHERE  userid = ? AND
                                               timeclosed BETWEEN
                                               ? AND ?
                                    },
                                    undef,
                                    $userid,
                                    $from,
                                    $to
    );
    
    return $sum;
}


# userid may be undef/0 in the setting to zero case
sub set_points
{
    my ($spid, $userid, $points) = @_;

    my $dbh = LJ::get_db_writer();
    if ($points) {
        $dbh->do("REPLACE INTO supportpoints (spid, userid, points, timeclosed) ".
                 "VALUES (?,?,?,UNIX_TIMESTAMP())", undef, $spid, $userid, $points);
    } else {
        $userid ||= $dbh->selectrow_array("SELECT userid FROM supportpoints WHERE spid=?",
                                          undef, $spid);
        $dbh->do("DELETE FROM supportpoints WHERE spid=?", undef, $spid);
    }

    $dbh->do("REPLACE INTO supportpointsum (userid, totpoints, lastupdate) ".
             "SELECT userid, SUM(points), UNIX_TIMESTAMP() FROM supportpoints ".
             "WHERE userid=? GROUP BY 1", undef, $userid) if $userid;

    # clear caches
    if ($userid) {
        my $u = LJ::load_userid($userid);
        delete $u->{_supportpointsum} if $u;

        my $memkey = [$userid, "supportpointsum:$userid"];
        LJ::MemCache::delete($memkey);
    }
}

# closes request, assigning points for the last response left to the request

sub close_request_with_points {
    my ($sp, $spcat, $remote) = @_;

    my $spid = $sp->{'spid'}+0;

    my $dbh = LJ::get_db_writer();
    $dbh->do('UPDATE support SET state="closed", '.
             'timeclosed=UNIX_TIMESTAMP() WHERE spid=?', undef, $spid);

    my $response = $dbh->selectrow_hashref(
        'SELECT splid, timelogged, userid FROM supportlog '.
        'WHERE spid=? AND type="answer" '.
        'ORDER BY timelogged DESC LIMIT 1', undef, $spid);

    my $res;
    unless (defined $response) {
        $res = $dbh->do(
            'INSERT INTO supportlog '.
            '(spid, timelogged, type, userid, message) VALUES '.
            '(?, UNIX_TIMESTAMP(), "internal", ?, ?)', undef,
            $spid, LJ::want_userid($remote),
            "(Request has been closed as part of mass closure)");
        return 0;
    }

    my $helperid = $response->{'userid'};
    my $points = LJ::Support::calc_points(
        $sp, $response->{'timelogged'} - $sp->{'timecreate'}, $spcat);

    LJ::Support::set_points($spid, $helperid, $points);

    # deliberately not using LJ::Support::append_request
    # to avoid sysban checks etc.; this sub is supposed to be fast.

    my $username = LJ::want_user($response->{'userid'})->display_name;

    $res = $dbh->do(
        'INSERT INTO supportlog '.
        '(spid, timelogged, type, userid, message) VALUES '.
        '(?, UNIX_TIMESTAMP(), "internal", ?, ?)', undef,
        $spid, LJ::want_userid($remote),
        "(Request has been closed as part of mass closure, ".
        "granting $points points to $username ".
        "for response #".$response->{'splid'}.")");
    return $helperid;
}

sub touch_request
{
    my ($spid) = @_;

    # no touching if the request is locked
    return 0 if LJ::Support::is_locked($spid);

    my $dbh = LJ::get_db_writer();

    $dbh->do("UPDATE support".
             "   SET state='open', timeclosed=0, timetouched=UNIX_TIMESTAMP()".
             " WHERE spid=?",
             undef, $spid)
      or return 0;

    set_points($spid, undef, 0);

    return 1;
}

sub mail_response_to_user
{
    my $sp = shift;
    my $splid = shift;

    $splid += 0;

    my $res = load_response($splid);

    my ($u, $email, $html, $email_format);
    if ($sp->{'reqtype'} eq "email") {
        $email = $sp->{'reqemail'};
    } else {
        $u = LJ::load_userid($sp->{'requserid'});
        $email = $u->email_raw || $sp->{'reqemail'};
        $html  = $u->receives_html_emails;
    }

    $email_format = $html ? 'html' : 'plain';
    my $spid  = $sp->{'spid'}+0;
    my $faqid = $res->{'faqid'}+0;
    my $type  = $res->{'type'};

    # don't mail internal comments (user shouldn't see) or
    # screened responses (have to wait for somebody to approve it first)
    return if ($type eq "internal" || $type eq "screened");

    # the only way it can be zero is if it's a reply to an email, so it's
    # problem the person replying to their own request, so we don't want
    # to mail them:
    return unless ($res->{'userid'});

    # also, don't send them their own replies:
    return if ($sp->{'requserid'} == $res->{'userid'});

    my $lang = LJ::Support::prop($sp->{'spid'}, 'language') || $LJ::DEFAULT_LANG;
    my ($username, $ljuser);
    if ($u) {
        if ($u->prop('browselang')) {
            $lang  = $u->prop('browselang');
        }
        $username = $u->display_username;
        $ljuser   = $u->ljuser_display;
    }

    my $dbh = LJ::get_db_writer();
    my $miniauth = mini_auth($sp);
    my $urlauth  = "$LJ::SITEROOT/support/see_request.bml?id=$spid&auth=$miniauth";

    # preparing [[faqref]] param
    my $faqref='';
    if ($faqid) {
        my $faq = LJ::Faq->load($faqid, lang => $lang);
        $faq->render_in_place;
        my $faqname = $faq->question_raw || '';
        $faqref = LJ::Lang::get_text (
                    $lang,
                    "notification.support.reply.request.faqref." . $email_format,
                    undef,
                    {
                        faqname =>  $faqname,
                        faqurl  =>  LJ::Faq->page_url( 'faqid' => $faqid ),
                    }
                  );
    }

    # preparing [[closeable]] param
    my $closeable='';
    if ($sp->{_cat}->{user_closeable}) {
        my $closeurl = "$LJ::SITEROOT/support/act.bml?" .
                       "close;$spid;$sp->{'authcode'}";
        $closeurl .= ";$splid" if $type eq "answer";
        $closeable = LJ::Lang::get_text (
                    $lang,
                    "notification.support.reply.request.closeable." . $email_format,
                    undef,
                    {
                        closeurl => $closeurl,
                        urlauth  => $urlauth,
                    }
                  );
    }

    my $fromemail;
    my $bogus_note = '';
    if ($sp->{_cat}->{'replyaddress'}) {
        my $miniauth = mini_auth($sp);
        $fromemail = $sp->{_cat}->{'replyaddress'};
        # insert mini-auth stuff:
        my $rep = "+${spid}z$miniauth\@";
        $fromemail =~ s/\@/$rep/;
    } else {
        $fromemail = $LJ::BOGUS_EMAIL;
        $bogus_note = LJ::Lang::get_text (
                        $lang,
                        'notification.support.bogus_email.note'
                      );
    }

    my $requester = LJ::Lang::get_text ($lang,'notification.support.requester');
    my $reply_type = LJ::Lang::get_text ( $lang, "support.request." . $type );
    my $subject = LJ::Lang::get_text (
                    $lang,
                    'notification.support.reply.request.subject',
                    undef,
                    {
                        subject     => $sp->{'subject'},
                        request_id  => $spid
                    }
                  );
    my $body = LJ::Lang::get_text (
                        $lang,
                        'notification.support.reply.request.body.plain',
                        undef,
                        {
                            username    => $username ||
                                           $sp->{'reqname'} ||
                                           $requester,
                            reply_type  => $reply_type,
                            subject     => $sp->{'subject'},
                            request_id  => $spid,
                            urlauth     => $urlauth,
                            faqref      => $faqref,
                            reply_text  => $res->{'message'},
                            closeable   => $closeable,
                            sitename    => $LJ::SITENAMESHORT,
                            siteroot    => $LJ::SITEROOT,
                            bogus_note  => $bogus_note,
                        }
                );
    if ($html) {
        my $html_body = LJ::Lang::get_text (
                            $lang,
                            'notification.support.reply.request.body.html',
                            undef,
                            {
                                username    => $ljuser ||
                                               $sp->{'reqname'} ||
                                               $requester,
                                reply_type  => $reply_type,
                                subject     => $sp->{'subject'},
                                request_id  => $spid,
                                urlauth     => $urlauth,
                                faqref      => $faqref,
                                reply_text  => LJ::html_newlines(
                                                  LJ::ehtml($res->{'message'})),
                                closeable   => $closeable,
                                sitename    => $LJ::SITENAMESHORT,
                                siteroot    => $LJ::SITEROOT,
                                bogus_note  => $bogus_note,
                            }
                        );
        LJ::send_mail({
            to          => $email,
            from        => $fromemail,
            fromname    => "$LJ::SITENAMESHORT Support",
            charset     => 'utf-8',
            subject     => $subject,
            body        => $body,
            html        => $html_body,
        });
    } else {
        LJ::send_mail({
            to          => $email,
            from        => $fromemail,
            fromname    => "$LJ::SITENAMESHORT Support",
            charset     => 'utf-8',
            subject     => $subject,
            body        => $body,
        });
    }


}

sub mini_auth
{
    my $sp = shift;
    return substr($sp->{'authcode'}, 0, 4);
}

# <LJFUNC>
# name: LJ::Support::get_support_by_daterange
# des: Get all the [dbtable[support]] rows based on a date range.
# args: date1, date2
# des-date1: YYYY-MM-DD of beginning date of range
# des-date2: YYYY-MM-DD of ending date of range
# returns: HashRef of support rows by support id
# </LJFUNC>
sub get_support_by_daterange {
    my ($date1, $date2) = @_;

    # Build the query out based on the dates specified
    my $time1 = LJ::TimeUtil->mysqldate_to_time($date1);
    my $time2 = LJ::TimeUtil->mysqldate_to_time($date2) + $SECONDS_IN_DAY;

    # Convert from times to IDs because support.timecreate isn't indexed
    my ($start_id, $end_id) = LJ::DB::time_range_to_ids
                                   (table       => 'support',
                                    roles       => ['slow'],
                                    idcol       => 'spid',
                                    timecol     => 'timecreate',
                                    starttime   => $time1,
                                    endtime     => $time2,
                                   );

    # Generate the SQL.  Include time fields to be safe
    my $sql = "SELECT * FROM support "
            . "WHERE spid >= ? AND spid <= ? "
            . "  AND timecreate >= ? AND timecreate < ?";

    # Get the results from the database
    my $dbh = LJ::Support::slow_query_dbh()
        or return "Database unavailable";
    my $sth = $dbh->prepare($sql);
    $sth->execute($start_id, $end_id, $time1, $time2);
    die $dbh->errstr if $dbh->err;
    $sth->{mysql_use_result} = 1;

    # Loop over the results, generating a hash by Support ID
    my %result_hash = ();
    while (my $row = $sth->fetchrow_hashref) {
        $result_hash{$row->{spid}} = $row;
    }

    return \%result_hash;
}

# <LJFUNC>
# name: LJ::Support::get_support_by_ids
# des: Get all the [dbtable[support]] rows based on a list of Support IDs
# args: support_ids_ref
# des-support_ids_ref: ArrayRef of Support IDs.
# returns: ArrayRef of support rows
# </LJFUNC>
sub get_support_by_ids {
    my ($support_ids_ref) = @_;
    my %result_hash = ();
    return \%result_hash unless @$support_ids_ref;

    # Build the query out based on the dates specified
    my $support_ids_bind = join ',', map { '?' } @$support_ids_ref;
    my $sql = "SELECT * FROM support "
            . "WHERE spid IN ($support_ids_bind)";

    # Get the results from the database
    my $dbh = LJ::Support::slow_query_dbh()
        or return "Database unavailable";
    my $sth = $dbh->prepare($sql);
    $sth->execute(@$support_ids_ref);
    die $dbh->errstr if $dbh->err;
    $sth->{mysql_use_result} = 1;

    # Loop over the results, generating a hash by Support ID
    while (my $row = $sth->fetchrow_hashref) {
        $result_hash{$row->{spid}} = $row;
    }

    return \%result_hash;
}

# <LJFUNC>
# name: LJ::Support::get_supportlogs
# des: Get all the [dbtable[supportlog]] rows for a list of Support IDs.
# args: support_ids_ref
# des-support_ids_ref: ArrayRef of Support IDs.
# returns: HashRef of supportlog rows by support id.
# </LJFUNC>
sub get_supportlogs {
    my $support_ids_ref = shift;
    my %result_hash = ();
    return \%result_hash unless @$support_ids_ref;

    # Build the query out based on the dates specified
    my $spid_bind = join ',', map { '?' } @$support_ids_ref;
    my $sql = "SELECT * FROM supportlog WHERE spid IN ($spid_bind) ";

    # Get the results from the database
    my $dbh = LJ::Support::slow_query_dbh()
        or return "Database unavailable";
    my $sth = $dbh->prepare($sql);
    $sth->execute(@$support_ids_ref);
    die $dbh->errstr if $dbh->err;
    $sth->{mysql_use_result} = 1;

    # Loop over the results, generating a hash by Support ID
    while (my $row = $sth->fetchrow_hashref) {
        push @{$result_hash{$row->{spid}}}, $row;
    }

    return \%result_hash;
}

# <LJFUNC>
# name: LJ::Support::get_touch_supportlogs_by_user_and_date
# des: Get all touch (non-req) supportlogs based on User ID and Date Range.
# args: userid, date1, date2
# des-userid: User ID to filter on, or Undef for all users.
# des-date1: YYYY-MM-DD of beginning date of range
# des-date2: YYYY-MM-DD of ending date of range
# returns: Support HashRef of Support Logs Array, sorted by log time.
# </LJFUNC>
sub get_touch_supportlogs_by_user_and_date {
    my ($userid, $date1, $date2) = @_;

    # Build the query out based on the dates specified
    my $time1 = LJ::TimeUtil->mysqldate_to_time($date1);
    my $time2 = LJ::TimeUtil->mysqldate_to_time($date2) + $SECONDS_IN_DAY;

    # Convert from times to IDs because supportlog.timelogged isn't indexed
    my ($start_id, $end_id) = LJ::DB::time_range_to_ids
                                   (table       => 'supportlog',
                                    roles       => \@LJ::SUPPORT_SLOW_ROLES,
                                    idcol       => 'splid',
                                    timecol     => 'timelogged',
                                    starttime   => $time1,
                                    endtime     => $time2,
                                   );

    # Generate the SQL.  Include time fields to be safe
    my $sql = "SELECT * FROM supportlog"
            . " WHERE type <> 'req' "
            . " AND splid >= ? AND splid <= ?"
            . " AND timelogged >= ? AND timelogged < ?"
            . ($userid ? " AND userid = ?" : '');

    # Get the results from the database
    my $dbh = LJ::Support::slow_query_dbh()
        or return "Database unavailable";
    my $sth = $dbh->prepare($sql);
    my @parms = ($start_id, $end_id, $time1, $time2);
    push @parms, $userid if $userid;
    $sth->execute(@parms);
    die $dbh->errstr if $dbh->err;
    $sth->{mysql_use_result} = 1;

    # Store the query results in an array
    my @results;
    while (my $row = $sth->fetchrow_hashref) {
        push @results, $row;
    }

    # Sort logs by time
    @results = sort {$a->{timelogged} <=> $b->{timelogged}} @results;

    # Loop over the results, generating an array that's hashed by Support ID
    my %result_hash = ();
    foreach my $row (@results) {
        push @{$result_hash{$row->{spid}}}, $row;
    }

    return \%result_hash;
}

# <LJFUNC>
# name: LJ::Support::get_previous_screened_replies
# des: Get screened replies between approve one and the previous answer
# args: splid
# splid: newly approved reply
# returns: hashref  {splid => userid}
# </LJFUNC>
sub get_previous_screened_replies {
    my $splid = shift;

    my $resp           = LJ::Support::load_response($splid);
    my $approved_splid = LJ::Support::response_prop($splid, 'approved');
    my $spid           = $resp->{spid};



    my $dbr = LJ::get_db_reader();
    my $touches = $dbr->selectall_arrayref(
                            qq{
                                SELECT   splid, type, userid
                                FROM     supportlog
                                WHERE    spid = ? AND
                                         splid < ?
                                ORDER BY splid DESC
                            },
                            { Slice => {} },
                            $spid,
                            $splid
                        );
    my %res;
    foreach my $touch (@$touches) {
        if ($touch->{type} eq 'screened') {
            $res{$touch->{splid}} = $touch->{userid};
        }
        elsif (($touch->{type} eq 'internal') ||
               ($touch->{splid} == $approved_splid)) {
            next;
        } else {
            last;
        }
    }

    return \%res;
}

# <LJFUNC>
# name: LJ::Support::get_stock_answer_catid
# des: Get support category id for specified stock answer
# args: ansid
# ansid: id of support stock answer we are looking after
# returns: spcatid or undef
# </LJFUNC>
sub get_stock_answer_catid {
    my $ansid = shift;
    
    my $dbr = LJ::get_db_reader();
    my $res = $dbr->selectrow_hashref( 
        qq(
            SELECT spcatid
            FROM   support_answers
            WHERE  ansid = ?
        ),
        undef,
        $ansid,
    );

    return $res->{'spcatid'} if $res;

    return 0;
}

# <LJFUNC>
# name: LJ::Support::get_latest_screen
# des: Get screened replies between approve one and the previous answer
# args: splid, userid
# splid: id of response we are looking after
# userid: userid of the author
# returns: splid or undef
# </LJFUNC>
sub get_latest_screen {
    my ($splid, $userid) = @_;

    my $screens = LJ::Support::get_previous_screened_replies($splid);

    foreach my $key (sort {$b <=> $a} keys %$screens) {
        if ($screens->{$key} eq $userid) {
            return $key;
        }
    }

    return undef;
}



# <LJFUNC>
# name:     LJ::Support::get_touches_by_type
# des:      Get support request replies of particular type
# args:     spid, type
# des-spid: support request id
# des-type: reply type
# returns:  hashref  {splid => userid}
# </LJFUNC>
sub get_touches_by_type {
    my ($spid,$type) = @_;

    my $dbr = LJ::get_db_reader();
    my $touches = $dbr->selectall_arrayref(
                            qq{
                                SELECT   splid, userid
                                FROM     supportlog
                                WHERE    spid = ? AND
                                         type = ?
                                ORDER BY splid DESC
                            },
                            { Slice => {} },
                            $spid,
                            $type
                        );
    my %res;
    foreach my $touch (@$touches) {
        $res{$touch->{splid}} = $touch->{userid};
    }

    return \%res;
}

# <LJFUNC>
# name:     LJ::Support::is_helper
# des:      Check if user answered to the request
# args:     u, spid
# des-spid: support request id
# des-u:    LJ::user object
# returns:  boolean
# </LJFUNC>
sub is_helper {
    my ($u,$spid) = @_;

    my $dbr = LJ::get_db_reader();
    my ($splid) = $dbr->selectrow_array(
                                    qq{
                                        SELECT splid
                                        FROM   supportlog
                                        WHERE  spid = ? AND
                                               userid = ? AND
                                               type='answer'
                                    },
                                    undef,
                                    $spid,
                                    $u->id,
    );

    return 1 if $splid;

    return 0;
}

sub support_notify {
    my $params = shift;
    my $sclient = LJ::theschwartz() or
        return 0;

    my $h = $sclient->insert("LJ::Worker::SupportNotify", $params);
    return $h ? 1 : 0;
}

package LJ::Worker::SupportNotify;
use base 'TheSchwartz::Worker';

use LJ::Text;

sub work {
    my ($class, $job) = @_;
    my $a = $job->arg;

    # load basic stuff common to both paths
    my $type = $a->{type};
    my $spid = $a->{spid}+0;
    my $load_body = $type eq 'new' ? 1 : 0;
    my $sp = LJ::Support::load_request($spid, $load_body, { force => 1 }); # force from master
    my $cat = $sp->{_cat};
    # we're only going to be reading anyway, but these jobs
    # sometimes get processed faster than replication allows,
    # causing the message not to load from the reader
    my $dbr = LJ::get_db_writer();

    # now branch a bit to select the right user information
    my $level = $type eq 'new' ? "'new', 'all'" : "'all'";
    my $data = $dbr->selectcol_arrayref("SELECT userid FROM supportnotify " .
                                        "WHERE spcatid=? AND level IN ($level)", undef, $cat->{spcatid});
    my $userids = LJ::load_userids(@$data);

    # prepare the email
    my $body;
    my @emails;

    my $req_subject = LJ::Text->fix_utf8($sp->{'subject'});
    if ($type eq 'new') {
        $body = "A $LJ::SITENAME support request has been submitted regarding the following:\n\n";
        $body .= "Category: $cat->{catname}\n";
        $body .= "Subject:  $req_subject\n\n";
        $body .= "You can track its progress or add information here:\n\n";
        $body .= "$LJ::SITEROOT/support/see_request.bml?id=$spid";
        $body .= "\n\nIf you do not wish to receive notifications of incoming support requests, you may change your notification settings here:\n\n";
        $body .= "$LJ::SITEROOT/support/changenotify.bml";
        $body .= "\n\n" . "="x70 . "\n\n";
        $body .= LJ::Text->fix_utf8($sp->{body});

        foreach my $u (values %$userids) {
            next unless $u->is_visible;
            next unless $u->{status} eq "A";
            push @emails, $u->email_raw;
        }


    } elsif ($type eq 'update') {
        # load the response we want to stuff in the email
        my ($resp, $rtype, $posterid) =
            $dbr->selectrow_array("SELECT message, type, userid FROM supportlog WHERE spid = ? AND splid = ?",
                                  undef, $sp->{spid}, $a->{splid}+0);

        # build body
        $body = "A follow-up to the request regarding \"$req_subject\" has ";
        $body .= "been submitted.  You can track its progress or add ";
        $body .= "information here:\n\n  ";
        $body .= "$LJ::SITEROOT/support/see_request.bml?id=$spid";
        $body .= "\n\n" . "="x70 . "\n\n";
        $body .= LJ::Text->fix_utf8($resp);

        # now see who this should be sent to
        foreach my $u (values %$userids) {
            next unless $u->is_visible;
            next unless $u->{status} eq "A";
            next if $posterid == $u->id;
            next if $rtype eq 'screened' &&
                !LJ::Support::can_read_screened($cat, $u);
            next if $rtype eq 'internal' &&
                !LJ::Support::can_read_internal($cat, $u);
            push @emails, $u->email_raw;
        }
    }

    # send the email
    LJ::send_mail({
        bcc => join(', ', @emails),
        from => $LJ::BOGUS_EMAIL,
        fromname => "$LJ::SITENAME Support",
        charset => 'utf-8',
        subject => ($type eq 'update' ? 'Re: ' : '') . "Support Request \#$spid",
        body => $body,
        wrap => 1,
    }) if @emails;

    $job->completed;
    return 1;
}

sub keep_exit_status_for { 0 }
sub grab_for { 30 }
sub max_retries { 5 }
sub retry_delay {
    my ($class, $fails) = @_;
    return 30;
}

1;
