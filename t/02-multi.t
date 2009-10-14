use strict;
use warnings;

use DBI;
use Test::More;
use Test::postgresql;

Test::postgresql->new()
    or plan skip_all => $Test::postgresql::errstr;

plan tests => 3;

my @pgsql = map {
    my $pgsql = Test::postgresql->new();
    ok($pgsql);
    $pgsql;
} 0..1;
is(scalar @pgsql, 2);
