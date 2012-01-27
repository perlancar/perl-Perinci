package Perinci;

# VERSION

1;
# ABSTRACT: Collection of Perl modules for Rinci and Riap

=head1 STATUS

Some modules have been implemented, some (including important ones) have not.
See details on CPAN.


=head1 DESCRIPTION

Perinci is a collection of modules for implementing/providing tools pertaining
to L<Rinci> and L<Riap>.

=head2 Module organization

B<Perinci::Access::*> are implementation of L<Riap>, for example:
L<Perinci::Access::InProcess>, L<Perinci::Access::HTTP::Server> (a.k.a.
L<Serabi>), L<Perinci::Access::HTTP::Client>, L<Perinci::Access::TCP::Server>,
L<Perinci::Access::TCP::Client>.

L<Perinci::Access> itself is an easy wrapper for the various Perinci::Access::*
clients. It can select the appropriate class based on the URI scheme.

B<Perinci::Sub::*> are modules that relate to function metadata and/or Perl
subroutines. They are further divided:

B<Perinci::Sub::Gen::*> are modules that generate functions and/or function
metadata. Examples are L<Perinci::Sub::Gen::AccessTable> and
L<Perinci::Sub::Gen::ForModule>.

B<Perinci::Package::*> relate to package metadata and/or Perl packages.

B<Perinci::Var::*> relate to variable metadata and/or Perl variables.

B<Perinci::To::*> modules convert metadata to other stuffs. B<Perinci::From::*>
on the other hand convert other stuffs to metadata. B<Perinci::Sub::To::*> and
B<Perinci::Sub::From::*> are similar to their ::To::* and ::From::* counterparts
but handle function metadata specifically. For example L<Perinci::Sub::To::POD>,
L<Perinci::Sub::To::HTML>, or L<Perinci::Sub::To::Text>. There will also be
equivalents for other types of metadata.

B<Perinci::Sub::From::*> modules convert other stuffs to function metadata.
There will also be equivalents for other types of metadata.

Command-line programs are usually prefixed with B<peri-*> to avoid name clashes
with other Rinci implementations (like those in PHP or Ruby), for example
B<peri-test-examples> in L<Perinci::Sub::Examples>. However there maybe
exceptions to avoid names being too long; when those happen the names should
preferably be pretty specific instead of too short and generic.


=head1 GETTING STARTED

To get started, you'll need to put some metadata in your code, mostly for your
functions. The metadata normally goes to %SPEC package variable. Example:

 package My::App;

 our %SPEC;

 $SPEC{mult2} = {
     v => 1.1,
     summary => 'Multiple two numbers',
     args => {
         a => { schema=>'float*', req=>1, pos=>0 },
         b => { schema=>'float*', req=>1, pos=>1 },
     },
     examples => [
         {args=>{a=>2, b=>3}, result=>6},
     ],
 };
 sub mult {
     my %args = @_;
     [200, "OK", $args{a} * $args{b}];
 }

 $SPEC{multn} = {
     v => 1.1,
     summary => 'Multiple many numbers',
     args => {
         n => { schema=>[array=>{of=>'float*'}], req=>1, pos=>0, greedy=>1 },
     },
 };
 sub multn {
     my %args = @_;
     my @n = @{$args{n}};
     my $res = 0;
     if (@n) {
         $res = shift(@n);
         $res *= $_ while $_ = shift(@n);
     }
     return [200, "OK", $res];
 }

 1;

For the specification of the metadata itself, head over to L<Rinci>. You can
also peek into modules that already have metadata. A few examples:
L<Git::Bunch>, L<File::RsyBak>, L<Setup::File>.

With Perinci you are actually given flexibility, you can store your metadata in
other places if you want. See L<Perinci::Access::InProcess> for more details.

You might also notice that instead of just returning C<$args{a} * $args{b}> we
return an enveloped result: C<[200, "OK", $args{a} * $args{b}]>. This is not
absolutely necessary (e.g. if you use a wrapper like L<Perinci::Sub::Wrapper> it
can generate envelope for you), but envelope allows you to return error
code/message as well as extra metadata. This will be useful in various
situation. To read more about result envelope, see L<Rinci::function>.

Now that the metadata are written, you can various tools that leverage the
metadata. For example L<Perinci::CmdLine> that can turn your module into a
command-line program:

 # in myapp script
 use Perinci::CmdLine qw(run);
 run(uri=>'/My/App/');

 # in shell
 % ./myapp --help
 % ./myapp --list
 % ./myapp mult2 --help
 % ./myapp mult2 2 3
 % ./myapp mult2 --a 2 --b 3
 % ./myapp multn 2 3 4

There is also L<Perinci::Access::HTTP::Server> to run your module over HTTP:

 # start HTTP server
 % peri-run-http My::App

 # access your module over HTTP
 % curl http://localhost:5000/My::App/mult2?a=2&b=3

To generate documentation from your metadata in a module:

 % peri-doc My::App
 % peri-doc http://localhost:5000/My::App/ ; # can access metadata remotely

There are a lot more than this. See all the Perinci::* modules on CPAN.


=head1 FAQ

=head2 What does Perinci mean?

Perinci is taken from Indonesian word, meaning: to specify, to explain in more
detail. It can also be an abbreviation for "B<Pe>rl implementation of B<Rinci>".


=head1 SEE ALSO

L<Rinci>

=cut
