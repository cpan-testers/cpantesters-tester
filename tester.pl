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
use Test::Reporter::Transport::File;

# set default values for command line variables
my $jobs = 5;    # number of test processes created by Parallel::ForkManager
                 # one for each perl build invoked by perlbrew
                 # should be equal to number of entries in perlbuilds.txt

my $verbose = '';    # --verbose will print many trace messages

# CPAN server to check for updated modules
# if omitted URL below is default
my $cpan_server = 'http://cpan.cpantesters.org/authors';

GetOptions(
    'jobs=i'        => \$jobs,
    'verbose'       => \$verbose,
    'cpan_server=s' => \$cpan_server,
) or die "wrong Getopt usage \n";

print "\n\n==========>  ";    # indicate script start in output
system("date");

# kill any previously running instances of this script
kill_previous_run();

# save current PID
open my $tester_PID_fh, '>', 'tester_PID' or die "can't write tester_PID";
my $current_PID = $$;
print $tester_PID_fh $current_PID;
print "current PID is $current_PID, saving it\n" if ($verbose);
close $tester_PID_fh;

# what process name accompanies current PID?
# my $temp=`ps -e | grep $current_PID | grep -v grep`;
# print "my process name is:  $temp\n";

# if log directories or log files are absent, create them
create_log_files();

# load copies of RECENT.recent and disabled files from CPAN
# RECENT.recent contains names of new/changed modules
# disabled file contains names of modules not to be tested
my $Recent = get_files();

# when was RECENT file updated?
my $Recent_updated = $Recent->{meta}{minmax}{max};

# when was RECENT file previously updated?
open my $previous_Recent_update_fh, '<', 'previous_Recent_update';
my $previous_Recent_update = <$previous_Recent_update_fh>;
close $previous_Recent_update_fh;
chomp $previous_Recent_update;

# if newest Recent file was updated after previous Recent file,
# there may be modules to test
if ( $Recent_updated > $previous_Recent_update ) {
    open my $previous_Recent_update_fh, '>', 'previous_Recent_update';

    # save time of latest Recent file update
    print $previous_Recent_update_fh $Recent_updated;
    close $previous_Recent_update_fh;
    chomp $previous_Recent_update;

    print "RECENT file updated since last checked\n" if ($verbose);
    check_for_updated_modules();
}
else {
    print "RECENT file not updated since last checked, exit\n" if ($verbose);
}

print "==========>  ";    # indicate script end in output
system("date");

###### end of main script ######

sub kill_previous_run {

    # kill previous PID
    # if the script's previous run is still alive, kill it
    if ( -e "tester_PID" )    # PID for previous script run is in this file
    {
        print "fetching previous PID\n" if ($verbose);
        open my $tester_PID_fh, '<', 'tester_PID'
          or die "can't read tester_PID";
        my $previous_PID = <$tester_PID_fh>;
        $previous_PID = " " . $previous_PID . " ";
        print "previous PID is $previous_PID\n" if ($verbose);

        # command returns 1 if still alive, 0 if not
        my $previous_tester_alive = `ps $previous_PID | grep -c $previous_PID`;
        print "previous_test_alive is: $previous_tester_alive\n" if ($verbose);

        if ( $previous_tester_alive != 0 ) {
            print "Previous script instance still alive, killing it\n"
              if ($verbose);

            # using -15 is supposed to kill all PID descendants,
            # but it kills this currently running script also
            # a -1 SIGUP seems to work best
            system("kill -1 $previous_PID");
            sleep 10;    # allow some time to die

            # if that didn't kill the still running script quit this script
            $previous_tester_alive = `ps $previous_PID | grep -c $previous_PID`;
            if ( $previous_tester_alive != 0 ) {
                die "previous script instance didn't die";
            }
        }
        else {
            print "Previous script instance not running now.\n" if ($verbose);
        }
        close $tester_PID_fh;
    }
}

