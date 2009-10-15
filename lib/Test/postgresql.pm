package Test::postgresql;

use strict;
use warnings;

use 5.008;
use Class::Accessor::Lite;
use Cwd;
use DBI;
use File::Temp qw(tempdir);
use POSIX qw(SIGTERM WNOHANG setuid);

our $VERSION = '0.07';

our @SEARCH_PATHS = (
    # popular installtion dir?
    qw(/usr/local/pgsql),
    # ubuntu (maybe debian as well, find the newest version)
    (sort { $b cmp $a } grep { -d $_ } glob "/usr/lib/postgresql/*"),
    # macport
    (sort { $b cmp $a } grep { -d $_ } glob "/opt/local/lib/postgresql-*"),
);

our $errstr;
our $BASE_PORT = 15432;

our %Defaults = (
    auto_start      => 2,
    base_dir        => undef,
    initdb          => undef,
    initdb_args     => '-U postgres -A trust',
    pid             => undef,
    port            => undef,
    postmaster      => undef,
    postmaster_args => '-h 127.0.0.1',
    uid             => undef,
);

Class::Accessor::Lite->mk_accessors(keys %Defaults);

sub new {
    my $klass = shift;
    my $self = bless {
        %Defaults,
        @_ == 1 ? %{$_[0]} : @_
    }, $klass;
    if (! defined $self->uid && $ENV{USER} eq 'root') {
        my @a = getpwnam('nobody')
            or die "user nobody does not exist, use uid() to specify user:$!";
        $self->uid($a[2]);
    }
    if (defined $self->base_dir) {
        $self->base_dir(cwd . '/' . $self->base_dir)
            if $self->base_dir !~ m|^/|;
    } else {
        $self->base_dir(
            tempdir(
                CLEANUP => $ENV{TEST_POSTGRESQL_PRESERVE} ? undef : 1,
            ),
        );
        chown $self->uid, -1, $self->base_dir
            if defined $self->uid;
    }
    if (! defined $self->initdb) {
        my $prog = _find_program('initdb')
            or return;
        $self->initdb($prog);
    }
    if (! defined $self->postmaster) {
        my $prog = _find_program('postmaster')
            or return;
        $self->postmaster($prog);
    }
    if ($self->auto_start) {
        $self->setup
            if $self->auto_start >= 2;
        $self->start;
    }
    $self;
}

sub DESTROY {
    my $self = shift;
    $self->stop
        if defined $self->pid;
}

sub dsn {
    my ($self, %args) = @_;
    $args{host} ||= '127.0.0.1';
    $args{port} ||= $self->port;
    $args{user} ||= 'postgres';
    $args{dbname} ||= 'test';
    return 'DBI:Pg:' . join(';', map { "$_=$args{$_}" } sort keys %args);
}

sub start {
    my $self = shift;
    return
        if defined $self->pid;
    # start (or die)
    sub {
        if ($self->port) {
            if ($self->_try_start($self->port)) {
                return;
            }
        } else {
            # try by incrementing port no
            for (my $port = $BASE_PORT; $port < $BASE_PORT + 100; $port++) {
                if ($self->_try_start($port)) {
                    return;
                }
            }
        }
        # failed
        die "failed to launch postgresql:$!";
    }->();
    { # create "test" database
        my $dbh = DBI->connect($self->dsn(dbname => 'template1'), '', '', {})
            or die $DBI::errstr;
        if ($dbh->selectrow_arrayref(q{SELECT COUNT(*) FROM pg_database WHERE datname='test'})->[0] == 0) {
            $dbh->do('CREATE DATABASE test')
                or die $dbh->errstr;
        }
    }
}

sub _try_start {
    my ($self, $port) = @_;
    # open log and fork
    open my $logfh, '>', $self->base_dir . '/postgres.log'
        or die 'failed to create log file:' . $self->base_dir
            . "/postgres.log:$!";
    my $pid = fork;
    die "fork(2) failed:$!"
        unless defined $pid;
    if ($pid == 0) {
        open STDOUT, '>&', $logfh
            or die "dup(2) failed:$!";
        open STDERR, '>&', $logfh
            or die "dup(2) failed:$!";
        if (defined $self->uid) {
            setuid($self->uid)
                or die "setuid failed:$!";
        }
        my $cmd = join(
            ' ',
            $self->postmaster,
            $self->postmaster_args,
            '-p', $port,
            '-D', $self->base_dir . '/data',
            '-k', $self->base_dir . '/tmp',
        );
        exec($cmd);
        die "failed to launch postmaster:$?";
    }
    close $logfh;
    # wait until server becomes ready (or dies)
    for (my $i = 0; $i < 100; $i++) {
        open $logfh, '<', $self->base_dir . '/postgres.log'
            or die 'failed to open log file:' . $self->base_dir
                . "/postgres.log:$!";
        my $lines = do { join '', <$logfh> };
        close $logfh;
        last
            if $lines =~ /is ready to accept connections/;
        if (waitpid($pid, WNOHANG) > 0) {
            # failed
            return;
        }
        sleep 1;
    }
    # postgresql is ready
    $self->pid($pid);
    $self->port($port);
    return 1;
}

