#!/usr/bin/env perl

use strict;
use warnings;
use Parallel::ForkManager;
use LWP::Simple qw( get getstore );
use YAML qw( Load LoadFile );
use Time::HiRes qw( gettimeofday );
use App::cpanminus::reporter;
use Data::Dumper;
use Getopt::Long;
use List::MoreUtils qw( uniq );
use System::Timeout qw( timeout );
use Test::Reporter::Transport::File;

# setup variable number of jobs
my $jobs    = 4;
my $verbose = '';

GetOptions(
    'jobs=i'  => \$jobs,
    'verbose' => \$verbose,
) or die "wrong Getopt usage \n";

print "\n**********\n";
print "Starting script\n";
system("date");

print "look for group id\n";
`ps x -o  "%p %r %y %x %c " | grep test27 | grep -v grep`;

# kill previous PID
# if the script's previous run is still alive, kill it
if ( -e "testbox_PID" ) {
    print "fetching previous PID\n";
    open my $testbox_PID_fh, '<', 'testbox_PID' or die "can't read testbox_PID";
    my $previous_PID = <$testbox_PID_fh>;
    print "previous PID is $previous_PID\n";
    my $previous_testbox_alive = `ps -e | grep -c $previous_PID | grep -v grep`;
    print "previous testbox alive $previous_testbox_alive\n";

    if ( $previous_testbox_alive != 0 ) {
        print "Previous script run still alive, killing it\n";

        # using -15 is supposed to kill all descendants, kills itself also
        system("kill -1 $previous_PID");
        $previous_testbox_alive =
          `ps -e | grep -c $previous_PID | grep -v grep`;
        print "previous testbox alive $previous_testbox_alive\n";

	print "look for group id after killing previous PID\n";
	`ps x -o  "%p %r %y %x %c " | grep test27 | grep -v grep`;

    }
    else {
        print "Previous script run not running now.\n";
	
	print "but look for group id again anyway\n";
	`ps x -o  "%p %r %y %x %c " | grep test27 | grep -v grep`;
    }

    close $testbox_PID_fh;
}


sleep 10;

# save my PID
open my $testbox_PID_fh, '>', 'testbox_PID' or die "can't write testbox_PID";
my $current_PID = $$;
print $testbox_PID_fh $current_PID;
print "current PID is $current_PID, saving it\n";
close $testbox_PID_fh;

# save my GPID
open my $testbox_GPID_fh, '>>', 'testbox_GPID' or die "can't write test_GPID";
my $current_GPID = `ps x -o  "%p %r %y %x %c " | grep test27 | grep -v grep`;

my $timestamp = `date`;
print $testbox_GPID_fh "$current_GPID $timestamp";
print "current GPID is $current_GPID, saving it\n";
close $testbox_GPID_fh;

print "starting $jobs jobs\n" if ($verbose);

open my $perlrevs_fh, '<', 'perlrevs.txt' or die "can't open perlrevs.txt";

# slurp file but don't change $/ in this case
my @revs = <$perlrevs_fh>;
close $perlrevs_fh;

print "Perl revisions to test under:\n @revs\n" if ($verbose);

my $Recent = YAML::Load( get("http://www.cpan.org/authors/RECENT.recent") );

LWP::Simple::getstore(
    "http://cpansearch.perl.org/src/ANDK/CPAN-2.10/distroprefs/01.DISABLED.yml",
    "01.DISABLED.yml"
);

my $Disabled = YAML::LoadFile('01.DISABLED.yml')
  or die "no local copy of 01.DISABLED.yml found\n";

# when was RECENT file last updated
my $last_updated = $Recent->{meta}{minmax}{max};

my $last_checked;

# when did we last check the RECENT file
if ( -e "last_checked" ) {
    open my $last_checked_fh, '<', 'last_checked';
    $last_checked = <$last_checked_fh>;
    close $last_checked_fh;
    chomp $last_checked;
}
else {
    $last_checked = "0";
}

print "RECENT file updated $last_updated\n" if ($verbose);
print "RECENT file checked $last_checked\n" if ($verbose);
print "If negative, check modules ", $last_checked - $last_updated, "\n"
  if ($verbose);

