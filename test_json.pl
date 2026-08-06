#!/usr/bin/perl

# Test driver for the JSON encode_json()/decode_json() replacement in
# COP.pm (a dependency-free stand-in for the CPAN JSON module).
#
# COP.pm is normally installed inside a full TSH tree and pulls in
# several TSH::* framework modules that aren't part of this repository.
# None of them are touched by the JSON functions themselves, so we stub
# them out here (by pre-populating %INC) purely so this script can load
# COP.pm standalone.

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

# ---------------------------------------------------------------------------
# encode_json()
# ---------------------------------------------------------------------------

check(
    "encode: scalars",
    TSH::Command::COP::encode_json( { a => 1, b => "x", c => undef } ) eq
      '{"a":1,"b":"x","c":null}'
);

check(
    "encode: negative and float numbers",
    TSH::Command::COP::encode_json( [ -1, 0, 3.5, -2.25 ] ) eq
      '[-1,0,3.5,-2.25]'
);

check(
    "encode: nested arrays/objects",
    TSH::Command::COP::encode_json(
        { pairings => [ 1, 2, -1 ], meta => { ok => 1 } }
      ) eq '{"meta":{"ok":1},"pairings":[1,2,-1]}'
);

check(
    "encode: string escaping",
    TSH::Command::COP::encode_json( { s => qq{a"b\\c\nd\te} } ) eq
      '{"s":"a\\"b\\\\c\\nd\\te"}'
);

check(
    "encode: JSON::true/JSON::false",
    TSH::Command::COP::encode_json(
        { yes => JSON::true(), no => JSON::false() }
      ) eq '{"no":false,"yes":true}'
);

check(
    "encode: empty array and empty object",
    TSH::Command::COP::encode_json( { a => [], b => {} } ) eq
      '{"a":[],"b":{}}'
);

# A shape close to the real COP API request: mixed strings, numbers,
# arrays of hashes, and booleans.
{
    my $req = {
        pair_method       => 'COP',
        player_names      => [ 'Josh', 'Alice' ],
        division_pairings => [ { pairings => [ 1, -1 ] } ],
        allow_repeat_byes => JSON::false(),
        top_down_byes     => JSON::true(),
        seed              => 0,
    };
    my $encoded = TSH::Command::COP::encode_json($req);
    my $decoded = eval { TSH::Command::COP::decode_json($encoded) };
    check( "encode+decode: COP-request-shaped structure round-trips", !$@,
        $@ );
    check(
        "encode+decode: round-tripped structure matches",
        $decoded->{pair_method} eq 'COP'
          && $decoded->{player_names}[0] eq 'Josh'
          && $decoded->{player_names}[1] eq 'Alice'
          && $decoded->{division_pairings}[0]{pairings}[0] == 1
          && $decoded->{division_pairings}[0]{pairings}[1] == -1
          && $decoded->{allow_repeat_byes} == 0
          && $decoded->{top_down_byes} == 1
          && $decoded->{seed} == 0
    );
}

# ---------------------------------------------------------------------------
# decode_json()
# ---------------------------------------------------------------------------

{
    my $d = TSH::Command::COP::decode_json('{"a":1,"b":"x","c":null}');
    check(
        "decode: simple object",
        $d->{a} == 1 && $d->{b} eq 'x' && !defined( $d->{c} )
    );
}

{
    my $d = TSH::Command::COP::decode_json('[1,2.5,-3,"s",true,false,null]');
    check(
        "decode: array of mixed types",
        $d->[0] == 1
          && $d->[1] == 2.5
          && $d->[2] == -3
          && $d->[3] eq 's'
          && $d->[4] == 1
          && $d->[5] == 0
          && !defined( $d->[6] )
    );
}

{
    my $d = TSH::Command::COP::decode_json('{"s":"a\\"b\\\\c\\nd\\te"}');
    check( "decode: string escapes", $d->{s} eq qq{a"b\\c\nd\te} );
}

{
    my $d = TSH::Command::COP::decode_json('{"u":"\\u0041\\u0042"}');
    check( "decode: \\u escapes", $d->{u} eq "AB" );
}

# A response shaped like the real COP API's response.
{
    my $json =
      '{"pairings":[1,0,-1],"log":"some log text","error_code":"SUCCESS","error_message":""}';
    my $d = TSH::Command::COP::decode_json($json);
    check(
        "decode: COP-response-shaped structure",
        $d->{log} eq 'some log text'
          && $d->{error_code} eq 'SUCCESS'
          && $d->{error_message} eq ''
          && $d->{pairings}[0] == 1
          && $d->{pairings}[1] == 0
          && $d->{pairings}[2] == -1
    );
}

{
    my $d = TSH::Command::COP::decode_json('  {  "a" : [ 1 , 2 ]  }  ');
    check( "decode: whitespace tolerance", $d->{a}[0] == 1 && $d->{a}[1] == 2 );
}

{
    my $ok = eval { TSH::Command::COP::decode_json('{"a":1'); 1 };
    check( "decode: malformed JSON (truncated) dies", !$ok );
}

{
    my $ok = eval { TSH::Command::COP::decode_json('{"a":1} garbage'); 1 };
    check( "decode: malformed JSON (trailing garbage) dies", !$ok );
}

print "\n$tests_run tests run, "
  . ( $tests_run - $tests_failed )
  . " passed, $tests_failed failed.\n";

exit( $tests_failed == 0 ? 0 : 1 );
