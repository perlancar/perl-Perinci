package Perinci::Access;

use 5.010;
use strict;
use warnings;

use Module::Load;
use Module::Loaded;
use Scalar::Util qw(blessed);
use URI;

# VERSION

sub new {
    my ($class, %opts) = @_;
    bless [], $class;
}

my $re_var = qr/\A[A-Za-z_][A-Za-z_0-9]+\z/;
my $re_mod = qr/\A[A-Za-z_][A-Za-z_0-9]+(::[A-Za-z_][A-Za-z_0-9]+)*\z/;

sub request {
    my ($self, $action, $uri, $extra) = @_;
    my $req = {};

    # check args

    $extra //= {};
    return [400, "Invalid extra arguments: must be hashref"]
        unless ref($extra) eq 'HASH';
    for (keys %$extra) {
        return [400, "Invalid request key '$_', ".
                    "please only use letters/numbers"]
            unless $_ =~ $re_var;
        $req->{$_} = $extra->{$_};
    }

    return [400, "Please specify action"] unless $action;
    return [400, "Invalid syntax in action, please only use letters/numbers"]
        unless $action =~ $re_var;
    $req->{action} = $action;

    return [400, "Please specify URI"] unless $uri;
    $uri = URI->new($uri) unless blessed($uri);
    $req->{uri} = $uri;

    my $scheme = $uri->scheme;
    return [502, "Can't handle scheme '$scheme' in URI"]
        unless !$scheme || $scheme eq 'pm';


    # parse code entity from URI && load module

    my $path = $uri->path || "/";
    my ($module, $local);
    if ($path eq '/') {
        $module = '';
        $local  = '';
    } elsif ($path =~ m!(.+)/+(.*)!) {
        $module = $1;
        $local  = $2;
    } else {
        $module = $path;
        $local  = '';
    }
    $module =~ s!^/+!!;
    $module =~ s!/+!::!g;
    return [400, "Invalid syntax in module '$module', ".
                "please use valid module name"]
        if $module ne '' && $module !~ $re_mod;

    unless (is_loaded $module) {
        eval { load $module };
        return [500, "Can't load module $module: $@"] if $@;
    }
    $req->{-module} = $module;
    $req->{-local}  = $local;

    # handle action

    my $meth = "action_$action";
    return [502, "Action not implemented"] unless
        $self->can($meth);

    $self->$meth($req);
}

=for Pod::Coverage ^action_.+

=cut

sub action_info {
    my ($self, $req) = @_;
    [502, "Not yet implemented"];
}

sub action_meta {
    my ($self, $req) = @_;
    [502, "Not yet implemented"];
}

sub action_list {
    my ($self, $req) = @_;
    [502, "Not yet implemented"];
}

sub action_call {
    my ($self, $req) = @_;
    [502, "Not yet implemented"];
}

sub action_complete {
    my ($self, $req) = @_;
    [502, "Not yet implemented"];
}

1;
# ABSTRACT: Use Rinci access protocol (Riap) to access Perl code

=head1 SYNOPSIS

 use Perinci::Access;
 my $pa = Perinci::Access->new();

 # list all packages
 my $res = $pa->request(list => '/', {type=>'package', recursive=>1});
 die "Failed: $res->[0] - $res->[1]" unless $res->[0] == 200;

 # get summary for each package
 for my $uri (@{$res->[2]}) {
     $res = $pa->request(meta => $uri);
     my $meta = $res->[2];
     print "$uri - ", ($meta ? $meta->{summary} : "(No meta)"), "\n";
 }

 # call a function
 $res = $pa->request(call => '/Foo/Bar/func', {args => {a=>1, b=>2}});


=head1 DESCRIPTION

This class implements Rinci access protocol (L<Riap>) to access local Perl
code.


=head1 METHODS

=head2 PKG->new(%opts) => OBJ

Instantiate object.

=head2 $pa->request($action => $uri, \%extra) => $res

Process Riap request and return enveloped result. This method will in turn parse
URI and other Riap request keys and call C<action_ACTION> methods.


=head1 SEE ALSO

L<Riap>, L<Rinci>

=cut
