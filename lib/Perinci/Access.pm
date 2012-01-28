package Perinci::Access;

use 5.010;
use strict;
use warnings;

1;
# ABSTRACT: Wrapper for Riap clients

=head1 SYNOPSIS

 use Perinci::Access;

 # XXX


=head1 DESCRIPTION

This module provides a convenient interface to select appropriate Riap client
class based on URI scheme (or lack thereof).

 # XXX temp, illustration
 Foo::Bar -> InProcess (/Foo/Bar/)
 /Foo/Bar/ -> InProcess
 http://... -> HTTP
 https://... -> HTTP
 riap+http:// ? (url scheme is riap uri://     -> TCP?
 riap+tcp:// -> TCP

=cut
