#!/usr/bin/perl
#
# <LJDEP>
# lib: cgi-bin/ljlib.pl
# </LJDEP>

use strict;
require "$ENV{'LJHOME'}/cgi-bin/ljlib.pl";
require "$ENV{'LJHOME'}/cgi-bin/ljviews.pl";

my $dbh = LJ::get_db_writer();

sub header_text {
    return <<"HEADER";
# This file is automatically generated from MySQL by \$LJHOME/bin/dumpsql.pl
# Don't submit a diff against a hand-modified file - dump and diff instead.

HEADER
}

# what tables don't we want to export the auto_increment columns from
# because they already have their own unique string, which is what matters
my %skip_auto = ("userproplist" => "name",
                 "talkproplist" => "name",
                 "logproplist" => "name",
                 "priv_list" => "privcode",
                 "supportcat" => "catkey",
                 "ratelist" => "rlid",
                 );

# get tables to export
my %tables = ();
my $sth = $dbh->prepare("SELECT tablename, redist_mode, redist_where ".
                        "FROM schematables WHERE redist_mode NOT IN ('off')");
$sth->execute;
while (my ($table, $mode, $where) = $sth->fetchrow_array) {
    $tables{$table}->{'mode'} = $mode;
    $tables{$table}->{'where'} = $where;
}

my %output;  # {general|local} -> [ [ $alphasortkey, $SQL ]+ ]

# dump each table.
foreach my $table (sort keys %tables)
{
    my $where;
    if ($tables{$table}->{'where'}) {
        $where = "WHERE $tables{$table}->{'where'}";
    }

    my $sth = $dbh->prepare("DESCRIBE $table");
    $sth->execute;
    my @cols = ();
    my $skip_auto = 0;
    while (my $c = $sth->fetchrow_hashref) {
        if ($c->{'Extra'} =~ /auto_increment/ && $skip_auto{$table}) {
            $skip_auto = 1;
        } else {
            push @cols, $c;
        }
    }

    # DESCRIBE table can be different between developers
    @cols = sort { $a->{'Field'} cmp $b->{'Field'} } @cols;

    my $cols = join(", ", map { $_->{'Field'} } @cols);
    my $sth = $dbh->prepare("SELECT $cols FROM $table $where");
    $sth->execute;
    my $sql;
    while (my @r = $sth->fetchrow_array)
    {
        my %vals;
        my $i = 0;
        foreach (map { $_->{'Field'} } @cols) {
            $vals{$_} = $r[$i++];
        }
        my $scope = "general";
        $scope = "local" if (defined $vals{'scope'} &&
                             $vals{'scope'} eq "local");
        my $verb = "INSERT IGNORE";
        $verb = "REPLACE" if ($tables{$table}->{'mode'} eq "replace" &&
                              ! $skip_auto);
        $sql = "$verb INTO $table ";
        $sql .= "($cols) ";
        $sql .= "VALUES (" . join(", ", map { db_quote($_) } @r) . ");\n";

        my $uniqc = $skip_auto{$table};
        my $skey = $uniqc ? $vals{$uniqc} : $sql;
        push @{$output{$scope}}, [ "$table.$skey.1", $sql ];

        if ($skip_auto) {
            # for all the *proplist tables, there might be new descriptions
            # or columns, but we can't do a REPLACE, because that'd mess
            # with their auto_increment ids, so we do insert ignore + update
            my $where = "$uniqc=" . db_quote($vals{$uniqc});
            delete $vals{$uniqc};
            $sql = "UPDATE $table SET ";
            $sql .= join(",", map { "$_=" . db_quote($vals{$_}) } sort keys %vals);
            $sql .= " WHERE $where;\n";
            push @{$output{$scope}}, [ "$table.$skey.2", $sql ];
        }
    }
}

# don't use $dbh->quote because it's changed between versions
# and developers sending patches can't generate concise patches
# it used to not quote " in a single quoted string, but later it does.
# so we'll implement the new way here.
sub db_quote {
    my $s = shift;
    return "NULL" unless defined $s;
    $s =~ s/\\/\\\\/g;
    $s =~ s/\"/\\\"/g;
    $s =~ s/\'/\\\'/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    return "'$s'";
}

foreach my $k (keys %output) {
    my $file = $k eq "general" ? "base-data.sql" : "base-data-local.sql";
    print "Dumping $file\n";
    my $ffile = "$ENV{'LJHOME'}/bin/upgrading/$file";
    open (F, ">$ffile") or die "Can't write to $ffile\n";
    print F header_text();
    foreach (sort { $a->[0] cmp $b->[0] } @{$output{$k}}) {
        print F $_->[1];
    }
    close F;
}

# now dump school related information
print "Dumping schools.dat\n";
open(F, ">$ENV{LJHOME}/bin/upgrading/schools.dat") or die;
$sth = $dbh->prepare('SELECT name, country, state, city, url FROM schools');
$sth->execute;
while (my @row = $sth->fetchrow_array) {
    my $line = '"' . join('","', map { $_ || "" } @row) . '"';
    print F "$line\n";
}
close F;

# and do S1 styles (ugly schema)
print "Dumping s1styles.dat\n";
require "$ENV{'LJHOME'}/bin/upgrading/s1style-rw.pl";
my $ss = {};
my $pubstyles = LJ::S1::get_public_styles({ 'formatdata' => 1});
foreach my $s (values %$pubstyles) {
    my $uniq = "$s->{'type'}/$s->{'styledes'}";
    $ss->{$uniq}->{$_} = $s->{$_} foreach keys %$s;
}
s1styles_write($ss);

# and dump mood info
print "Dumping moods.dat\n";
open (F, ">$ENV{'LJHOME'}/bin/upgrading/moods.dat") or die;
$sth = $dbh->prepare("SELECT moodid, mood, parentmood FROM moods ORDER BY moodid");
$sth->execute;
while (@_ = $sth->fetchrow_array) {
    print F "MOOD @_\n";
}

$sth = $dbh->prepare("SELECT moodthemeid, name, des FROM moodthemes WHERE is_public='Y' ORDER BY name");
$sth->execute;
while (my ($id, $name, $des) = $sth->fetchrow_array) {
    $name =~ s/://;
    print F "MOODTHEME $name : $des\n";
    my $std = $dbh->prepare("SELECT moodid, picurl, width, height FROM moodthemedata ".
                            "WHERE moodthemeid=$id ORDER BY moodid");
    $std->execute;
    while (@_ = $std->fetchrow_array) {
	print F "@_\n";
    }
}
close F;


print "Done.\n";
