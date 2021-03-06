package LJ::Event::Befriended;
use strict;
use Scalar::Util qw(blessed);
use Carp qw(croak);
use base 'LJ::Event';

sub new {
    my ($class, $u, $fromu) = @_;

    my $uid      = LJ::want_userid($u); ## friendid
    my $fromuid  = LJ::want_userid($fromu);
    return $class->SUPER::new($uid, $fromuid);
}

sub is_common { 0 }

my @_ml_strings_en = (
    'esn.public',                       # 'public',
    'esn.befriended.subject',           # '[[who]] added you as a friend!',
    'esn.add_friend',                   # '[[openlink]]Add [[journal]] to your Friends list[[closelink]]',
    'esn.read_journal',                 # '[[openlink]]Read [[postername]]\'s journal[[closelink]]',
    'esn.view_profile',                 # '[[openlink]]View [[postername]]\'s profile[[closelink]]',
    'esn.edit_friends',                 # '[[openlink]]Edit Friends[[closelink]]',
    'esn.edit_groups',                  # '[[openlink]]Edit Friends groups[[closelink]]',
    'esn.befriended.alert',             # '[[who]] has added you as a friend.',
    'esn.befriended.email_text',        # 'Hi [[user]],
                                        #
                                        #[[poster]] has added you to their Friends list. They will now be able to read your[[entries]] entries on their Friends page.
                                        #
                                        #You can:',
    'esn.befriended.openid_email_text', # 'Hi [[user]],
                                        #
                                        #[[poster]] has added you to their Friends list.
                                        #
                                        #You can:',
                                        #
    'esn.befriended.params.body',       # [[user]] has added you as a friend.
    'esn.befriended.params.subject',    # Someone has addded you as friend.
    'esn.befriended.actions.add.friend', # Add Friend
    'esn.befriended.actions.view.profile', # View Profile

);

sub as_email_subject {
    my ($self, $u) = @_;
    return LJ::Lang::get_text($u->prop('browselang'), 'esn.befriended.subject', undef, { who => $self->friend->display_username } );
}

sub _as_email {
    my ($self, $u, $is_html) = @_;

    my $lang        = $u->prop('browselang');
    my $user        = $is_html ? ($u->ljuser_display) : ($u->display_username);
    my $poster      = $is_html ? ($self->friend->ljuser_display) : ($self->friend->display_username);
    my $postername  = $self->friend->user;
    my $journal_url = $self->friend->journal_base;
    my $journal_profile = $self->friend->profile_url;

    # Precache text lines
    LJ::Lang::get_text_multi($lang, undef, \@_ml_strings_en);

    my $entries = LJ::is_friend($u, $self->friend) ? "" : " " . LJ::Lang::get_text($lang, 'esn.public', undef);
    my $is_open_identity = $self->friend->is_identity;

    my $vars = {
        who         => $self->friend->display_username,
        poster      => $poster,
        postername  => $poster,
        journal     => $poster,
        user        => $user,
        entries     => $entries,
    };

    my $email_body_key = 'esn.befriended.' .
        ($u->is_identity ? 'openid_' : '' ) . 'email_text';

    return LJ::Lang::get_text($lang, $email_body_key, undef, $vars) .
        $self->format_options($is_html, $lang, $vars,
        {
            'esn.add_friend'      => [ LJ::is_friend($u, $self->friend) ? 0 : 1,
                                            # Why not $self->friend->addfriend_url ?
                                            "$LJ::SITEROOT/friends/add.bml?user=$postername" ],
            'esn.read_journal'    => [ $is_open_identity ? 0 : 2,
                                            $journal_url ],
            'esn.view_profile'    => [ 3, $journal_profile ],
            'esn.edit_friends'    => [ 4, "$LJ::SITEROOT/friends/edit.bml" ],
            'esn.edit_groups'     => [ 5, "$LJ::SITEROOT/friends/editgroups.bml" ],
        }
    );
}

sub as_email_string {
    my ($self, $u) = @_;
    return _as_email($self, $u, 0);
}

sub as_email_html {
    my ($self, $u) = @_;
    return _as_email($self, $u, 1);
}

sub friend {
    my $self = shift;
    return LJ::load_userid($self->arg1);
}

sub as_html {
    my $self = shift;
    return sprintf("%s has added you as a friend.",
                   $self->friend->ljuser_display);
}

