#! /usr/bin/perl

# This script will try to set everything needed to run
# the virtuops/* containers for zabbix and related
# services

use strict;
use warnings;
use Term::ANSIColor qw(:constants);
use Term::ReadLine;
use File::Basename;
use POSIX qw(:sys_wait_h);
$| = 1;

my $version = '0.2';
my ($script_name, $script_path, $script_suffix) = fileparse($0,'.pl');

my $log = $script_path . $script_name . ".log";

# Define this vars on global scope but initialize on INIT block to decluter script
my ( $release_files_directory, $standard_release_file, %release_files, %data,
    %version_match, %docker_distros, %distro_specifics );

if ( $^O ne 'linux' ) {
    die "\n** I'm sorry. This is meant to run on a linux OS\n";
}

print GREEN
  "\n\n** Bootstrapping script for running docker images by VirtuOps **\n";
print "    this is version $version - updated as of May 31, 2018\n";
print "    log located at: $log\n\n";
print RESET;

print "Let's get started by checking if running as root ... ";

my $pwuid = getpwuid($<);

if ( $pwuid ne 'root' ) {
    print RED "$pwuid\n";
    print "\nI'm sorry $pwuid. This script has to be run by the root user\n";
    print RESET;
    exit 1;
}
else {
    print GREEN "$pwuid\n";
    print RESET;
}
open( LOG, ">> $log" ) or die "Couldn't create log file $log: $!\n";
logger("running as $pwuid");

print "Checking the linux distro ... ";
my $lx_distro  = distribution_name();
my $lx_version = distribution_version();
my $lx_name    = distribution_codename() || '';

unless ( $lx_distro ) {
  print YELLOW "Either your platform is not easily detectable or is not supported by this
  installer script.
  Please visit the following URL for more detailed installation instructions:

  https://docs.docker.com/engine/installation/";
  exit 1;
}

logger("Using distro $lx_distro $lx_version $lx_name");
print "$lx_distro $lx_version";

if ( grep(/$lx_version/, @{ $docker_distros{$lx_distro} }) ) {
    print GREEN " is supported.\n";
    print RESET;
}
else {
    print RED " NOT supported.\n";
    print RESET;
    exit 1;
}

# Find out if Docker is already installed using the distro's package manager
print "Let me find out if Docker is already installed ... ";

my $distro = $distro_specifics{$lx_distro};
my $cmd    = $distro->{'search_cmd'} . " " . $distro->{'docker_pkg'};
logger("Checking if Docker already installed with $cmd");

my $o = `$cmd 2>&1`;
logger("Resulting in '$o'\n");

if ( $o =~ $distro->{'not_installed'} ) {
    print RED "no, it's not\n";
    print RESET;
    # TODO: maybe check also if the docker command is found ?
    print "Do you want me to install Docker from official repositories ? [Yn]: ";
    my $install_docker = <STDIN>;
    chomp($install_docker);
    if ( $install_docker =~ /^[Yy]/ ) {
        vo_install_docker($distro);
    }
    elsif ( $install_docker =~ /^$/ ) {
        vo_install_docker($distro);
    }
    else {
        print "\n**Good bye.\n";
        exit 0;
    }
}
else {
    print GREEN "it is\n";
    print RESET;
}

# If we get here Docker is installed and we proceed to ask for our containers installation.
my $install_type = ask_install_type();
my $container_db_info;
my @containers;
my $spun_containers;

print "** Starting $install_type installation ...\n";
logger ("User selected $install_type installation");

if ( $install_type eq 'typical' ) {
   $container_db_info->{'db_location'} = 'local';
   @containers = qw( db server frontend );
}
elsif ( $install_type eq 'zabbix' ) {
  $container_db_info->{'db_location'} = 'remote';
  @containers = qw ( server frontend );
}
elsif ( $install_type eq 'proxy') {
  $container_db_info->{'db_location'} = 'nodb';
  print "Sorry, not implemented yet"; exit 1;
  @containers = qw( proxy );
}
else {
  die "I don't know how you managed to get here, but it was wrong.\n";
}

ask_db_config( $container_db_info->{'db_location'} );

foreach my $container ( @containers ) {
  spin_container( $container );
}

