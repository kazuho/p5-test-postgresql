use strict;
use warnings;

use DBI;
use Test::postgresql;

use Test::More tests => 3;

$ENV{PATH} = '/nonexistent';
@Test::postgresql::SEARCH_PATHS = ();

ok(! defined $Test::postgresql::errstr);
ok(! defined Test::postgresql->new());
ok($Test::postgresql::errstr);
