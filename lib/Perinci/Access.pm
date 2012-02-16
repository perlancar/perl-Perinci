package Perinci::Access;

use 5.010;
use strict;
use warnings;

use Scalar::Util qw(blessed);
use URI;

sub new {
    my ($class, %args) = @_;
    bless \%args, $class;
}

sub request {
    my ($self, $action, $uri, $extra) = @_;

    my ($sch, $which);
    if ($uri =~ /^\w+(::\w+)+$/) {
        $uri =~ s!::!/!g;
        $uri = "/$uri";
        $which = "inprocess";
    } else {
        $uri = URI->new($uri) unless blessed($uri);
        $sch = $uri->scheme;
        if (!$sch || $sch eq 'pm') {
            $which = "inprocess";
        } elsif ($sch eq 'http' || $sch eq 'https') {
            $which = "http";
        } elsif ($sch eq 'riap+tcp') {
            $which = "tcp";
        }
    }
    die "Unrecognized scheme '$sch' in URL" unless $which;

    my $pa;
    if ($which eq 'inprocess') {
        if ($self->{_pa_inprocess}) {
            $pa = $self->{_pa_inprocess};
        } else {
            require Perinci::Access::InProcess;
            $pa = $self->{_pa_inprocess} = Perinci::Access::InProcess->new;
        }
    } elsif ($which eq 'http') {
        if ($self->{_pa_http}) {
            $pa = $self->{_pa_http};
        } else {
            require Perinci::Access::HTTP::Client;
            $pa = $self->{_pa_http} = Perinci::Access::HTTP::Client->new;
        }
    } elsif ($which eq 'tcp') {
        if ($self->{_pa_tcp}) {
            $pa = $self->{_pa_tcp};
        } else {
            require Perinci::Access::TCP::Client;
            $pa = $self->{_pa_tcp} = Perinci::Access::TCP::Client->new;
        }
    } else {
        die "BUG: Can't handle which=$which";
    }

    $pa->request($action, $uri, $extra);
}

1;
# ABSTRACT: Wrapper for Perinci Riap clients

=head1 SYNOPSIS

 use Perinci::Access;

 my $pa = Perinci::Access->new;
 my $res;

 # use Perinci::Access::InProcess
 $res = $pa->request(call => "/Mod/SubMod/func");

 # ditto
 $res = $pa->request(call => "Mod::SubMod::func");
 $res = $pa->request(call => "pm:/Mod/SubMod/func");

 # use Perinci::Access::HTTP::Client
 $res = $pa->request(info => "http://example.com/Sub/ModSub/func");

 # use Perinci::Access::TCP::Client
 $res = $pa->request(meta => "riap+tcp://localhost:7001/Sub/ModSub/");

 # dies, unknown scheme
 $res = $pa->request(call => "baz://example.com/Sub/ModSub/");


=head1 DESCRIPTION

This module provides a convenient wrapper to select appropriate Riap client
objects based on URI scheme (or lack thereof).

 Foo::Bar    -> InProcess (pm:/Foo/Bar/)
 /Foo/Bar/   -> InProcess
 pm:/Foo/Bar -> InProcess
 http://...  -> HTTP
 https://... -> HTTP
 riap+tcp:// -> TCP

=cut