print `docker ps -a`;
exit 0;

# --- End main()

# There be monsters down below
sub spin_container {
  my $container = shift;
  my $run_command = 'docker run -d';

  logger("** Starting container spin for $container");

  # Spinning container for database
  # db configurations variables are stored on global hash ref $container_db_info
  if ( $container eq 'db' ) {
    my $db_run_command = $run_command;
    print "\n** Preparing container for the Database ...\n";
    $spun_containers->{'db_container_name'} = get_user_response(
                 {'prompt'   => "What name do you want to give the Database container",
                  'default'  => "mysql-server",
                  'on_blank' => 'use_default'
                  } );
    logger ("Database container name is '$spun_containers->{db_container_name}'");
    $db_run_command .= " --name $spun_containers->{'db_container_name'}";

    if ( $container_db_info->{'db_location'} eq 'local' ) {
      $db_run_command .= ' -p 3306:3306';
    }


    logger("Information for database %{$container_db_info}");
    foreach my $env ( keys %{ $container_db_info } ) {
      next if ($env eq 'db_location');
      $db_run_command .= ' -e ' . $env . '=' . $container_db_info->{$env};
    }
    $db_run_command .= ' mariadb';

    # Perform actual spinning of the container
    print "\n** Starting database container, please wait a minute ...\n";
    execute_and_validate("Spinning Database container", $db_run_command, 1);
  }

  if ($container eq 'server') {
    my $server_run_command = $run_command;
    print "\n** Preparing container for the Zabbix server ...\n";
    $spun_containers->{'server_container_name'} = get_user_response(
                 {'prompt'   => "What name do you want to give the Zabbix server container",
                  'default'  => "zabbix-server",
                  'on_blank' => 'use_default'
                  } );
    logger ("Zabbix server container name is '$spun_containers->{server_container_name}'");
    $server_run_command .= " --name $spun_containers->{'server_container_name'}";
    $server_run_command .= ' -p 10051:10051';

    if ( $container_db_info->{'db_location'} eq 'local') {
      $server_run_command .= ' --link ' . $spun_containers->{'db_container_name'} .
                             ':mysql-server';
    }
    else {
      print "\n** Need some information but my programmer has not built this part yet";
    }

    foreach my $env ( keys %{ $container_db_info } ) {
      next if ($env eq 'db_location');
      $server_run_command .= ' -e ' . $env . '=' . $container_db_info->{$env};
    }
    $server_run_command .= ' virtuops/zabbix-server';

    # Perform actual spinning of the container
    print "\n** Starting Zabbix Server container, please wait a minute ...\n";
    execute_and_validate("Spinning Zabbix Server container", $server_run_command, 1);
  }

  if ($container eq 'frontend') {
    my $web_run_command = $run_command;
    print "\n** Preparing the container for the Zabbix Frontend ...\n";
    $spun_containers->{'web_container_name'} = get_user_response(
                 {'prompt'   => "What name do you want to give the Web Frontend container",
                  'default'  => "zabbix-webif",
                  'on_blank' => 'use_default'
                  } );
    logger ("Web Frontend Container name is '$spun_containers->{web_container_name}'");
    $web_run_command .= " --name $spun_containers->{'web_container_name'}";
    $web_run_command .= ' -p 80:80';
    $web_run_command .= ' --link ' .
                        $spun_containers->{'server_container_name'} . ':zabbix-server';

    if ( $container_db_info->{'db_location'} eq 'local') {
      # At this point there must be a container for the database and zabbix server
      $web_run_command .= ' --link ' .
                          $spun_containers->{'db_container_name'} . ':mysql-server';
    }
    else {
      print "\n** Need some information but my programmer has not built this part yet";
    }

    foreach my $env ( keys %{ $container_db_info } ) {
      next if ($env eq 'db_location');
      $web_run_command .= ' -e ' . $env . '=' . $container_db_info->{$env};
    }
    $web_run_command .= ' virtuops/zabbix-webif';

    # Perform actual spinning of the container
    print "\n** Starting Web Frontend container, please wait a minute ...\n";
    execute_and_validate("Spinning Zabbix Server container", $web_run_command, 1);
  }

}

