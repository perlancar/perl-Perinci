package Perinci::Access::InProcess;

use 5.010;
use strict;
use warnings;
use Log::Any '$log';

use parent qw(Perinci::Access::Base);

use Perinci::Util qw(get_package_meta_accessor);
use Scalar::Util qw(blessed reftype);
use SHARYANTO::Package::Util qw(package_exists);
use URI;

# VERSION

our $re_mod = qr/\A[A-Za-z_][A-Za-z_0-9]*(::[A-Za-z_][A-Za-z_0-9]*)*\z/;

# note: no method should die() because we are called by
# Perinci::Access::HTTP::Server without extra eval().

sub _init {
    require Class::Inspector;
    require Tie::Cache;

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

    # to cache wrapped result
    tie my(%cache), 'Tie::Cache', 100;
    $self->{_cache} = \%cache;

    $self->{use_tx}                //= 0;
    $self->{custom_tx_manager}     //= undef;

    # other attributes
    $self->{meta_accessor} //= "Perinci::MetaAccessor::Default";
    $self->{load}                  //= 1;
    $self->{extra_wrapper_args}    //= {};
    $self->{extra_wrapper_convert} //= {};
}

sub _get_meta_accessor {
    my ($self, $req) = @_;

    get_package_meta_accessor(
        package => $req->{-module},
        default_class => $self->{meta_accessor}
    );
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

    my $meta = $ma->get_meta($req->{-module}, $req->{-leaf});

    # supply a default, empty metadata for package, just so we can put $VERSION
    # into it
    if (!$meta && $req->{-type} eq 'package') {
        $meta = {v=>1.1};
    }
    return [404, "No metadata"] unless $meta;

    my $code;
    my $extra;
    if ($req->{-type} eq 'function') {
        $code = \&{$name};
        my $wres = Perinci::Sub::Wrapper::wrap_sub(
            sub=>$code, sub_name=>$name, meta=>$meta,
            forbid_tags => ['die'],
            %{$self->{extra_wrapper_args}},
            convert=>{
                args_as=>'hash', result_naked=>0,
                %{$self->{extra_wrapper_convert}},
            });
        return [500, "Can't wrap function: $wres->[0] - $wres->[1]"]
            unless $wres->[0] == 200;
        $code = $wres->[2]{sub};

        $extra = {
            # store some info about the old meta, no need to store all for
            # efficiency
            orig_meta=>{
                result_naked=>$meta->{result_naked},
                args_as=>$meta->{args_as},
            },
        };
        $meta = $wres->[2]{meta};
        $self->{_cache}{$name} = [$code, $meta, $extra];
    }
    unless (defined $meta->{entity_version}) {
        my $ver = ${ $req->{-module} . "::VERSION" };
        if (defined $ver) {
            $meta->{entity_version} = $ver;
        }
    }
    [200, "OK", [$code, $meta, $extra]];
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

    # check transaction

    my $mmeth = "actionmeta_$action";
    $self->$meth($req);
}

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
    my $spec = $ma->get_all_metas($req->{-module});
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

sub actionmeta_meta { +{
    applies_to => ['*'],
    summary    => "Get metadata",
} }

sub action_meta {
    my ($self, $req) = @_;
    return [404, "No metadata for /"] unless $req->{-module};
    my $res = $self->_get_code_and_meta($req);
    return $res unless $res->[0] == 200;
    my (undef, $meta, $extra) = @{$res->[2]};
    [200, "OK", $meta, {orig_meta=>$extra->{orig_meta}}];
}

sub actionmeta_call { +{
    applies_to => ['function'],
    summary    => "Call function",
} }

