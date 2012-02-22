package Perinci::Access::InProcess;

use 5.010;
use strict;
use warnings;

use parent qw(Perinci::Access::Base);

# VERSION

our $re_mod = qr/\A[A-Za-z_][A-Za-z_0-9]*(::[A-Za-z_][A-Za-z_0-9]*)*\z/;

sub _init {
    require Tie::Cache;

    my ($self) = @_;
    $self->SUPER::_init();

    # to cache wrapped result
    tie my(%cache), 'Tie::Cache', 100;
    $self->{_cache} = \%cache;

    $self->{load} //= 1;
}

sub _before_action {
    my ($self, $req) = @_;
    no strict 'refs';

    # parse code entity from URI (cache the result in the request object) & load
    # module

    my $path = $req->{uri}->path || "/";
    $req->{-path} = $path;

    my ($package, $module, $leaf);
    if ($path eq '/') {
        $package = '/';
        $leaf    = '';
        $module  = '';
    } else {
        if ($path =~ m!(.+)/+(.*)!) {
            $package = $1;
            $leaf    = $2;
        } else {
            $package = $path;
            $leaf    = '';
        }
        $module = $package;
        $module =~ s!^/+!!g;
        $module =~ s!/+!::!g;
    }

    return [400, "Invalid syntax in module '$module', ".
                "please use valid module name"]
        if $module && $module !~ $re_mod;

    $req->{-package} = $package;
    $req->{-leaf}    = $leaf;
    $req->{-module}  = $module;

    if ($module) {
        my $module_p = $module;
        $module_p =~ s!::!/!g;
        $module_p .= ".pm";

        # WISHLIST: cache negative result if someday necessary
        if ($self->{load}) {
            unless ($INC{$module_p}) {
                eval { require $module_p };
                if ($@) {
                    return [404, "Can't find module $module"];
                } else {
                    if ($self->{after_load}) {
                        eval { $self->{after_load}($self, module=>$module) };
                        return [500, "after_load dies: $@"] if $@;
                    }
                }
            }
        }
    }

    # find out type of leaf
    my $type;
    if ($leaf) {
        if ($leaf =~ /^[%\@\$]/) {
            # XXX check existence of variable
            $type = 'variable';
        } else {
            return [404, "Can't find function $leaf in $module"]
                unless defined &{"$module\::$leaf"};
            $type = 'function';
        }
    } else {
        $type = 'package';
    }
    $req->{-type} = $type;

    0;
}

sub _get_meta_accessor {
    my ($self, $req) = @_;

    no strict 'refs';
    my $ma = ${ $req->{-module} . "::PERINCI_META_ACCESSOR" } //
        $self->{meta_accessor} //
            "Perinci::Access::InProcess::MetaAccessor";
    my $ma_p = $ma;
    $ma_p =~ s!::!/!g;
    $ma_p .= ".pm";
    eval { require $ma_p };
    return [500, "Can't load meta accessor module $ma"] if $@;
    [200, "OK", $ma];
}

sub _get_code_and_meta {
    require Perinci::Sub::Wrapper;

    no strict 'refs';
    my ($self, $req) = @_;
    my $name = $req->{-module} . "::" . $req->{-leaf};
    return [200, "OK", $self->{_cache}{$name}] if $self->{_cache}{$name};

    my $res = $self->_get_meta_accessor($req);
    return $res if $res->[0] != 200;
    my $ma = $res->[2];

    my $meta = $ma->get_meta($req);
    return [404, "No metadata"] unless $meta;

    my $code = \&{$name};
    my $wres = Perinci::Sub::Wrapper::wrap_sub(
        sub=>$code, meta=>$meta,
        convert=>{args_as=>'hash', result_naked=>0});
    return [500, "Can't wrap function: $wres->[0] - $wres->[1]"]
        unless $wres->[0] == 200;
    $code = $wres->[2]{sub};

    $self->{_cache}{$name} = [$code, $meta];
    [200, "OK", [$code, $meta]];
}

sub action_list {
    require Module::List;

    my ($self, $req) = @_;
    my $detail = $req->{detail};
    my $f_type = $req->{type} || "";

    my @res;

    # XXX recursive?

    # get submodules
    unless ($f_type && $f_type ne 'package') {
        my $lres = Module::List::list_modules(
            $req->{-module} ? "$req->{-module}\::" : "",
            {list_modules=>1});
        my $p0 = $req->{-path};
        $p0 =~ s!/+$!!;
        for my $m (sort keys %$lres) {
            $m =~ s!.+::!!;
            my $uri = join("", "pm:", $p0, "/", $m, "/");
            if ($detail) {
                push @res, {uri=>$uri, type=>"package"};
            } else {
                push @res, $uri;
            }
        }
    }

    # get all entities from this module
    my $res = $self->_get_meta_accessor($req);
    return $res if $res->[0] != 200;
    my $ma = $res->[2];
    my $spec = $ma->get_all_meta($req);
    my $base = "pm:/$req->{-module}"; $base =~ s!::!/!g;
    for (sort keys %$spec) {
        next if /^:/;
        my $uri = join("", $base, "/", $_);
        my $t = $_ =~ /^[%\@\$]/ ? 'variable' : 'function';
        next if $f_type && $f_type ne $t;
        if ($detail) {
            push @res, {
                #v=>1.1,
                uri=>$uri, type=>$t,
            };
        } else {
            push @res, $uri;
        }
    }

    [200, "OK", \@res];
}

sub action_meta {
    my ($self, $req) = @_;
    return [404, "No metadata for /"] unless $req->{-module};
    my $res = $self->_get_code_and_meta($req);
    return $res unless $res->[0] == 200;
    my (undef, $meta) = @{$res->[2]};
    [200, "OK", $meta];
}

