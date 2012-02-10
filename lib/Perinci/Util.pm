package Perinci::Util;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(add_property);

sub add_property {
    my %args = @_;
    my $type = $args{type};
    my $schema_var;

    if (!$type) {
        $schema_var = "base";
    } elsif ($type eq 'function') {
    } elsif ($type eq 'variable') {
    } elsif ($type eq 'package') {
    } else {
        die "BUG: Unknown/unsupported property type: $type";
    }
    $schema_var //= $type;

    $schema_var = "Rinci::Schema::$schema_var";

    require Rinci::Schema;
    # XXX add to schema

}

sub add_function_feature {
    my %args = @_;

    require Rinci::Schema;
    # XXX: bail if feature already defined in schema

    # XXX: add to schema

}

sub add_function_dep {
    my %args = @_;

    require Rinci::Schema;
    # XXX: bail if dep already defined in schema

    # XXX: add to schema

    # XXX: add routine for Perinci::Sub::DepChecker
    require Perinci::Sub::DepChecker;
}

1;
