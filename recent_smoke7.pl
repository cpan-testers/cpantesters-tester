#!/usr/bin/env perl

BEGIN { unshift @INC, "$ENV{HOME}/perl5/lib/perl5"; }

use strict;
use warnings;
use v5.10;
use Parallel::ForkManager;
use LWP::Simple qw (get getstore);
use YAML qw ( Load LoadFile );
use Time::HiRes qw ( gettimeofday);
use App::cpanminus::reporter;
use Data::Dumper;
use Getopt::Long;
use List::MoreUtils qw ( uniq);
use Test::Reporter::Transport::File;
use File::Path::Tiny qw (mk rm);

#
## main begins here
## set variables using command line arguments
#

# default function is to test files in RECENT.recent file
my $function = '';
my $jobs     = 8;    # number of test processes created by Parallel::ForkManager
my $verbose  = '';   # --verbose will print many trace messages

# CPAN server to fetch modules from,
# this path must be in user's MyConfig.pm urllist.
# MyConfig.pl should be in ~/.local/share/.cpan/CPAN
# use mkmyconfig command described in http://metacpan.org/pod/CPAN
# to create MyConfig.pm
my $cpan_server = 'http://cpan.cpantesters.org/authors';

GetOptions(
    'function=s'    => \$function,
    'jobs=i'        => \$jobs,
    'verbose'       => \$verbose,
    'cpan_server=s' => \$cpan_server,
) or die "wrong Getopt usage \n";

# variables pointing to paths and files
my $perlbuild = '';    #perl version under which module will be tested
my $function_home               = "$ENV{PWD}/$function";
my $function_cpanm_home         = "$function_home/.cpanm";
my $function_cpanmreporter_home = "$function_home/.cpanmreporter/$perlbuild";
my $cpanmreporter_reports_sent  = "$ENV{PWD}/.cpanreporter/reports-sent.db";

my $recent_file_home  = "$function_home/recent_files";
my $reporter_log_home = "$function_home/reporter_logs";
my $test_log_home     = "$function_home/testlogs";
my $script_PID        = "$function_home/script_PID";

my $recent_file_url = "http://cpan.org/authors/RECENT.recent";
my $modules_url  = "http://cpan.cpantesters.org/modules/01modules.index.html";
my $modules_list = "$function_home/modules";

my $disabled_file_url =
  "http://cpansearch.perl.org/src/ANDK/CPAN-2.10/distroprefs/01.DISABLED.yml";
my $disabled_file   = "$function_home/01.DISABLED.yml";
my $mydisabled_file = "$function_home/01.myDISABLED.yml";

my $rcnt_file             = "$recent_file_home/rcnt";
my $running_disabled_list = "$function_home/disabled_list";
my $running_enabled_list  = "$function_home/enabled_list";
my $enabled_list_sort     = "$function_home/enabled_list_sort";

my $modules_tested_log = "$function_home/modules_tested_log";
my $perlbuilds         = "$function_home/perlbuilds";

local $ENV{PERL_CPAN_REPORTER_CONFIG} =
  "$function_home/.cpanmreporter/config.ini";

my %functions =
  ( recent => \&do_recent, list => \&do_list, smoke => \&do_smoke, );

unless ( $function eq 'recent' | $function eq 'list' | $function eq 'smoke' ) {
    die "variable \$function must be recent, list or smoke:  $function \n";
}
say "\n\n=============>" if ($verbose);
say "starting script"    if ($verbose);
system("date");

verify_directories_files();

# dispatch the function
my $do_function = $functions{$function};
$do_function->();

