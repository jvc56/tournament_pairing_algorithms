#!/usr/bin/perl

# Test driver for TSH::Command::COP::max_weight_matching().
#
# COP.pm is normally installed inside a full TSH tree and pulls in
# several TSH::* framework modules that aren't part of this repository.
# None of them are touched by max_weight_matching() itself, so we stub
# them out here (by pre-populating %INC) purely so this script can load
# COP.pm standalone.
#
# The test cases below are ported from the woogles-io/liwords Go
# implementation's test suite:
#   https://github.com/woogles-io/liwords/blob/master/pkg/matching/matching_test.go
#
# The Go tests express expected results as a "mates" array indexed by
# vertex (0-indexed, -1 meaning unmatched) plus a total matching weight.
# max_weight_matching() here returns a hash of matched pairs instead (in
# the style of the Graph::Matching module it replaces), so each test
# below checks the equivalent set of matched pairs and the total weight
# of the matching instead of the raw mates array.

use strict;
use warnings;
use FindBin qw($Bin);

BEGIN {
    for my $mod (qw(TSH::Command::ShowPairings TSH::PairingCommand)) {
        ( my $path = $mod ) =~ s{::}{/}g;
        $INC{"$path.pm"} = 1;
    }
    package TSH::Command::ShowPairings;
    sub new { return bless {}, shift; }
    sub Run { return 1; }
    package TSH::PairingCommand;
}

require "$Bin/COP.pm";

my $tests_run    = 0;
my $tests_failed = 0;

sub check {
    my ( $name, $cond, $detail ) = @_;
    $tests_run++;
    if ($cond) {
        print "ok - $name\n";
    }
    else {
        $tests_failed++;
        print "not ok - $name" . ( defined $detail ? " ($detail)" : '' ) . "\n";
    }
}

# Returns the total weight of the edges present in %matching.
sub matching_weight {
    my ( $edges, $matching ) = @_;
    my $total = 0;
    my %counted;
    foreach my $e ( @{$edges} ) {
        my ( $v, $w, $wt ) = @{$e};
        next if $counted{"$w,$v"};
        if ( exists( $matching->{$v} ) && $matching->{$v} eq $w ) {
            $total += $wt;
            $counted{"$v,$w"} = 1;
        }
    }
    return $total;
}

# Returns true if %matching contains exactly the matched pairs listed
# in %expected (given one-directional, e.g. { 1 => 2 } for edge 1-2;
# both directions are checked automatically).
sub mates_equal {
    my ( $matching, $expected ) = @_;
    my %got = %{$matching};
    foreach my $v ( keys %{$expected} ) {
        my $w = $expected->{$v};
        return 0 if !exists( $got{$v} ) || $got{$v} ne $w;
        return 0 if !exists( $got{$w} ) || $got{$w} ne $v;
        delete $got{$v};
        delete $got{$w};
    }
    return !%got;
}

sub run_case {
    my ( $name, $edges, $maxcardinality, $expected_pairs, $expected_weight ) = @_;
    my %matching =
      TSH::Command::COP::max_weight_matching( $edges, $maxcardinality );
    check( "$name (matching)", mates_equal( \%matching, $expected_pairs ) );
    check(
        "$name (weight)",
        matching_weight( $edges, \%matching ) == $expected_weight,
        "got " . matching_weight( $edges, \%matching ) . ", want $expected_weight"
    );
}

# TestMaxWeightMatching10
run_case( "10: empty graph", [], 0, {}, 0 );

# TestMaxWeightMatching11
run_case( "11: single edge", [ [ 0, 1, 1 ] ], 0, { 0 => 1 }, 1 );

# TestMaxWeightMatching12
run_case(
    "12: two edges",
    [ [ 1, 2, 10 ], [ 2, 3, 11 ] ],
    0, { 2 => 3 }, 11
);

# TestMaxWeightMatching13
run_case(
    "13: path, no maxcardinality",
    [ [ 1, 2, 5 ], [ 2, 3, 11 ], [ 3, 4, 5 ] ],
    0, { 2 => 3 }, 11
);

