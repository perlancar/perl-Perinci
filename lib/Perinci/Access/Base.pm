package Perinci::Access::Base;

use 5.010;
use strict;
use warnings;

use Scalar::Util qw(blessed);
use URI;

# VERSION

sub new {
    my ($class, %opts) = @_;
    bless \%opts, $class;
}

our $re_var     = qr/\A[A-Za-z_][A-Za-z_0-9]*\z/;
our $re_req_key = $re_var;
our $re_action  = $re_var;

sub request {
    my ($self, $action, $uri, $extra) = @_;
    my $req = {};

    # check args

    $extra //= {};
    return [400, "Invalid extra arguments: must be hashref"]
        unless ref($extra) eq 'HASH';
    for my $k (keys %$extra) {
        return [400, "Invalid request key '$k', ".
                    "please only use letters/numbers"]
            unless $k =~ $re_req_key;
        $req->{$k} = $extra->{$k};
    }

    $req->{v} //= 1.1;
    return [500, "Protocol version not supported"] if $req->{v} ne '1.1';

    return [400, "Please specify action"] unless $action;
    return [400, "Invalid syntax in action, please only use letters/numbers"]
        unless $action =~ $re_action;
    $req->{action} = $action;

    my $meth = "action_$action";
    return [502, "Action not implemented"] unless
        $self->can($meth);

    return [400, "Please specify URI"] unless $uri;
    $uri = URI->new($uri) unless blessed($uri);
    $req->{uri} = $uri;

    my $res;
    if ($self->can("_prehandle")) {
        $res = $self->_prehandle($req);
        return $res if $res;
    }
    $res = $self->$meth($req);
}

1;
# ABSTRACT: Base class for Perinci Riap clients
