package Perinci::Tx::Manager;

use 5.010;
use strict;
use warnings;
use DBI;
use JSON;
use Log::Any '$log';
use Time::HiRes qw(time);

# VERSION

my $json = JSON->new->allow_nonref;

sub new {
    my ($class, %opts) = @_;
    my $obj = bless \%opts, $class;
    if (!$opts{data_dir}) {
        for ("$ENV{HOME}/.perinci", "$ENV{HOME}/.perinci/.tx") {
            unless (-d $_) {
                mkdir $_ or die "Can't mkdir $_: $!";
            }
        }
        $opts{data_dir} = "$ENV{HOME}/.perinci/.tx";
    }
    $obj->_init;
    $obj;
}

sub _init {
    my ($self) = @_;
    my $data_dir = $self->{data_dir};
    $log->tracef("Initializing tx data dir %s ...", $data_dir);

    (-d $data_dir)
        or die "Transaction data dir ($data_dir) doesn't exist or not a dir";
    my $dbh = DBI->connect("dbi:SQLite:dbname=$data_dir/tx.db", undef, undef,
                       {RaiseError=>0});

    # init database
    $dbh->do(<<_) or die "Can't init tx db: create tx: ". $dbh->errstr;
CREATE TABLE IF NOT EXISTS tx (
    ser_id INTEGER PRIMARY KEY AUTOINCREMENT,
    str_id VARCHAR(200) NOT NULL,
    owner_id VARCHAR(64) NOT NULL,
    summary TEXT,
    status CHAR(1) NOT NULL, -- I, A, C, R, u, d, (E)
    ctime REAL NOT NULL,
    mtime REAL NOT NULL,
    last_processed_seq INTEGER,
    UNIQUE (str_id)
)
_
    $dbh->do(<<_) or die "Can't init tx db: create txcall: ". $dbh->errstr;
CREATE TABLE IF NOT EXISTS txcall (
    tx_ser_id INTEGER NOT NULL, -- refers tx(ser_id)
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    f TEXT NOT NULL,
    args TEXT NOT NULL
)
_
    $dbh->do(<<_) or die "Can't init tx db: create txcall: ". $dbh->errstr;
CREATE TABLE IF NOT EXISTS txstep (
    call_id INT NOT NULL, -- refers txcall(id)
    -- seq INTEGER NOT NULL, -- uses ROWID instead, sqlite-specific
    name TEXT, -- for named savepoint
    ctime REAL NOT NULL,
    mtime REAL NOT NULL,
    undo_step BLOB NOT NULL,
    redo_step BLOB
)
_

    $self->{_dbh} = $dbh;
    $self->recover;
}

sub recover {
    my ($self) = @_;
    $log->tracef("[txm] Performing recovery ...");

    # XXX lock database

    # XXX find all transaction with status A, u, d. Rollback them.

    # XXX unlock database
}

sub _tx_id {
    my ($self, $tx_id) = @_;
    $self->{_tx_id} = $tx_id;
}

sub __resp_tx_status {
    my ($r) = @_;
    my $s = $r->{status};
    my $ss =
        $s eq 'I' ? "still in-progress" :
            $s eq 'A' ? "aborted, further requests ignored until rolled back" :
                $s eq 'C' ? "already committed" :
                    $s eq 'R' ? "already rolled back" :
                        $s eq 'u' ? "undoing" :
                            $s eq 'd' ? "redoing" :
                                "unknown ('$s'), this is a bug and should ".
                                    "be reported";
    [480, "tx #$r->{ser_id}: Incorrect status, status is $ss"];
}

