package Perinci::Tx::Manager;

use 5.010;
use strict;
use warnings;
use DBI;
use File::Flock;
use JSON;
use Log::Any '$log';
use Scalar::Util qw(blessed);
use Time::HiRes qw(time);

# VERSION

my $json = JSON->new->allow_nonref;

# note: to avoid confusion, whenever we mention 'transaction' (or tx for short)
# in the code, we must always specify whether it is a sqlite tx (sqltx) or a
# Rinci tx (Rtx).

# note: no method should die(), they all should return error message/response
# instead. this is because we are called by Perinci::Access::InProcess and in
# turn it is called by Perinci::Access::HTTP::Server without extra eval().

# note: we have not dealt with sqlite's rowid wraparound. since it's a 64-bit
# integer, we're pretty safe. we also usually rely on ctime first for sorting.

# new() should return an error string if failed
sub new {
    my ($class, %opts) = @_;
    return "Please supply pa object" unless blessed $opts{pa};
    return "pa object must be an instance of Perinci::Access::InProcess"
        unless $opts{pa}->isa("Perinci::Access::InProcess");

    my $obj = bless \%opts, $class;
    if (!$opts{data_dir}) {
        for ("$ENV{HOME}/.perinci", "$ENV{HOME}/.perinci/.tx") {
            unless (-d $_) {
                mkdir $_ or return "Can't mkdir $_: $!";
            }
        }
        $opts{data_dir} = "$ENV{HOME}/.perinci/.tx";
    }
    my $res = $obj->_init;
    return $res if $res;
    $obj;
}

sub _lock_db {
    my ($self, $shared) = @_;

    my $locked;
    my $secs = 0;
    for (1..5) {
        $locked = lock("$self->{_db_file}", $shared, "nonblocking");
        last if $locked;
        sleep    $_;
        $secs += $_;
    }
    return "Tx database is still locked by other process (probably recovery) ".
        "after $secs seconds, giving up" unless $locked;
    return;
}

sub _unlock_db {
    my ($self) = @_;

    unlock("$self->{_db_file}");
    return;
}

# return undef on success, or an error string on failure
sub _init {
    my ($self) = @_;
    my $data_dir = $self->{data_dir};
    $log->tracef("[txm] Initializing data dir %s ...", $data_dir);

    unless (-d "$self->{data_dir}/.trash") {
        mkdir "$self->{data_dir}/.trash"
            or return "Can't create .trash dir: $!";
    }
    unless (-d "$self->{data_dir}/.tmp") {
        mkdir "$self->{data_dir}/.tmp"
            or return "Can't create .tmp dir: $!";
    }

    $self->{_db_file} = "$data_dir/tx.db";

    (-d $data_dir)
        or return "Transaction data dir ($data_dir) doesn't exist or not a dir";
    my $dbh = DBI->connect("dbi:SQLite:dbname=$self->{_db_file}", undef, undef,
                           {RaiseError=>0});

    # init database
    $dbh->do(<<_) or return "Can't init tx db: create tx: ". $dbh->errstr;
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
    $dbh->do(<<_) or return "Can't init tx db: create call: ". $dbh->errstr;
CREATE TABLE IF NOT EXISTS call (
    tx_ser_id INTEGER NOT NULL, -- refers tx(ser_id)
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ctime REAL NOT NULL,
    f TEXT NOT NULL,
    args TEXT NOT NULL
)
_
    $dbh->do(<<_) or return "Can't init tx db: create undo_step: ".$dbh->errstr;
CREATE TABLE IF NOT EXISTS undo_step (
    call_id INT NOT NULL, -- refers txcall(id)
    -- seq INTEGER NOT NULL, -- uses ROWID instead, sqlite-specific
    name TEXT, -- for named savepoint
    ctime REAL NOT NULL,
    data BLOB NOT NULL
)
_
    $dbh->do(<<_) or return "Can't init tx db: create redo_step: ".$dbh->errstr;
CREATE TABLE IF NOT EXISTS redo_step (
    call_id INT NOT NULL, -- refers txcall(id)
    -- seq INTEGER NOT NULL, -- uses ROWID instead, sqlite-specific
    ctime REAL NOT NULL,
    data BLOB NOT NULL
)
_

    $self->{_dbh} = $dbh;
    $log->tracef("[txm] Data dir initialization finished");
    $self->_recover;
}

