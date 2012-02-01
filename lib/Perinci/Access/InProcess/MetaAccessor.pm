package Perinci::Access::InProcess::MetaAccessor;

use 5.010;
use strict;
use warnings;

# static method
sub get_meta {
    my ($class, $req) = @_;

    my $uri    = $req->{uri};
    my $leaf   = $req->{-leaf};

    my $key;
    if ($leaf) {
        $key = $leaf;
    } else {
        $key  = ':package';
    }
    no strict 'refs';
    ${ $req->{-module} . "::SPEC" }{$key};
}

1;
# ABSTRACT: Default class to access metadata in
