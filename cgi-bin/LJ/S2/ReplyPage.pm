#!/usr/bin/perl
#

use strict;
package LJ::S2;
use LJ::TimeUtil;
use LJ::UserApps;

sub ReplyPage
{
    my ($u, $remote, $opts) = @_;

    # Check if we should redirect due to a bad password
    $opts->{'redir'} = LJ::bad_password_redirect({ 'returl' => 1 }); # Get the URL back
    return 1 if $opts->{'redir'};

    my $p = Page($u, $opts);
    $p->{'_type'} = "ReplyPage";
    $p->{'view'} = "reply";
    $p->{'head_content'}->set_object_type( $p->{'_type'} );

    my $get = $opts->{'getargs'};

    my ($entry, $s2entry) = EntryPage_entry($u, $remote, $opts);
    return if $opts->{'suspendeduser'};

    # reply page of suspended entry cannot be accessed by anyone, even entry poster
    if ($entry && $entry->is_suspended) {
        $opts->{suspendedentry} = 1;
        return;
    }

    # read-only users can't comment anywhere
    if ($remote && $remote->is_readonly) {
        $opts->{readonlyremote} = 1;
        return;
    }

    # no one can comment in a read-only journal
    if ($u->is_readonly) {
        $opts->{readonlyjournal} = 1;
        return;
    }

    return if $opts->{'handler_return'};
    return if $opts->{'redir'};
    my $ditemid = $entry->ditemid;    

    LJ::Talk::resources_for_talkform();    

    my $block_robots = ($u->should_block_robots || $entry->should_block_robots);
    $p->{head_content}->set_options( {reply_block_robots => $block_robots } );

    $p->{'entry'} = $s2entry;
    LJ::run_hook('notify_event_displayed', $entry);

    # setup the replying item
    my $replyto = $s2entry;
    my $editid = $get->{edit} ? $get->{edit} : 0;
    my $replytoid = $get->{replyto} ? $get->{replyto} : 0;
    my $parpost;

    my $comment;
    my %comment_values;
    if ($editid) {
        my $errref;
        $comment = LJ::Comment->new($u, dtalkid => $editid);

        unless ($comment) {
            my $comment = LJ::Lang::ml('comment.not.found');
            $opts->{status} = "404 $comment)";
            return "<p>$comment</p>";
        }
        unless ($remote) {
            my $redir = LJ::eurl( LJ::Request->current_page_url );
            $opts->{'redir'} = "$LJ::SITEROOT/?returnto=$redir&errmsg=notloggedin";
            return;
        }
        unless ($comment->remote_can_edit(\$errref)) {
            if ($errref) {
                $opts->{status} = "403 Forbidden";
                return "<p>$errref</p>";
            }
            $opts->{'handler_return'} = 403;
            return;
        }

        $parpost = $comment->parent;
        $parpost = undef if $parpost && !$parpost->is_active;

        $replytoid = $parpost ? $comment->parent->dtalkid : 0;

        $comment_values{edit} = $editid;
        $comment_values{replyto} = $replytoid;
        $comment_values{subject} = $comment->subject_orig;
        $comment_values{body} = $comment->body_orig;
        $comment_values{subjecticon} = $comment->prop('subjecticon');
        $comment_values{prop_picture_keyword} = $comment->prop('picture_keyword');
        $comment_values{prop_opt_preformatted} = $comment->prop('opt_preformatted');
    }

    if ($replytoid) {
        my $re_talkid = int($replytoid / 256);
        my $re_anum = $replytoid % 256;
        unless ($re_anum == $entry->anum) {
            $opts->{'handler_return'} = 404;
            return;
        }

        my $sql = "SELECT jtalkid, posterid, state, datepost FROM talk2 ".
            "WHERE journalid=$u->{'userid'} AND jtalkid=$re_talkid ".
            "AND nodetype='L' AND nodeid=" . $entry->jitemid;
        foreach my $pass (1, 2) {
            my $db = $pass == 1 ? LJ::get_cluster_reader($u) : LJ::get_cluster_def_reader($u);
            $parpost = $db->selectrow_hashref($sql);
            last if $parpost;
        }
        unless ($parpost and $parpost->{'state'} ne 'D') {
            # FIXME: This is a hack. See below...

            $opts->{status} = "404 Not Found";
            return "<p>This comment has been deleted; you cannot reply to it.</p>";
        }
        if ($parpost->{'state'} eq 'S' && !LJ::Talk::can_unscreen($remote, $u, $s2entry->{'poster'}->{'username'}, undef)) {
            $opts->{'handler_return'} = 403;
            return;
        }
        if ($parpost->{'state'} eq 'F') {
            # frozen comment, no replies allowed

            # FIXME: eventually have S2 ErrorPage to handle this and similar
            #    For now, this hack will work; this error is pretty uncommon anyway.
            $opts->{status} = "403 Forbidden";
            return "<p>This thread has been frozen; no more replies are allowed.</p>";
        }
        if ($entry->is_suspended) {
            $opts->{status} = "403 Forbidden";
            return "<p>This entry has been suspended; you cannot reply to it.</p>";
        }
        if ($remote && $remote->is_readonly) {
            $opts->{status} = "403 Forbidden";
            return "<p>You are read-only.  You cannot reply to this entry.</p>";
        }

        my $tt = LJ::get_talktext2($u, $re_talkid);
        $parpost->{'subject'} = $tt->{$re_talkid}->[0];
        $parpost->{'body'} = $tt->{$re_talkid}->[1];
        $parpost->{'props'} =
            LJ::load_talk_props2($u, [ $re_talkid ])->{$re_talkid} || {};

        if($LJ::UNICODE && $parpost->{'props'}->{'unknown8bit'}) {
            LJ::item_toutf8($u, \$parpost->{'subject'}, \$parpost->{'body'}, {});
        }

        my $datetime = DateTime_unix(LJ::TimeUtil->mysqldate_to_time($parpost->{'datepost'}));

        my ($s2poster, $pu);
        my $comment_userpic;
        if ($parpost->{'posterid'}) {
            $pu = LJ::load_userid($parpost->{'posterid'});
            return $opts->{handler_return} = 403 if $pu->{statusvis} eq 'S'; # do not show comments by suspended users
            $s2poster = UserLite($pu);

            # FIXME: this is a little heavy:
            $comment_userpic = Image_userpic($pu, 0, $parpost->{'props'}->{'picture_keyword'});
        }

        LJ::CleanHTML::clean_comment(\$parpost->{'body'},
                                     {
                                         'preformatted' => $parpost->{'props'}->{'opt_preformatted'},
                                         'anon_comment' => !$parpost->{posterid} || $pu->{'journaltype'} eq 'I',
                                     });

        LJ::run_hook('blocked_comment_content', $parpost);

        my $dtalkid = $re_talkid * 256 + $entry->anum;
        $replyto = {
            '_type' => 'Comment',
            'subject' => LJ::ehtml($parpost->{'subject'}),
            'text' => $parpost->{'body'},
            'userpic' => $comment_userpic,
            'poster' => $s2poster,
            'journal' => $s2entry->{'journal'},
            'metadata' => {},
            'permalink_url' => $u->{'_journalbase'} . "/$ditemid.html?view=$dtalkid#t$dtalkid",
            'depth' => 1,
            'time' => $datetime,
            'system_time' => $datetime,
            'tags' => [],
            'talkid' => $dtalkid,
            'link_keyseq' => [ 'delete_comment' ],
            'screened' => $parpost->{'state'} eq "S" ? 1 : 0,
            'frozen' => $parpost->{'state'} eq "F" ? 1 : 0,
            'deleted' => $parpost->{'state'} eq "D" ? 1 : 0,
        };

        # Conditionally add more links to the keyseq
        my $link_keyseq = $replyto->{'link_keyseq'};
        push @$link_keyseq, $replyto->{'screened'} ? 'unscreen_comment' : 'screen_comment';
        push @$link_keyseq, $replyto->{'frozen'} ? 'unfreeze_thread' : 'freeze_thread';
        push @$link_keyseq, "watch_thread" unless $LJ::DISABLED{'esn'};
        push @$link_keyseq, "unwatch_thread" unless $LJ::DISABLED{'esn'};
        push @$link_keyseq, "watching_parent" unless $LJ::DISABLED{'esn'};
        unshift @$link_keyseq, "edit_comment" if LJ::is_enabled("edit_comments");
    }

    $p->{'replyto'} = $replyto;

    $p->{'form'} = {
        '_type' => "ReplyForm",
        '_remote' => $remote,
        '_u' => $u,
        '_ditemid' => $ditemid,
        '_parpost' => $parpost,
        '_stylemine' => $get->{'style'} eq "mine",
        '_values' => \%comment_values,
    };

    return $p;
}