# all methods have some common code, refactored into _wrap(). arguments:
#
# - args* (hashref, arguments to method)
#
# - code (coderef, main method code, will be passed args as hash)
#
# - hook_check_args (coderef, will be passed args as hash)
#
# - hook_after_commit (coderef, will be passed args as hash).
#
# - rollback_tx_on_code_failure (bool, default 1).
#
# wrap() will also put current transaction record to $self->{_cur_tx}
sub _wrap {
    my ($self, %wargs) = @_;
    my $margs = $wargs{args} or die "BUG: args not passed to _wrap()";
    my @caller = caller(1);
    $log->tracef("[txm] -> %s(%s)", $caller[3], $margs);

    my $res;

    # initialize & check tx_id argument
    $margs->{tx_id} //= $self->{_tx_id};
    my $tx_id = $margs->{tx_id};
    return [400, "Please specify tx_id"]
        unless defined($tx_id) && length($tx_id);
    return [400, "Invalid tx_id, please use 1-200 characters only"]
        unless length($tx_id) <= 200;

    my $dbh = $self->{_dbh};
    $dbh->begin_work or return [532, "SQLite: Can't begin: ".$dbh->errstr];

    my $r = $dbh->selectrow_hashref(
        "SELECT ser_id, str_id, status FROM tx WHERE str_id=?", {}, $tx_id);
    $self->{_cur_tx} = $r;

    if ($wargs{hook_check_args}) {
        $res = $wargs{hook_check_args}->(%$margs);
        if ($res) {
            $dbh->rollback;
            $self->_rollback;
            return $res;
        }
    }

    if ($wargs{tx_status}) {
        if (!$r) {
            $dbh->rollback;
            return [484, "No such transaction"];
        }
        my $ok;
        # 'str' ~~ $aryref doesn't seem to work?
        if (ref($wargs{tx_status}) eq 'ARRAY') {
            $ok = $r->{status} ~~ @{$wargs{tx_status}};
        } else {
            $ok = $r->{status} ~~ $wargs{tx_status};
        }
        unless ($ok) {
            $dbh->rollback;
            return __resp_tx_status($r);
        }
    }

    if ($wargs{code}) {
        $res = $wargs{code}->(%$margs, _tx=>$r);
        # on error, rollback sqlite tx and skip the rest
        if ($res->[0] >= 400) {
            $dbh->rollback;
            if ($wargs{rollback_tx_on_code_failure} // 1) {
                $self->_rollback;
            }
            return $res;
        }
    }

    $dbh->commit or return [532, "SQLite: Can't commit: ".$dbh->errstr];

    if ($wargs{hook_after_commit}) {
        my $res2 = $wargs{hook_after_tx}->(%$margs);
        return $res2 if $res2;
    }

    return $res;
}

sub begin {
    my ($self, %args) = @_;
    $self->_wrap(
        args => \%args,
        code => sub {
            my $dbh = $self->{_dbh};
            my $r = $dbh->selectrow_hashref("SELECT * FROM tx WHERE str_id=?",
                                            {}, $args{tx_id});
            return [409, "Another transaction with that ID exists"] if $r;

            # XXX check for limits

            my $now = time();
            $dbh->do("INSERT INTO tx (str_id, owner_id, summary, status, ".
                         "ctime, mtime) VALUES (?,?,?,?, ?,?)", {},
                     $args{tx_id}, $args{client_token}//"", $args{summary}, "I",
                     $now, $now,
                 ) or return [532, "SQLite: Can't insert tx: ".$dbh->errstr];

            $self->_tx_id($args{tx_id});
            [200, "OK"];
        },
        rollback_tx_on_code_failure => 0,
    );
}

sub record_call {
    my ($self, %args) = @_;
    my @caller = caller(1);
    my ($f, $eargs);

    $self->_wrap(
        args => \%args,
        tx_status => "I",
        hook_check_args => sub {
            #return [400, "Please specify f"]         unless $args{f};
            return [400, "Please specify args"]      unless $args{args};

            my $f = $args{f} // $caller[3];
            # strip special arguments
            my %h;
            for (keys %{$args{args}}) {
                $h{$_} = $args{args}{$_} unless /^-/;
            }
            eval { $eargs = $json->encode(\%h) };
            return [400, "args data not serializable to JSON: $@"] if $@;

            return;
        },
        code => sub {
            my $dbh = $self->{_dbh};
            my $f = $args{f} // $caller[3];
            my $now = time();
            $dbh->do("INSERT INTO txcall (tx_ser_id, f, args) ".
                         "VALUES (?,?,?)", {},
                     $self->{_cur_tx}{ser_id}, $f, $eargs)
                or return [532, "SQLite: Can't insert txcall: ".$dbh->errstr];
            return [200, "OK", $dbh->last_insert_id('','','','')];
        },
    );
}