sub create_log_files {

    # contains text output from 'cpanm --test_only $module' command
    unless ( -d "testlogs" ) {
        mkdir "testlogs";
        print "testlogs directory not found, created it\n" if ($verbose);
    }

    # contains text output from 'cpanm-reporter' command
    unless ( -d "reporterlogs" ) {
        mkdir "reporterlogs";
        print "reporterlogs directory not found, created it\n" if ($verbose);
    }

    # each tested module's name is stored here
    unless ( -e "modules_tested.log" ) {
        open my $modules_tested_log_fh, '>', 'modules_tested.log'
          or die "can't create modules_tested.log";
        close $modules_tested_log_fh;
        print "modules_tested.log file not found, created it\n" if ($verbose);
    }

    # timestamp of update to Recent.recent file previous to current recent file
    unless ( -e "previous_Recent_update" ) {
        open my $previous_Recent_update_fh, '>', 'previous_Recent_update'
          or die "can't create previous_Recent_update";
        print $previous_Recent_update_fh "0";
        close $previous_Recent_update_fh;
    }

    # contains copies of Recent.recent files, epoch time read is in filename
    unless ( -d "recentlogs" ) {
        mkdir "recentlogs";
        print "recentlogs directory not found, created it\n" if ($verbose);
    }

# local copy list of modules to not test, entries to be added by this script's user
    unless ( -e "01.myDISABLED.yml" ) {
        open my $myDISABLED_fh, '>', '01.myDISABLED.yml'
          or die "can't create 01.myDISABLED.yml";
        close $myDISABLED_fh;
        print "01.myDISABLED.yml file not found, created empty copy\n"
          if ($verbose);
    }
}

sub get_files {

    # get the latest list of new or updated modules
    $Recent = YAML::Load( get("http://www.cpan.org/authors/RECENT.recent") );

########### for testing only ###########
    {
        # comment this code if not needed,
        # save copy of recent file to aid troubleshooting
        ( my $s, my $usec ) = gettimeofday;
        chomp $s;
        chomp $usec;
        my $rcnt = "recentlogs/rcnt" . "$s";
        LWP::Simple::getstore( "http://www.cpan.org/authors/RECENT.recent",
            "$rcnt" );
    }
########### for testing only ###########

    # get and save a copy of list of modules which are not to be tested
    # file is maintained by CPAN tester ANDK
    LWP::Simple::getstore(
"http://cpansearch.perl.org/src/ANDK/CPAN-2.10/distroprefs/01.DISABLED.yml",
        "01.DISABLED.yml"
    );
    return ($Recent);
}

sub check_for_updated_modules {

    # we know the RECENT.recent file has been updated,
    # are there any new or updated modules to test?
    for my $recent_entry ( reverse @{ $Recent->{recent} } ) {

        # check only files ending in .tar.gz
        next unless ( $recent_entry->{path} =~ /\.tar\.gz$/ );
        print "found module $recent_entry->{path}\n" if ($verbose);

        my $Disabled = YAML::LoadFile('01.DISABLED.yml')
          or die "no local copy of 01.DISABLED.yml found\n";

        # script user's edition of
        # list of modules not to be tested
        my $myDisabled = YAML::LoadFile('01.myDISABLED.yml')
          or die "no local copy of 01.myDISABLED.yml found\n";

        # isolate author/module name
        my $module = $recent_entry->{path};
        $module =~ s/\.tar\.gz//;
        my @name = split '/', $module;
        print "$module \n" if ($verbose);
        chomp $name[4];
        $module = $name[3] . '/' . $name[4];
        print "$name[3] $name[4]\n" if ($verbose);

        open my $disabled_list_fh, '>>', 'disabled_list.txt'
          or die "can't open disabled_list.txt";

        open my $enabled_list_fh, '>>', 'enabled_list.txt'
          or die "can't open enabled_list.txt";

        # check if this module is included in either disabled list
        # if it is, don't test this module
        # keep separate lists of enabled and disabled module names
        if (   ( $module =~ /$Disabled->{match}{distribution}/ )
            or ( $module =~ /$myDisabled->{match}{distribution}/ ) )
        {
            print $disabled_list_fh "$module \n";
            print "$module found in disabled list, do not test\n" if ($verbose);
            close $disabled_list_fh;
            close $enabled_list_fh;
            next;
        }
        else {
            print $enabled_list_fh "$module \n";
            print "$module not found in disabled list, continue\n"
              if ($verbose);
            close $disabled_list_fh;
            close $enabled_list_fh;
        }

        # module already been tested?
        # keep a list of tested modules in modules_tested.log
        # if a current module has already been tested
        # skip testing it
        my $already_tested = 0;
        open my $modules_tested_log_fh, '<', 'modules_tested.log'
          or die "cannot read modules_tested.log\n";
        while (<$modules_tested_log_fh>) {
            if (/$recent_entry->{path}/) {
                close $modules_tested_log_fh;
                print "$recent_entry->{path} has been tested, skip it\n"
                  if ($verbose);
                $already_tested = 1;
                last;
            }
        }

        # module hasn't been tested
        if ( $already_tested == 0 ) {
            close $modules_tested_log_fh;
            print "$recent_entry->{path} has not been tested, test it\n"
              if ($verbose);

            # update list of tested modules
            # add this module to list
            open my $modules_tested_log_fh, '>>', 'modules_tested.log'
              or die "can't open modules_tested.log";

            my $timestamp = `date`;
            ( my $s, my $usec ) = gettimeofday;
            chomp $s;
            chomp $usec;
            my $this_check = "$s" . "." . "$usec ";

            # add current epoch time and formatted date and time
            # to module name entry, save in modules_tested file
            print $modules_tested_log_fh
              "$recent_entry->{path} $this_check $timestamp";
            close $modules_tested_log_fh;
            print
"added to modules tested log:  $recent_entry->{path} $this_check $timestamp"
              if ($verbose);
            test_module( $recent_entry->{path} );
        }
    }
}

