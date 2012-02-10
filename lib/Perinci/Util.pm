package Perinci::Util;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(
                       declare_property
                       declare_function_feature
                       declare_function_dep
               );

sub declare_property {
    my %args   = @_;
    my $name   = $args{name}   or die "Please specify property's name";
    my $schema = $args{schema} or die "Please specify property's schema";
    my $type   = $args{type};

    my $bs; # base schema (Rinci::metadata)
    my $ts; # per-type schema (Rinci::metadata::TYPE)
    my $bpp;
    my $tpp;

    require Rinci::Schema;
    $bs = $Rinci::Schema::base;
    $bpp = $bs->[1]{"keys"}
        or die "BUG: Schema structure changed (1)";
    $bpp->{$name}
        and die "Property '$name' is already declared in base schema";
    if ($type) {
        if ($type eq 'function') {
            $ts = $Rinci::Schema::function;
        } elsif ($type eq 'variable') {
            $ts = $Rinci::Schema::variable;
        } elsif ($type eq 'package') {
            $ts = $Rinci::Schema::package;
        } else {
            die "Unknown/unsupported property type: $type";
        }
        $tpp = $ts->[1]{"[merge:+]keys"}
            or die "BUG: Schema structure changed (1)";
        $tpp->{$name}
            and die "Property '$name' is already declared in $type schema";
    }
    ($bpp // $tpp)->{$name} = $schema;

    if ($args{wrap_meta}) {
        require Perinci::Sub::Wrapper;
        no strict 'refs';
        *{"Perinci::Sub::Wrapper::handlemeta_$name"} = sub { $args{wrap_meta} };
        *{"Perinci::Sub::Wrapper::handle_$name"} = $args{wrap} if $args{wrap};
    }
}

sub declare_function_feature {
    my %args   = @_;
    my $name   = $args{name}   or die "Please specify feature's name";
    my $schema = $args{schema} or die "Please specify feature's schema";

    $name =~ /\A\w+\z/
        or die "Invalid syntax on feature's name, please use alphanums only";

    require Rinci::Schema;
    # XXX merge first or use Perinci::Object, less fragile
    my $ff = $Rinci::Schema::function->[1]{"[merge:+]keys"}{features}
        or die "BUG: Schema structure changed (1)";
    $ff->[1]{keys}
        or die "BUG: Schema structure changed (2)";
    $ff->[1]{keys}{$name}
        and die "Feature '$name' is already declared";
    $ff->[1]{keys}{$name} = $args{schema};
}

sub declare_function_dep {
    my %args    = @_;
    my $name    = $args{name}   or die "Please specify dep's name";
    my $schema  = $args{schema} or die "Please specify dep's schema";
    my $check   = $args{check};

    $name =~ /\A\w+\z/
        or die "Invalid syntax on dep's name, please use alphanums only";

    require Rinci::Schema;
    # XXX merge first or use Perinci::Object, less fragile
    my $dd = $Rinci::Schema::function->[1]{"[merge:+]keys"}{deps}
        or die "BUG: Schema structure changed (1)";
    $dd->[1]{keys}
        or die "BUG: Schema structure changed (2)";
    $dd->[1]{keys}{$name}
        and die "Dependency type '$name' is already declared";
    $dd->[1]{keys}{$name} = $args{schema};

    if ($check) {
        require Perinci::Sub::DepChecker;
        no strict 'refs';
        *{"Perinci::Sub::DepChecker::checkdep_$name"} = $check;
    }
}

1;
# ABSTRACT: Utility routines