sub vo_install_docker {
    my $install = shift;
    print "\n** Installing Docker Community Edition\n";
    logger("User requested installation of docker");

   # As a precaution, Docker suggests to try and remove older versions of docker
    my $cmd = $install->{'remove_cmd'} . ' '
      . join( ' ', @{ $install->{'docker_old'} } );
    print "Making sure to clean older versions of docker ... ";
    logger("Cleaing with command: '$cmd'");
    eval { `$cmd 2>&1 >> $log` };
    if ($@) {
        print RED "\nThere was an error trying to clean older packages please review log: $log\n";
        print RESET;
    }
    print GREEN "done\n";
    print RESET;

    # TODO: Extra steps for Ubuntu 14.04

    ##  setup the repository
    $cmd = $install->{'update_cmd'};
    print "Updating repository to install some pre-requisites... ";
    execute_and_validate( "Updating repository", $cmd, 0 );

    # Install pre-requisites
    if ( $install->{'pre_pkgs'} ) {
        print "Installing pre-requisites for Docker ... ";
        $cmd = $install->{'install_cmd'} . ' '
          . join( ' ', @{ $install->{'pre_pkgs'} } );
        execute_and_validate( "Installing pre-requisites", $cmd, 1 );
    }

    # Running commands necessary before pulling docker packages
    if ( $install->{'pre_cmds'} ) {
        print "Running additional commands in preparation for Docker packages ...\n";
        foreach $cmd ( @{ $install->{'pre_cmds'} } ) {
            print "\t$cmd ...";
            execute_and_validate( "Pre Install command", $cmd, 1 );
        }
    }

  # Add repository. Some substitutions need to be made depending on Linux distro
    my $repo = $install->{'repo_string'};
    $repo =~ s/\{codename\}/$lx_name/;
    $cmd = $install->{'add_rep_cmd'} . ' ' . $repo;
    print "Adding $repo to $lx_distro repositories ... ";
    execute_and_validate( "Adding repo", $cmd, 1 );

    # Install Docker
    print "Updating repository information ... ";
    execute_and_validate( "Update repositories for $lx_distro",
        $install->{'update_cmd'}, 1 );

    print "Installing Docker ... ";
    $cmd = $install->{'install_cmd'} . ' ' . $install->{'docker_pkg'};
    execute_and_validate( "Installing Docker", $cmd, 1 );

    # Enable Docker systemctl TODO: verify distro to use specific init type
    $cmd = "systemctl enable docker";
    print "Enabling start on boot ... ";
    execute_and_validate( "Enabling start on boot", $cmd, 0 );

    # Make sure docker daemon starts running
    $cmd = "service docker start";
    print "Starting docker daemon ... ";
    execute_and_validate( "Starting docker daemon", $cmd, 0 );
}

# Runs the defined commands and logs the result
# A true value on the 3rd parameter indicates if it should stop on error or ignore
sub execute_and_validate {
    my ( $stage, $cmd, $die_on_error ) = @_;
    logger("$stage. Command: '$cmd'");
    my $out = `$cmd 2>&1 >> $log`;

    if ( $? == 0 ) {
        print GREEN "\n $stage ok\n";
        print RESET;
    }
    else {
        print RED;
        if ( $? == -1 ) {
            print "failed to execute: $!\n";
        }
        elsif ( $? & 127 ) {
            printf "died with signal %d, %s coredump\n", ( $? & 127 ),
              ( $? & 128 ) ? 'with' : 'without';
        }
        else {
            printf "finished with value %d\n", $? >> 8;
        }

        if ($die_on_error) {
            print "Fatal error $stage: $out $! $@\n";
            print "Check log $log\n";
            print RESET;
            exit 1;
        }
    }
}

