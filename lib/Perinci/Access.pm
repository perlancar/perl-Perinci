package Perinci::Access;

use 5.010;
use strict;
use warnings;

use Scalar::Util qw(blessed);
use URI;

sub new {
    my ($class, %opts) = @_;

    $opts{handlers}             //= {};
    $opts{handlers}{pm}         //= 'Perinci::Access::InProcess';
    $opts{handlers}{http}       //= 'Perinci::Access::HTTP::Client';
    $opts{handlers}{https}      //= 'Perinci::Access::HTTP::Client';
    $opts{handlers}{'riap+tcp'} //= 'Perinci::Access::TCP::Client';

    $opts{_handler_objs}        //= {};
    bless \%opts, $class;
}

sub request {
    my ($self, $action, $uri, $extra) = @_;

    my ($sch, $subclass);
    if ($uri =~ /^\w+(::\w+)+$/) {
        $uri =~ s!::!/!g;
        $uri = URI->new("pm:/$uri");
        $sch = "pm";
    } else {
        $uri = URI->new($uri) unless blessed($uri);
        $sch = $uri->scheme;
        $sch ||= "pm";
    }
    die "Unrecognized scheme '$sch' in URL" unless $self->{handlers}{$sch};

    unless ($self->{_handler_objs}{$sch}) {
        if (blessed($self->{handlers}{$sch})) {
            $self->{_handler_objs}{$sch} = $self->{handlers}{$sch};
        } else {
            my $mod_pm = $self->{handlers}{$sch};
            $mod_pm =~ s!::!/!g;
            require "$mod_pm.pm";
            $self->{_handler_objs}{$sch} = $self->{handlers}{$sch}->new;
        }
    }

    $self->{_handler_objs}{$sch}->request($action, $uri, $extra);
}

1;
# ABSTRACT: Wrapper for Perinci Riap clients

=head1 SYNOPSIS

 use Perinci::Access;

 my $pa = Perinci::Access->new;
 my $res;

 # use Perinci::Access::InProcess
 $res = $pa->request(call => "pm:/Mod/SubMod/func");

 # ditto
 $res = $pa->request(call => "/Mod/SubMod/func");
 $res = $pa->request(call => "Mod::SubMod::func");

 # use Perinci::Access::HTTP::Client
 $res = $pa->request(info => "http://example.com/Sub/ModSub/func");

 # use Perinci::Access::TCP::Client
 $res = $pa->request(meta => "riap+tcp://localhost:7001/Sub/ModSub/");

 # dies, unknown scheme
 $res = $pa->request(call => "baz://example.com/Sub/ModSub/");


=head1 DESCRIPTION

This module provides a convenient wrapper to select appropriate Riap client
(Perinci::Access::*) objects based on URI scheme (or lack thereof).

 Foo::Bar    -> InProcess
 /Foo/Bar/   -> InProcess
 pm:/Foo/Bar -> InProcess
 http://...  -> HTTP::Client
 https://... -> HTTP::Client
 riap+tcp:// -> TCP::Client

You can customize or add supported schemes by providing the .


=head1 METHODS

=head2 new(%opts) -> OBJ

Create new instance. Known options:

=over 4

=item * handlers (HASH)

A mapping of scheme names and class names or objects. If values are class names,
they will be require'd and instantiated. The default is:

 {
   pm         => 'Perinci::Access::InProcess',
   http       => 'Perinci::Access::HTTP::Client',
   https      => 'Perinci::Access::HTTP::Client',
   'riap+tcp' => 'Perinci::Access::TCP::Client',
 }

Objects can be given instead of class names. This is used if you need to pass
special options when instantiating the class.

=back

=head2 $pa->request($action, $uri, \%extra) -> RESP

Pass the request to the appropriate Riap client objects (as configured in
C<handlers> constructor options). RESP is the enveloped result.


=head1 SEE ALSO

L<Perinci>, L<Riap>

=cut
