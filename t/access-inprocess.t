#!perl

use 5.010;
use strict;
use warnings;
use FindBin '$Bin';
use lib "$Bin/lib";

use Test::More 0.96;

use File::chdir;
use File::Temp qw(tempdir);
use Perinci::Access::InProcess;
use Perinci::Tx::Manager;
use Scalar::Util qw(blessed);

my $pa_cached;
my $pa;

package Foo;

package Bar;
our $VERSION = 0.123;

package Test::Perinci::Access::InProcess;
our %SPEC;

$SPEC{':package'} = {v=>1.1, summary=>"A package"};

$SPEC{'$v1'} = {v=>1.1, summary=>"A variable"};
our $VERSION = 1.2;
our $v1 = 123;

$SPEC{f1} = {
    v => 1.1,
    summary => "An example function",
    args => {
        a1 => {schema=>"int"},
    },
    result => {
        schema => 'int*',
    },
    _internal1=>1,
};
sub f1 { [200, "OK", 2] }

$SPEC{f2} = {v=>1.1};
sub f2 { [200, "OK", 3] }

package main;

# test after_load first, for first time loading of
# Perinci::Examples

my $var = 12;
test_request(
    name => 'opt: after_load called',
    object_opts=>{after_load=>sub {$var++}},
    req => [call => '/Perinci/Examples/noop'],
    status => 200,
    posttest => sub {
        is($var, 13, "\$var incremented");
    },
);
test_request(
    name => 'opt: after_load not called twice',
    object_opts=>{after_load=>sub {$var++}},
    req => [call => '/Perinci/Examples/noop'],
    status => 200,
    posttest => sub {
        is($var, 13, "\$var not incremented again");
    },
);
# XXX test trapping of die in after_load

test_request(
    name => 'unknown action',
    req => [zzz => "/"],
    status => 502,
);
test_request(
    name => 'unknown action for a type',
    req => [call => "/"],
    status => 502,
);
test_request(
    req => [info => "/"],
    status => 200,
    result => { type => "package", uri => "/", v => 1.1 },
);
test_request(
    name => 'pl: uri scheme',
    req => [info => "pl:/"],
    status => 200,
    result => { type => "package", uri => "pl:/", v => 1.1 },
);
test_request(
    name => 'meta on / doesn\'t work yet',
    req => [meta => "pl:/"],
    status => 404,
);
test_request(
    name => 'meta on package',
    req => [meta => "/Test/Perinci/Access/InProcess/"],
    status => 200,
    result => { summary => "A package",
                v => 1.1,
                entity_version => $Test::Perinci::Access::InProcess::VERSION },
);
test_request(
    name => 'meta on package (default meta)',
    req => [meta => "/Foo/"],
    status => 200,
    result => { v => 1.1 },
);
test_request(
    name => 'meta on package (default meta + version)',
    req => [meta => "/Bar/"],
    status => 200,
    result => { v => 1.1, entity_version => 0.123 },
);
test_request(
    name => 'ending slash matters',
    req => [meta => "/Perinci/Examples"],
    status => 404,
);

test_request(
    name => 'meta on function',
    req => [meta => "/Perinci/Examples/test_completion"],
    status => 200,
    posttest => sub {},
);

test_request(
    name => 'actions on package',
    req => [actions => "/Perinci/Examples/"],
    status => 200,
    result => [qw/actions begin_tx child_metas commit_tx discard_all_txs discard_tx info list list_txs meta redo release_tx_savepoint rollback_tx savepoint_tx undo/],
);
test_request(
    name => 'actions on function',
    req => [actions => "/Perinci/Examples/gen_array"],
    status => 200,
    result => [qw/actions begin_tx call commit_tx complete_arg_val discard_all_txs discard_tx info list_txs meta redo release_tx_savepoint rollback_tx savepoint_tx undo/],
);
test_request(
    name => 'actions on variable',
    req => [actions => "/Perinci/Examples/\$Var1"],
    status => 200,
    result => [qw/actions begin_tx commit_tx discard_all_txs discard_tx get info list_txs meta redo release_tx_savepoint rollback_tx savepoint_tx undo/],
);
# XXX actions: detail