sub ask_db_config {
  my $db_type = shift;
  return if ($db_type eq 'nodb');

  # Required information for the database container
  my $db_var_config = {
      'MYSQL_DATABASE' => {
        'default' => 'zabbix',
        'prompt'  => "Name of the database to use",
        'on_blank' => 'use_default'
      },
      'MYSQL_ROOT_PASSWORD' => {
        'default' => '',
        'prompt'  => "Password for database user root",
        'on_blank' => 'custom'
      },
      'DB_SERVER_HOST' => {
        'default' => 'mysql-server',
        'prompt'  => "Hostname or IP of the MySQL server",
        'on_blank' => 'use_default'
      },
      'DB_SERVER_PORT' => {
        'default' => 3306,
        'prompt'  => "Database port to connect to",
        'on_blank' => 'use_default'
      },
      'MYSQL_USER' => {
        'default' => 'zabbix',
        'prompt'  => "MySQL user to connect to Zabbix database",
        'on_blank' => 'use_default'
      },
      'MYSQL_PASSWORD' => {
        'default' => 'zabbix',
        'prompt'  => "Password for MySQL user to connect to Zabbix database",
        'on_blank' => 'use_default'
      },
    };


  if ( $db_type eq 'local' ) {
    $container_db_info->{'MYSQL_DATABASE'} = get_user_response( $db_var_config->{'MYSQL_DATABASE'} );
    $container_db_info->{'MYSQL_USER'}     = get_user_response( $db_var_config->{'MYSQL_USER'} );
    $container_db_info->{'MYSQL_PASSWORD'} = get_user_response( $db_var_config->{'MYSQL_PASSWORD'} );

    # Always create a dedicated user on the database for zabbix if local install with container
    $container_db_info->{'CREATE_ZBX_DB_USER'} = "true";

    # Assign a password for the database root user. We use root to create zabbix user and db
    my $db_root_passwrd = get_user_response( $db_var_config->{'MYSQL_ROOT_PASSWORD'} );
    if ( $db_root_passwrd eq '_blank_' ) {
      print YELLOW "  Using empty password for user root\n";
      $container_db_info->{'MYSQL_ROOT_PASSWORD'} = "";
      $container_db_info->{'MYSQL_ALLOW_EMPTY_PASSWORD'} = "true";
    }
    else {
      $container_db_info->{'MYSQL_ROOT_PASSWORD'} = $db_root_passwrd;
    }
  }

  if ( $db_type eq 'remote' ) {
    # Ask if the remote server has a DB created. Also get the user and password with all the privileges
    print YELLOW "In order to use a remote database for Zabbix we need either: \n";
    print " - Remote database created and a user with all privileges so we can connect to it\n";
    print "   and create the schema.\n\n";
    print " - Password for the root user on the MySQL server so we create database and user.\n\n";
    print RESET;

    my $term = Term::ReadLine->new("remote_db_prompt");
    my $prompt = 'Do you have a MySQL schema with a user or have the root password [ user | root ] ?: ';
    my $OUT = $term->OUT() || *STDOUT;
    my $choice;

    while ( defined ( $choice = $term->readline($prompt) )) {
      if ( $choice =~ /root/i ) {
      	 print "\n";
      	 $container_db_info->{'CREATE_ZBX_DB_USER'} = "true";
         $container_db_info->{'MYSQL_ROOT_PASSWORD'} = get_user_response( $db_var_config->{'MYSQL_ROOT_PASSWORD'} );
      	 $container_db_info->{'MYSQL_DATABASE'} = 'zabbix';
      	 $container_db_info->{'MYSQL_USER'} = 'zabbix';
      	 $container_db_info->{'MYSQL_PASSWORD'} = 'zabbix';
         $container_db_info->{'DEBUG_MODE'} = 'true';
      	 last;
      }
      elsif ( $choice =~ /user/i ) {
      	print "\n";
        $container_db_info->{'MYSQL_DATABASE'} = get_user_response( $db_var_config->{'MYSQL_DATABASE'} );
        $container_db_info->{'MYSQL_USER'}     = get_user_response( $db_var_config->{'MYSQL_USER'} );
        $container_db_info->{'MYSQL_PASSWORD'} = get_user_response( $db_var_config->{'MYSQL_PASSWORD'} );
      	last;
      }
      else {
        print RED "$choice doesn't look like anything to me\n";
        undef $choice;
        print RESET;
      }
    }

    $container_db_info->{'DB_SERVER_HOST'} = get_user_response( $db_var_config->{'DB_SERVER_HOST'});
    $container_db_info->{'DB_SERVER_PORT'} = get_user_response( $db_var_config->{'DB_SERVER_PORT'});

  }
}

