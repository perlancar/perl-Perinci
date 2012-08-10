package TestNested;

use 5.010;
use strict;
use warnings;
use Log::Any '$log';

use Perinci::Sub::Gen::Undoable 0.20 qw(gen_undoable_func);
use Setup::File::Symlink;

our %SPEC;

my $res = gen_undoable_func(
    name        => 'setup_two_symlinks',
    summary     => "Setup two symlinks",
    description => <<'_',

This function tests calling another undoable function.

_
    args        => {
        symlink1 => {schema=>'str*', req=>1},
        target1  => {schema=>'str*', req=>1},
        symlink2 => {schema=>'str*', req=>1},
        target2  => {schema=>'str*', req=>1},
    },

    build_steps => sub {
        my $args = shift;

        [200, "OK", [
            ['call' => 'Setup::File::Symlink::setup_symlink', {symlink=>$args->{symlink1}, target=>$args->{target1}}],
            ['call' => 'Setup::File::Symlink::setup_symlink', {symlink=>$args->{symlink2}, target=>$args->{target2}}],
        ]];
    },

    steps => {
        call => 'Common::call',
        call_undo => 'Common::call_undo',
    },
);
die "Can't generate function: $res->[0] - $res->[1]" unless $res->[0] == 200;

1;