test_request(
    name => 'list action 1',
    req => [list => "/Perinci/Examples/"],
    status => 200,
    posttest => sub {
        my ($res) = @_;
        ok(@{$res->[2]} > 5, "number of results"); # safe number
        ok(!ref($res->[2][0]), "record is scalar");
    },
);
test_request(
    name => 'list action: detail',
    req => [list => "/Perinci/Examples/", {detail=>1}],
    status => 200,
    posttest => sub {
        my ($res) = @_;
        ok(@{$res->[2]} > 5, "number of results");
        is(ref($res->[2][0]), 'HASH', "record is hash");
    },
);
# XXX list: recursive
# XXX list: type

test_request(
    name => 'call 1',
    req => [call => "/Perinci/Examples/gen_array", {args=>{len=>1}}],
    status => 200,
    result => [1],
);
test_request(
    name => 'call: die trapped by wrapper',
    req => [call => "/Perinci/Examples/dies"],
    status => 500,
);
# XXX call: invalid args

test_request(
    name => 'complete_arg_val: missing arg',
    req => [complete_arg_val => "/Perinci/Examples/test_completion", {}],
    status => 400,
);
test_request(
    name => 'complete: str\'s in',
    req => [complete_arg_val => "/Perinci/Examples/test_completion",
            {arg=>"s1", word=>"r"}],
    status => 200,
    result => ["red date", "red grape"],
);
test_request(
    name => 'complete: int\'s min+max',
    req => [complete_arg_val => "/Perinci/Examples/test_completion",
            {arg=>"i1", word=>"1"}],
    status => 200,
    result => [1, 10..19],
);
test_request(
    name => 'complete: int\'s min+max range too big = not completed',
    req => [complete_arg_val => "/Perinci/Examples/test_completion",
            {arg=>"i2", word=>"1"}],
    status => 200,
    result => [],
);
test_request(
    name => 'complete: sub',
    req => [complete_arg_val => "/Perinci/Examples/test_completion",
            {arg=>"s2", word=>"z"}],
    status => 200,
    result => ["za".."zz"],
);
test_request(
    name => 'complete: sub die trapped',
    req => [complete_arg_val => "/Perinci/Examples/test_completion",
            {arg=>"s3"}],
    status => 500,
);

test_request(
    name => 'opt: load=1 (will still try accessing the package anyway)',
    req => [call => '/Test/Perinci/Access/InProcess/f1'],
    status => 200,
);

test_request(
    name => 'opt: load=0',
    object_opts=>{load=>0},
    req => [call => '/Test/Perinci/Access/InProcess/f1'],
    status => 200,
    result => 2,
);
test_request(
    name => 'schema in metadata is normalized',
    object_opts=>{load=>0},
    req => [meta => '/Test/Perinci/Access/InProcess/f1'],
    status => 200,
    result => {
        v => 1.1,
        summary => "An example function",
        args => {
            a1 => {schema=>["int"=>{}]},
        },
        result => {
            schema => ['int'=>{req=>1}],
        },
        result_naked=>0,
        args_as=>'hash',
        entity_version=>1.2,
    },
);

test_request(
    name => 'child_metas action',
    object_opts=>{load=>0},
    req => [child_metas => '/Test/Perinci/Access/InProcess/'],
    status => 200,
    result => {
        'pl:/Test/Perinci/Access/InProcess/$v1' =>
            {
                v=>1.1,
                summary=>"A variable",
                entity_version=>1.2,
            },
        'pl:/Test/Perinci/Access/InProcess/f1' =>
            {
                v=>1.1,
                summary => "An example function",
                args => {
                    a1 => {schema=>["int"=>{}]},
                },
                result => {
                    schema => ['int'=>{req=>1}],
                },
                args_as => 'hash', result_naked => 0,
                entity_version=>1.2,
            },
        'pl:/Test/Perinci/Access/InProcess/f2' =>
            {
                v=>1.1,
                args_as => 'hash', result_naked => 0,
                entity_version=>1.2,
            },
    },
);

test_request(
    name => 'opt: extra_wrapper_args',
    object_opts=>{extra_wrapper_args=>{remove_internal_properties=>0}},
    req => [meta => '/Test/Perinci/Access/InProcess/f1'],
    status => 200,
    posttest => sub {
        my ($res) = @_;
        my $meta = $res->[2];
        ok($meta->{_internal1}, "remove_internal_properties passed to wrapper")
            or diag explain $res;
    },
);
test_request(
    name => 'opt: extra_wrapper_convert',
    object_opts=>{extra_wrapper_convert=>{default_lang=>"id_ID"}},
    req => [meta => '/Test/Perinci/Access/InProcess/f1'],
    status => 200,
    posttest => sub {
        my ($res) = @_;
        my $meta = $res->[2];
        ok($meta->{"summary.alt.lang.en_US"},
           "default_lang convert passed to wrapper (1)")
            or diag explain $res;
        ok(!$meta->{summary},
           "default_lang convert passed to wrapper (2)")
            or diag explain $res;
    },
);