sub record_step {
    my ($self, %args) = @_;
    my ($eundo_step, $eredo_step);

    $self->_wrap(
        args => \%args,
        hook_check_args => sub {
            return [400, "Please specify call_id"] unless $args{call_id};

            return [400, "Please specify undo_step or redo_step"]
                unless $args{undo_step} || $args{redo_step};
            if ($args{undo_step}) {
                return [400, "undo_step must be array"]
                    unless ref($args{undo_step}) eq 'ARRAY';
                eval { $eundo_step = $json->encode($args{undo_step}) };
                return [400, "undo_step data not serializable to JSON: $@"]
                    if $@;
            }
            if ($args{redo_step}) {
                return [400, "redo_step must be array"]
                    unless ref($args{redo_step}) eq 'ARRAY';
                eval { $eredo_step = $json->encode($args{redo_step}) };
                return [400, "redo_step data not serializable to JSON: $@"]
                    if $@;
            }
            return;
        },
        tx_status => "I",
        code => sub {
            my $dbh = $self->{_dbh};

            my $rc = $dbh->selectrow_hashref(
                "SELECT id FROM txcall WHERE id=?", {}, $args{call_id});
            return [400, "call_id does not exist in database"] unless $rc;

            my $now = time();
            $dbh->do("INSERT INTO txstep (ctime, mtime, call_id, ".
                         "undo_step, redo_step) VALUES (?,?,?, ?,?)", {},
                     $now, $now, $args{call_id},
                     $eundo_step, $eredo_step)
                or return [532, "SQLite: Can't insert txstep: ".$dbh->errstr];
            [200, "OK", $dbh->last_insert_id('','','','')];
        },
    );
}

sub commit {
    my ($self, %args) = @_;
    $self->_wrap(
        args => \%args,
        tx_status => ["I", "A"],
        code => sub {
            my $dbh = $self->{_dbh};
            my $tx  = $self->{_cur_tx};
            if ($tx->{status} eq 'A') {
                my $res = $self->_rollback;
                return $res if $res;
                return [200, "Rolled back"];
            }
            my $now = time();
            $dbh->do("UPDATE tx SET mtime=?, status=? WHERE ser_id=?",
                     {}, $now, "C", $tx->{ser_id})
                or return [532, "SQLite: Can't update tx status to committed: ".
                               $dbh->errstr];
            [200, "OK"];
        },
    );
}

# dies on failure
sub _rollback {
    my ($self) = @_;
    my $tx = $self->{_cur_tx};
    die "BUG: _rollback called without transaction" unless $tx;
    $log->tracef("[txm] Rolling back tx #%d (%s) ...",
                 $tx->{ser_id}, $tx->{str_id});
    my $dbh = $self->{_dbh};

    eval {
        # XXX perform undo of all steps
        my $now = time();
        $dbh->do("UPDATE tx SET status='R', mtime=? WHERE ser_id=?", {},
                 $now, $tx->{ser_id});
    };
    if ($@) {
        my $now = time();
        $dbh->do("UPDATE tx SET status='U', mtime=? WHERE ser_id=?", {},
                 $tx->{ser_id});
        die $@;
    }
}

sub rollback {
    my ($self, %args) = @_;
    $self->_wrap(
        args => \%args,
        tx_status => ["I", "A"],
        code => sub {
            my $res = $self->_rollback;
            return $res if $res;
            [200, "Rolled back"];
        },
    );
}