sub as_html_actions {
    my ($self) = @_;

    my $u = $self->u;
    my $friend = $self->friend;
    my $ret .= "<div class='actions'>";
    $ret .= $u->is_friend($friend)
            ? " <a href='" . $friend->profile_url . "'>View Profile</a>"
            : " <a href='" . $friend->addfriend_url . "'>Add Friend</a>";
    $ret .= "</div>";

    return $ret;
}

sub as_string {
    my $self = shift;
    return sprintf("%s has added you as a friend.",
                   $self->friend->{user});
}

sub as_sms {
    my ($self, $u, $opt) = @_;
    my $lang = $u->prop('browselang') || $LJ::DEFAULT_LANG;
    
    my $tinyurl = "http://m.livejournal.com/read/user/"
        . $self->friend->user;
    my $mparms = $opt->{mobile_url_extra_params};
    $tinyurl .= '?' . join('&', map {$_ . '=' . $mparms->{$_}} keys %$mparms) if $mparms;
    $tinyurl = LJ::Client::BitLy->shorten($tinyurl);
    undef $tinyurl if $tinyurl =~ /^500/;

# [[friend]] has added you to their friends list. Reply with ADD [[friend]] to add them [[disclaimer]]
    return LJ::Lang::get_text($lang, 'notification.sms.befriended', undef, { 
        friend     => $self->friend->user,
        disclaimer => $LJ::SMS_DISCLAIMER,
        mobile_url => $tinyurl,
    });
}

sub as_alert {
    my $self = shift;
    my $u = shift;
    my $friend = $self->friend;
    return '' unless $friend;
    return LJ::Lang::get_text($u->prop('browselang'),
        'esn.befriended.alert', undef, { who => $friend->ljuser_display() });
}

sub subscription_as_html {
    my ($class, $subscr) = @_;
    my $journal = $subscr->journal or croak "No user";
    my $journal_is_owner = LJ::u_equals($journal, $subscr->owner);

    if ($journal_is_owner) {
        return LJ::Lang::ml('event.befriended.me');   # "Someone adds me as a friend";
    } else {
        my $user = $journal->ljuser_display;
        return LJ::Lang::ml('event.befriended.user', { user => $user } ); # "Someone adds $user as a friend";
    }
}

sub content {
    my ($self, $target) = @_;
    return $self->as_html_actions;
}

sub tmpl_params {
    my ($self, $remote) = @_; 
    
    my $u = $self->u;
    my $friend = $self->friend;

    my $lang = $remote && $remote->prop('browselang') || $LJ::DEFAULT_LANG;

    my $actions = [];

    if ($u->is_friend($friend)) {
        push @$actions, {
            action_url => $friend->profile_url,
            action     => LJ::Lang::get_text($lang, "esn.befriended.actions.view.profile"),
        }
    } else {
        push @$actions, {
            action_url => $friend->addfriend_url,
            action     => LJ::Lang::get_text($lang, "esn.befriended.actions.add.friend"),
        }
    }
 
    return {
        body    => LJ::Lang::get_text($lang, "esn.befriended.params.body", undef, { user => $friend->ljuser_display } ),
        userpic => $friend->userpic ? $friend->userpic->url : '',
        subject => LJ::Lang::get_text($lang, "esn.befriended.params.subject"), 
        actions => $actions,
    }
}

sub available_for_user  {
    my ($self, $u) = @_;

    return $self->userid != $u->id ? 0 : 1;
}

sub is_subscription_visible_to  {
    my ($self, $u) = @_;

    return $self->userid != $u->id ? 0 : 1;
}

sub is_tracking { 0 }

sub as_push {
    my $self = shift;
    my $u    = shift;
    my $lang = shift;

    return LJ::Lang::get_text($lang, "esn.push.notification.befriended", 1, {
        user => $self->friend->user,
    })
}

sub as_push_payload {
    my $self = shift;

    return { 't' => 7,
             'j' => $self->friend->user,   
           };
}

sub update_events_counter {
    my $self = shift;

    my $u = $self->u;
    return unless $u;

    my $etypeid = $self->etypeid;
    return unless $etypeid;

    my $friend = $self->friend;
    return unless $friend;

    my $friendid  = $friend->userid;
    return unless $friendid;

    LJ::Widget::HomePage::UpdatesForUser->add_event($u, pack("nnN", int(rand(2**16)), $etypeid, $friendid));
}

1;