sub action_call {
    my ($self, $req) = @_;

    my $res = $self->_get_code_and_meta($req);
    return $res unless $res->[0] == 200;
    my ($code, undef) = @{$res->[2]};
    my $args = $req->{args} // {};
    $code->(%$args);
}

sub action_complete_arg_val {
    my ($self, $req) = @_;
    my $arg = $req->{arg} or return [400, "Please specify arg"];
    my $word = $req->{word} // "";

    my $res = $self->_get_code_and_meta($req);
    return $res unless $res->[0] == 200;
    my (undef, $meta) = @{$res->[2]};
    my $args_p = $meta->{args} // {};
    my $arg_p = $args_p->{$arg} or return [404, "No such function arg"];

    my $words;
    eval { # completion sub can die, etc.

        if ($arg_p->{completion}) {
            $words = $arg_p->{completion}(word=>$word);
            die "Completion sub does not return array"
                unless ref($words) eq 'ARRAY';
            return;
        }

        my $sch = $arg_p->{schema};

        my ($type, $cs) = @{$sch};
        if ($cs->{'in'}) {
            $words = $cs->{'in'};
            return;
        }

        if ($type =~ /^int\*?$/) {
            my $limit = 100;
            if ($cs->{between} &&
                    $cs->{between}[0] - $cs->{between}[0] <= $limit) {
                $words = [$cs->{between}[0] .. $cs->{between}[1]];
                return;
            } elsif ($cs->{xbetween} &&
                    $cs->{xbetween}[0] - $cs->{xbetween}[0] <= $limit) {
                $words = [$cs->{xbetween}[0]+1 .. $cs->{xbetween}[1]-1];
                return;
            } elsif (defined($cs->{min}) && defined($cs->{max}) &&
                         $cs->{max}-$cs->{min} <= $limit) {
                $words = [$cs->{min} .. $cs->{max}];
                return;
            } elsif (defined($cs->{min}) && defined($cs->{xmax}) &&
                         $cs->{xmax}-$cs->{min} <= $limit) {
                $words = [$cs->{min} .. $cs->{xmax}-1];
                return;
            } elsif (defined($cs->{xmin}) && defined($cs->{max}) &&
                         $cs->{max}-$cs->{xmin} <= $limit) {
                $words = [$cs->{xmin}+1 .. $cs->{max}];
                return;
            } elsif (defined($cs->{xmin}) && defined($cs->{xmax}) &&
                         $cs->{xmax}-$cs->{xmin} <= $limit) {
                $words = [$cs->{min}+1 .. $cs->{max}-1];
                return;
            }
        }

        $words = [];
    };
    return [500, "Completion died: $@"] if $@;

    [200, "OK", [grep /^\Q$word\E/, @$words]];
}

1;
# ABSTRACT: Use Rinci access protocol (Riap) to access Perl code

=for Pod::Coverage ^action_.+

=cut

=head1 SYNOPSIS

 # in Your/Module.pm

 package My::Module;
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

 # in another file

 use Perinci::Access::InProcess;
 my $pa = Perinci::Access::Process->new();

 # list all functions in package
 my $res = $pa->request(list => '/My/Module/', {type=>'function'});
 # -> [200, "OK", ['/My/Module/mult2', '/My/Module/mult2']]

 # call function
 my $res = $pa->request(call => '/My/Module/mult2', {args=>{a=>2, b=>3}});
 # -> [200, "OK", 6]

 # get function metadata
 $res = $pa->request(meta => '/Foo/Bar/multn');
 # -> [200, "OK", {v=>1.1, summary=>'Multiple many numbers', ...}]


=head1 DESCRIPTION

This class implements Rinci access protocol (L<Riap>) to access local Perl code.
This might seem like a long-winded and slow way to access things that are
already accessible from Perl like functions and metadata (in C<%SPEC>). Indeed,
if you do not need Riap, you can access your module just like any normal Perl
module.

The abstraction provides some benefits, still. For example, you can actually
place metadata not in C<%SPEC> but elsewhere, like in another file or even
database, or even by merging from several sources. By using this module, you
don't have to change client code. This class also does some function wrapping to
convert argument passing style or produce result envelope, so you get a
consistent interface.

=head2 Location of metadata

By default, the metadata should be put in C<%SPEC> package variable, in a key
with the same name as the URI path leaf (use C<:package>) for the package
itself). For example, metadata for C</Foo/Bar/$var> should be put in
C<$Foo::Bar::SPEC{'$var'}>, C</Foo/Bar/> in C<$Foo::Bar::SPEC{':package'}>. The
metadata for the top-level namespace (C</>) should be put in
C<$main::SPEC{':package'}>.

If you want to put metadata elsewhere, you can pass C<meta_accessor> =>
C<'Custom_Class'> to constructor argument, or set this in your module:

 our $PERINCI_META_ACCESSOR = 'Custom::Class';

The default accessor class is L<Perinci::Access::InProcess::MetaAccessor>.
Alternatively, you can simply devise your own system to retrieve metadata which
you can put in C<%SPEC> at the end.


=head1 METHODS

=head2 PKG->new(%opts) => OBJ

Instantiate object. Known options:

=over 4

=item * meta_accessor => STR (default 'Perinci::Access::InProcess::MetaAccessor')

=item * load => STR (default 1)

Whether to load modules using C<require>.

=back

=head2 $pa->request($action => $uri, \%extra) => $res

Process Riap request and return enveloped result. This method will in turn parse
URI and other Riap request keys into C<$req> hash, and then call
C<action_ACTION> methods.


=head1 FAQ

=head2 Why %SPEC?

The name was first chosen when during Sub::Spec era, so it stuck.


=head1 SEE ALSO

L<Riap>, L<Rinci>

=cut