sub ask_install_type {

  print "** We have Docker lets get our containers\n";
  print YELLOW "\n",
   'This script can perform the following type of Zabbix installations:', "\n",
   'Typical: A typical installation will have the containers for the Database,',"\n",
   '         Zabbix Server and Zabbix Frontend running on the same node',"\n\n";
  print
   'Zabbix: The Zabbix installation will install the Zabbix Server and Zabbix', "\n",
   '        Frontend on this node using a remote MySQL database.', "\n",
   '        Be ready to provide connection information for remote database', "\n\n";

  print
   'Proxy: Zabbix Proxy for remote monitoring. This proxy needs to connect to',"\n",
   '       an already running Zabix Server.',"\n",
   '       Be ready to provide connection information for remote Zabbix Server', "\n\n";
  print RESET;

  my $term = Term::ReadLine->new("Install_details");
  my $prompt = 'What installation do you want [ typical | zabbix | proxy ]: ';
  my $OUT = $term->OUT() || *STDOUT;
  my $choice;

  while ( defined ($choice = $term->readline($prompt) )) {
    if ( $choice =~ /typical/i ) {
      print "\n";
      return 'typical';
    } elsif ( $choice =~ /zabbix/i ) {
      print "\n";
      return 'zabbix';
    } elsif ( $choice =~ /proxy/i ) {
      print "\n";
      return 'proxy'
    } else {
      print RED "$choice doesn't look like anything to me\n";
      undef $choice;
      print RESET;
    }
  }
}

sub get_user_response {
  my $config = shift;
  my $answer;

  my $prompt = $config->{'prompt'};
  my $default = $config->{'default'};

  if ( $default ) {
    $prompt .=  " [$default]";
  }
  $prompt .= ' : ';
  print "$prompt";

  chomp($answer = <STDIN>);
  if ( $answer =~ /^$/ ) {
    if ( $config->{'on_blank'} eq 'use_default' ){
      return $default
    }
    else {
      logger("There should be a proper handling of blank value for '$config->{prompt}'");
      return '_blank_';
    }
  }
  else {
    return $answer;
  }
}

sub logger {
    my $msg = shift;
    my $ts  = localtime;
    print LOG "$ts: $msg\n";
}

sub distribution_name {
    my $distro;

    if ( $distro = _get_lsb_info() ) {
        return $distro if ($distro);
    }

    foreach (qw(enterprise-release fedora-release CloudLinux-release)) {
        if ( -f "$release_files_directory/$_"
            && !-l "$release_files_directory/$_" )
        {
            if ( -f "$release_files_directory/$_"
                && !-l "$release_files_directory/$_" )
            {
                $data{'DISTRIB_ID'}   = $release_files{$_};
                $data{'release_file'} = $_;
                return $data{'DISTRIB_ID'};
            }
        }
    }

    foreach ( keys %release_files ) {
        if ( -f "$release_files_directory/$_"
            && !-l "$release_files_directory/$_" )
        {
            if ( -f "$release_files_directory/$_"
                && !-l "$release_files_directory/$_" )
            {
                if ( $release_files{$_} eq 'redhat' ) {
                    foreach my $rhel_deriv ( 'centos', 'scientific', ) {
                        $data{'pattern'}      = $version_match{$rhel_deriv};
                        $data{'release_file'} = 'redhat-release';
                        if ( _get_file_info() ) {
                            $data{'DISTRIB_ID'}   = $rhel_deriv;
                            $data{'release_file'} = $_;
                            return $data{'DISTRIB_ID'};
                        }
                    }
                    $data{'pattern'} = '';
                }
                $data{'release_file'} = $_;
                $data{'DISTRIB_ID'}   = $release_files{$_};
                return $data{'DISTRIB_ID'};
            }
        }
    }
    undef;
}

sub distribution_version {
    my $release;
    return $release if ( $release = _get_lsb_info('DISTRIB_RELEASE') );
    if ( !$data{'DISTRIB_ID'} ) {
        distribution_name() or die 'No version because no distro.';
    }
    $data{'pattern'}         = $version_match{ $data{'DISTRIB_ID'} };
    $release                 = _get_file_info();
    $data{'DISTRIB_RELEASE'} = $release;
    return $release;
}

