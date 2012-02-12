package Perinci::Sub::dep::pm;

use 5.010;
use strict;
use warnings;

use Perinci::Util qw(declare_function_dep);

# VERSION

declare_function_dep(
    name => 'pm',
    schema => ['str*' => {}],
    check => sub {
        my ($val) = @_;
        my $m = $val;
        $m =~ s!::!/!g;
        $m .= ".pm";
        #eval { require $m } ? "" : "Can't load module $val: $@";
        eval { require $m } ? "" : "Can't load module $val";
    }
);

1;
# ABSTRACT: Depends on a Perl module

=head1 SYNOPSIS

 # in function metadata
 deps => {
     ...
     pm => 'Foo::Bar',
 }

=cut