# TestMaxWeightMatching14
run_case(
    "14: path, maxcardinality",
    [ [ 1, 2, 5 ], [ 2, 3, 11 ], [ 3, 4, 5 ] ],
    1, { 1 => 2, 3 => 4 }, 10
);

# TestMaxWeightMatching16
run_case(
    "16a: negative weights, no maxcardinality",
    [ [ 1, 2, 2 ], [ 1, 3, -2 ], [ 2, 3, 1 ], [ 2, 4, -1 ], [ 3, 4, -6 ] ],
    0, { 1 => 2 }, 2
);
run_case(
    "16b: negative weights, maxcardinality",
    [ [ 1, 2, 2 ], [ 1, 3, -2 ], [ 2, 3, 1 ], [ 2, 4, -1 ], [ 3, 4, -6 ] ],
    1, { 1 => 3, 2 => 4 }, -3
);

# TestMaxWeightMatching20
run_case(
    "20a",
    [ [ 1, 2, 8 ], [ 1, 3, 9 ], [ 2, 3, 10 ], [ 3, 4, 7 ] ],
    0, { 1 => 2, 3 => 4 }, 15
);
run_case(
    "20b",
    [
        [ 1, 2, 8 ], [ 1, 3, 9 ], [ 2, 3, 10 ],
        [ 3, 4, 7 ], [ 1, 6, 5 ], [ 4, 5, 6 ]
    ],
    0, { 1 => 6, 2 => 3, 4 => 5 }, 21
);

# TestMaxWeightMatching21
run_case(
    "21a",
    [
        [ 1, 2, 9 ], [ 1, 3, 8 ], [ 2, 3, 10 ],
        [ 1, 4, 5 ], [ 4, 5, 4 ],  [ 1, 6, 3 ]
    ],
    0, { 1 => 6, 2 => 3, 4 => 5 }, 17
);
run_case(
    "21b",
    [
        [ 1, 2, 9 ], [ 1, 3, 8 ], [ 2, 3, 10 ],
        [ 1, 4, 5 ], [ 4, 5, 3 ],  [ 1, 6, 4 ]
    ],
    0, { 1 => 6, 2 => 3, 4 => 5 }, 17
);
run_case(
    "21c",
    [
        [ 1, 2, 9 ], [ 1, 3, 8 ], [ 2, 3, 10 ],
        [ 1, 4, 5 ], [ 4, 5, 3 ],  [ 3, 6, 4 ]
    ],
    0, { 1 => 2, 3 => 6, 4 => 5 }, 16
);

# TestMaxWeightMatching22
run_case(
    "22",
    [
        [ 1, 2, 9 ], [ 1, 3, 9 ], [ 2, 3, 10 ], [ 2, 4, 8 ],
        [ 3, 5, 8 ], [ 4, 5, 10 ], [ 5, 6, 6 ]
    ],
    0, { 1 => 3, 2 => 4, 5 => 6 }, 23
);

# TestMaxWeightMatching23
run_case(
    "23",
    [
        [ 1, 2, 10 ], [ 1, 7, 10 ], [ 2, 3, 12 ], [ 3, 4, 20 ],
        [ 3, 5, 20 ], [ 4, 5, 25 ], [ 5, 6, 10 ], [ 6, 7, 10 ],
        [ 7, 8, 8 ]
    ],
    0, { 1 => 2, 3 => 4, 5 => 6, 7 => 8 }, 48
);

# TestMaxWeightMatching24
run_case(
    "24",
    [
        [ 1, 2, 8 ],  [ 1, 3, 8 ],  [ 2, 3, 10 ], [ 2, 4, 12 ],
        [ 3, 5, 12 ], [ 4, 5, 14 ], [ 4, 6, 12 ], [ 5, 7, 12 ],
        [ 6, 7, 14 ], [ 7, 8, 12 ]
    ],
    0, { 1 => 2, 3 => 5, 4 => 6, 7 => 8 }, 44
);

# TestMaxWeightMatching25
run_case(
    "25",
    [
        [ 1, 2, 23 ], [ 1, 5, 22 ], [ 1, 6, 15 ], [ 2, 3, 25 ],
        [ 3, 4, 22 ], [ 4, 5, 25 ], [ 4, 8, 14 ], [ 5, 7, 13 ]
    ],
    0, { 1 => 6, 2 => 3, 4 => 8, 5 => 7 }, 67
);

