package Perinci::Access::InProcess::Tx;

# VERSION

package Perinci::Access::InProcess;

use 5.010;
use strict;
use warnings;

sub _pre_tx_action {
    my ($self, $req) = @_;

    return [501, "Transaction not supported by server"]
        unless $self->{use_tx};

    # instantiate custom tx manager, per request if necessary
    my $am = $self->$mmeth;
    if (ref($self->{custom_tx_manager}) eq 'CODE') {
        $self->{_tx} = $self->{custom_tx_manager}->($self);
        return [500, "BUG: custom_tx_manager did not return object"]
            unless blessed($self->{_tx});
    } elsif (!blessed($self->{_tx})) {
        my $txm_cl = $self->{custom_tx_manager} // "Perinci::Tx::Manager";
        my $txm_cl_p = $txm_cl; $txm_cl_p =~ s!::!/!g; $txm_cl .= ".pm";
        eval {
            require $txm_cl_p;
            $self->{_tx} = $txm_cl->new;
            die "BUG: tx manager object not created?"
                unless blessed($self->{_tx});
        };
        return [500, "Can't initialize tx manager ($txm_cl): $@, ".
                    "you probably need to install the module first"] if $@;
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

    $self->{_tx}->begin(%$req);
}

sub actionmeta_commit { +{
    applies_to => ['*'],
    summary    => "Commit a transaction",
} }

sub action_commit_tx {
    my ($self, $req) = @_;
    my $res = $self->_pre_tx_action($req);
    return $res if $res;

    $self->{_tx}->commit(%$req);
}

sub actionmeta_savepoint_tx { +{
    applies_to => ['*'],
    summary    => "Create a savepoint in a transaction",
} }

sub action_savepoint_tx {
    my ($self, $req) = @_;
    my $res = $self->_pre_tx_action($req);
    return $res if $res;

    $self->{_tx}->savepoint(%$req);
}

sub actionmeta_release_tx_savepoint { +{
    applies_to => ['*'],
    summary    => "Release a transaction savepoint",
} }

sub action_release_tx_savepoint {
    my ($self, $req) =\ @_;
    my $res = $self->_pre_tx_action($req);
    return $res if $res;

    $self->{_tx}->release_savepoint(%$req);
}

sub actionmeta_rollback_tx { +{
    applies_to => ['*'],
    summary    => "Rollback a transaction (optionally to a savepoint)",
} }

sub action_rollback_tx {
    my ($self, $req) = @_;
    my $res = $self->_pre_tx_action($req);
    return $res if $res;

    $self->{_tx}->rollback(%$req);
}

sub actionmeta_list_txs { +{
    applies_to => ['*'],
    summary    => "List transactions",
} }

sub action_list_txs {
    my ($self, $req) = @_;
    my $res = $self->_pre_tx_action($req);
    return $res if $res;

    $self->{_tx}->list(%$req);
}

sub actionmeta_undo { +{
    applies_to => ['*'],
    summary    => "Undo a committed transaction",
} }

sub action_undo {
    my ($self, $req) = @_;
    my $res = $self->_pre_tx_action($req);
    return $res if $res;

    $self->{_tx}->undo(%$req);
}

sub actionmeta_redo { +{
    applies_to => ['*'],
    summary    => "Redo an undone committed transaction",
} }

sub action_redo {
    my ($self, $req) = @_;
    my $res = $self->_pre_tx_action($req);
    return $res if $res;

    $self->{_tx}->redo(%$req);
}

sub actionmeta_discard_tx { +{
    applies_to => ['*'],
    summary    => "Discard (forget) a committed transaction",
} }

sub action_discard_tx {
    my ($self, $req) = @_;
    my $res = $self->_pre_tx_action($req);
    return $res if $res;

    $self->{_tx}->discard(%$req);
}

sub actionmeta_discard_all_txs { +{
    applies_to => ['*'],
    summary    => "Discard (forget) all committed transactions",
} }

sub action_discard_all_txs {
    my ($self, $req) = @_;
    [501, "Not yet implemented"];
    my $res = $self->_pre_tx_action($req);
    return $res if $res;

    $self->{_tx}->discard_all(%$req);
}

1;
# ABSTRACT: Handle transaction-/undo-related Riap requests

=head1 SEE ALSO

The default implementation of transaction manager: L<Perinci::Tx::Manager>