package S2::Builtin::LJ;

sub ReplyForm__print
{
    my ($ctx, $form) = @_;
    my $remote = $form->{'_remote'};
    my $u = $form->{'_u'};
    my $parpost = $form->{'_parpost'};
    my $parent = $parpost ? $parpost->{'jtalkid'} : 0;
    my $comment_form_text_hint = $ctx->[S2::PROPS]->{'comment_form_text_hint'} || '';
    $comment_form_text_hint = LJ::dhtml ($comment_form_text_hint);

    LJ::CleanHTML::clean(\$comment_form_text_hint, {
        'linkify' => 1,
        'wordlength' => 40,
        'mode' => 'deny',
        'allow' => [ qw/ abbr acronym address br code dd dfn dl dt em li ol p strong sub sup ul / ],
        'cleancss' => 1,
        'strongcleancss' => 1,
        'noearlyclose' => 1,
        'tablecheck' => 1,
        'remove_all_attribs' => 1,
    });

    my $post_vars = { LJ::Request->post_params() };
    $post_vars = $form->{_values} unless keys %$post_vars;

    $S2::pout->(LJ::Talk::talkform({ 'remote'    => $remote,
                                     'journalu'  => $u,
                                     'text_hint' => $comment_form_text_hint,
                                     'parpost'   => $parpost,
                                     'replyto'   => $parent,
                                     'ditemid'   => $form->{'_ditemid'},
                                     'stylemine' => $form->{'_stylemine'},
                                     'form'      => $post_vars,
                                     'do_captcha' => LJ::Talk::Post::require_captcha_test($remote, $u, $post_vars->{body}, $form->{'_ditemid'}),
                                   }),
                );

}

1;