sub prepare {
    [501, "Not implemented"];
}

sub savepoint {
    [501, "Not yet implemented"];
}

sub release_savepoint {
    [501, "Not yet implemented"];
}

sub list {
}

sub undo {
}

sub redo {
}

sub discard {
}

sub discard_all {
}

1;
# ABSTRACT: Transaction manager

=head1 SYNOPSIS

 # used by Perinci::Access::InProcess


=head1 DESCRIPTION

This class implements transaction and undo manager (TM).

It uses SQLite database to store transaction list and undo data as well as
transaction data directory to provide trash_dir/tmp_dir for functions that
require it.

It is used by L<Perinci::Access::InProcess>.


=head1 METHODS

=head2 new(%args) => OBJ

Create new object. Arguments:

=over 4

=item * data_dir => STR (default C<~/.perinci/.tx>)

=item * max_txs => INT (default 1000)

Limit maximum number of transactions maintained by the TM, including all rolled
back and committed transactions, since they are still recorded in the database.
The default is 1000.

Not yet implemented.

After this limit is reached, cleanup will be performed to delete rolled back
transactions, and after that committed transactions.

=item * max_open_txs => INT (default 100)

Limit maximum number of open (in progress, aborted, prepared) transactions. This
exclude resolved transactions (rolled back and committed). The default is no
limit.

Not yet implemented.

After this limit is reached, starting a new transaction will fail.

=item * max_committed_txs => INT (default 100)

Limit maximum number of committed transactions that is recorded by the database.
This is equal to the number of undo steps that are remembered.

After this limit is reached, cleanup will automatically be performed so that
the oldest committed transactions are purged.

Not yet implemented.

=item * max_open_age => INT

Limit the maximum age of open transactions (in seconds). If this limit is
reached, in progress transactions will automatically be purged because it times
out.

Not yet implemented.

=item * max_committed_age => INT

Limit the maximum age of committed transactions (in seconds). If this limit is
reached, the old transactions will start to be purged.

Not yet implemented.

=back

=head2 $tx->_tx_id($tx_id)

Set tx_id. This is just a convenience so that methods that require tx_id will
get the default value from here if tx_id not specified in arguments.

=head2 $tx->begin(%args) => RESP

Start a new transaction.

Arguments: tx_id (str, required, unless already supplied via _tx_id()), twopc
(bool, optional, must be false since distributed transaction is not supported),
summary (optional).

=head2 $tx->record_call(%args) => RESP

Arguments: tx_id, f (optional, function name, will be retrieved from caller(1)
if not specified), args (required, function arguments).

Return call ID in enveloped response.

=head2 $tx->record_step(%args) => RESP

Arguments: call_id, redo_step, undo_step (must specify at least one).

=head2 $tx->get_undo_steps(%args) => RESP

=head2 $tx->get_redo_steps(%args) => RESP

=head2 $tx->commit(%args) => RESP

=head2 $tx->rollback(%args) => RESP

=head2 $tx->prepare(%args) => RESP

Currently will return 501 (not implemented). This TM does not support
distributed transaction.

=head2 $tx->savepoint(%args) => RESP

=head2 $tx->release_savepoint(%args) => RESP

=head2 $tx->undo(%args) => RESP

=head2 $tx->redo(%args) => RESP

=head2 $tx->list(%args) => RESP

List transactions.

Arguments: B<detail> (bool, default 0, whether to return transaction records
instead of just a list of transaction ID's).

=head2 $tx->discard(%args) => RESP

Discard (forget) a committed transaction. The transaction will no longer be
undoable.

=head2 $tx->discard_all(%args) => RESP

Discard (forget) all committed transactions.

=head2 $tx->cleanup => RESP

=head2 $tx->recover => RESP


=head1 SEE ALSO

L<Riap::Transaction>

L<Perinci::Access::InProcess>

L<Rinci::function::Undo>

L<Rinci::function::Transaction>

=cut
