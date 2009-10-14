use strict;
use warnings;

use DBI;
use Test::More;
use Test::postgresql;

my $pgsql = Test::postgresql->new()
    or plan skip_all => $Test::postgresql::errstr;

plan tests => 3;

my $dsn = $pgsql->dsn;

is(
    $dsn,
    "DBI:Pg:dbname=template1;host=127.0.0.1;port=@{[$pgsql->port]};user=postgres",
    'check dsn',
);

my $dbh = DBI->connect($dsn);
ok($dbh, 'connect to postgresql');
undef $dbh;

undef $pgsql;
ok(
    ! DBI->connect($dsn),
    "shutdown postgresql",
);