# TestMaxWeightMatching26
run_case(
    "26",
    [
        [ 1, 2, 19 ], [ 1, 3, 20 ], [ 1, 8, 8 ],  [ 2, 3, 25 ],
        [ 2, 4, 18 ], [ 3, 5, 18 ], [ 4, 5, 13 ], [ 4, 7, 7 ],
        [ 5, 6, 7 ]
    ],
    0, { 1 => 8, 2 => 3, 4 => 7, 5 => 6 }, 47
);

# TestMaxWeightMatching30
run_case(
    "30",
    [
        [ 1, 2, 45 ], [ 1, 5, 45 ], [ 2, 3, 50 ], [ 3, 4, 45 ],
        [ 4, 5, 50 ], [ 1, 6, 30 ], [ 3, 9, 35 ], [ 4, 8, 35 ],
        [ 5, 7, 26 ], [ 9, 10, 5 ]
    ],
    0, { 1 => 6, 2 => 3, 4 => 8, 5 => 7, 9 => 10 }, 146
);

# TestMaxWeightMatching31
run_case(
    "31",
    [
        [ 1, 2, 45 ], [ 1, 5, 45 ], [ 2, 3, 50 ], [ 3, 4, 45 ],
        [ 4, 5, 50 ], [ 1, 6, 30 ], [ 3, 9, 35 ], [ 4, 8, 26 ],
        [ 5, 7, 40 ], [ 9, 10, 5 ]
    ],
    0, { 1 => 6, 2 => 3, 4 => 8, 5 => 7, 9 => 10 }, 151
);

# TestMaxWeightMatching32
run_case(
    "32",
    [
        [ 1, 2, 45 ], [ 1, 5, 45 ], [ 2, 3, 50 ], [ 3, 4, 45 ],
        [ 4, 5, 50 ], [ 1, 6, 30 ], [ 3, 9, 35 ], [ 4, 8, 28 ],
        [ 5, 7, 26 ], [ 9, 10, 5 ]
    ],
    0, { 1 => 6, 2 => 3, 4 => 8, 5 => 7, 9 => 10 }, 139
);

# TestMaxWeightMatching33
run_case(
    "33",
    [
        [ 1, 2, 45 ],  [ 1, 7, 45 ],  [ 2, 3, 50 ],  [ 3, 4, 45 ],
        [ 4, 5, 95 ],  [ 4, 6, 94 ],  [ 5, 6, 94 ],  [ 6, 7, 50 ],
        [ 1, 8, 30 ],  [ 3, 11, 35 ], [ 5, 9, 36 ],  [ 7, 10, 26 ],
        [ 11, 12, 5 ]
    ],
    0,
    { 1 => 8, 2 => 3, 4 => 6, 5 => 9, 7 => 10, 11 => 12 },
    241
);

# TestMaxWeightMatching34
run_case(
    "34",
    [
        [ 1, 2, 40 ], [ 1, 3, 40 ], [ 2, 3, 60 ], [ 2, 4, 55 ],
        [ 3, 5, 55 ], [ 4, 5, 50 ], [ 1, 8, 15 ], [ 5, 7, 30 ],
        [ 7, 6, 10 ], [ 8, 10, 10 ], [ 4, 9, 30 ]
    ],
    0, { 1 => 2, 3 => 5, 4 => 9, 6 => 7, 8 => 10 }, 145
);

# TestMaxWeightMatchingError from the Go suite feeds a negative vertex
# id, which is only invalid there because the Go implementation stores
# mates in a plain array indexed by vertex id. This Perl implementation
# (like the Graph::Matching module it replaces) keys its hashes by
# arbitrary scalar vertex identifiers, so negative (or any other) vertex
# ids are perfectly valid input; there is no equivalent restriction to
# test here.

print "\n$tests_run tests run, " . ( $tests_run - $tests_failed ) . " passed, $tests_failed failed.\n";

exit( $tests_failed == 0 ? 0 : 1 );