sub do_smoke {

    kill_previous_run();
    open my $perlbuilds_fh, '<', "$perlbuilds" or die "can't open $perlbuilds";

    # slurp file but don't change $/ in this case
    my @revs = <$perlbuilds_fh>;
    close $perlbuilds_fh;

    say "Perl revisions to test with:\n @revs" if ($verbose);

    # get all module names from cpan
    # save module names and excluded file names to disk, aid troubleshooting
    my $Modules = get($modules_url);

    open my $modules_fh, '>', "$modules_list"
      or die "can't open $modules_list";
    say $modules_fh $Modules;
    close $modules_fh;

    LWP::Simple::getstore( $disabled_file_url, $disabled_file );
    my $Disabled = YAML::LoadFile($disabled_file);

    # myDisabled file containing my additions
    my $myDisabled = YAML::LoadFile($mydisabled_file);

` grep  '.tar.gz' $modules_list | sed -e 's/\.tar\.gz.*//g' | cut -c27- > tmp`;

    open my $tmp_fh,           '<', "tmp";
    open my $disabled_list_fh, '>', $running_disabled_list
      or die "can't open $running_disabled_list";

    open my $enabled_list_fh, '>', $running_enabled_list
      or die "can't open $running_enabled_list";

    while (<$tmp_fh>) {
        my $module = $_;
        chomp $module;

        # check if this module is included in either disabled list
        # if it is, don't test this module
        if (   ( $module =~ /$Disabled->{match}{distribution}/ )
            or ( $module =~ /$myDisabled->{match}{distribution}/ ) )
        {
      # module in excluded list
      #           say "$module in excluded list, skip testing it" if ($verbose);
            say $disabled_list_fh "$module " if ($verbose);
            next;
        }
        else {
         # module not in excluded list, test it
         #           say "$module not in excluded list, continue" if ($verbose);
            say $enabled_list_fh "$module ";
        }
    }

    close $disabled_list_fh;
    close $enabled_list_fh;
    close $tmp_fh;

    unlink("tmp");    # no reason to keep it
    open my $unsorted_modules_fh, '<', $running_enabled_list
      or die "can't open $running_enabled_list";
    my @unsorted_modules = <$unsorted_modules_fh>;
    close $unsorted_modules_fh;

    my @tmp            = sort @unsorted_modules;
    my @sorted_modules = uniq(@tmp);
    undef @tmp;
    undef @unsorted_modules;

    open my $sorted_modules_fh, '>', $enabled_list_sort
      or die "can't open $enabled_list_sort";
    say $sorted_modules_fh @sorted_modules;
    close $sorted_modules_fh;

    foreach my $module (@sorted_modules) {

        # see if this shows mem disappearing
        #       system("grep Mem /proc/meminfo") if ($verbose);
        #       system("date")                   if ($verbose);

        #       say "module under test is:  $module" if ($verbose);
        #       system("ls -a") if ($verbose);

        # has module already been tested?
        chomp($module);
        my $tested = `grep -c $module $modules_tested_log`;
        chomp($tested);
        if ( $tested > 0 ) {

            #           say "$module already tested, skip it" if ($verbose);
        }
        else {
            #           say "$module not yet tested, continue" if ($verbose);
            `echo $module >> $modules_tested_log`;
            test_module($module);
            say "exiting script" if ($verbose);
            system("date");
            say "<=============" if ($verbose);
            last;    # see if loading a fresh copy of script each time
                     # makes it run longer
        }
    }
}

sub do_recent {

    # kill any previously running instances of this script
    say "entered sub do_recent" if ($verbose);
    kill_previous_run();

    my $Recent = get_recent_file();

    check_for_updated_modules($Recent);

    say "exiting do_current" if ($verbose);
}

sub kill_previous_run {

    # if the script's previous run is still alive, kill it,
    # PID for previous script run is in this file
    if ( -e "$script_PID" ) {
        say "fetching previous PID" if ($verbose);
        open my $tester_PID_fh, '<', "$script_PID"
          or die "can't open for read $script_PID";
        my $previous_PID = <$tester_PID_fh>;
        chomp $previous_PID;
        close $tester_PID_fh;
        $previous_PID = " " . $previous_PID . " ";
        say "previous PID is $previous_PID" if ($verbose);

        # command returns 1 if still alive, 0 if not
        my $previous_tester_alive = kill 0, $previous_PID;
        say
"previous_tester_alive is (1=alive; 0=not alive): $previous_tester_alive"
          if ($verbose);

        if ( $previous_tester_alive != 0 ) {
            say "Previous script instance still alive, killing it";

            # using -15 is supposed to kill all PID descendants,
            # but it kills this currently running script also,
            # -1 SIGUP works
            $previous_PID *= -1;
            kill -1, $previous_PID;
            sleep 10;    # allow some time to die

            # if that didn't kill the still running script quit this script
            $previous_tester_alive = kill 0, $previous_PID;
            if ( $previous_tester_alive != 0 ) {
                die "previous script instance didn't die, quitting script\n";
            }
        }
        else {
            say "Previous script instance not running now, continue"
              if ($verbose);

        }
    }

    # save this script's  PID
    open my $script_PID_fh, '>', "$script_PID"
      or die "can't open $script_PID";
    my $this_PID = $$;
    say $script_PID_fh $this_PID;
    say "script PID is $this_PID, saving it" if ($verbose);
    close $script_PID_fh;

}