# there might be new modules to test if true
if ( $last_updated > $last_checked ) {
    print "RECENT file updated since last checked\n" if ($verbose);

    for my $recent_entry ( reverse @{ $Recent->{recent} } ) {

        # test only files ending in .tar.gz

        if ( $recent_entry->{path} =~ /\.tar\.gz$/ ) {
            print "found module $recent_entry->{path}\n" if ($verbose);
        }
        else {
            #	print "do not test $recent_entry->{path}\n" if ($verbose);
            next;
        }

        # test the module if updated since previous check
        if ( $recent_entry->{epoch} > $last_checked ) {
            print "updated $recent_entry->{epoch}, testing module\n"
              if ($verbose);
            test_module( $recent_entry->{path} );
        }
        else {
            print "module not updated since last check, do not test\n"
              if ($verbose);

########### for testing only ###########
            # print ">>>>>>>>>> but test it anyway\n" if ($verbose);
            # test_module( $recent_entry->{path} );
########### end for testing only ###########

        }
    }
}
( my $s, my $usec ) = gettimeofday;
chomp $s;
chomp $usec;
$last_checked = "$s" . "." . "$usec\n";

open my $last_checked_fh, '>', 'last_checked';
print $last_checked_fh $last_checked;
close $last_checked_fh;

system("date");
print "\nExiting script\n\n\n";

sub test_module {
    my ($path) = @_;

    # Use Parallel::ForkManager to test module under each perl version
    # run $jobs concurrent processes
    my $pm = Parallel::ForkManager->new($jobs);
    foreach my $rev (@revs) {

        chomp $rev;
        $path =~ s/\.tar\.gz//;
        my @name = split '/', $path;
        chomp $name[4];
        my $module = $name[3] . '/' . $name[4];

        open my $disabled_list_fh, '>>', 'disabled_list.txt'
          or die "can't open disabled_list.txt";

        open my $enabled_list_fh, '>>', 'enabled_list.txt'
          or die "can't open enabled_list.txt";

        # check if this module is included in disabled list
        # if it is, don't test this module
        if ( $module =~ /$Disabled->{match}{distribution}/ ) {
            print $disabled_list_fh "$module \n";
	    print "$module found in disabled list, do not test\n";
            next;
        }
        else {
            print $enabled_list_fh "$module \n";
        }

        close $disabled_list_fh;
        close $enabled_list_fh;

        $module = substr( $module, 0, rindex( $module, '-' ) );
        $module = substr( $module, rindex( $module, '/' ) + 1 );
        $module =~ s/-/::/g;

        # keep a list of tested modules
        open my $modules_tested_fh, '>>', 'modules_tested.txt'
          or die "can't open modules_tested.txt";
        my $timestamp = `date`;
        print $modules_tested_fh "$module $timestamp";
        close $modules_tested_fh;

        # test the module and report results
        $pm->start and next;

        eval {
            # setup to handle signals
            local $SIG{'HUP'} = sub { print "Got hang up\n" }
              if ($verbose);
            local $SIG{'INT'} = sub { print "Got interrupt\n" }
              if ($verbose);
            local $SIG{'STOP'} = sub { print "Stopped\n" }
              if ($verbose);
            local $SIG{'TERM'} = sub { print "Got term\n" }

              if ($verbose);
            local $SIG{'KILL'} = sub { print "Got kill\n" }
              if ($verbose);
            local $SIG{__DIE__} = sub { print "Got die\n" }
              if ($verbose);

            print "\n\ntesting $module with $rev\n" if ($verbose);

            my $PERL_CPANM_HOME = "/home/ray/.cpanm/work";
            print "cpanm home ", $PERL_CPANM_HOME, "\n" if ($verbose);

            # define command where it's used
            my $command = "perlbrew exec --with $rev ";
            $command .= "cpanm --test-only $module ";
            $command .= "| tee ./testlogs/$module.$rev";
            system("$command") && check_test_exit($?);

            $command = "/usr/local/bin/cpanm-reporter ";
            $command .= "--ignore-versions ";
            $command .= "| tee ./reporterlogs/$module.$rev ";

            system("$command") && check_reporter_exit($?);
        };
        $pm->finish;
    }
    $pm->wait_all_children();

}

sub check_test_exit {
    my ($exit) = @_;
    if ( $exit == -1 ) {

        # hasn't done this yet
        print "test failed to execute: $!\n";
    }
    elsif ( $exit & 127 ) {

        # hasn't done this yet either
        printf "test child died with signal %d, %s coredump\n",
          ( $exit & 127 ), ( $exit & 128 ) ? 'with' : 'without';
    }
    else {
        # does this often
        printf "test child exited with value %d\n", $exit >> 8;
    }
}

sub check_reporter_exit {
    my ($exit) = @_;
    if ( $exit == -1 ) {
        print "reporter failed to execute: $!\n";
    }
    elsif ( $exit & 127 ) {
        printf "reporter child died with signal %d, %s coredump\n",
          ( $exit & 127 ), ( $exit & 128 ) ? 'with' : 'without';
    }
    else {
        printf "reporter child exited with value %d\n", $exit >> 8;
    }
}