sub get_trash_dir {
    my ($self) = @_;
    my $tx = $self->{_cur_tx};
    return [412, "No current transaction, won't create trash dir"] unless $tx;
    my $d = "$self->{data_dir}/.trash/$tx->{ser_id}";
    unless (-d $d) {
        mkdir $d or return [500, "Can't mkdir $d: $!"];
    }
    [200, "OK", $d];
}

sub get_tmp_dir {
    my ($self) = @_;
    my $tx = $self->{_cur_tx};
    return [412, "No current transaction, won't create tmp dir"] unless $tx;
    my $d = "$self->{data_dir}/.tmp/$tx->{ser_id}";
    unless (-d $d) {
        mkdir $d or return [500, "Can't mkdir $d: $!"];
    }
    [200, "OK", $d];
}

# return an enveloped response
sub _get_func_and_meta {
    my ($self, $func) = @_;

    my ($module, $leaf) = $func =~ /(.+)::(.+)/
        or return [400, "Not a valid fully qualified function name: $func"];
    my $res = $self->{pa}->_get_code_and_meta({
        -module=>$module, -leaf=>$leaf, -type=>'function'});
    $res;
}

sub _rollback_dbh {
    my $self = shift;
    $self->{_dbh}->rollback if $self->{_in_sqltx};
    $self->{_in_sqltx} = 0;
}

# return undef on success, or an error string on failure
sub _rollback {
    my ($self) = @_;

    # prevent endless loop, since we call functions when doing rollback, and
    # functions might call $tx->rollback too upon failure.
    return if $self->{_in_rollback};
    local $self->{_in_rollback} = 1;

    my $tx = $self->{_cur_tx};
    unless ($tx) {
        $log->warnf("[txm] _rollback() called w/o transaction, probably a bug");
        return;
    }

    $log->tracef("[txm] Rolling back tx #%d (%s) ...",
                 $tx->{ser_id}, $tx->{str_id});
    my $dbh = $self->{_dbh};

    $self->_rollback_dbh;

    # we're now in sqlite autocommit mode, we use this mode for the following
    # reasons: 1) after we set Rtx status to 'A', we need other clients to see
    # so they do not try to add steps to it. also after that, each function call
    # will involve record_call() and record_step() that are all separate
    # sqltx's.

    my (@calls, $i_call, $call);
    eval {
        my $now = time();
        $dbh->do("UPDATE tx SET status='A', mtime=? WHERE ser_id=? ".
                     "AND status IN ('I')",
                 {}, $now, $tx->{ser_id})
            or die "sqlite: Can't update tx status: ".$dbh->errstr;

        # for safety, check once again if Rtx status is indeed aborted
        my @r = $dbh->selectrow_array("SELECT status FROM tx WHERE ser_id=?",
                                      {}, $tx->{ser_id});
        die "Status incorrect ($r[0])" unless $r[0] eq 'A';

        my $rows = $dbh->selectall_arrayref(
            "SELECT id, f, args FROM call WHERE tx_ser_id=? ORDER BY ctime, id",
            {}, $tx->{ser_id});
        for (@$rows) {
            push @calls, {id=>$_->[0], f=>$_->[1],
                          args=>$json->decode($_->[2])};
        }

        $i_call = 0;
        for (@calls) {
            $call = $_;
            $i_call++;
            $log->tracef("[txm] [rollback] Performing call %d/%d: %s(%s) ...",
                         $i_call, scalar(@calls), $call->{f}, $call->{args});
            my $res = $self->_get_func_and_meta($call->{f});
            die "Can't get func: $res->[0] - $res->[1]" unless $res->[0] == 200;
            my ($func, $meta) = @{$res->[2]};
            # XXX check meta whether func supports undo + transactional?
            $res = $func->(
                %{$call->{args}},
                -undo_action=>'undo',
                -tx_manager=>$self, -tx_call_id=>$call->{id},
                # the following special arg is just informative, so function
                # knows and can act more robust if it needs to
                -tx_action=>'rollback',
            );
            $log->tracef("[txm] [rollback] Call result: %s", $res);
            die "Call failed: $res->[0] - $res->[1]"
                unless $res->[0] == 200 || $res->[0] == 304;
        }
        $dbh->do("UPDATE tx SET status='R', mtime=? WHERE ser_id=?", {},
                 $tx->{ser_id})
            or die "sqlite: Can't set tx status to R: ".$dbh->errstr;

    };
    my $eval_err = $@;
    if ($eval_err) {
        # if failed during rolling back, we don't know what else to do. we set
        # Rtx status to U (unknown) and ignore it.
        my $now = time();
        $dbh->do("UPDATE tx SET status='U', mtime=? ".
                     "WHERE ser_id=? AND status='A'",
                 {}, $now, $tx->{ser_id});
        return join("",
                    ($i_call ? "Call #$i_call/".scalar(@calls).
                         " (func $call->{f}): " : ""),
                    $eval_err);
    }

    return;
}

