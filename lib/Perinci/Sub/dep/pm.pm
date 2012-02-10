package Perinci::Sub::dep::pm;

use 5.010;
use strict;
use warnings;

use Perinci::Util qw(add_function_dep);

add_function_dep(
    name => 'pm',
    schema => ['str' => {
    }],
);

use Rinci::Schema;
# XXX: add to schema

1;
# ABSTRACT: Require a Perl module

=head1 SYNOPSIS

 # in function metadata
 deps => {
     ...
     pm => 'Foo::Bar', # specify that this function requires a
 }


=head1 DESCRIPTION

NOT YET IMPLEMENTED

=head1 TMP

sub checkdep_pm {
    my ($val) = @_;
    my $m = $val;
    $m =~ s!::!/!g;
    $m .= ".pm";
    #eval { require $m } ? "" : "Can't load module $val: $@";
    eval { require $m } ? "" : "Can't load module $val";
}

sub checkdep_sub {
    my ($val) = @_;
    my ($pkg, $name);
    if ($val =~ /(.*)::(.+)/) {
        $pkg = $1 || "main";
        $name = $2;
    } else {
        $pkg = "main";
        $name = $val;
    }
    no strict 'refs';
    my $stash = \%{"$pkg\::"};
    $stash->{$name} ? "" : "Subroutine $val doesn't exist";
}

=cut