sub distribution_codename {
    my $codename;
    return $codename if ( $codename = _get_lsb_info('DISTRIB_CODENAME') );
    if ( !$data{'DISTRIB_ID'} ) {
        distribution_name() or die 'No version because no distro.';
    }
    $data{'pattern'}          = $version_match{ $data{'DISTRIB_ID'} };
    $codename                 = _get_file_info();
    $data{'DISTRIB_CODENAME'} = $codename;
    return $codename;
}

sub _get_lsb_info {
    my $field = shift || 'DISTRIB_ID';
    my $tmp = $data{'release_file'};
    if ( -r "$release_files_directory/" . $standard_release_file ) {
        $data{'release_file'} = $standard_release_file;
        $data{'pattern'}      = $field . '=["]?([^"]+)["]?';
        my $info = _get_file_info();
        if ($info) {
            $data{$field} = $info;
            return $info;
        }
    }
    $data{'release_file'} = $tmp;
    $data{'pattern'}      = '';
    undef;
}

sub _get_file_info {
    open my $fh, '<', "$release_files_directory/" . $data{'release_file'}
      or die 'Cannot open file: '
      . $release_files_directory . '/'
      . $data{'release_file'};
    my $info = '';
    local $_;
    while (<$fh>) {
        chomp $_;
        ($info) = $_ =~ m/$data{'pattern'}/;
        return "\L$info" if $info;
    }
    undef;
}

