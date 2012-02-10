#!perl

use 5.010;
use strict;
use warnings;
use Test::More 0.96;

use Perinci::Sub::DepChecker qw(check_deps);
use Perinci::Sub::dep::pm;

# BEGIN copy-pasted from Perinci::Sub::Wrapper's test script
sub test_check_deps {
    my %args = @_;
    my $name = $args{name};
    my $res = check_deps($args{deps});
    if ($args{met}) {
        ok(!$res, "$name met") or diag($res);
    } else {
        ok( $res, "$name unmet");
    }
}

sub deps_met {
    test_check_deps(deps=>$_[0], name=>$_[1], met=>1);
}

sub deps_unmet {
    test_check_deps(deps=>$_[0], name=>$_[1], met=>0);
}
# END copy-pasted code

deps_met   {pm=>"Perinci::Sub::DepChecker"}, "pm 1";
deps_unmet {pm=>"NonExistingModule"}, "pm 2";

done_testing();