# return undef on success, or an error string on failure
sub _recover {
    my ($self) = @_;
    $log->tracef("[txm] Performing recovery ...");

    # there should only one recovery or cleanup process running
    my $res = $self->_lock_db(undef);
    return $res if $res;

    my $dbh = $self->{_dbh};
    my $sth = $dbh->prepare(
        "SELECT * FROM tx WHERE status IN ('A', 'u', 'd') ".
            "ORDER BY ctime DESC",
    );
    $sth->execute or return "sqlite: Can't select tx: ".$dbh->errstr;

    while (my $row = $sth->fetchrow_hashref) {
        $self->{_cur_tx} = $row;
        $self->_rollback;
    }

    $self->_unlock_db;

    $log->tracef("[txm] Recovery finished");
    return;
}

# similar to recover, except only rolls back ...?
sub _cleanup {
    # clean old tx's tmp_dir & trash_dir.
}

# store _tx_id attribute so method calls don't have to specify tx_id. this is
# just a convenience.
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
                                "unknown";
    [480, "tx #$r->{ser_id}: Incorrect status, status is $s ($ss)"];
}

# all methods have some common code, e.g. database file locking, starting sqltx,
# checking Rtx status, etc. hence refactored into _wrap(). arguments:
#
# - args* (hashref, arguments to method)
#
# - tx_status (str/array, if set then it means method requires Rtx to exist and
#   have a certain status(es)
#
# - code (coderef, main method code, will be passed args as hash)
#
# - hook_check_args (coderef, will be passed args as hash)
#
# - hook_after_commit (coderef, will be passed args as hash).
#
# - rollback_tx_on_code_failure (bool, default 1).
#
# - update_tx_mtime (bool, whether to update tx mtime on success of code,
#   default 0).
#
# wrap() will also put current Rtx record to $self->{_cur_tx}
sub _wrap {
    my ($self, %wargs) = @_;
    my $margs = $wargs{args}
        or return [500, "BUG: args not passed to _wrap()"];
    my @caller = caller(1);
    $log->tracef("[txm] -> %s(%s)", $caller[3],
                 { map {$_=>$margs->{$_}}
                       grep {!/^-/ && !/^args$/} keys %$margs });

    # so we wait/bail when db is in recovery
    $self->_lock_db("shared");

    $self->{_now} = time();
    my $res;

    # initialize & check tx_id argument
    $margs->{tx_id} //= $self->{_tx_id};
    my $tx_id = $margs->{tx_id};
    return [400, "Please specify tx_id"]
        unless defined($tx_id) && length($tx_id);
    return [400, "Invalid tx_id, please use 1-200 characters only"]
        unless length($tx_id) <= 200;

    my $dbh = $self->{_dbh};

    $res = $self->_cleanup;
    return [532, "Can't succesfully cleanup: $res"] if $res;

    # we need to begin sqltx here so that client's actions like rollback() and
    # commit() are indeed atomic and do not interfere with other clients'.
    $dbh->begin_work or return [532, "db: Can't begin: ".$dbh->errstr];

    # DBI/DBD::SQLite currently does not support checking whether we are in an
    # active sqltx, except $dbh->{BegunWork} which is undocumented. we use our
    # own flag here.
    local $self->{_in_sqltx} = 1;

    my $cur_tx = $dbh->selectrow_hashref(
        "SELECT * FROM tx WHERE str_id=?", {}, $tx_id);
    $self->{_cur_tx} = $cur_tx;

    if ($wargs{hook_check_args}) {
        $res = $wargs{hook_check_args}->(%$margs);
        if ($res) {
            $self->_rollback;
            return $res;
        }
    }

    if ($wargs{tx_status}) {
        if (!$cur_tx) {
            $self->_rollback_dbh;
            return [484, "No such transaction"];
        }
        my $ok;
        # 'str' ~~ $aryref doesn't seem to work?
        if (ref($wargs{tx_status}) eq 'ARRAY') {
            $ok = $cur_tx->{status} ~~ @{$wargs{tx_status}};
        } else {
            $ok = $cur_tx->{status} ~~ $wargs{tx_status};
        }
        unless ($ok) {
            $self->_rollback_dbh;
            return __resp_tx_status($cur_tx);
        }
    }

    if ($wargs{code}) {
        $res = $wargs{code}->(%$margs, _tx=>$cur_tx);
        # on error, rollback sqlite tx and skip the rest
        if ($res->[0] >= 400) {
            $self->_rollback_dbh;
            if ($wargs{rollback_tx_on_code_failure} // 1) {
                $self->_rollback;
            }
            return $res;
        }
    }

    if ($wargs{update_tx_mtime}) {
        $dbh->do("UPDATE tx SET mtime=? WHERE ser_id=?", {},
             $self->{_now}, $cur_tx->{ser_id});
    }

    $dbh->commit or return [532, "db: Can't commit: ".$dbh->errstr];
    $self->{_in_sqltx} = 0;

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

            $dbh->do("INSERT INTO tx (str_id, owner_id, summary, status, ".
                         "ctime, mtime) VALUES (?,?,?,?, ?,?)", {},
                     $args{tx_id}, $args{client_token}//"", $args{summary}, "I",
                     $self->{_now}, $self->{_now},
                 ) or return [532, "db: Can't insert tx: ".$dbh->errstr];

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
            $dbh->do("INSERT INTO call (tx_ser_id, ctime, f, args) ".
                         "VALUES (?,?,?,?)", {},
                     $self->{_cur_tx}{ser_id}, $self->{_now}, $f, $eargs)
                or return [532, "db: Can't insert call: ".$dbh->errstr];
            return [200, "OK", $dbh->last_insert_id('','','','')];
        },
        update_tx_mtime => 1,
    );
}

