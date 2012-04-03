#!perl

use 5.010;
use strict;
use warnings;
use Test::More 0.96;

use Perinci::Access::InProcess;

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
    name => 'ending slash matters',
    req => [meta => "/Perinci/Examples"],
    status => 404,
);

test_request(
    name => 'meta on function',
    req => [meta => "/Perinci/Examples/test_completion"],
    status => 200,
    posttest => sub {
        my ($res) = @_;
    },
);

test_request(
    name => 'actions on package',
    req => [actions => "/Perinci/Examples/"],
    status => 200,
    result => [qw/actions child_metas info list meta/],
);
test_request(
    name => 'actions on function',
    req => [actions => "/Perinci/Examples/gen_array"],
    status => 200,
    result => [qw/actions call complete_arg_val info meta/],
);
test_request(
    name => 'actions on variable',
    req => [actions => "/Perinci/Examples/\$Var1"],
    status => 200,
    result => [qw/actions get info meta/],
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

done_testing();

sub test_request {
    my %args = @_;
    my $req = $args{req};
    my $test_name = ($args{name} // "") . " ($req->[0] $req->[1])";
    subtest $test_name => sub {
        state $pa_cached;
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