sub get_recent_file {

    # get the latest list of new or updated modules
    my $Recent = YAML::Load( get($recent_file_url) );

########### begin for testing only ###########
    {
        # comment this code if not needed,
        # save copy of recent file to aid troubleshooting
        ( my $s, my $usec ) = gettimeofday;
        chomp $s;
        chomp $usec;
        my $rcnt = $rcnt_file . "$s";
        LWP::Simple::getstore( $recent_file_url, $rcnt );
    }
########### end for testing only ###########

    # get and save a copy of list of modules which are not to be tested
    # file is maintained by CPAN tester ANDK
    LWP::Simple::getstore( $disabled_file_url, $disabled_file );
    return ($Recent);
}

sub check_for_updated_modules {
    my $Recent = $_[0];

    # when was RECENT file updated?
    my $Recent_updated = $Recent->{meta}{minmax}{max};

    my $previous_Recent_update_file = "$function_home/previous_Recent_update";

    # first time through set previous recent update time to nil
    unless ( -e $previous_Recent_update_file ) {
        open my $previous_Recent_update_fh, '>', $previous_Recent_update_file;
        say $previous_Recent_update_fh "0";
        close $previous_Recent_update_fh;
    }

    # when was RECENT file previously updated?
    open my $previous_Recent_update_fh, '<', $previous_Recent_update_file;
    my $previous_Recent_update = <$previous_Recent_update_fh>;
    close $previous_Recent_update_fh;
    chomp $previous_Recent_update;

    # if newest Recent file was updated after previous Recent file,
    # there may be modules to test
    if ( $Recent_updated > $previous_Recent_update ) {

        say "RECENT file updated since last checked" if ($verbose);
        open my $previous_Recent_update_fh, '>', "$previous_Recent_update_file";

        # save time of latest Recent file update
        say $previous_Recent_update_fh $Recent_updated;
        close $previous_Recent_update_fh;
        chomp $previous_Recent_update;

        # we know the RECENT.recent file has been updated,
        # are there any new or updated modules to test?
        for my $recent_entry ( reverse @{ $Recent->{recent} } ) {

            # check only files ending in .tar.gz
            say "checking file $recent_entry->{path}" if ($verbose);
            next unless ( $recent_entry->{path} =~ /\.tar\.gz$/ );
            say "found module $recent_entry->{path}" if ($verbose);

            say "Reading cpan disabled file" if ($verbose);
            my $Disabled = YAML::LoadFile($disabled_file);
            say "Read cpan disabled file" if ($verbose);

            say "Reading user copy of disabled file" if ($verbose);
            my $myDisabled = YAML::LoadFile($mydisabled_file);
            say "Read user's disabled file" if ($verbose);

            # isolate author/module name
            my $module = $recent_entry->{path};
            $module =~ s/\.tar\.gz//;
            my @name = split '/', $module;
            say "$module " if ($verbose);
            chomp $name[4];
            $module = $name[3] . '/' . $name[4];
            say "$name[3] $name[4]" if ($verbose);

            open my $disabled_list_fh, '>>', $running_disabled_list
              or die "can't open $running_disabled_list";

            open my $enabled_list_fh, '>>', $running_enabled_list
              or die "can't open $running_enabled_list";

            # check if this module is included in either disabled list
            # if it is, don't test this module
            # keep separate lists of enabled and disabled module names
            if (   ( $module =~ /$Disabled->{match}{distribution}/ )
                or ( $module =~ /$myDisabled->{match}{distribution}/ ) )
            {
                say $disabled_list_fh "$module ";
                say "$module found in disabled list, do not test"
                  if ($verbose);
                close $disabled_list_fh;
                close $enabled_list_fh;
                next;
            }
            else {
                say $enabled_list_fh "$module ";
                say "$module not found in disabled list, continue"
                  if ($verbose);
                close $disabled_list_fh;
                close $enabled_list_fh;
            }

            # has module already been tested?
            chomp($module);
            my $tested = `grep -c $module $modules_tested_log`;
            chomp($tested);
            if ( $tested > 0 ) {
                say "$module already tested, skip it" if ($verbose);
            }
            else {
                say "$module not yet tested, continue" if ($verbose);
                `echo $module >> $modules_tested_log`;
                test_module($module);
            }
        }
        say "Finished checking RECENT file for updated *.tar.gz module files"
          if ($verbose);
    }
    say "Finished checking RECENT file for any updates"
      if ($verbose);
}