sub test_module {

# $id contains (example)
# http://cpan.cpantesters.org/authors/id/D/DA/DAGOLDEN/Acme-Devel-Hide-Tiny-0.001.tar.gz
    my ($id) = @_;

    # get list of perl builds to test modules against
    open my $perlbuilds_fh, '<', 'perlbuilds.txt'
      or die "can't open perlbuilds.txt";

    # slurp file but don't change $/ in this case
    my @perlbuilds = <$perlbuilds_fh>;
    close $perlbuilds_fh;
    print "Perl revisions to test under:\n @perlbuilds\n" if ($verbose);

    # start a test process for each perl build,
    # maybe $jobs should be read from # of lines in perlbuilds.txt
    my $pm = Parallel::ForkManager->new($jobs);
    foreach my $perlbuild (@perlbuilds) {

        # make sure there's some time between file timestamps
        sleep 1;

        print "starting test process for perl build $perlbuild\n" if ($verbose);
        chomp $perlbuild;

        $pm->start and next;

        eval {
            # setup to handle signals
            local $SIG{'HUP'}  = sub { print "Got hang up\n" };
            local $SIG{'INT'}  = sub { print "Got interrupt\n" };
            local $SIG{'STOP'} = sub { print "Stopped\n" };
            local $SIG{'TERM'} = sub { print "Got term\n" };
            local $SIG{'KILL'} = sub { print "Got kill\n" };

            # this one won't work with apostrophes like above
            local $SIG{__DIE__} = sub { print "Got die\n" };

            # next two variable settings are explained in this link
### http://www.dagolden.com/index.php/2098/the-annotated-lancaster-consensus
            local $ENV{NONINTERACTIVE_TESTING} = 1;
            local $ENV{AUTOMATED_TESTING}      = 1;

            # cpanm will put its test reports in this directory,
            # cpanm-reporter will get its input from this directory
            unless ( -d "/home/ray/.cpanm/$perlbuild" ) {
                mkdir "/home/ray/.cpanm/$perlbuild";
            }
            system("chmod 777 /home/ray/.cpanm/$perlbuild");

            local $ENV{PERL_CPANM_HOME} = "/home/ray/.cpanm/$perlbuild";
            print "PERL_CPANM_HOME is:  $ENV{PERL_CPANM_HOME}\n" if ($verbose);

            # isolate module name
            my $module = substr( $id, 0, rindex( $id, '-' ) );
            $module = substr( $module, rindex( $module, '/' ) + 1 );
            $module =~ s/-/::/g;
            print "testing $module with $perlbuild\n" if ($verbose);

            # test the module, don't install it
            system(
"perlbrew exec --with $perlbuild cpanm --test-only $module | tee ./testlogs/$module.$perlbuild"
            );

            my $BUILD_DIR     = "/home/ray/.cpanm/$perlbuild";
            my $BUILD_LOGFILE = "$BUILD_DIR/build.log";
            my $CPANM_REPORTER_HOME =
              "/home/ray/perl5/perlbrew/perls/$perlbuild/bin";

            print "BUILD_DIR is: $BUILD_DIR\n"         if ($verbose);
            print "BUILD_LOGFILE is: $BUILD_LOGFILE\n" if ($verbose);
            print "CPANM_REPORTER_HOME is: $CPANM_REPORTER_HOME\n"
              if ($verbose);
            print "Building command for cpanm-reporter\n" if ($verbose);

         # force cpanm-reporter to send all reports no matter when test was done
         # by unlinking reports-sent.db
         # --force arg to cpanm-reporter shouldn't be needed
            unlink("/home/ray/.cpanreporter/reports-sent.db");

            my $command = "perlbrew exec --with $perlbuild ";
            $command .= "$CPANM_REPORTER_HOME/cpanm-reporter ";
            $command .= "--ignore-versions --force ";
            $command .= "--build_dir=$BUILD_DIR ";
            $command .= "--build_logfile=$BUILD_LOGFILE ";
            $command .= "| tee ./reporterlogs/$module.$perlbuild ";
            print "Executing command:  $command\n" if ($verbose);
            system($command);
        };
        $pm->finish;
    }
    $pm->wait_all_children();
}