INIT {
  $SIG{INT} = sub { print RESET; print "\nInterrupted\n"; exit 10 };
  $SIG{TERM} = sub { print RESET; print "\niTerminated\n";  exit 11};

  $release_files_directory = '/etc';
  $standard_release_file   = 'lsb-release';

  %docker_distros = ( 'centos' => ['7'],
                      'debian' => ['8', '9'],
                      'fedora' => ['26', '27'],
                      'ubuntu' => ['16.04']
                      );

  %release_files = (
        'gentoo-release'        => 'gentoo',
        'fedora-release'        => 'fedora',
        'centos-release'        => 'centos',
        'enterprise-release'    => 'oracle enterprise linux',
        'turbolinux-release'    => 'turbolinux',
        'mandrake-release'      => 'mandrake',
        'mandrakelinux-release' => 'mandrakelinux',
        'debian_version'        => 'debian',
        'debian_release'        => 'debian',
        'SuSE-release'          => 'suse',
        'knoppix-version'       => 'knoppix',
        'yellowdog-release'     => 'yellowdog',
        'slackware-version'     => 'slackware',
        'slackware-release'     => 'slackware',
        'redflag-release'       => 'redflag',
        'redhat-release'        => 'redhat',
        'redhat_version'        => 'redhat',
        'conectiva-release'     => 'conectiva',
        'immunix-release'       => 'immunix',
        'tinysofa-release'      => 'tinysofa',
        'trustix-release'       => 'trustix',
        'adamantix_version'     => 'adamantix',
        'yoper-release'         => 'yoper',
        'arch-release'          => 'arch',
        'libranet_version'      => 'libranet',
        'va-release'            => 'va-linux',
        'pardus-release'        => 'pardus',
        'system-release'        => 'amazon',
        'CloudLinux-release'    => 'CloudLinux',
    );

    %version_match = (
        'gentoo' => 'Gentoo Base System release (.*)',
        'debian' => '(.+)',
        'suse'   => 'VERSION = (.*)',
        'fedora' => 'Fedora(?: Core)? release (\d+) \(',
        'redflag' =>
          'Red Flag (?:Desktop|Linux) (?:release |\()(.*?)(?: \(.+)?\)',
        'redhat' => 'Red Hat(?: Enterprise)? Linux(?: Server)? release (.*) \(',
        'oracle enterprise linux' => 'Enterprise Linux Server release (.+) \(',
        'slackware'               => '^Slackware (.+)$',
        'pardus'                  => '^Pardus (.+)$',
        'centos'                  => '^CentOS(?: Linux)? release (.+) \(',
        'scientific'              => '^Scientific Linux release (.+) \(',
        'amazon'                  => 'Amazon Linux AMI release (.+)$',
        'CloudLinux'              => 'CloudLinux Server release (\S+)'
    );

    %data = (
        'DISTRIB_ID'          => '',
        'DISTRIB_RELEASE'     => '',
        'DISTRIB_CODENAME'    => '',
        'DISTRIB_DESCRIPTION' => '',
        'release_file'        => '',
        'pattern'             => ''
    );

    %distro_specifics = (
        'debian' => {
            'search_cmd'  => 'dpkg -s',
            'update_cmd'  => 'apt-get update -qq',
            'remove_cmd'  => 'apt-get remove -qq -y',
            'install_cmd' => 'apt-get install -y',
            'add_rep_cmd' => 'add-apt-repository',
            'pre_pkgs'    => [
                'apt-transport-https', 'ca-certificates',
                'curl', 'gnupg2', 'software-properties-common'
            ],
            'pre_cmds' => [
'curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /tmp/docker.gpg',
                'apt-key add /tmp/docker.gpg'
            ],
            'repo_string' =>
'"deb [arch=amd64] https://download.docker.com/linux/debian {codename} stable"',
            'docker_pkg'    => 'docker-ce',
            'docker_old'    => [ 'docker', 'docker-engine', 'docker.io' ],
            'not_installed' => qr/package '(.*)' is not installed/,
        },

        'ubuntu' => {
            'search_cmd'  => 'dpkg -s',
            'update_cmd'  => 'apt-get update -qq',
            'remove_cmd'  => 'apt-get remove -qq -y',
            'install_cmd' => 'apt-get install -y',
            'add_rep_cmd' => 'add-apt-repository',
            'pre_pkgs'    => [
                'apt-transport-https', 'ca-certificates',
                'curl',                'software-properties-common'
            ],
            'pre_cmds' => [
'curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /tmp/docker.gpg',
                'apt-key add /tmp/docker.gpg'
            ],
            'repo_string' =>
'"deb [arch=amd64] https://download.docker.com/linux/ubuntu {codename} stable"',
            'docker_pkg'    => 'docker-ce',
            'docker_old'    => [ 'docker', 'docker-engine', 'docker.io' ],
            'not_installed' => qr/package '(.*)' is not installed/,
        },

        'fedora' => {
            'search_cmd'  => 'dnf list installed',
            'update_cmd'  => 'apt-get update',
            'remove_cmd'  => 'dnf remove',
            'install_cmd' => 'dnf -y install',
            'add_rep_cmd' => 'dnf config-manager --add-repo',
            'pre_pkgs'    => [ 'dnf-plugins-core' ],
            'pre_cmds' => '',
            'repo_string' => 'https://download.docker.com/linux/fedora/docker-ce.repo',
            'docker_pkg'    => 'docker-ce',
            'docker_old'    => [ 'docker', 'docker-client', 'docker-client-latest',
                                 'docker-common', 'docker-latest',
                                 'docker-latest-logrotate', 'docker-logrotate',
                                 'docker-selinux', 'docker-engine-selinux',
                                 'docker-engine'
                                ],
            'not_installed' => qr/Error: No matching Packages to list/,
        },

        'centos' => {
            'search_cmd'  => 'yum list installed',
            'update_cmd'  => 'yum makecache fast',
            'remove_cmd'  => 'yum remove',
            'install_cmd' => 'yum install -y',
            'add_rep_cmd' => 'yum-config-manager --add-repo',
            'pre_pkgs'    => [ 'yum-utils', 'device-mapper-persistent-data',
                               'lvm2',
                              ],
            'pre_cmds' => '',
            'repo_string' => 'https://download.docker.com/linux/centos/docker-ce.repo',
            'docker_pkg'    => 'docker-ce',
            'docker_old'    => [ 'docker', 'docker-client', 'docker-client-latest',
                                 'docker-common', 'docker-latest',
                                 'docker-latest-logrotate', 'docker-logrotate',
                                 'docker-selinux', 'docker-engine-selinux',
                                 'docker-engine'
                                ],
            'not_installed' => qr/Error: No matching Packages to list/,
        }
    );
}

END { print RESET }