sub test_module {

# $id contains (example)
# http://cpan.cpantesters.org/authors/id/D/DA/DAGOLDEN/Acme-Devel-Hide-Tiny-0.001.tar.gz
    my ($module) = @_;
    say "arg to test_module input:  $module " if ($verbose);

    # get list of perl builds to test modules against,
    # this list could change while script is running,
    # so read it here
    open my $perlbuilds_fh, '<', $perlbuilds
      or die "can't open $perlbuilds";

    # slurp file but don't change $/ in this case
    my @perlbuilds = <$perlbuilds_fh>;
    close $perlbuilds_fh;
    say "Perl revisions to test under:\n @perlbuilds" if ($verbose);

    # start a test process for each perl build,
    # maybe $jobs should be read from # of lines in perlbuilds.txt
    my $pm = Parallel::ForkManager->new($jobs);
    foreach my $perlbuild (@perlbuilds) {

        # make sure there's some time between output file timestamps
        sleep 2;

        say "starting test process for perl build $perlbuild" if ($verbose);
        chomp $perlbuild;
        system("date");

        $pm->start and next;

        eval {
            # setup to handle signals
            local $SIG{'HUP'}  = sub { say "Got hang up" };
            local $SIG{'INT'}  = sub { say "Got interrupt" };
            local $SIG{'STOP'} = sub { say "Stopped" };
            local $SIG{'TERM'} = sub { say "Got term" };
            local $SIG{'KILL'} = sub { say "Got kill" };

            # this one won't work with apostrophes like above
            local $SIG{__DIE__} = sub { say "Got die" };

            # next two variable settings are explained in this link
### http://www.dagolden.com/index.php/2098/the-annotated-lancaster-consensus
            local $ENV{NONINTERACTIVE_TESTING} = 1;
            local $ENV{AUTOMATED_TESTING}      = 1;

            # cpanm will put its test reports in this directory,
            # cpanm-reporter will get its input from this directory
            local $ENV{PERL_CPANM_HOME} = "$function_cpanm_home/$perlbuild";
            say "PERL_CPANM_HOME is:  $ENV{PERL_CPANM_HOME}" if ($verbose);

            my $BUILD_DIR     = $ENV{PERL_CPANM_HOME};
            my $BUILD_LOGFILE = "$BUILD_DIR/build.log";

          #            my $CPANM_REPORTER_HOME = "$function_cpanmreporter_home";

            unless ( -d $BUILD_DIR ) {
                mkdir $BUILD_DIR;
                system("chmod 777 $BUILD_DIR");
            }

            say "BUILD_DIR is: $BUILD_DIR for $perlbuild"         if ($verbose);
            say "BUILD_LOGFILE is: $BUILD_LOGFILE for $perlbuild" if ($verbose);

            # isolate module name
            $module = substr( $module, 0, rindex( $module, '-' ) )
              if ( $module =~ /-/ );
            say "module name cleared of final dash:  $module" if ($verbose);

            $module = substr( $module, rindex( $module, '/' ) + 1 );
            $module =~ s/-/::/g;

            my $cpanm_timeouts = " --configure-timeout 3600 ";
            $cpanm_timeouts .= " --build-timeout 3600 ";
            $cpanm_timeouts .= " --test-timeout 3600 ";

            # test the module, don't install it
            my $command = "perlbrew exec --with $perlbuild ";
            $command .= "cpanm $cpanm_timeouts --test-only $module ";
            $command .= "| tee $test_log_home/$module.$perlbuild ";
            say "about to test $module for $perlbuild" if ($verbose);
            system("which perl");
            check_test_exit( system("$command") );
            say "Should have completed testing $module for $perlbuild"
              if ($verbose);

            local $ENV{CPANM_REPORTER_HOME} = $function_cpanmreporter_home;
            say "CPANM_REPORTER_HOME is $ENV{CPANM_REPORTER_HOME}"
              if ($verbose);

  # reports already sent are listed in "user_home"/.cpanreporter/reports-sent.db
            unlink("$cpanmreporter_reports_sent");
            $command = "perlbrew exec --with $perlbuild ";
            $command .= "cpanm-reporter --verbose ";
            $command .= "--skip-history --ignore-versions --force ";
            $command .= "--build_dir=$BUILD_DIR ";
            $command .= "--build_logfile=$BUILD_LOGFILE ";
            $command .=
              "| tee $reporter_log_home/$module.$function.$perlbuild ";

            say "About to send cpanm report for $perlbuild: \n  $command"
              if ($verbose);
            check_reporter_exit( system($command) );
            say
"Should have completed sending cpanm report for $perlbuild :\n  $command"
              if ($verbose);
        };
        warn("bad exit from test_module subr") if $@;
        $pm->finish;
    }
    $pm->wait_all_children();
}

