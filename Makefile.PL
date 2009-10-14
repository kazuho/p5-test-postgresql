use strict;
use inc::Module::Install;

name 'Test-postgresql';
all_from 'lib/Test/postgresql.pm';

requires 'Class::Accessor::Lite';
test_requires 'DBI';
test_requires 'DBD::Pg';

WriteAll;
