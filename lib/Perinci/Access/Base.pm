package Perinci::Access::Base;

use 5.010;
use strict;
use warnings;

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

sub check_request {
    my ($self, $req) = @_;

    # check args

    # XXX schema
    #$req //= {};
    #return [400, "Invalid req: must be hashref"]
    #    unless ref($req) eq 'HASH';
    for my $k (keys %$req) {
        return [400, "Invalid request key '$k', ".
                    "please only use letters/numbers"]
            unless $k =~ $re_req_key;
    }

    $req->{v} //= 1.1;
    return [500, "Protocol version not supported"] if $req->{v} ne '1.1';

    my $action = $req->{action};
    return [400, "Please specify action"] unless $action;
    return [400, "Invalid action, please only use letters/numbers"]
        unless $action =~ $re_action;

    # return success for further processing
    0;
}

sub _init {
    require Class::Inspector;

    my ($self) = @_;

    # build a list of supported actions for each type of entity
    my %typeacts = (
        package  => [],
        function => [],
        variable => [],
    ); # key = type, val = [[ACTION, META], ...]

    my @comacts;
    for my $meth (@{Class::Inspector->methods(ref $self)}) {
        next unless $meth =~ /^actionmeta_(.+)/;
        my $act = $1;
        my $meta = $self->$meth();
        for my $type (@{$meta->{applies_to}}) {
            if ($type eq '*') {
                push @comacts, [$act, $meta];
            } else {
                push @{$typeacts{$type}}, [$act, $meta];
            }
        }
    }

    for my $type (keys %typeacts) {
        $typeacts{$type} = { map {$_->[0] => $_->[1]}
                                 @{$typeacts{$type}}, @comacts };
    }

    $self->{_typeacts} = \%typeacts;
}

# can be overriden, should return a response on error, or false if nothing is
# wrong.
sub _before_action {}

sub actionmeta_info { +{
    applies_to => ['*'],
    summary    => "Get general information on code entity",
} }

sub action_info {
    my ($self, $req) = @_;
    my $res = {
        v    => 1.1,
        uri  => $req->{uri}->as_string,
        type => $req->{-type},
    };
    $res->{entity_version} = $req->{-entity_version}
        if defined $req->{-entity_version};
    [200, "OK", $res];
}

sub actionmeta_actions { +{
    applies_to => ['*'],
    summary    => "List available actions for code entity",
} }

sub action_actions {
    my ($self, $req) = @_;
    my @res;
    for my $k (sort keys %{ $self->{_typeacts}{$req->{-type}} }) {
        my $v = $self->{_typeacts}{$req->{-type}}{$k};
        if ($req->{detail}) {
            push @res, {name=>$k, summary=>$v->{summary}};
        } else {
            push @res, $k;
        }
    }
    [200, "OK", \@res];
}

sub actionmeta_list { +{
    applies_to => ['package'],
    summary    => "List code entities inside this package code entity",
} }

sub actionmeta_meta { +{
    applies_to => ['*'],
    summary    => "Get metadata",
} }

sub actionmeta_call { +{
    applies_to => ['function'],
    summary    => "Call function",
} }

sub actionmeta_complete_arg_val { +{
    applies_to => ['function'],
    summary    => "Complete function's argument value"
} }

sub actionmeta_child_metas { +{
    applies_to => ['package'],
    summary    => "Get metadata of all child entities",
} }

sub actionmeta_get { +{
    applies_to => ['variable'],
    summary    => "Get value of variable",
} }

1;
# ABSTRACT: Base class for Perinci Riap clients
