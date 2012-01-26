package Perinci;

# VERSION

1;
# ABSTRACT: Use Rinci metadata in your Perl code

=head1 DESCRIPTION

Perinci is a set of Perl modules to implement L<Rinci> and L<Riap>. It provides:

=over 4

=item * a convention of where to put Rinci metadata in your code;

=item * an API to access them (implementing the L<Riap> protocol);

=item * a function wrapper framework to implement many Rinci properties;

=item * various other tools that utilize information in the metadata.

Many of the modules are separated into their own Perl distributions, to enable
quicker releases.

If you want to install all Perinci:: distributions, look at L<Task::Perinci>.

=head2 Namespace organization

B<Perinci::Access::*> are API modules to access Rinci metadata in your Perl
code.

B<Perinci::Sub::*> are modules that relate to function metadata and/or Perl
subroutines. They are further divided:

B<Perinci::Sub::Gen::*> are modules that generate functions and/or function
metadata. Examples are L<Perinci::Sub::Gen::AccessTable> and
L<Perinci::Sub::Gen::ForModule>.

B<Perinci::To::*> modules convert metadata to other stuffs. B<Perinci::From::*>
on the other hand convert other stuffs to metadata. B<Perinci::Sub::To::*> and
B<Perinci::Sub::From::*> are similar to their ::To::* and ::From::* counterparts
but handle function metadata specifically. For example L<Perinci::Sub::To::POD>,
L<Perinci::Sub::To::HTML>, or L<Perinci::Sub::To::Text>.

B<Perinci::Sub::From::*> modules convert other stuffs to function metadata.

B<Perinci::Package::*> relate to package metadata and/or Perl packages.

B<Perinci::Var::*> relate to variable metadata and/or Perl variables.

B<Perinci::HTTP::*> are modules that relate to L<Riap::HTTP> protocol.

Command-line programs are usually prefixed with B<peri-*> to avoid name clashes
with other Rinci implementations (like those in PHP or Ruby), for example
B<peri-test-examples> in L<Perinci::Sub::Examples>. However there maybe
exceptions to avoid names being too long; when those happen the names should
preferably be pretty specific instead of too short and generic.


=head1 FAQ

=head2 What does Perinci mean?

Perinci is taken from Indonesian word, meaning: to specify, to explain in more
detail. It can also be an abbreviation for "B<Pe>rl implementation of B<Rinci>".


=head1 SEE ALSO

L<Rinci>

=cut
