package Perinci::Access::Base;

use 5.010;
use strict;
use warnings;

use Scalar::Util qw(blessed);
use URI;

# VERSION

sub new {
    my ($class, %opts) = @_;
    my $obj = bless \%opts, $class;
    $obj->_init();
    $obj;
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

    my $res = $self->_before_action($req);
    return $res if $res;

    return [502, "Action not implemented for '$req->{-type}' entity"]
        unless $self->{_typeacts}{ $req->{-type} }{ $action };

    $res = $self->$meth($req);
}

sub _init {
    require Class::Inspector;

    my ($self) = @_;

    # build a list of supported actions for each type of entity
    my %typeacts; # key = type, val = [action, ...]
    my @comacts;  # common actions

    for my $meth (@{Class::Inspector->methods(ref $self)}) {
        next unless $meth =~ /^actionmeta_(.+)/;
        my $act = $1;
        my $meta = $self->$meth();
        for my $type (@{$meta->{applies_to}}) {
            if ($type eq '*') {
                push @comacts, $act;
            } else {
                push @{$typeacts{$type}}, $act;
            }
        }
    }

    for my $type (keys %typeacts) {
        $typeacts{$type} = { map {$_=>{}} @{$typeacts{$type}}, @comacts };
    }

    $self->{_typeacts} = \%typeacts;
}

# can be overriden, should return a response on error, or false if nothing is
# wrong.
sub _before_action {}

sub actionmeta_info { { applies_to => ['*'], } }
sub action_info {
    my ($self, $req) = @_;
    [200, "OK", {
        v    => 1.1,
        uri  => $req->{uri}->as_string,
        type => $req->{-type},
        acts => [keys %{ $self->{_typeacts}{$req->{-type}} }],
    }];
}

sub actionmeta_list { { applies_to => ['package'], } }
sub actionmeta_meta { { applies_to => ['*'], } }
sub actionmeta_call { { applies_to => ['function'], } }
sub actionmeta_complete { { applies_to => ['function'], } }

1;
# ABSTRACT: Base class for Perinci Riap clients
