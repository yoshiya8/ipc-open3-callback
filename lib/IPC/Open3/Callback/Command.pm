#!/usr/local/bin/perl

use strict;
use warnings;

package IPC::Open3::Callback::Command;

# ABSTRACT: A utility class that provides subroutines for building shell command strings.

use Exporter qw(import);
our @EXPORT_OK = qw(batch_command command command_options mkdir_command pipe_command rm_command sed_command write_command);

sub batch_command {
    wrap(
        {},
        @_,
        sub {
            return @_;
        }
    );
}

sub command_options {
    return IPC::Open3::Callback::Command::CommandOptions->new( @_ );
}

sub command {
    wrap(
        {},
        @_,
        sub {
            return shift;
        }
    );
}

sub mkdir_command {
    wrap(
        {},
        @_,
        sub {
            return 'mkdir -p "' . join( '" "', @_ ) . '"';
        }
    );
}

sub pipe_command {
    wrap(
        { command_separator => '|' },
        @_,
        sub {
            return @_;
        }
    );
}

sub rm_command {
    wrap(
        {},
        @_,
        sub {
            return 'rm -rf "' . join( '" "', @_ ) . '"';
        }
    );
}

sub sed_command {
    wrap(
        {},
        @_,
        sub {
            my @args = @_;
            my $options = {};

            if ( ref($args[$#args]) eq 'HASH' ) {
                $options = pop(@args);
            }

            my $command = 'sed';
            $command .= ' -i' if ( $options->{in_place} );
            if ( defined( $options->{temp_script_file} ) ) {
                my $temp_script_file_name = $options->{temp_script_file}->filename();
                print( { $options->{temp_script_file} } join( ' ', '', map {"$_;"} @args ) )
                    if ( scalar(@args) );
                print(
                    { $options->{temp_script_file} } join( ' ',
                        '',
                        map {"s/$_/$options->{replace_map}{$_}/g;"}
                            keys( %{ $options->{replace_map} } ) )
                ) if ( defined( $options->{replace_map} ) );
                $options->{temp_script_file}->flush();
                $command .= " -f $temp_script_file_name";
            }
            else {
                $command .= join( ' ', '', map {"-e '$_'"} @args ) if ( scalar(@args) );
                $command .= join( ' ',
                    '',
                    map {"-e 's/$_/$options->{replace_map}{$_}/g'"}
                        keys( %{ $options->{replace_map} } ) )
                    if ( defined( $options->{replace_map} ) );
            }
            $command .= join( ' ', '', @{ $options->{files} } ) if ( $options->{files} );

            return $command;
        }
    );
}

sub write_command {
    # ($filename, @lines, [\%write_options], [$command_options])
    my $filename = shift;
    my @lines = @_;
    my $command_options = pop( @lines ) if ( ref($lines[$#lines]) eq 'IPC::Open3::Callback::Command::CommandOptions' );
    my $write_options = pop( @lines ) if ( ref($lines[$#lines]) eq 'HASH' );

    my $remote_command = "dd of=$filename";
    if ( defined( $write_options ) && defined( $write_options->{mode} ) ) {
        if ( defined( $command_options ) ) {
            $remote_command = batch_command( $remote_command, 
                "chmod $write_options->{mode} $filename",
                $command_options );
        }
        elsif ( defined( $command_options ) ) {
            $remote_command = batch_command( $remote_command, 
                "chmod $write_options->{mode} $filename" );
        }
    }
    elsif ( defined( $command_options ) ) {
        $remote_command = command( $remote_command, $command_options );
    }

    my $line_separator = ( defined( $write_options ) && defined( $write_options->{line_separator} ) ) 
        ? $write_options->{line_separator} : '\n';
    return pipe_command( 'printf "' . join( $line_separator, @lines ) . '"', $remote_command );
}

# Handles wrapping commands with possible ssh and command prefix
sub wrap {
    my $wrap_options = shift;
    my $builder      = pop;
    my @args         = @_;
    my ( $ssh, $username, $hostname, $sudo_username, $pretty );

    if ( ref($args[$#args]) eq 'IPC::Open3::Callback::Command::CommandOptions' ) {
        my $options = pop( @args );
        $ssh            = $options->get_ssh() || 'ssh';
        $username       = $options->get_username();
        $hostname       = $options->get_hostname();
        $sudo_username  = $options->get_sudo_username();
        $pretty         = $options->get_pretty();
    }

    my $destination_command = '';
    my $command_separator   = $wrap_options->{command_separator} || ';';
    my $commands            = 0;
    foreach my $command ( &$builder( @args ) ) {
        if ( defined($command) ) {
            if ($commands++ > 0) {
                $destination_command .= $command_separator;
                if ( $pretty ) {
                    $destination_command .= "\n";
                }
            }
            $command =~ s/^(.*?[^\\]);$/$1/; # from find -exec
            $destination_command .= $command;
        }
    }
    
    if ( defined( $sudo_username ) ) {
        $destination_command = "sudo " .
            ($sudo_username ? "-u $sudo_username " : '') . 
            "bash -c " . _quote_command( $destination_command );
    }

    if ( !defined($username) && !defined($hostname) ) {
        # silly to ssh to localhost as current user, so dont
        return $destination_command;
    }

    my $userAt = $username
        ? ( ( $ssh =~ /plink(?:\.exe)?$/ ) ? "-l $username " : "$username\@" )
        : '';

    $destination_command = _quote_command( $destination_command );
    return "$ssh $userAt" . ( $hostname || 'localhost' ) . " $destination_command";
}

sub _quote_command {
    my ($command) = @_;
    $command =~ s/\\/\\\\/g;
    $command =~ s/`/\\`/g; # for `command`
    $command =~ s/"/\\"/g;
    return "\"$command\"";
}

package IPC::Open3::Callback::Command::CommandOptions;

use parent qw(Class::Accessor);
__PACKAGE__->follow_best_practice;
__PACKAGE__->mk_accessors(
    qw(always_ssh hostname pretty ssh sudo_username username) );

use Socket qw(getaddrinfo getnameinfo);

sub new {
    my ($class, @args) = @_;
    return bless( {}, $class )->_init( @args );
}

sub _init {
    my ($self, %options) = @_;

    $self->{always_ssh} = $options{always_ssh};
    $self->{hostname} = $options{hostname} if ( defined( $options{hostname} ) );
    $self->{ssh} = $options{ssh} if ( defined( $options{ssh} ) );
    $self->{username} = $options{username} if ( defined( $options{username} ) );
    $self->{sudo_username} = $options{sudo_username} if ( defined( $options{sudo_username} ) );
    $self->{pretty} = $options{pretty} if ( defined( $options{pretty} ) );

    return $self;
}

sub set_hostname {
    my ($self, $hostname) = @_;
    $self->{hostname} = $hostname;
    delete( $self->{cached_hostname} );
    delete( $self->{cached_local} );
}

sub get_hostname {
    my ($self) = @_;
    
    if ( !defined( $self->{cached_hostname} ) ) {
        if ( $self->{always_ssh} || ! $self->is_local() ) {
            $self->{cached_hostname} = $self->{hostname};
        }
        else {
            $self->{cached_hostname} = undef;
        }
    }
    
    return $self->{cached_hostname}
}

sub is_local {
    my ($self) = @_;

    if ( ! defined( $self->{cached_local} ) ) {
        if ( ! $self->{hostname} ) {
            $self->{cached_local} = 1;
        }
        else {
            my ($local_hostname, $resolved_hostname, $addrinfo, $err);

            ($local_hostname) = `hostname --fqdn` =~ /^(\S+)/;
            ($err, $addrinfo) = getaddrinfo( $self->{hostname} );
            if ( ! $err ) {
                ($err, $resolved_hostname) = getnameinfo( $addrinfo->{addr} ) if ( ! $err );
            }

            if ( ! $err ) {
                $self->{cached_local} = $err ? 0 : lc($local_hostname) eq lc($resolved_hostname);
            }
        }
    }
    
    return $self->{cached_local};
}

1;

__END__
=head1 SYNOPSIS

  use IPC::Open3::Callback::Command qw(command batch_command mkdir_command pipe_command rm_command sed_command);
  my $command = command( 'echo' ); # echo

  # ssh foo "echo"
  $command = command( 'echo', command_options( hostname=>'foo' ) ); 

  # ssh bar@foo "echo"
  $command = command( 'echo', command_options( username=>'bar',hostname=>'foo' ) ); 
  
  # plink -l bar foo "echo"
  $command = command( 'echo', command_options( username=>'bar',hostname=>'foo',ssh=>'plink' ) ); 
  
  # cd foo;cd bar
  $command = batch_command( 'cd foo', 'cd bar' ); 
  
  # ssh baz "cd foo;cd bar"
  $command = batch_command( 'cd foo', 'cd bar', command_options( hostname=>'baz' ) ); 
  
  # ssh baz "sudo bash -c \"cd foo;cd bar\""
  $command = batch_command( 'cd foo', 'cd bar', command_options( hostname=>'baz',sudo_username=>'' ) ); 
  
  # ssh baz "mkdir -p \"foo\" \"bar\""
  $command = mkdir_command( 'foo', 'bar', command_options( hostname=>'baz' ) ); 

  # cat abc|ssh baz "dd of=def"
  $command = pipe_command( 
          'cat abc', 
          command( 'dd of=def', command_options( hostname=>'baz' ) ) 
      ); 

  # ssh fred@baz "sudo -u joe \"rm -rf \\\\"foo\\\\" \\\\"bar\\\\"\""
  $command = rm_command( 'foo', 'bar', command_options( username=>'fred',hostname=>'baz',sudo_username=>'joe' ) ); 
  
  # sed -e 's/foo/bar/'
  $command = sed_command( 's/foo/bar/' ); 
  
  
  # curl http://www.google.com|sed -e \'s/google/gaggle/g\'|ssh fred@baz "sudo -u joe bash -c \"dd of=\\\\\\"/tmp/gaggle.com\\\\\\"\"";ssh fred@baz "sudo -u joe bash -c \"rm -rf \\\\\\"/tmp/google.com\\\\\\"\"";
  my $command_options = command_options( username=>'fred',hostname=>'baz',sudo_username=>'joe' );
  $command = batch_command(
          pipe_command( 
              'curl http://www.google.com',
              sed_command( {replace_map=>{google=>'gaggle'}} ),
              command( 'dd of="/tmp/gaggle.com"', $command_options )
          ),
          rm_command( '/tmp/google.com', $command_options )
      );

=head1 DESCRIPTION

The subroutines exported by this module can build shell command strings that
can be executed by IPC::Open3::Callback, IPC::Open3::Callback::CommandRunner,
``, system(), or even plain old open 1, 2, or 3.  There is not much
point to I<shelling> out for commands locally as there is almost certainly a
perl function/library capable of doing whatever you need in perl code. However,
If you are designing a footprintless agent that will run commands on remote
machines using existing tools (gnu/powershell/bash...) these utilities can be
very helpful.  All functions in this module can take a C<command_options>
hash defining who/where/how to run the command.

=head1 OPTIONS

=func batch_command( $command1, $command2, ..., $commandN, [$command_options] )

This will join all the commands with a C<;> and apply the supplied 
C<command_options> to the result.

=func command( $command, [$command_options] )

This wraps the supplied command with all the destination options.  If no 
options are supplied, $command is returned.

=func command_options( %options ) 

Returns a C<command_options> object to be supplied to other commands.
All commands can be supplied with C<command_options>.  
C<command_options> control who/where/how to run the command.  The supported
options are:

=over 4

=item always_ssh

If true, the command will always be wrapped by an ssh command even if the 
hostname equates to localhost.

=item ssh

The ssh command to use, defaults to C<ssh>.  You can use this to specify other
commands like C<plink> for windows or an implementation of C<ssh> that is not
in your path.

=item command_prefix

As it sounds, this is a prefix to your command.  Mainly useful for using 
C<sudo>. This prefix is added like this C<$command_prefix$command> so be sure
to put a space at the end of your prefix unless you want to modify the name
of the command itself.  For example, 
C<$command_prefix = 'sudo -u priveleged_user ';>.

=item username

The username to C<ssh> with. If using C<ssh>, this will result in, 
C<ssh $username@$hostname> but if using C<plink> it will result in 
C<plink -l $username $hostname>.

=item hostname

The hostname/IP of the server to run this command on. If localhost, and no 
username is specified, the command will not be wrapped in C<ssh>

=back

=func mkdir_command( $path1, $path2, ..., $pathN, [$command_options] )

Results in C<mkdir -p $path1 $path2 ... $pathN> with the 
C<command_options> applied.

=func pipe_command( $command1, $command2, ..., $commandN, [$command_options] )

Identical to 
L<batch_command|"batch_command( $command1, $command2, ..., $commandN, [$command_options] )">
except uses C<\|> to separate the commands instead of C<;>.

=func rm_command( $path1, $path2, ..., $pathN, [$command_options] )

Results in C<rm -rf $path1 $path2 ... $pathN> with the 
C<command_options> applied. This is a I<VERY> dangerous command and should
be used with care.

=func sed_command( $expression1, $expression2, ..., $expressionN, [$command_options] )

Constructs a sed command

=over 4

=item files

An arrayref of files to apply the sed expressions to.  For use when not piping
from another command.

=item in_place

If specified, the C<-i> option will be supplied to C<sed> thus modifying the
file argument in place. Not useful for piping commands together, but can be 
useful if you copy a file to a temp directory, modify it in place, then 
transfer the file and delete the temp directory.  It would be more secure to 
follow this approach when using sed to fill in passwords in config files. For
example, if you wanted to use sed substitions to set passwords in a config file
template and then transfer that config file to a remote server:

C</my/config/passwords.cfg>

  app1.username=foo
  app1.password=##APP1_PASSWORD##
  app2.username=bar
  app2.password=##APP2_PASSWORD##

C<deploy_passwords.pl>

  use IPC::Open3::Callback::Command qw(batch_command command pipe_command sed_command);
  use IPC::Open3::Callback::CommandRunner;
  use File::Temp;
  
  my $temp_dir = File::Temp->newdir();
  my $temp_script_file = File::Temp->new();
  IPC::Open3::Callback::CommandRunner->new()->run_or_die(
      batch_command( 
          "cp /my/config/passwords.cfg $temp_dir->filename()/passwords.cfg",
          sed_command( 
              "s/##APP1_PASSWORD##/set4app1/g",
              "s/##APP2_PASSWORD##/set4app2/g", 
              {
                  in_place=>1,
                  temp_script_file=>$temp_script_file,
                  files=>[$temp_dir->filename()/passwords.cfg] 
              } 
          ),
          pipe_command( 
              "cat $temp_dir->filename()/passwords.cfg",
              command( "dd of='/remote/config/passwords.cfg'", {hostname=>'remote_host'} ) );
      )
  );

=item replace_map

A map used to construct a sed expression where the key is the match portion 
and the value is the replace portion. For example: C<{'key'=E<gt>'value'}> would 
result in C<'s/key/value/g'>.

=item temp_script_file

Specifies a file to write the sed script to rather than using the console.  
This is useful for avoiding generating commands that would get executed in the 
console that have protected information like passwords. If passwords are 
issued on the console, they might show up in the command history...

=back

=func write_command( $out_file, @lines, [$command_options] )

Writes the C<@lines> to C<$out_file> with the C<$command_options> applied.

=head1 SEE ALSO
IPC::Open3::Callback
IPC::Open3::Callback::CommandRunner
