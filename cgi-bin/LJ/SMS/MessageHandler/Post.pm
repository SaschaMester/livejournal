package LJ::SMS::MessageHandler::Post;

use base qw(LJ::SMS::MessageHandler);

use strict;
use Carp qw(croak);

sub handle {
    my ($class, $msg) = @_;

    my $text = $msg->body_text;

    my ($sec, $subject, $body) = $text =~ /
        ^\s*
        p(?:ost)?                 # post full or short

        (?:\.                     # optional security setting
         (
          (?:\"|\').+?(?:\"|\')   # single or double quoted security
          |
          \S+)                    # single word security
         )?

         \s+

         (?:                      # optional subject
          (?:\[|\()(.+)(?:\]|\))  # [...] or (...) subject
          )?

         \s*

         (.+)                     # teh paylod!

         \s*$/ix;

    # for quoted strings, the 'sec' segment will still have single or double quotes
    if ($sec) {
        $sec =~ s/^(?:\"|\')//;
        $sec =~ s/(?:\"|\')$//;
    }

    my $u = $msg->from_u;
    my $secmask = 0;

    if ($sec) {
        if ($sec =~ /^pu/) {
            $sec = 'public';
        } elsif ($sec =~ /^fr/) {
            $sec = 'usemask';
            $secmask = 1;
        } elsif ($sec =~ /^pr/) {
            $sec = 'private';
        } else {
            my $groups = LJ::get_friend_group($u);
            while (my ($bit, $grp) = each %$groups) {
                next unless $grp->{groupname} =~ /^$sec$/i;

                # found the security group the user is asking for
                $sec = 'usemask';
                $secmask = 1 << $bit;

                last;
            }

            $sec = 'private';
        }
    }

    # initiate a protocol request to post this message
    my $err;
    my $default_subject = "Posted using <a href='$LJ::SITEROOT/manage/sms/'>$LJ::SMS_TITLE</a>";
    my $res = LJ::Protocol::do_request
        ("postevent",
         { 
             ver        => 1,
             username   => $u->{user},
             lineendings => 'unix',
             subject     => $subject || $default_subject,
             event       => $body,
             props       => { sms_msgid => $msg->id },
             security    => $sec,
             allowmask   => $secmask,
             tz          => 'guess' 
         },
         \$err, { 'noauth' => 1 }
         );

    # set metadata on this sms message indicating the 
    # type of handler used and the jitemid of the resultant
    # journal post
    $msg->meta
        ( post_jitemid => $res->{itemid},
          post_error   => $err,
          );

    # if we got a jitemid and the user wants to be automatically notified
    # of new comments on this post via SMS, add a subscription to it
    my $post_notify = $u->prop('sms_post_notify');
    if ($res->{itemid} && $post_notify && $post_notify eq 'SMS') {
        # get an entry object to subscribe to
        my $entry = LJ::Entry->new($u, jitemid => $res->{itemid})
            or die "Could not load entry object";

        my %sub_args = (
                        event   => "LJ::Event::JournalNewComment",
                        journal => $u,
                        arg1    => $entry->ditemid,
                        );


        $u->subscribe(
                      method  => "LJ::NotificationMethod::SMS",
                      %sub_args,
                      );

        $u->subscribe(
                      method  => "LJ::NotificationMethod::Inbox",
                      %sub_args,
                      );
    }

    $msg->status($err ? 
                 ('error' => "Error posting to journal: $err") : 'success');

    return 1;
}

sub owns {
    my ($class, $msg) = @_;
    croak "invalid message passed to MessageHandler"
        unless $msg && $msg->isa("LJ::SMS::Message");

    return $msg->body_text =~ /^\s*p(?:ost)?[\.\s]/i ? 1 : 0;
}

1;
