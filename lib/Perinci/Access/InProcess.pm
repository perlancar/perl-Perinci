package Perinci::Access::InProcess;

use 5.010;
use strict;
use warnings;
use Log::Any '$log';

use parent qw(Perinci::Access::Base);

use Scalar::Util qw(blessed);
use SHARYANTO::Package::Util qw(package_exists);
use URI;

# VERSION

our $re_mod = qr/\A[A-Za-z_][A-Za-z_0-9]*(::[A-Za-z_][A-Za-z_0-9]*)*\z/;

sub _init {
    require Tie::Cache;

    my ($self) = @_;
    $self->SUPER::_init();

    # to cache wrapped result
    tie my(%cache), 'Tie::Cache', 100;
    $self->{_cache} = \%cache;

    # attributes
    $self->{meta_accessor} //= "Perinci::Access::InProcess::MetaAccessor";
    $self->{load}          //= 1;
    $self->{extra_wrapper_args}    //= {};
    $self->{extra_wrapper_convert} //= {};
}

sub _get_meta_accessor {
    my ($self, $req) = @_;

    no strict 'refs';
    my $ma = ${ $req->{-module} . "::PERINCI_META_ACCESSOR" } //
        $self->{meta_accessor};
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

    my $code;
    if ($req->{-type} eq 'function') {
        $code = \&{$name};
        my $wres = Perinci::Sub::Wrapper::wrap_sub(
            sub=>$code, meta=>$meta,
            %{$self->{extra_wrapper_args}},
            convert=>{
                args_as=>'hash', result_naked=>0,
                %{$self->{extra_wrapper_convert}},
            });
        return [500, "Can't wrap function: $wres->[0] - $wres->[1]"]
            unless $wres->[0] == 200;
        $code = $wres->[2]{sub};
        $meta = $wres->[2]{meta};

        $self->{_cache}{$name} = [$code, $meta];
    }
    unless (defined $meta->{entity_version}) {
        my $ver = ${ $req->{-module} . "::VERSION" };
        if (defined $ver) {
            $meta->{entity_version} = $ver;
        }
    }
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
            my $uri = join("", "pl:", $p0, "/", $m, "/");
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
    my $base = "pl:/$req->{-module}"; $base =~ s!::!/!g;
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

sub action_child_metas {
    my ($self, $req) = @_;

    my $res = $self->action_list($req);
    return $res unless $res->[0] == 200;
    my $ents = $res->[2];

    my %res;
    for my $ent (@$ents) {
        $res = $self->request(meta => $ent);
        # ignore failed request
        next unless $res->[0] == 200;
        $res{$ent} = $res->[2];
    }
    [200, "OK", \%res];
}

sub action_get {
    no strict 'refs';

    my ($self, $req) = @_;
    local $req->{-leaf} = $req->{-leaf};

    # extract prefix
    $req->{-leaf} =~ s/^([%\@\$])//
        or return [500, "BUG: Unknown variable prefix"];
    my $prefix = $1;
    my $name = $req->{-module} . "::" . $req->{-leaf};
    my $res =
        $prefix eq '$' ? ${$name} :
            $prefix eq '@' ? \@{$name} :
                $prefix eq '%' ? \%{$name} :
                    undef;
    [200, "OK", $res];
}

sub request {
    no strict 'refs';

    my ($self, $action, $uri, $extra) = @_;

    my $req = { action=>$action, %{$extra // {}} };
    my $res = $self->check_request($req);
    return $res if $res;

    my $meth = "action_$action";
    return [502, "Action '$action' not implemented"] unless
        $self->can($meth);

    return [400, "Please specify URI"] unless $uri;
    $uri = URI->new($uri) unless blessed($uri);
    $req->{uri} = $uri;

    # parse path, package, leaf, module

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
                my $req_err = $@;
                if ($req_err) {
                    if (!package_exists($module)) {
                        return [500, "Can't load module $module (probably ".
                                    "mistyped or missing module): $req_err"];
                    } elsif ($req_err !~ m!Can't locate!) {
                        return [500, "Can't load module $module (probably ".
                                    "compile error): $req_err"];
                    }
                    # require error of "Can't locate ..." can be ignored. it
                    # might mean package is already defined by other code. we'll
                    # try and access it anyway.
                } elsif (!package_exists($module)) {
                    # shouldn't happen
                    return [500, "Module loaded OK, but no $module package ".
                                "found, something's wrong"];
                } else {
                    if ($self->{after_load}) {
                        eval { $self->{after_load}($self, module=>$module) };
                        return [500, "after_load dies: $@"] if $@;
                    }
                }
            }
        }
    }

    # find out type of leaf and other information

    my $type;
    my $entity_version;
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
        $entity_version = ${$module . '::VERSION'};
    }
    $req->{-type} = $type;
    $req->{-entity_version} = $entity_version;

    #$log->tracef("req=%s", $req);

    return [502, "Action '$action' not implemented for ".
                "'$req->{-type}' entity"]
        unless $self->{_typeacts}{ $req->{-type} }{ $action };
    $self->$meth($req);
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
 sub mult2 {
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
 # -> [200, "OK", ['/My/Module/mult2', '/My/Module/multn']]

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

=head2 PKG->new(%attrs) => OBJ

Instantiate object. Known attributes:

=over 4

=item * meta_accessor => STR (default 'Perinci::Access::InProcess::MetaAccessor')

=item * load => STR (default 1)

Whether attempt to load modules using C<require>.

=item * after_load => CODE

If set, code will be executed the first time Perl module is successfully loaded.

=item * extra_wrapper_args => HASH

If set, will be passed to L<Perinci::Sub::Wrapper>'s wrap_sub() when wrapping
subroutines.

Some applications of this include: adding C<timeout> or C<result_postfilter>
properties to functions.

=item * extra_wrapper_convert => HASH

If set, will be passed to L<Perinci::Sub::Wrapper> wrap_sub()'s C<convert>
argument when wrapping subroutines.

Some applications of this include: changing C<default_lang> of metadata.

=back

=head2 $pa->request($action => $server_url, \%extra) => $res

Process Riap request and return enveloped result. $server_url will be used as
the Riap request key 'uri', as there is no server in this case.

Some notes:

=over 4

=item * Metadata returned by the 'meta' action has normalized schemas in them

Schemas in metadata (like in the C<args> and C<return> property) are normalized
by L<Perinci::Sub::Wrapper>.

=back


=head1 FAQ

=head2 Why %SPEC?

The name was first chosen when during Sub::Spec era, so it stuck.


=head1 SEE ALSO

L<Riap>, L<Rinci>

=cut
