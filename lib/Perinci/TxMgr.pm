package Perinci::TxMgr;

use 5.010;
use strict;
use warnings;
use Log::Any '$log';

# VERSION

sub new {
    my ($class, %opts) = @_;
    my $obj = bless \%opts, $class;
    $obj;
}

sub get_active_tx_id {
}

sub _init {
}

1;
# ABSTRACT: Transaction manager

=head1 SYNOPSIS

 # used by Perinci::Access::InProcess


=head1 DESCRIPTION

This class implements transaction and undo manager.

It uses SQLite database (to store transaction list and undo data) as well as
transaction data directory to provide trash_dir/tmp_dir for functions that
require it.

It is used by L<Perinci::Access::InProcess>.


=head1 METHODS

=head2 new(%args)

Create new object. Arguments:

=over 4

=item * data_dir => STR

Defaults to C<~/.perinci/.tx>.

=back

=head2 $txm->get_active_tx => HASH

Get active transaction information (a hashref: {id=>..., status=>...,
undone=>..., start_time=>..., finish_time=>..., summary=>...}), or undef if
there is none. An active transaction is transaction that is started (C<in
progress> or C<aborted>) and have not been committed or rolled back.

=head2 $txm->list_txs(%crit) => [HASH, ...]

List transactions.

=head1 SEE ALSO

L<Perinci::Access::InProcess>

L<Riap::Transaction>

The undo protocol section in L<Rinci::function>

=cut