sub stop {
    my ($self, $sig) = @_;
    return
        unless defined $self->pid;
    $sig ||= SIGTERM;
    kill $sig, $self->pid;
    while (waitpid($self->pid, 0) <= 0) {
    }
    $self->pid(undef);
}

sub setup {
    my $self = shift;
    # (re)create directory structure
    mkdir $self->base_dir;
    if (mkdir $self->base_dir . '/tmp') {
        if ($self->uid) {
            chown $self->uid, -1, $self->base_dir . '/tmp'
                or die "failed to chown dir:" . $self->base_dir . "/tmp:$!";
        }
    }
    # initdb
    if (! -d $self->base_dir . '/data') {
        pipe my $rfh, my $wfh
            or die "failed to create pipe:$!";
        my $pid = fork;
        die "fork failed:$!"
            unless defined $pid;
        if ($pid == 0) {
            close $rfh;
            open STDOUT, '>&', $wfh
                or die "dup(2) failed:$!";
            open STDERR, '>&', $wfh
                or die "dup(2) failed:$!";
            if (defined $self->uid) {
                setuid($self->uid)
                    or die "setuid failed:$!";
            }
            my $cmd = join(
                ' ',
                $self->initdb,
                $self->initdb_args,
                '-D', $self->base_dir . '/data',
            );
            exec($cmd);
            die "failed to exec:$cmd:$!";
        }
        close $wfh;
        my $output = '';
        while (my $l = <$rfh>) {
            $output .= $l;
        }
        close $rfh;
        while (waitpid($pid, 0) <= 0) {
        }
        die "*** initdb failed ***\n$output\n"
            if $? != 0;
    }
}

sub _find_program {
    my $prog = shift;
    undef $errstr;
    my $path = _get_path_of($prog);
    return $path
        if $path;
    for my $sp (@SEARCH_PATHS) {
        return "$sp/bin/$prog"
            if -x "$sp/bin/$prog";
    }
    $errstr = "could not find $prog, please set appropriate PATH";
    return;
}

sub _get_path_of {
    my $prog = shift;
    my $path = `which $prog 2> /dev/null`;
    chomp $path
        if $path;
    $path = ''
        unless -x $path;
    $path;
}

1;
__END__

=head1 NAME

Test::postgresql - postgresql runner for tests

=head1 SYNOPSIS

  use DBI;
  use Test::postgresql;
  use Test::More;
  
  my $pgsql = Test::postgresql->new()
      or plan skip_all => $Test::postgresql::errstr;
  
  plan tests => XXX;
  
  my $dbh = DBI->connect($pgsql->dsn);

=head1 DESCRIPTION

C<Test::postgresql> automatically setups a postgresql instance in a temporary directory, and destroys it when the perl script exits.

=head1 FUNCTIONS

=head2 new

Create and run a postgresql instance.  The instance is terminated when the returned object is being DESTROYed.  If required programs (initdb and postmaster) were not found, the function returns undef and sets appropriate message to $Test::postgresql::errstr.

=head2 base_dir

Returns directory under which the postgresql instance is being created.  The property can be set as a parameter of the C<new> function, in which case the directory will not be removed at exit.

=head2 initdb

=head2 postmaster

Path to C<initdb> and C<postmaster> which are part of the postgresql distribution.  If not set, the programs are automatically searched by looking up $PATH and other prefixed directories.

=head2 initdb_args

=head2 postmaster_args

Arguments passed to C<initdb> and C<postmaster>.  Following example adds --encoding=utf8 option to C<initdb_args>.

  my $pgsql = Test::postgresql->new(
      initdb_args
          => $Test::postgresql::Defaults{initdb_args} . ' --encoding=utf8'
  ) or plan skip_all => $Test::postgresql::errstr;

=head2 dsn

Builds and returns dsn by using given parameters (if any).  Default username is 'postgres', and dbname is 'test' (an empty database).

=head2 pid

Returns process id of postgresql (or undef if not running).

=head2 port

Returns TCP port number on which postmaster is accepting connections (or undef if not running).

=head2 start

Starts postmaster.

=head2 stop

Stops postmaster.

=head2 setup

Setups the postgresql instance.

=head1 AUTHOR

Kazuho Oku

=head1 THANKS TO

HSW

=head1 COPYRIGHT

Copyright (C) 2009 Cybozu Labs, Inc.

=head1 LICENSE

This program is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

See L<http://www.perl.com/perl/misc/Artistic.html>

=cut