################ Documentation ################

=head1 NAME

tester.pl - Runs self-tests on newly added CPAN modules

=head1 SYNOPSIS

Using crontab -e, enter:

*/20 * * * *  cd /full/path/to/tester.pl; ./tester.pl [--jobs=N] [--verbose] [--cpan_server='http://cpan.cpantesters.org/authors' ] >> /full/path/to/tester.pl/cronlog 2>&1

Note that cron does not import variables so paths must be fully specified.

=head1 DESCRIPTION

The PERL script 'tester.pl' is the first experimental release in what is to be a package of scripts designed to make testing the most recent module entries to CPAN as easy as possible.

In brief the script functions as follows:  The script downloads the RECENT.recent file from the cpan.org server specified on the command line when tester.pl is invoked.  This file lists the newly submitted modules to CPAN.  The 01.DISABLED.yml file (maintained by CPAN tester ANDK) containing module names which are not to be tested is also downloaded.  

The script examines the date and time the RECENT.recent file was updated.  If this time is later than the previous time the file was updated, the module names in the file are checked for new or updated modules.  Each module name is compared to a list of modules already tested.  If the module has been tested it is skipped.   If the module is not in the list the script continues execution..

When the script finds module names not previously tested, the module's name is checked against the 01.DISABLED.yml file and if there is a match the module is not tested.  Also, the module name is compared to a list in the 01.myDISABLED.yml file which is created by the script user and also contains module names not to be tested.  If there is no match tester.pl starts a set of tester processes determined by the contents of the 'perlbuilds.txt' file.  An example of the file is:

5.24.0-thread-debug
5.24.0-thread
5.24.0-default
5.24.0-debug

Using the 'perlbrew' tool the user has built four PERL executables of the indicated revisions and build options.  These will be placed in the proper position in the 'perlbrew' directory tree.  

The script starts a test process for each of the PERL builds using the Parallel::ForkManager CPAN module.  The tester script then sets up a series of handlers to capture Linux signals.  

Using the perlbrew tool the script instructs 'cpanm' to test the module under each of the perl executables in the perlbuilds.txt file.  The script then transmits the test results to the CPAN Testers server using the 'cpanm-reporter' standalone program.

The above sequence is repeated for each updated module in the RECENT.recent file.  The script then exits.

The tester script is invoked by the cron utility by means of a crontab file similar to this:

*/20 * * * * cd/media/ray/sq2TB/cpantesters-tester; ./tester.pl -–verbose >> /media/ray/sg2TB/cpantesters-tester cronlog 2>&1