sub action_call {
    my ($self, $req) = @_;

    my $res;

    my $tx; # = does client mention tx_id?
    if ($req->{tx_id}) {
        $res = $self->_pre_tx_action($req);
        return $res if $res;
        $tx = $self->{_tx};
        $tx->{_tx_id} = $req->{tx_id};
    }

    $res = $self->_get_code_and_meta($req);
    return $res unless $res->[0] == 200;
    my ($code, $meta) = @{$res->[2]};
    my %args = %{ $req->{args} // {} };

    my $ff  = $meta->{features} // {};
    my $ftx = $ff->{tx} && ($ff->{tx}{use} || $ff->{tx}{req});
    my $dry = $ff->{dry_run} && $args{-dry_run};

    # even if client doesn't mention tx_id, some function still needs
    # -undo_trash_dir under dry_run for testing (e.g. setup_symlink()).
    if (!$tx && $ftx && $dry && !$args{-undo_trash_dir}) {
        if ($self->{_tx}) {
            $res = $self->{_tx}->get_trash_dir;
            $args{-undo_trash_dir} = $res->[2]; # XXX if error?
        } else {
            $args{-undo_trash_dir} = "/tmp"; # TMP
        }
    }

    if ($tx) {

        # if function features does not qualify in transaction, this constitutes
        # an error and should cause a rollback
        unless (
            ($ftx && $ff->{undo} && $ff->{idempotent}) ||
                $ff->{pure} ||
                    ($ff->{dry_run} && $args{-dry_run})) {
            my $rbres = $tx->rollback;
            return [412, "Can't call this function using transaction".
                        ($rbres->[0] == 200 ?
                             " (rollbacked)" : " (rollback failed)")];
        }
        $args{-tx_manager} = $tx;
        $args{-undo_action} //= 'do' if $ftx;
    }

    $res = $code->(%args);

    if ($tx) {
        if ($res->[0] =~ /^(?:200|304)$/) {
            # suppress undo_data from function, as per Riap::Tx spec
            delete $res->[3]{undo_data} if $res->[3];
        } else {
            # if function returns non-success, this also constitutes an error in
            # transaction and should cause a rollback
            my $rbres = $tx->rollback;
            $res->[1] .= $rbres->[0] == 200 ?
                " (rollbacked)" : " (rollback failed)";
        }
    }

    $tx->{_tx_id} = undef if $tx;

    $res;
}

sub actionmeta_complete_arg_val { +{
    applies_to => ['function'],
    summary    => "Complete function's argument value"
} }

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

sub actionmeta_child_metas { +{
    applies_to => ['package'],
    summary    => "Get metadata of all child entities",
} }

sub action_child_metas {
    my ($self, $req) = @_;

    my $res = $self->action_list($req);
    return $res unless $res->[0] == 200;
    my $ents = $res->[2];

    my %res;
    my %om;
    for my $ent (@$ents) {
        $res = $self->request(meta => $ent);
        # ignore failed request
        next unless $res->[0] == 200;
        $res{$ent} = $res->[2];
        $om{$ent}  = $res->[3]{orig_meta};
    }
    [200, "OK", \%res, {orig_metas=>\%om}];
}

sub actionmeta_get { +{
    applies_to => ['variable'],
    summary    => "Get value of variable",
} }

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

sub _pre_tx_action {
    my ($self, $req) = @_;

    return [501, "Transaction not supported by server"]
        unless $self->{use_tx};

    # instantiate custom tx manager, per request if necessary
    if ((reftype($self->{custom_tx_manager}) // '') eq 'CODE') {
        eval {
            $self->{_tx} = $self->{custom_tx_manager}->($self);
            die $self->{_tx} unless blessed($self->{_tx});
        };
        return [500, "Can't initialize custom tx manager: $self->{_tx}: $@"]
            if $@;
    } elsif (!blessed($self->{_tx})) {
        my $txm_cl = $self->{custom_tx_manager} // "Perinci::Tx::Manager";
        my $txm_cl_p = $txm_cl; $txm_cl_p =~ s!::!/!g; $txm_cl_p .= ".pm";
        eval {
            require $txm_cl_p;
            $self->{_tx} = $txm_cl->new(pa => $self);
            die $self->{_tx} unless blessed($self->{_tx});
        };
        return [500, "Can't initialize tx manager ($txm_cl): $@"] if $@;
    }

    return;
}

sub actionmeta_begin_tx { +{
    applies_to => ['*'],
    summary    => "Start a new transaction",
} }

sub action_begin_tx {
    my ($self, $req) = @_;
    my $res = $self->_pre_tx_action($req);
    return $res if $res;

    $self->{_tx}->begin(
        tx_id   => $req->{tx_id},
        summary => $req->{summary},
    );
}

sub actionmeta_commit_tx { +{
    applies_to => ['*'],
    summary    => "Commit a transaction",
} }

sub action_commit_tx {
    my ($self, $req) = @_;
    my $res = $self->_pre_tx_action($req);
    return $res if $res;

    $self->{_tx}->commit(
        tx_id  => $req->{tx_id},
    );
}

sub actionmeta_savepoint_tx { +{
    applies_to => ['*'],
    summary    => "Create a savepoint in a transaction",
} }

sub action_savepoint_tx {
    my ($self, $req) = @_;
    my $res = $self->_pre_tx_action($req);
    return $res if $res;

    $self->{_tx}->savepoint(
        tx_id => $req->{tx_id},
        sp    => $req->{tx_spid},
    );
}

sub actionmeta_release_tx_savepoint { +{
    applies_to => ['*'],
    summary    => "Release a transaction savepoint",
} }

sub action_release_tx_savepoint {
    my ($self, $req) =\ @_;
    my $res = $self->_pre_tx_action($req);
    return $res if $res;

    $self->{_tx}->release_savepoint(
        tx_id => $req->{tx_id},
        sp    => $req->{tx_spid},
    );
}

sub actionmeta_rollback_tx { +{
    applies_to => ['*'],
    summary    => "Rollback a transaction (optionally to a savepoint)",
} }

sub action_rollback_tx {
    my ($self, $req) = @_;
    my $res = $self->_pre_tx_action($req);
    return $res if $res;

    $self->{_tx}->rollback(
        tx_id => $req->{tx_id},
        sp    => $req->{tx_spid},
    );
}

sub actionmeta_list_txs { +{
    applies_to => ['*'],
    summary    => "List transactions",
} }

sub action_list_txs {
    my ($self, $req) = @_;
    my $res = $self->_pre_tx_action($req);
    return $res if $res;

    $self->{_tx}->list(
        detail    => $req->{detail},
        tx_status => $req->{tx_status},
        tx_id     => $req->{tx_id},
    );
}

sub actionmeta_undo { +{
    applies_to => ['*'],
    summary    => "Undo a committed transaction",
} }

sub action_undo {
    my ($self, $req) = @_;
    my $res = $self->_pre_tx_action($req);
    return $res if $res;

    $self->{_tx}->undo(
        tx_id => $req->{tx_id},
    );
}

sub actionmeta_redo { +{
    applies_to => ['*'],
    summary    => "Redo an undone committed transaction",
} }

sub action_redo {
    my ($self, $req) = @_;
    my $res = $self->_pre_tx_action($req);
    return $res if $res;

    $self->{_tx}->redo(
        tx_id => $req->{tx_id},
    );
}

sub actionmeta_discard_tx { +{
    applies_to => ['*'],
    summary    => "Discard (forget) a committed transaction",
} }

sub action_discard_tx {
    my ($self, $req) = @_;
    my $res = $self->_pre_tx_action($req);
    return $res if $res;

    $self->{_tx}->discard(
        tx_id => $req->{tx_id},
    );
}

sub actionmeta_discard_all_txs { +{
    applies_to => ['*'],
    summary    => "Discard (forget) all committed transactions",
} }

sub action_discard_all_txs {
    my ($self, $req) = @_;
    my $res = $self->_pre_tx_action($req);
    return $res if $res;

    $self->{_tx}->discard_all(
        # XXX select client
    );
}

1;
# ABSTRACT: Use Rinci access protocol (Riap) to access Perl code

=for Pod::Coverage ^actionmeta_.+ ^action_.+

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

But Perinci::Access::InProcess offers several benefits:

=over 4

=item * Custom location of metadata

Metadata can be placed not in C<%SPEC> but elsewhere, like in another file or
even database, or even by merging from several sources.

=item * Function wrapping

Can be used to convert argument passing style or produce result envelope, so you
get a consistent interface.

=item * Transaction/undo

This class implements L<Riap::Transaction>. See
L<Perinci::Access::InProcess::Tx> for more details.

=back

=head2 Location of metadata

By default, the metadata should be put in C<%SPEC> package variable, in a key
with the same name as the URI path leaf (use C<:package> for the package
itself). For example, metadata for C</Foo/Bar/$var> should be put in
C<$Foo::Bar::SPEC{'$var'}>, C</Foo/Bar/> in C<$Foo::Bar::SPEC{':package'}>. The
metadata for the top-level namespace (C</>) should be put in
C<$main::SPEC{':package'}>.

If you want to put metadata elsewhere, you can pass C<meta_accessor> =>
C<'Custom_Class'> to constructor argument, or set this in your module:

 our $PERINCI_META_ACCESSOR = 'Custom::Class';

The default accessor class is L<Perinci::MetaAccessor::Default>. Alternatively,
you can simply devise your own system to retrieve metadata which you can put in
C<%SPEC> at the end.


=head1 METHODS

=head2 PKG->new(%attrs) => OBJ

Instantiate object. Known attributes:

=over 4

=item * meta_accessor => STR (default 'Perinci::MetaAccessor::Default')

=item * load => BOOL (default 1)

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

=item * use_tx => BOOL (default 0)

Whether to allow transaction requests from client. Since this can cause the
server to store transaction/undo data, this must be explicitly allowed.

=item * custom_tx_manager => STR|CODE

Can be set to a string (class name) or a code that is expected to return a
transaction manager class.

By default, L<Perinci::Tx::Manager> is instantiated and maintained (not
reinstantiated on every request), but if C<custom_tx_manager> is a coderef, it
will be called on each request to get transaction manager.

This can be used to instantiate L<Perinci::Tx::Manager> in a custom way, e.g.
specifying per-user transaction data directory and limits, which needs to be
done on a per-request basis.

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