sub check_test_exit {
    my ($exit) = @_;
    if ( $exit == -1 ) {
        say "test failed to execute: $!";
    }
    elsif ( $exit & 127 ) {
        printf "test child died with signal %d, %s coredump\n",
          ( $exit & 127 ), ( $exit & 128 ) ? 'with' : 'without';
    }
    else {
        printf "test child exited with value %d\n", $exit >> 8;
    }
}

sub check_reporter_exit {
    my ($exit) = @_;
    if ( $exit == -1 ) {
        say "reporter failed to execute: $!";
    }
    elsif ( $exit & 127 ) {
        printf "reporter child died with signal %d, %s coredump\n",
          ( $exit & 127 ), ( $exit & 128 ) ? 'with' : 'without';
    }
    else {
        printf "reporter child exited with value %d\n", $exit >> 8;
    }
}

# create needed directories if they don't exist,
# only called when script doing recent function is started,
# better way to do this is set up an array and loop thru entries,
# however, how do I have $array[$function_home] return $ENV{HOME}/testers/$function?
# dereference a pointer [$function_home] to a pointer [$ENV{HOME}/testers/$function]?
sub verify_directories_files {
    if ( !File::Path::Tiny::mk("$function_home") ) {
        die "Could not make path $function_home : $!";
    }

    #    say "Path $function_home found" if ($verbose);

    if ( !File::Path::Tiny::mk("$function_cpanm_home") ) {
        die "Could not make path $function_cpanm_home : $!";
    }

    #    say "Path $function_cpanm_home found" if ($verbose);

    if ( !File::Path::Tiny::mk("$function_cpanmreporter_home") ) {
        die "Could not make path $function_cpanmreporter_home : $!";
    }

    #    say "Path $function_cpanmreporter_home found" if ($verbose);

    if ( !File::Path::Tiny::mk("$recent_file_home") ) {
        die "Could not make path $recent_file_home : $!";
    }

    #    say "Path $recent_file_home found" if ($verbose);

    if ( !File::Path::Tiny::mk("$reporter_log_home") ) {
        die "Could not make path $reporter_log_home : $!";
    }

    #    say "Path $reporter_log_home found" if ($verbose);

    if ( !File::Path::Tiny::mk("$test_log_home") ) {
        die "Could not make path $test_log_home : $!";
    }

    #    say "Path $test_log_home found" if ($verbose);

    # first time through this file shouldn't be there
    if ( ( $function eq 'current' ) && ( -e "$script_PID" ) ) {
        say "unlinking $script_PID" if ($verbose);
        unlink $script_PID or die "cannot unlink file $script_PID\n";
    }

    unless ( -e "$mydisabled_file" ) {
        open( my $mydisabled_file_fh, '>', "$mydisabled_file" )
          or die("cannot open $mydisabled_file\n");
        say $mydisabled_file_fh "0";
        close $mydisabled_file_fh;
    }

    unless ( -e "$modules_tested_log" ) {
        open( my $modules_tested_log_fh, '>', "$modules_tested_log" )
          or die("cannot create $modules_tested_log\n");
        close $modules_tested_log_fh;
    }

    # since this is run only at script start up,
    # get rid of history of tested and nontested files
    unlink $running_disabled_list if ( -e "$running_disabled_list" );
    unlink $running_enabled_list  if ( -e "$running_enabled_list" );
}