For this example, the tester script will run every twenty minutes with the –verbose option causing a log to be written to the cronlog file.  Note that cron does not import variables so the file paths are required.

=head2 Command line options

The script accepts three command line options.

=head3 --jobs=N

This option instructs the file to create N parallel test processes for each module tested. Each test process executes an executable copy of the Perl language built with the 'perlbrew' tool and with the --thread and/or --debug support compiled in.  

=head3 --verbose

The script will write many trace messages to the terminal as it executes.  Note that the cron command in the SYNOPSIS redirects this output to a file called 'cronlog' in the same directory as 'tester.pl'.

=head3 --cpan-server='http://cpan.cpantesters.org/authors'

This option tells the script which CPAN server from which to load modules.  If the option is omitted the script will default to the url listed above.

=head2 Directory structures and files

Except where indicated otherwise, all of these directories and files are in the same directory as the 'tester.pl' script.

=head2 tester.pl

This file contains the script itself.  It should reside in a dedicated directory.  The user may place this directory in the file system wherever it is most convenient.

=head2 testlogs

This subdirectory and next the two are in the same directory as the tester.pl script.  If they do not exist when the script starts, the script will create them.  The testlogs directory contains a set of files whose names indicate the module name tested and the PERL build the module was tested against.  The files contain the logged output of the 'cpanm –test-only' command for the selected module.

=head2 reporterlogs

The reporterlogs directory contains the information normally written to the terminal by the 'cpanm-reporter' command.

=head2 recentlogs

The recentlogs directory contains copies of each of the RECENT.recent files the script has read from the CPAN server.  The epoch time at which the file was read is part of the file name.

=head2 01.DISABLED.yml

The 01.DISABLED.yml file is read from the CPAN-2.10 directory maintained by CPAN author ANDK.  It contains a list of CPAN modules ANDK has found to be difficult to test automatically and can be skipped during testing.

=head2 01.myDISABLED.yml

The second file can be populated by the 'tester.pl' user and contains module names the user does not wish to test.  It follows the same file structure as 01.DISABLED.yml.  If the file is not present an empty copy is created.

=head2 cronlog

Output from tester.pl which would normally be written to the terminal is logged to the cronlog file.  The file contains messages enabled by the 
'--verbose' command line option.

=head2 ~/.cpanm/work

This subdirectory is created in the user's home directory when the 'cpanm' module is installed.  The directory contains a set of subdirectories labeled with the epoch timestamp at which each directory was created.  The 'cpanm –test-only' command creates a 'build.log' file in each subdirectory containing information needed by 'cpanm-reporter' when transmitting a test report to the CPAN testers server.

=head2 disabled_list.txt
=head2 enabled_list.txt

The first file contains the file names of those modules which are not to be tested based on files 01.DISABLED.yml or 01.myDISABLED.yml above.  The second file contains module names which do not appear in either *.yml file.

=head2 modules_tested.log

This file contains a list of modules which were tested.  Each module to be tested is compared to this list and if a match occurs the module is not tested.

=head2 perlbuilds.txt

A list of executable copies of the Perl language.  Each file name is made up of the Perl revision the executable is based on and the options compiled into the executable.  These executables are built by the user through the 'perlbuild install' command.  See the entry for 'perlbrew' in cpan.org.  The script will test each module under each of the Perl executables.

=head2 previous_Recent_update

Contains the epoch time at which the next to last RECENT file was updated.  The same time from the latest RECENT file is compared to this and if they differ, the RECENT file is checked for module updates.

=head2 previous_PID

Contains the process id for the previous execution of 'tester.pl'.  If the 'ps' command shows this process to be still running, the process is ended with the 'kill' command.  Whether the previous process is running or not the script then saves the current script PID to this file.

