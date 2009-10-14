use strict;
use warnings;

use DBI;
use Test::More;
use Test::postgresql;

my $pgsql = Test::postgresql->new()
    or plan skip_all => $Test::postgresql::errstr;

plan tests => 2;

my $base_dir = $pgsql->base_dir;
my $port = $pgsql->port;

my $dbh = DBI->connect(
    "DBI:Pg:dbname=template1;user=postgres;port=$port"
);
ok($dbh, 'connect to postgresql');
undef $dbh;

undef $pgsql;
ok(
    ! DBI->connect(
        "DBI:Pg(PrintError=>0,RaiseError=>0):dbname=template1;user=postgres;port=$port"),
    "shutdown postgresql",
);