sub record_undo_step {
    my $self = shift;
    $self->_record_step('undo', @_);
}

sub record_redo_step {
    my $self = shift;
    $self->_record_step('redo', @_);
}

sub _record_step {
    my ($self, $which, %args) = @_;
    die "BUG: which must be undo/redo" unless $which =~ /\A(un|re)do\z/;
    my $data;

    $self->_wrap(
        args => \%args,
        hook_check_args => sub {
            $args{call_id} or return [400, "Please specify call_id"];
            $data = $args{data} or return [400, "Please specify data"];
            ref($data) eq 'ARRAY' or return [400, "data must be array"];
            eval { $data = $json->encode($data) };
            $@ and return [400, "step data not serializable to JSON: $@"];
            return;
        },
        tx_status => "I",
        code => sub {
            my $dbh = $self->{_dbh};

            my $rc = $dbh->selectrow_hashref(
                "SELECT id FROM call WHERE id=?", {}, $args{call_id});
            return [400, "call_id does not exist in database"] unless $rc;

            $dbh->do("INSERT INTO ${which}_step (ctime, call_id, data) VALUES ".
                         "(?,?,?)", {}, $self->{_now}, $args{call_id}, $data)
                or return [532, "db: Can't insert step: ".$dbh->errstr];
            [200, "OK", $dbh->last_insert_id('','','','')];
        },
        update_tx_mtime => 1,
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
            $dbh->do("UPDATE tx SET mtime=?, status=? WHERE ser_id=?",
                     {}, $self->{_now}, "C", $tx->{ser_id})
                or return [532, "db: Can't update tx status to committed: ".
                               $dbh->errstr];
            [200, "OK"];
        },
    );
}