=head2 Example of 'tester.pl' home directory

 ~/$TESTER_HOME
     -rw-rw-r-- 1 userid userid   19173 Oct  2 18:09 01.DISABLED.yml
     -rwxrwxrwx 1 userid userid    1384 Sep 26 12:17 01.myDISABLED.yml
     -rw-rw-r-- 1 userid userid 7489290 Oct  2 18:00 cronlog
     -rw-rw-r-- 1 userid userid    1582 Oct  2 15:00 disabled_list.txt
     -rw-rw-r-- 1 userid userid   51175 Oct  2 18:00 enabled_list.txt
     -rw-rw-r-- 1 userid userid   58862 Oct  2 17:20 modules_tested.log
     -rwxrwxrwx 1 userid userid      62 Sep  3 17:59 perlbuilds.txt
     -rw-rw-r-- 1 userid userid      16 Oct  2 18:00 previous_Recent_update
     drwxrwxr-x 2 userid userid   36864 Oct  2 18:09 recentlogs
     drwxrwxr-x 2 userid userid   90112 Oct  2 17:20 reporterlogs
     -rw-rw-r-- 1 userid userid       4 Oct  2 18:09 tester_PID
     -rwxr-xr-x 1 userid userid   20215 Oct  2 18:13 tester.pl
     drwxrwxr-x 2 userid userid   90112 Oct  2 17:20 testlogs

./$TESTER_HOME/recentlogs:
     -rw-rw-r-- 1 userid userid  5188 Sep 26 20:25 rcnt1474939501
     -rw-rw-r-- 1 userid userid  5666 Sep 26 20:30 rcnt1474939802
     -rw-rw-r-- 1 userid userid  5666 Sep 26 20:35 rcnt1474940102
     ...
     -rw-rw-r-- 1 userid userid  7629 Oct  2 17:20 rcnt1475446801
     -rw-rw-r-- 1 userid userid  7108 Oct  2 17:40 rcnt1475448002
     -rw-rw-r-- 1 userid userid  5725 Oct  2 18:00 rcnt1475449202
     -rw-r--r-- 1 userid userid  5725 Oct  2 18:09 rcnt1475449781

./$TESTER_HOME/reporterlogs:
     -rw-rw-r-- 1 userid userid  152 Sep 27 13:45 Acme::MITHALDU::BleedingOpenGL.5.24.0-debug
     -rw-rw-r-- 1 userid userid  152 Sep 27 13:45 Acme::MITHALDU::BleedingOpenGL.5.24.0-default
     -rw-rw-r-- 1 userid userid  152 Sep 27 13:45 Acme::MITHALDU::BleedingOpenGL.5.24.0-thread
     -rw-rw-r-- 1 userid userid  152 Sep 27 13:45 Acme::MITHALDU::BleedingOpenGL.5.24.0-thread-debug
     ...
     -rw-rw-r-- 1 userid userid  100 Oct  1 20:20 ZooKeeper.5.24.0-debug
     -rw-rw-r-- 1 userid userid  100 Oct  1 20:20 ZooKeeper.5.24.0-default
     -rw-rw-r-- 1 userid userid  100 Oct  1 20:20 ZooKeeper.5.24.0-thread
     -rw-rw-r-- 1 userid userid  100 Oct  1 20:20 ZooKeeper.5.24.0-thread-debug

./$TESTER_HOME/testlogs:
     -rw-rw-r-- 1 userid userid   739 Sep 27 13:45 Acme::MITHALDU::BleedingOpenGL.5.24.0-debug
     -rw-rw-r-- 1 userid userid   739 Sep 27 13:45 Acme::MITHALDU::BleedingOpenGL.5.24.0-default
     -rw-rw-r-- 1 userid userid   739 Sep 27 13:45 Acme::MITHALDU::BleedingOpenGL.5.24.0-thread
     -rw-rw-r-- 1 userid userid   739 Sep 27 13:45 Acme::MITHALDU::BleedingOpenGL.5.24.0-thread-debug
     ...
     -rw-rw-r-- 1 userid userid   671 Oct  1 20:20 ZooKeeper.5.24.0-debug
     -rw-rw-r-- 1 userid userid   671 Oct  1 20:20 ZooKeeper.5.24.0-default
     -rw-rw-r-- 1 userid userid   671 Oct  1 20:20 ZooKeeper.5.24.0-thread
     -rw-rw-r-- 1 userid userid   671 Oct  1 20:20 ZooKeeper.5.24.0-thread-debug

=head1 BUGS

Script truncates Perl version names like perl-5.22.2-debug to perl-5.22.2. See App::cpanminus::reporter.pm line 226 for possible reason.

=cut

