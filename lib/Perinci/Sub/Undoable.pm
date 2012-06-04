package Perinci::Sub::Undoable;

use 5.010;
use strict;
use warnings;
use Log::Any '$log';

use Scalar::Util qw(blessed);
use URI;

# VERSION

our %SPEC;

$SPEC = {
};
sub  {
    my %args = @_;
}

1;
# ABSTRACT: Helper to create undoable/transactional function

=head1 SYNOPSIS

 use Perinci::Sub::Undoable qw//;

 our %SPEC;

 $SPEC{myfunc} = {
     ...
     features => {
         undo       => 1,
         idempotent => 1,
         dry_run    => 1,
         tx         => {use=>1},
     },
 };
 sub myfunc {
     my %args = @_;
     do_undo(
     );
 }


=head1 DESCRIPTION

This module provides a helper to write undoable/transactional functions (as well
as functions that support dry-run and are idempotent).


=head1 SEE ALSO

L<Perinci>

=cut
