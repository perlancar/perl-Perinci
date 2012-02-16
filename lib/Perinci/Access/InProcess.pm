package Perinci::Access::InProcess;

use 5.010;
use strict;
use warnings;

use parent qw(Perinci::Access::Base);

use Module::List;
use Perinci::Sub::Wrapper qw(wrap_sub);
use Tie::Cache;

# VERSION

our $re_mod = qr/\A[A-Za-z_][A-Za-z_0-9]*(::[A-Za-z_][A-Za-z_0-9]*)*\z/;

sub _init {
    my ($self) = @_;
    $self->SUPER::_init();
    tie my(%cache), 'Tie::Cache', 100;
    $self->{_cache} = \%cache;
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

    if ($module) {
        my $module_p = $module;
        $module_p =~ s!::!/!g;
        $module_p .= ".pm";

        # WISHLIST: cache negative result if someday necessary
        eval { require $module_p };
        return [404, "Can't find module $module"] if $@;
        $req->{-package} = $package;
        $req->{-leaf}    = $leaf;
        $req->{-module}  = $module;
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

=for Pod::Coverage ^action_.+

=cut

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
    no strict 'refs';
    my ($self, $req) = @_;
    my $name = $req->{-module} . "::" . $req->{-leaf};
    return @{$self->{_cache}{$name}} if $self->{_cache}{$name};

    my $res = $self->_get_meta_accessor($req);
    return $res if $res->[0] != 200;
    my $ma = $res->[2];

    my $meta = $ma->get_meta($req);
    return [404, "No metadata"] unless $meta;

    my $code = \&{$name};
    my $wres = wrap_sub(sub=>$code, meta=>$meta,
                        convert=>{args_as=>'hash', result_naked=>0});
    return [500, "Can't wrap function: $wres->[0] - $wres->[1]"]
        unless $wres->[0] == 200;
    $code = $wres->[2]{sub};

    $self->{_cache}{$name} = [$code, $meta];
    [200, "OK", [$code, $meta]];
}

sub actionmeta_meta { { applies_to => ['*'], } }
sub action_meta {
    my ($self, $req) = @_;
    return [404, "No metadata for /"] unless $req->{-module};
    my $res = $self->_get_code_and_meta($req);
    return $res unless $res->[0] == 200;
    my (undef, $meta) = @{$res->[2]};
    [200, "OK", $meta];
}

sub actionmeta_list { { applies_to => ['package'], } }
sub action_list {
    my ($self, $req) = @_;
    my $detail = $req->{detail};

    my @res;

    # get submodules
    my $lres = Module::List::list_modules(
        $req->{-module} ? "$req->{-module}\::" : "",
        {list_modules=>1});
    #my $m0 = $req->{-module};
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

    # get all entities from this module
    my $res = $self->_get_meta_accessor($req);
    return $res if $res->[0] != 200;
    my $ma = $res->[2];
    my $spec = $ma->get_all_meta($req);
    my $base = "pm:/$req->{-module}"; $base =~ s!::!/!g;
    for (sort keys %$spec) {
        next if /^:/;
        my $uri = join("", $base, "/", $_);
        if ($detail) {
            my $type = $_ =~ /^[%\@\$]/ ? 'variable' : 'function';
            push @res, {
                #v=>1.1,
                uri=>$uri, type=>$type,
                #acts=> [keys %{ $self->{_typeacts}{$type} }],
            };
        } else {
            push @res, $uri;
        }
    }

    [200, "OK", \@res];
}

sub actionmeta_call { { applies_to => ['function'], } }
sub action_call {
    my ($self, $req) = @_;
    my $res = $self->_get_code_and_meta($req);
    return $res unless $res->[0] == 200;
    my ($code, undef) = @{$res->[2]};
    my $args = $req->{args} // {};
    $code->(%$args);
}

sub actionmeta_complete { { applies_to => ['function'], } }
sub action_complete {
    my ($self, $req) = @_;
    [502, "Not yet implemented (2)"];
}

1;
# ABSTRACT: Use Rinci access protocol (Riap) to access Perl code

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
convert argument passing style or produce result envelope, so you a consistent
interface.

=head2 Functions not accepting hash arguments

As can be seen from the Synopsis, Perinci expects functions to accept arguments
as hash. If your function accepts arguments from array, add C<args_as> =>
C<array> to your metadata property. When wrapping, L<Perinci::Sub::Wrapper> can
add a conversion code so that the function wrapper accepts hash as normal, but
your function still gets an array. Example:

 $SPEC{is_palindrome} = {
     v => 1.1,
     summary => 'Multiple two numbers',
     args => {
         a => { schema=>'float*', req=>1, pos=>0 },
         b => { schema=>'float*', req=>1, pos=>1 },
     },
 };
 sub mult2 {
     my ($a, $b) = @_;
     [200, "OK", $a*$b];
 }

 # called without wrapping
 mult2(2, 3); # -> [200,"OK",6]

 # called after wrapping, by default wrapper will convert hash arguments to
 # array for passing to the original function
 mult2(a=>2, b=>3); # -> [200,"OK",6]

=head2 Functions not returning enveloped result

Likewise, by default Perinci assumes your function returns enveloped result. But
if your function does not, you can set C<result_naked> => 1 to declare that. The
wrapper code can add code to create envelope for the function result.

 $SPEC{is_palindrome} = {
     v => 1.1,
     summary                 => 'Check whether a string is a palindrome',
     args                    => {str => {schema=>'str*'}},
     result                  => {schema=>'bool*'},
     result_naked            => 1,
 };
 sub is_palindrome {
     my %args = @_;
     my $str  = $args{str};
     $str eq reverse($str);
 }

 # called without wrapping
 is_palindrome(str=>"kodok"); # -> 1

 # called after wrapping, by default wrapper adds envelope
 is_palindrome(str=>"kodok"); # -> [200,"OK",1]

=head2 Location of metadata

By default, the metadata should be put in C<%SPEC> package variable, in a key
with the same name as the URI path leaf (use C<:package>) for the package
itself). For example, metadata for C</Foo/Bar/$var> should be put in
C<$Foo::Bar::SPEC{'$var'}>, C</Foo/Bar/> in C<$Foo::Bar::SPEC{':package'}. The
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

=item * meta_accessor => STR

=back

=head2 $pa->request($action => $uri, \%extra) => $res

Process Riap request and return enveloped result. This method will in turn parse
URI and other Riap request keys into C<$req> hash, and then call
C<action_ACTION> methods.


=head1 FAQ

=head1 Why %SPEC?

The name was first chosen when during Sub::Spec era, so it stuck. You can change
it though.


=head1 SEE ALSO

L<Riap>, L<Rinci>

=cut