sub rollback {
    my ($self, %args) = @_;
    $self->_wrap(
        args => \%args,
        tx_status => ["I", "A"],
        code => sub {
            my $res = $self->_rollback;
            return [532, "Can't rollback: $res"] if $res;
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

This class implements transaction and undo manager (TM), as specified by
L<Rinci::function::Transaction> and L<Riap::Transaction>. It is meant to be
instantiated by L<Perinci::Access::InProcess>, but will also be passed to
transactional functions to save undo/redo data.

It uses SQLite database to store transaction list and undo/redo data as well as
transaction data directory to provide trash_dir/tmp_dir for functions that
require it.


=head1 METHODS

=head2 new(%args) => OBJ

Create new object. Arguments:

=over 4

=item * pa => OBJ

Perinci::Access::InProcess object. This is required by Perinci::Tx::Manager to
load/get functions when it wants to perform undo/redo/recovery.
Perinci::Access::InProcess conveniently require() the Perl modules and wraps the
functions.

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
(bool, optional, currently must be false since distributed transaction is not
yet supported), summary (optional).

TM will create an entry for this transaction in its database.

=head2 $tx->record_call(%args) => RESP

Record a function call. This method needs to be called before function does any
step.

Arguments: tx_id, f (optional, function name, will be retrieved from caller(1)
if not specified, assuming the call is from the function itself), args
(required, function arguments).

TM will create an entry for this call in its database.

Return call ID in enveloped response.

=head2 $tx->record_undo_step(%args) => RESP

Record an undo step. This method needs to be called before performing a step.

Arguments: tx_id, call_id, data (an array).

=head2 $tx->record_redo_step(%args) => RESP

Record a redo step. This method needs to be called before performing an undo
step.

Arguments: tx_id, call_id, data (an array).

=head2 $tx->get_undo_steps(%args) => RESP

Will return (in enveloped response) an array of undo steps, e.g. [200, "OK",
[["step1"], ["step2", "arg"], ...]] for the particular call.

Arguments: tx_id, call_id.

=head2 $tx->get_redo_steps(%args) => RESP

Will return (in enveloped response) an array of redo steps, e.g. [200, "OK",
[["step2"], ["step1"], ...]] for the particular call.

Arguments: tx_id, call_id.

=head2 $tx->commit(%args) => RESP

Arguments: tx_id

=head2 $tx->rollback(%args) => RESP

Arguments: tx_id, sp (optional, savepoint name to rollback to a specific
savepoint only).

Currently rolling back to a savepoint is not implemented.

=head2 $tx->prepare(%args) => RESP

Currently will return 501 (not implemented). This TM does not support
distributed transaction.

Arguments: tx_id

=head2 $tx->savepoint(%args) => RESP

Arguments: tx_id, sp (savepoint name).

Currently not implemented.

=head2 $tx->release_savepoint(%args) => RESP

Arguments: tx_id, sp (savepoint name).

Currently not implemented.

=head2 $tx->undo(%args) => RESP

Arguments: tx_id

=head2 $tx->redo(%args) => RESP

Arguments: tx_id

=head2 $tx->list(%args) => RESP

List transactions. Return an array of results sorted by creation date (in
ascending order).

Arguments: B<detail> (bool, default 0, whether to return transaction records
instead of just a list of transaction ID's).

=head2 $tx->discard(%args) => RESP

Discard (forget) a committed transaction. The transaction will no longer be
undoable.

Arguments: tx_id

=head2 $tx->discard_all(%args) => RESP

Discard (forget) all committed transactions.


=head1 SEE ALSO

L<Riap::Transaction>

L<Perinci::Access::InProcess>

L<Rinci::function::Undo>

L<Rinci::function::Transaction>

=cut