subtest "transaction" => sub {
    # yeah, symlink() is not really necessary, but at the time of writing this
    # test script, only Setup::File::Symlink has been converted to use
    # Riap::Transaction.
    plan skip_all => "symlink() not available"
        unless eval { symlink "", ""; 1 };

    test_request(
        name => 'must be activated with use_tx',
        req => [begin_tx=>"/", {tx_id=>"tx1"}],
        status => 501,
    );

    my $txm;
    my $tmp_dir = tempdir(CLEANUP=>1);
    $CWD = $tmp_dir;
    my $tx_dir  = "$tmp_dir/.tx";
    diag "tx dir is $tx_dir";
    $pa_cached = Perinci::Access::InProcess->new(
        use_tx=>1,
        custom_tx_manager => sub {
            my $self = shift;
            $txm //= Perinci::Tx::Manager->new(
                data_dir => $tx_dir, pa => $self);
            die $txm unless blessed($txm);
            $txm;
        });

    subtest 'request to unknown tx = fail' => sub {
        test_request(
            req => [call=>"/Setup/File/Symlink/setup_symlink",
                    {tx_id=>"unknown1",
                     args=>{symlink=>"$tmp_dir/s1", target=>"t1"}}],
            status => 484,
        );
    };

    subtest 'successful transaction' => sub {
        test_request(
            req => [begin_tx=>"/", {tx_id=>"s1"}],
            status => 200,
            posttest => sub {
                my $tres = $txm->list(detail=>1);
                is($tres->[0], 200, "txm->list() success");
                is(scalar(@{$tres->[2]}), 1, "There is 1 transaction");
                is($tres->[2][0]{tx_status}, "i", "Transaction status is i");
            },
        );
        test_request(
            req => [call=>"/Setup/File/Symlink/setup_symlink",
                    {tx_id=>"s1",
                     args=>{symlink=>"$tmp_dir/s1-l1", target=>"t1"}}],
            status => 200,
            posttest => sub {
                my ($res) = @_;
                my $tres = $txm->list(detail=>1, tx_id=>"s1");
                is($tres->[2][0]{tx_status}, "i", "Transaction status is i");

                ok(!$res->[3]{undo_data},
                   "undo_data result metadata is suppressed");
            },
        );
        test_request(
            req => [call=>"/Setup/File/Symlink/setup_symlink",
                    {tx_id=>"s1",
                     args=>{symlink=>"$tmp_dir/s1-l2", target=>"t1"}}],
            status => 200,
            posttest => sub {
                my $tres = $txm->list(detail=>1, tx_id=>"s1");
                is($tres->[2][0]{tx_status}, "i", "Transaction status is i");
            },
        );
        test_request(
            req => [commit_tx=>"/", {tx_id=>"s1"}],
            status => 200,
            posttest => sub {
                my $tres = $txm->list(detail=>1, tx_id=>"s1");
                is($tres->[2][0]{tx_status}, "C", "Transaction status is C");

                ok((-l "$tmp_dir/s1-l1"), "final state of s1 (l1) = done");
                ok((-l "$tmp_dir/s1-l2"), "final state of s1 (l2) = done");
            },
        );
    };
    # txs: s1(C)

    subtest 'cannot begin transaction with the same name as existing' => sub {
        test_request(
            req => [begin_tx=>"/", {tx_id=>"s1"}],
            status => 409,
            posttest => sub {
                my $tres = $txm->list(detail=>1, tx_id=>"s1");
                is($tres->[2][0]{tx_status}, "C", "Transaction status is C");
            },
        );
    };

    subtest 'failed invocation = rolls back' => sub {
        test_request(
            req => [begin_tx=>"/", {tx_id=>"f1"}],
            status => 200,
        );
        test_request(
            req => [call=>"/Setup/File/Symlink/setup_symlink",
                    {tx_id=>"f1", args=>{}}],
            status => 400,
            posttest => sub {
                my $tres = $txm->list(detail=>1, tx_id=>"f1");
                is($tres->[2][0]{tx_status}, "R", "Transaction status is R");
            },
        );
    };
    # txs: s1(C), f1(R)

    subtest 'other qualified functions: pure, dry_run' => sub {
        test_request(
            req => [begin_tx=>"/", {tx_id=>"s2"}],
            status => 200,
        );
        test_request(
            name => 'pure',
            req => [call=>"/Perinci/Examples/noop",
                    {tx_id=>"f2", args=>{}}],
            status => 200,
        );
        test_request(
            name => 'dry_run',
            req => [call=>"/Setup/File/Symlink/setup_symlink",
                    {tx_id=>"s2",
                     args=>{symlink=>"$tmp_dir/s2-l1",
                            target=>"t1", -dry_run=>1}}],
            status => 200,
        );
        test_request(
            req => [commit_tx=>"/",
                    {tx_id=>"s2"}],
            status => 200,
            posttest => sub {
                my $tres = $txm->list(detail=>1, tx_id=>"s2");
                is($tres->[2][0]{tx_status}, "C", "Transaction status is C");
            },
        );
    };
    # txs: s1(C), f1(R), s2(C)

    subtest 'invoking unqualified function = rolls back' => sub {
        test_request(
            req => [begin_tx=>"/", {tx_id=>"f2"}],
            status => 200,
        );
        test_request(
            req => [call=>"/Perinci/Examples/delay",
                    {tx_id=>"f2", args=>{n=>0}}],
            status => 412,
            posttest => sub {
                my $tres = $txm->list(detail=>1, tx_id=>"f2");
                is($tres->[2][0]{tx_status}, "R", "Transaction status is R");
            },
        );
    };
    # txs: s1(C), f1(R), s2(C), f2(R)

    subtest 'rollback' => sub {
        test_request(
            req => [begin_tx=>"/", {tx_id=>"r1"}],
            status => 200,
        );
        test_request(
            req => [call=>"/Setup/File/Symlink/setup_symlink",
                    {tx_id=>"r1",
                     args=>{symlink=>"$tmp_dir/r1-l1", target=>"t1"}}],
            status => 200,
        );
        test_request(
            req => [call=>"/Setup/File/Symlink/setup_symlink",
                    {tx_id=>"r1",
                     args=>{symlink=>"$tmp_dir/r1-l2", target=>"t1"}}],
            status => 200,
        );
        test_request(
            req => [call=>"/Setup/File/Symlink/setup_symlink",
                    {args=>{-undo_trash_dir=>"$tmp_dir/.tx/.trash",
                            symlink=>"$tmp_dir/r1-l3", target=>"t1"}}],
            status => 200,
        );
        test_request(
            req => [rollback_tx=>"/", {tx_id=>"r1"}],
            status => 200,
            posttest => sub {
                my $tres = $txm->list(detail=>1, tx_id=>"r1");
                is($tres->[2][0]{tx_status}, "R", "Transaction status is R");

                ok(!(-l "$tmp_dir/r1-l1"), "final state of r1 (l1) = undone");
                ok(!(-l "$tmp_dir/r1-l2"), "final state of r1 (l2) = undone");

                # call without tx_id is outside of tx
                ok((-l "$tmp_dir/r1-l3"),
                   "final state of r1 (l3) = done (outside tx)");
            },
        );
    };
    # txs: s1(C), f1(R), s2(C), f2(R), r1(R)

    subtest 'list_txs' => sub {
        test_request(
            name => 'detail=0',
            req => [list_txs=>"/", {}],
            status => 200,
            posttest => sub {
                my ($res) = @_;
                is(scalar(@{$res->[2]}), 5, "num");
                ok(!ref($res->[2][0]), "no detail");
            },
        );
        test_request(
            name => 'tx_id',
            req => [list_txs=>"/", {tx_id=>'s1'}],
            status => 200,
            posttest => sub {
                my ($res) = @_;
                is(scalar(@{$res->[2]}), 1, "num");
            },
        );
        test_request(
            name => 'tx_status',
            req => [list_txs=>"/", {tx_status=>'R'}],
            status => 200,
            posttest => sub {
                my ($res) = @_;
                is(scalar(@{$res->[2]}), 3, "num");
            },
        );
    };

    subtest 'cannot rollback transactions with status C' => sub {
        test_request(
            req => [rollback_tx=>"/", {tx_id=>"s1"}],
            status => 480,
            posttest => sub {
                my $tres = $txm->list(detail=>1, tx_id=>"s1");
                is($tres->[2][0]{tx_status}, "C", "Transaction status is C");

                ok((-l "$tmp_dir/s1-l1"), "final state of s1 (l1) = done");
                ok((-l "$tmp_dir/s1-l2"), "final state of s1 (l2) = done");
            },
        );
    };
    subtest 'cannot rollback transactions with status R' => sub {
        test_request(
            req => [rollback_tx=>"/", {tx_id=>"r1"}],
            status => 480,
            posttest => sub {
                my $tres = $txm->list(detail=>1, tx_id=>"r1");
                is($tres->[2][0]{tx_status}, "R", "Transaction status is R");

                ok(!(-l "$tmp_dir/r1-l1"), "final state of r1 (l1) = undone");
                ok(!(-l "$tmp_dir/r1-l2"), "final state of r1 (l2) = undone");
            },
        );
    };

    # TODO cannot rollback transactions with status U, X

    subtest 'undo' => sub {
        test_request(
            req => [undo=>"/", {tx_id=>"s1"}],
            status => 200,
            posttest => sub {
                my $tres = $txm->list(detail=>1, tx_id=>"s1");
                is($tres->[2][0]{tx_status}, "U", "Transaction status is U");

                ok(!(-l "$tmp_dir/s1-l1"), "final state of s1 (l1) = undone");
                ok(!(-l "$tmp_dir/s1-l2"), "final state of s1 (l2) = undone");
            },
        );
    };
    # txs: s1(U), f1(R), s2(C), f2(R), r1(R)

    # TODO cannot undo transactions in states i, U, X, R, ...

    subtest 'redo' => sub {
        test_request(
            req => [redo=>"/", {tx_id=>"s1"}],
            status => 200,
            posttest => sub {
                my $tres = $txm->list(detail=>1, tx_id=>"s1");
                is($tres->[2][0]{tx_status}, "C", "Transaction status is C");

                ok((-l "$tmp_dir/s1-l1"), "final state of s1 (l1) = done");
                ok((-l "$tmp_dir/s1-l2"), "final state of s1 (l2) = done");
            },
        );
    };
    # txs: s1(C), f1(R), s2(C), f2(R), r1(R)

    # TODO cannot redo transactions in states i, C, X, R, ...

    subtest 'discard_tx' => sub {
        test_request(
            req => [discard_tx=>"/", {tx_id=>"s1"}],
            status => 200,
            posttest => sub {
                my $tres = $txm->list(tx_status=>"C");
                is(scalar(@{$tres->[2]}), 1, "num C = 1");
                $tres = $txm->list(tx_id=>"s1");
                is(scalar(@{$tres->[2]}), 0, "tx s1 is gone");

                # discarding does not effect transaction result
                ok((-l "$tmp_dir/s1-l1"), "final state of s1 (l1) = done");
                ok((-l "$tmp_dir/s1-l2"), "final state of s1 (l2) = done");
            },
        );
    };
    # txs: f1(R), s2(C), f2(R), r1(R)

    # TODO test cannot discard transactions in states i, ...

    subtest 'discard_all_txs' => sub {
        # commit some txs first
        test_request(req => [begin_tx=>"/" , {tx_id=>"sd1"}], status => 200);
        test_request(req => [commit_tx=>"/", {tx_id=>"sd1"}], status => 200);
        test_request(req => [begin_tx=>"/" , {tx_id=>"sd2"}], status => 200);
        test_request(req => [commit_tx=>"/", {tx_id=>"sd2"}], status => 200);
        test_request(req => [undo=>"/"     , {tx_id=>"sd2"}], status => 200);
        test_request(req => [begin_tx=>"/" , {tx_id=>"sd3"}], status => 200);
        test_request(
            req => [commit_tx=>"/", {tx_id=>"sd3"}], status => 200,
            posttest => sub {
                my $tres = $txm->list(tx_status=>"C");
                is(scalar(@{$tres->[2]}), 3, "num C = 3");
                $tres = $txm->list(tx_status=>"U");
                is(scalar(@{$tres->[2]}), 1, "num U = 1");
            }
        );
        # TODO test discard transactions in state X
        test_request(
            req => [discard_all_txs=>"/"],
            status => 200,
            posttest => sub {
                my $tres = $txm->list(tx_status=>"C");
                is(scalar(@{$tres->[2]}), 0, "num C = 0");
                $tres = $txm->list(tx_status=>"U");
                is(scalar(@{$tres->[2]}), 0, "num U = 0");
            },
        );
    };
    # txs: f1(R), f2(R), r1(R)

    subtest 'nested_call' => sub {
        my $txid = "n1";
        test_request(req => [begin_tx=>"/" , {tx_id=>$txid}], status => 200);
        test_request(
            req => [call=>"/TestNested/setup_two_symlinks",
                    {args=>{symlink1=>"$tmp_dir/$txid-l1", target1=>"t1",
                            symlink2=>"$tmp_dir/$txid-l2", target2=>"t2",},
                     tx_id=>$txid}],
            status => 200,
        );
        test_request(
            req => [commit_tx=>"/", {tx_id=>$txid}],
            status => 200,
            posttest => sub {
                my $tres = $txm->list(detail=>1, tx_id=>$txid);
                is($tres->[2][0]{tx_status}, "C", "Transaction status is C");

                ok((-l "$tmp_dir/$txid-l1"),"final state of $txid(l1) = done");
                ok((-l "$tmp_dir/$txid-l2"),"final state of $txid(l2) = done");
            },
        );
        test_request(
            req => [undo=>"/", {tx_id=>$txid}],
            status => 200,
            posttest => sub {
                my $tres = $txm->list(detail=>1, tx_id=>$txid);
                is($tres->[2][0]{tx_status}, "U", "Transaction status is U");

                ok(!(-l "$tmp_dir/$txid-l1"),"final state of $txid(l1)=undone");
                ok(!(-l "$tmp_dir/$txid-l2"),"final state of $txid(l2)=undone");
            },
        );
        test_request(
            req => [redo=>"/", {tx_id=>$txid}],
            status => 200,
            posttest => sub {
                my $tres = $txm->list(detail=>1, tx_id=>$txid);
                is($tres->[2][0]{tx_status}, "C", "Transaction status is C");

                ok((-l "$tmp_dir/$txid-l1"),"final state of $txid(l1) = done");
                ok((-l "$tmp_dir/$txid-l2"),"final state of $txid(l2) = done");
            },
        );
        test_request(
            req => [undo=>"/", {tx_id=>$txid}],
            status => 200,
            posttest => sub {
                my $tres = $txm->list(detail=>1, tx_id=>$txid);
                is($tres->[2][0]{tx_status}, "U", "Transaction status is U");

                ok(!(-l "$tmp_dir/$txid-l1"),"final state of $txid(l1)=undone");
                ok(!(-l "$tmp_dir/$txid-l2"),"final state of $txid(l2)=undone");
            },
        );
    };
    # txs: f1(R), f2(R), r1(R), n1(U)

    # TODO in-progress transaction cannot be discarded

    # TODO test two transactions in parallel (one client)

    # TODO test failed rollback (tx status becomes X)
    # TODO test failed rollback (tx status becomes X)
    # TODO test failed rollback (tx status becomes X)

    # TODO test crash during calls and recovery
    # TODO test crash during undoing and recovery
    # TODO test crash during redoing and recovery
    # TODO test crash during rollback and recovery

}; # transaction subtest


DONE_TESTING:
done_testing();
if (Test::More->builder->is_passing) {
    #diag "all tests successful, deleting test data dir";
    $CWD = "/" unless $ENV{NO_CLEANUP};
} else {
    diag "there are failing tests, not deleting tx dir";
}

sub test_request {
    my %args = @_;
    my $req = $args{req};
    my $test_name = ($args{name} // "") . " (req: $req->[0] $req->[1])";
    subtest $test_name => sub {
        my $pa;
        if ($args{object_opts}) {
            $pa = Perinci::Access::InProcess->new(%{$args{object_opts}});
        } else {
            unless ($pa_cached) {
                $pa_cached = Perinci::Access::InProcess->new;
            }
            $pa = $pa_cached;
        }
        my $res = $pa->request(@$req);
        if ($args{status}) {
            is($res->[0], $args{status}, "status")
                or diag explain $res;
        }
        if (exists $args{result}) {
            is_deeply($res->[2], $args{result}, "result")
                or diag explain $res;
        }
        if ($args{posttest}) {
            $args{posttest}($res);
        }
        done_testing();
    };
}

