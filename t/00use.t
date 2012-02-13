#!/usr/bin/perl

use warnings;
use strict;

use Test::More;
use Test::Exports;

my $BHAR = "B::Hooks::AtRuntime";

require_ok $BHAR                or BAIL_OUT "can't load module";

import_ok $BHAR, [],            "default import OK";
is_import "at_runtime", $BHAR,  "at_runtime imported by default";
cant_ok "lex_stuff",            "lex_stuff not imported by default";

my @all = qw/at_runtime lex_stuff/;

new_import_pkg;
import_ok $BHAR, \@all,         "explicit import OK";
is_import @all, $BHAR,          "explicit import succeeds";

is prototype(\&B::Hooks::AtRuntime::at_runtime), "&",
                                "at_runtime has & prototype";

done_testing;
