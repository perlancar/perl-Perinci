package Perinci::Access::InProcess::MetaAccessor;

use 5.010;
use strict;
use warnings;

# static method
sub get_meta {
    my ($class, $req) = @_;
    my $leaf   = $req->{-leaf};
    my $key = $req->{-leaf} || ':package';
    no strict 'refs';
    ${ $req->{-module} . "::SPEC" }{$key};
}

sub get_all_meta {
    my ($class, $req) = @_;
    no strict 'refs';
    \%{ $req->{-module} . "::SPEC" };
}

1;
# ABSTRACT: Default class to access metadata in
