package Perinci::Sub::Undoable;

use 5.010;
use strict;
use warnings;
use Log::Any '$log';

use Scalar::Util qw(blessed);
use URI;

# VERSION

sub do_undo {
    my %args = @_;
}

1;
# ABSTRACT: Helper to create undoable/transactional function

=head1 SYNOPSIS

 use Perinci::Sub::Undoable;

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
     do_undo();
 }


=head1 DESCRIPTION

This module provides a helper to write undoable/transactional functions (as well
as functions that support dry-run and are idempotent).


=head1 METHODS

=head2 new(%opts) -> OBJ

Create new instance. Known options:

=over 4

=item * handlers (HASH)

A mapping of scheme names and class names or objects. If values are class names,
they will be require'd and instantiated. The default is:

 {
   riap         => 'Perinci::Access::InProcess',
   pl           => 'Perinci::Access::InProcess',
   http         => 'Perinci::Access::HTTP::Client',
   https        => 'Perinci::Access::HTTP::Client',
   'riap+tcp'   => 'Perinci::Access::TCP::Client',
 }

Objects can be given instead of class names. This is used if you need to pass
special options when instantiating the class.

=back

=head2 $pa->request($action, $server_url, \%extra) -> RESP

Send Riap request to Riap server. Pass the request to the appropriate Riap
client (as configured in C<handlers> constructor options). RESP is the enveloped
result.


=head1 SEE ALSO

L<Perinci>, L<Riap>

=cut
