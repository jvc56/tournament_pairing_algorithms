#!/usr/bin/perl

# Test driver for COP.pm.
#
# Builds throwaway TSH tournament directories, runs the real tsh.pl against
# them with a 'cop' command, and checks the resulting .t file and COP log.
#
# Usage:
#   ./test_cop.pl                 run every test
#   ./test_cop.pl auto_ quarter   run tests whose name matches any of these
#   ./test_cop.pl --list          list test names
#   ./test_cop.pl --clean         delete the tournament directories of tests
#                                 that passed (they are kept by default)
#   ./test_cop.pl --tsh-dir DIR   TSH installation to drive (default /home/josh/TSH)
#   ./test_cop.pl --work-dir DIR  where to build tournaments (default a temp dir)
#
# Every tournament directory is left behind when the run ends, so the COP logs
# in <work-dir>/<test>/cop_logs, the tsh transcript in <work-dir>/<test>/
# tsh_output.txt and the resulting <work-dir>/<test>/a.t can all be inspected
# afterwards.
#
# COP.pm must be installed (or symlinked) into <tsh-dir>/lib/perl/TSH/Command.

use strict;
use warnings;

use File::Basename;
use File::Path qw(make_path remove_tree);
use File::Temp qw(tempdir);
use Getopt::Long;

my $tsh_dir  = '/home/josh/TSH';
my $work_dir = '';
my $clean    = 0;
my $list     = 0;
my $verbose  = 0;

GetOptions(
    'tsh-dir=s'  => \$tsh_dir,
    'work-dir=s' => \$work_dir,
    'clean'      => \$clean,
    'list'       => \$list,
    'verbose'    => \$verbose,
) or die "bad options\n";

my (@filters) = @ARGV;

# ---------------------------------------------------------------------------
# Tournament construction
# ---------------------------------------------------------------------------

# Deterministic RNG so that every run builds the same tournament histories.
{
    my $seed = 12345;

    sub reseed { $seed = shift; }

    sub rnd {
        my ($n) = @_;
        $seed = ( $seed * 1103515245 + 12345 ) % 2147483648;
        return $seed % $n;
    }
}

my %DEFAULT_CONFIG = (
    'use_cop_api'                   => '1',
    'simulations'                   => '1000',
    'always_wins_simulations'       => '1000',
    'gibson_spread'                 => '[250, 200]',
    'control_loss_thresholds'       => '[0.30]',
    'hopefulness'                   => '[0.2]',
    'control_loss_activation_round' => '12',
    'cop_threads'                   => '2',
    'track_firsts'                  => '1',
);

# Simulate $rounds_played rounds of a tournament so that the .t file has a
# plausible history for COP to pair from. Returns a list of player hashes.
sub simulate_players {
    my ( $count, $rounds_played ) = @_;

    my @players;
    for my $i ( 1 .. $count ) {
        push(
            @players,
            {
                'number'    => $i,
                'name'      => sprintf( "Player%02d, Test", $i ),
                'rating'    => 2000 - ( $i * 10 ),
                'pairings'  => [],
                'scores'    => [],
                'wins'      => 0,
                'spread'    => 0,
                'played'    => {},
            }
        );
    }

    for my $round ( 1 .. $rounds_played ) {
        my @ranked = sort {
                 $b->{'wins'} <=> $a->{'wins'}
              || $b->{'spread'} <=> $a->{'spread'}
              || $b->{'rating'} <=> $a->{'rating'}
        } @players;

        my %paired = ();
        for my $i ( 0 .. $#ranked ) {
            my $p = $ranked[$i];
            next if $paired{ $p->{'number'} };

            # Find the highest ranked available opponent not yet played.
            my $opp;
            my $fallback;
            for my $j ( $i + 1 .. $#ranked ) {
                my $q = $ranked[$j];
                next if $paired{ $q->{'number'} };
                $fallback ||= $q;
                next if $p->{'played'}{ $q->{'number'} };
                $opp = $q;
                last;
            }
            $opp ||= $fallback;

            if ( !$opp ) {
                # Odd player count: the lowest ranked unpaired player gets a bye.
                $paired{ $p->{'number'} } = 1;
                push( @{ $p->{'pairings'} }, 0 );
                push( @{ $p->{'scores'} },   50 );
                $p->{'wins'}   += 1;
                $p->{'spread'} += 50;
                next;
            }

            $paired{ $p->{'number'} }   = 1;
            $paired{ $opp->{'number'} } = 1;
            $p->{'played'}{ $opp->{'number'} }++;
            $opp->{'played'}{ $p->{'number'} }++;

            my $high = 340 + rnd(160);
            my $low  = 300 + rnd( $high - 300 );
            my ( $ps, $os ) = rnd(2) ? ( $high, $low ) : ( $low, $high );

            push( @{ $p->{'pairings'} },   $opp->{'number'} );
            push( @{ $opp->{'pairings'} }, $p->{'number'} );
            push( @{ $p->{'scores'} },     $ps );
            push( @{ $opp->{'scores'} },   $os );

            $p->{'spread'}   += $ps - $os;
            $opp->{'spread'} += $os - $ps;
            if    ( $ps > $os ) { $p->{'wins'}   += 1; }
            elsif ( $os > $ps ) { $opp->{'wins'} += 1; }
            else { $p->{'wins'} += 0.5; $opp->{'wins'} += 0.5; }
        }
    }

    return @players;
}

# Write a tournament directory. Options:
#   dir           (required) directory to create
#   players       number of players (default 20)
#   rounds        max_rounds (default 8)
#   rounds_played rounds of results to pregenerate (default 0)
#   config        hashref of config overrides; an undef value drops the entry
#   prizes        arrayref of 'prize ...' lines (default 3 rank prizes in a)
#   extra         extra raw config.tsh lines
sub build_tournament {
    my (%opt) = @_;

    my $dir           = $opt{'dir'};
    my $players       = $opt{'players'} || 20;
    my $rounds        = $opt{'rounds'} || 8;
    my $rounds_played = $opt{'rounds_played'} || 0;

    if ( -d $dir ) {

        # A previous aborted run may have left the directory read-only.
        chmod( 0755, $dir );
        remove_tree($dir);
    }
    make_path("$dir/html");

    my %config = ( %DEFAULT_CONFIG, 'max_rounds' => $rounds );
    if ( $opt{'config'} ) {
        for my $key ( keys %{ $opt{'config'} } ) {
            if ( defined $opt{'config'}{$key} ) {
                $config{$key} = $opt{'config'}{$key};
            }
            else {
                delete $config{$key};
            }
        }
    }

    my $prizes = $opt{'prizes'};
    if ( !defined $prizes ) {
        $prizes = [
            'prize rank 1 a "$500"',
            'prize rank 2 a "$300"',
            'prize rank 3 a "$200"',
        ];
    }

    open( my $cfg, '>', "$dir/config.tsh" ) or die "$dir/config.tsh: $!";
    print $cfg "division a a.t\n";
    print $cfg qq(config event_name = "COP test $opt{'name'}"\n) if $opt{'name'};
    for my $key ( sort keys %config ) {
        print $cfg "config $key = $config{$key}\n";
    }
    print $cfg "$_\n" for @$prizes;
    print $cfg "$_\n" for @{ $opt{'extra'} || [] };
    close($cfg);

    reseed(12345);
    my @sim = simulate_players( $players, $rounds_played );

    open( my $t, '>', "$dir/a.t" ) or die "$dir/a.t: $!";
    for my $p (@sim) {
        printf $t "%-30s %d %s; %s;\n", $p->{'name'}, $p->{'rating'},
          join( ' ', @{ $p->{'pairings'} } ), join( ' ', @{ $p->{'scores'} } );
    }
    close($t);

    return $dir;
}

# ---------------------------------------------------------------------------
# Running tsh
# ---------------------------------------------------------------------------

sub run_tsh {
    my ( $dir, $commands, %opt ) = @_;

    my $input = join( '', map { "$_\n" } @$commands );

    # One test makes the tournament directory read-only, so the driver's own
    # scratch files go next to it in that case.
    my $io_base = -w $dir ? "$dir/tsh" : "$dir.tsh";

    open( my $in, '>', "${io_base}_commands.txt" ) or die $!;
    print $in $input;
    close($in);

    my $path_prefix = $opt{'path_prefix'} ? "$opt{'path_prefix'}:" : '';
    my $cmd =
        "cd '$tsh_dir' && PATH='$path_prefix'\"\$PATH\" "
      . "./tsh.pl '$dir' < '${io_base}_commands.txt' 2>&1";
    my $output = `$cmd`;

    open( my $out, '>', "${io_base}_output.txt" ) or die $!;
    print $out $output;
    close($out);

    print $output if $verbose;
    return $output;
}

# Install a fake curl that produces $body on stdout and exits with $status.
# Its arguments, which include the JSON request COP built, are saved in
# curl_request.txt so tests can check what COP asked the API for.
sub fake_curl {
    my ( $dir, $body, $status ) = @_;
    $status = 0 unless defined $status;

    my $bin = "$dir/bin";
    make_path($bin);
    open( my $fh, '>', "$bin/curl" ) or die $!;
    print $fh "#!/bin/sh\n";
    print $fh "printf '%s\\n' \"\$@\" >> '$dir/curl_request.txt'\n";
    print $fh "cat <<'FAKE_CURL_EOF'\n$body\nFAKE_CURL_EOF\n";
    print $fh "exit $status\n";
    close($fh);
    chmod( 0755, "$bin/curl" );
    return $bin;
}

# The JSON requests COP sent, one per call to the fake curl.
sub curl_requests {
    my ($dir) = @_;

    return () unless -e "$dir/curl_request.txt";
    open( my $fh, '<', "$dir/curl_request.txt" ) or die $!;
    my @requests = grep { /"pair_method"/ } <$fh>;
    close($fh);
    return @requests;
}

# Check that COP asked the API for $method, and only that, on every call.
sub check_pair_method {
    my ( $dir, $method ) = @_;

    my @requests = curl_requests($dir);
    return ('COP made no API request') unless @requests;

    my @errors;
    for my $request (@requests) {
        my ($sent) = $request =~ /"pair_method":"(\w+)"/;
        push( @errors,
            "COP sent pair_method " . ( defined $sent ? $sent : '(none)' )
              . ", expected $method" )
          unless defined $sent && $sent eq $method;
    }
    return @errors;
}

# ---------------------------------------------------------------------------
# Inspecting results
# ---------------------------------------------------------------------------

# Parse a .t file into a list of { name, rating, pairings[], scores[] }.
sub read_tfile {
    my ($dir) = @_;

    open( my $fh, '<', "$dir/a.t" ) or die "$dir/a.t: $!";
    my @players;
    while ( my $line = <$fh> ) {
        next unless $line =~ /\S/;
        my ( $name, $rating, $pairings, $scores ) =
          $line =~ /^(.+?\S)\s+(\d+(?:[.+]\d+)*)\s*([\d\s]*);\s*([-\d\s]*)/;
        die "cannot parse .t line: $line" unless defined $scores;
        push(
            @players,
            {
                'name'     => $name,
                'rating'   => $rating,
                'pairings' => [ split( /\s+/, $pairings ) ],
                'scores'   => [ split( /\s+/, $scores ) ],
            }
        );
    }
    close($fh);
    return @players;
}

sub latest_cop_log {
    my ($dir) = @_;

    my @logs = sort glob("$dir/cop_logs/*.log");
    return undef unless @logs;

    # Log names are timestamped, so sorting by mtime is the safe choice when
    # several are written inside the same second.
    @logs = sort { ( stat $a )[9] <=> ( stat $b )[9] || $a cmp $b } @logs;
    my $latest = $logs[-1];
    open( my $fh, '<', $latest ) or die "$latest: $!";
    local $/ = undef;
    my $content = <$fh>;
    close($fh);
    return ( $content, $latest );
}

# Check that round $round1 is fully and consistently paired for every player.
sub check_round_paired {
    my ( $dir, $round1 ) = @_;

    my @players = read_tfile($dir);
    my $r0      = $round1 - 1;
    my @errors;

    my %by_number;
    for my $i ( 0 .. $#players ) { $by_number{ $i + 1 } = $players[$i]; }

    for my $i ( 0 .. $#players ) {
        my $number = $i + 1;
        my $opp    = $players[$i]{'pairings'}[$r0];
        if ( !defined $opp || $opp eq '' ) {
            push( @errors, "player $number has no round $round1 pairing" );
            next;
        }
        if ( $opp == $number ) {
            push( @errors, "player $number is paired with itself" );
            next;
        }
        next if $opp == 0;    # bye
        if ( !$by_number{$opp} ) {
            push( @errors, "player $number paired with nonexistent $opp" );
            next;
        }
        my $back = $by_number{$opp}{'pairings'}[$r0];
        if ( !defined $back || $back != $number ) {
            push( @errors,
                "asymmetric pairing: $number -> $opp, $opp -> "
                  . ( defined $back ? $back : 'undef' ) );
        }
    }

    return @errors;
}

# Count the leading rounds for which every player has a pairing. The COP API
# can pair several rounds at once, so this is how many rounds a cop command
# actually filled in.
sub count_paired_rounds {
    my ($dir) = @_;

    my @players = read_tfile($dir);
    my $rounds  = 0;
    while (1) {
        for my $p (@players) {
            my $opp = $p->{'pairings'}[$rounds];
            return $rounds unless defined $opp && $opp ne '';
        }
        $rounds++;
    }
}

# Round by round opponents, as 1-based player numbers, for round $round1.
sub round_pairings {
    my ( $dir, $round1 ) = @_;

    my @players = read_tfile($dir);
    return [
        map {
            my $opp = $_->{'pairings'}[ $round1 - 1 ];
            defined $opp ? $opp : '-'
        } @players
    ];
}

# Check that a multiround schedule is sound: over $rounds rounds, no two
# players may meet more often than the schedule allows. A division of n
# players supports n-1 rounds before a pairing has to repeat, so a pair may
# meet at most ceil(rounds / (n-1)) times. Initial fontes and partial round
# robins come out at one meeting per pair; a schedule of complete round robin
# cycles comes out at one per cycle.
sub check_schedule {
    my ( $dir, $rounds ) = @_;

    my @players = read_tfile($dir);
    my $count   = scalar @players;
    my %meetings;
    for my $round1 ( 1 .. $rounds ) {
        for my $i ( 0 .. $#players ) {
            my $number = $i + 1;
            my $opp    = $players[$i]{'pairings'}[ $round1 - 1 ];
            next unless defined $opp && $opp ne '';
            next if $opp == 0 || $opp < $number;    # bye, or counted already
            $meetings{"$number-$opp"}++;
        }
    }

    my $allowed = int( ( $rounds + $count - 2 ) / ( $count - 1 ) );
    my @errors;
    for my $pair ( sort keys %meetings ) {
        push( @errors,
                "players $pair meet $meetings{$pair} times over $rounds "
              . "rounds, expected at most $allowed" )
          if $meetings{$pair} > $allowed;
    }
    return @errors;
}

# ---------------------------------------------------------------------------
# Test definitions
# ---------------------------------------------------------------------------

my $ROUNDS = 16;    # rounds used by the "partly played tournament" tests

# A successful COP pairing: no TSH error, a log that says COP finished, and a
# complete set of pairings for the round that was paired.
sub expect_success {
    my ( $dir, $output, $round1, %opt ) = @_;

    my @errors;
    push( @errors, "tsh reported an error:\n$1" )
      if $output =~ /^(Error: .*(?:\n(?!tsh>).*)*)$/m;

    my ( $log, $log_name ) = latest_cop_log($dir);
    if ( !defined $log ) {
        push( @errors, 'no COP log was written' );
    }
    else {
        push( @errors, "COP log $log_name does not report success" )
          unless $log =~ /COP finished successfully/;
        if ( $opt{'log_matches'} ) {
            for my $re ( @{ $opt{'log_matches'} } ) {
                push( @errors, "COP log does not match $re" )
                  unless $log =~ $re;
            }
        }
        if ( ( $opt{'method'} || '' ) eq 'PAIR_COP' ) {

            # PAIR_COP is the zero value of the enum, so it is omitted from
            # the request the API echoes back into its log.
            push( @errors, 'COP log echoes a pair method but plain COP was '
                  . 'expected' )
              if $log =~ /"pairMethod"/;
            push( @errors, 'COP log does not contain COP pairings' )
              unless $log =~ /Final COP Pairings/;
        }
        elsif ( $opt{'method'} ) {
            push( @errors, "COP log does not report pair method $opt{'method'}" )
              if $log !~ /"pairMethod": "\Q$opt{'method'}\E"/;
        }
    }

    my $rounds = $opt{'rounds'} || 1;
    for my $offset ( 0 .. $rounds - 1 ) {
        push( @errors, check_round_paired( $dir, $round1 + $offset ) );
    }

    if ( $opt{'min_rounds'} ) {
        my $paired = count_paired_rounds($dir);
        push( @errors,
            "expected at least $opt{'min_rounds'} rounds to be paired, "
              . "found $paired" )
          if $paired < $opt{'min_rounds'};
    }
    if ( $opt{'check_schedule'} ) {
        push( @errors, check_schedule( $dir, count_paired_rounds($dir) ) );
    }
    if ( $opt{'exact_rounds'} ) {
        my $paired = count_paired_rounds($dir);
        push( @errors,
            "expected exactly $opt{'exact_rounds'} rounds to be paired, "
              . "found $paired" )
          if $paired != $opt{'exact_rounds'};
    }

    return @errors;
}

# A failed COP run: the expected TSH error code (and optionally message text),
# and no pairings written for the round COP was asked to pair.
sub expect_failure {
    my ( $dir, $output, $code, $round1, %opt ) = @_;

    my @errors;
    push( @errors, "expected error code [$code], got:\n$output" )
      unless $output =~ /\[\Q$code\E\]/;
    if ( $opt{'message'} ) {
        push( @errors, "expected message $opt{'message'} in:\n$output" )
          unless $output =~ $opt{'message'};
    }

    if ($round1) {
        my @players = read_tfile($dir);
        my $r0      = $round1 - 1;
        for my $i ( 0 .. $#players ) {
            my $opp = $players[$i]{'pairings'}[$r0];
            next unless defined $opp && $opp ne '';
            push( @errors,
                "player " . ( $i + 1 ) . " was paired for round $round1 "
                  . "even though COP should have failed" );
            last;
        }
    }
    return @errors;
}

# A canned successful response for a six player division that pairs three
# rounds at once, the way PAIR_AUTO does.
my @MULTIROUND_ROUNDS = (
    [ 1, 0, 3, 2, 5, 4 ],
    [ 2, 3, 0, 1, 5, 4 ],
    [ 3, 2, 1, 0, 5, 4 ],
);

# The same rounds as 1-based player numbers, which is how they appear in the
# .t file.
my @MULTIROUND_EXPECTED = (
    [ 2, 1, 4, 3, 6, 5 ],
    [ 3, 4, 1, 2, 6, 5 ],
    [ 4, 3, 2, 1, 6, 5 ],
);

sub api_multiround_response {
    my (@rounds) = @_;

    return sprintf(
        '{"error_code":"SUCCESS", "error_message":"", '
          . '"log":"fake multiround log. COP finished successfully.", "pairings":[%s], '
          . '"gibsonized_players":[], "multiround_pairings":[%s]}',
        join( ', ', @{ $rounds[0] } ),
        join( ', ', map { @$_ } @rounds )
    );
}

# A canned successful response that pairs a single round of six players.
my $API_SINGLE_ROUND = api_multiround_response( [ 1, 0, 3, 2, 5, 4 ] );

my $API_OK_BUT_EMPTY =
    '{"error_code":"SUCCESS", "error_message":"", "log":"", '
  . '"pairings":[], "gibsonized_players":[], "multiround_pairings":[]}';
my $API_ERROR_CODE =
    '{"error_code":"TIMEOUT", "error_message":"error computing required '
  . 'inputs: TIMEOUT", "log":"fake log contents", "pairings":[], '
  . '"gibsonized_players":[], "multiround_pairings":[]}';

my @TESTS = (

    # --- AUTO pairings for a tournament that has not started -----------------
    {
        'name'        => 'auto_init_fontes',
        'description' => 'empty tournament with more players than rounds '
          . 'pairs initial fontes',
        'build' => { 'players' => 20, 'rounds' => 8, 'rounds_played' => 0 },
        'commands' => ['cop 0 a'],
        'check'    => sub {
            my ( $dir, $output ) = @_;
            my @errors = expect_success(
                $dir, $output, 1,
                'method'      => 'PAIR_AUTO',
                'log_matches' => [
                    qr/using Initial Fontes/,
                    qr/Method: PAIR_INITIAL_FONTES/,
                ],

                # Initial fontes is a multiround pairing, so the API returns
                # every round it paired and all of them should be applied.
                'min_rounds' => 2,
            );
            @errors = expect_success(
                $dir, $output, 1,
                'rounds'         => count_paired_rounds($dir),
                'check_schedule' => 1,
            ) unless @errors;
            return @errors;
        },
    },
    {
        'name'        => 'auto_round_robin',
        'description' => 'empty tournament with more rounds than players '
          . 'pairs a round robin',
        'build' => { 'players' => 6, 'rounds' => 12, 'rounds_played' => 0 },
        'commands' => ['cop 0 a'],
        'check'    => sub {
            my ( $dir, $output ) = @_;
            my @errors = expect_success(
                $dir, $output, 1,
                'method'      => 'PAIR_AUTO',
                'log_matches' => [
                    qr/using Round Robin/,
                    qr/Method: PAIR_ROUND_ROBIN/,
                ],

                # A round robin covers several rounds, all of which the API
                # returns and COP should apply.
                'min_rounds' => 2,
            );
            @errors = expect_success(
                $dir, $output, 1,
                'rounds'         => count_paired_rounds($dir),
                'check_schedule' => 1,
            ) unless @errors;
            return @errors;
        },
    },

    # --- Successful COP pairings at various points in a tournament -----------
    {
        'name'        => 'cop_quarter_done',
        'description' => 'pair round 5 of 16 with a quarter of the '
          . 'tournament played',
        'build' => {
            'players'       => 20,
            'rounds'        => $ROUNDS,
            'rounds_played' => 4
        },
        'commands' => ['cop 4 a'],
        'check'    => sub {
            my ( $dir, $output ) = @_;
            return expect_success( $dir, $output, 5, 'method' => 'PAIR_COP',
                'exact_rounds' => 5 );
        },
    },
    {
        'name'        => 'cop_half_done',
        'description' => 'pair round 9 of 16 with half the tournament played',
        'build' => {
            'players'       => 20,
            'rounds'        => $ROUNDS,
            'rounds_played' => 8
        },
        'commands' => ['cop 8 a'],
        'check'    => sub {
            my ( $dir, $output ) = @_;
            return expect_success( $dir, $output, 9, 'method' => 'PAIR_COP',
                'exact_rounds' => 9 );
        },
    },
    {
        'name'        => 'cop_three_quarters_done',
        'description' => 'pair round 14 of 16, just past three quarters',
        'build' => {
            'players'       => 20,
            'rounds'        => $ROUNDS,
            'rounds_played' => 13
        },
        'commands' => ['cop 13 a'],
        'check'    => sub {
            my ( $dir, $output ) = @_;
            return expect_success( $dir, $output, 14, 'method' => 'PAIR_COP',
                'exact_rounds' => 14 );
        },
    },
    {
        'name'        => 'cop_penultimate_round',
        'description' => 'pair the penultimate round (15 of 16)',
        'build' => {
            'players'       => 20,
            'rounds'        => $ROUNDS,
            'rounds_played' => 14
        },
        'commands' => ['cop 14 a'],
        'check'    => sub {
            my ( $dir, $output ) = @_;
            return expect_success( $dir, $output, 15, 'method' => 'PAIR_COP',
                'exact_rounds' => 15 );
        },
    },
    {
        'name'        => 'cop_final_round',
        'description' => 'pair the final round (16 of 16)',
        'build' => {
            'players'       => 20,
            'rounds'        => $ROUNDS,
            'rounds_played' => 15
        },
        'commands' => ['cop 15 a'],
        'check'    => sub {
            my ( $dir, $output ) = @_;
            return expect_success( $dir, $output, 16, 'method' => 'PAIR_COP',
                'exact_rounds' => 16 );
        },
    },
    {
        'name'        => 'cop_odd_player_count',
        'description' => 'pair a division with an odd player count, which '
          . 'forces a bye',
        'build' => {
            'players'       => 19,
            'rounds'        => $ROUNDS,
            'rounds_played' => 6
        },
        'commands' => ['cop 6 a'],
        'check'    => sub {
            my ( $dir, $output ) = @_;
            my @errors =
              expect_success( $dir, $output, 7, 'method' => 'PAIR_COP',
                'exact_rounds' => 7 );
            my @players = read_tfile($dir);
            my $byes = grep { $_->{'pairings'}[6] == 0 } @players;
            push( @errors, "expected exactly one bye, found $byes" )
              unless $byes == 1;
            return @errors;
        },
    },

    # --- Multiround pairings -------------------------------------------------
    {
        'name'        => 'multiround_all_rounds_paired',
        'description' => 'every round returned in multiround_pairings is '
          . 'applied',
        'build' => { 'players' => 6, 'rounds' => 6, 'rounds_played' => 0 },
        'commands'    => ['cop 0 a'],
        'path_prefix' => sub {
            fake_curl( $_[0], api_multiround_response(@MULTIROUND_ROUNDS), 0 );
        },
        'check' => sub {
            my ( $dir, $output ) = @_;
            my @errors = expect_success( $dir, $output, 1, 'rounds' => 3,
                'exact_rounds' => 3 );
            for my $round1 ( 1 .. 3 ) {
                my $got      = round_pairings( $dir, $round1 );
                my $expected = $MULTIROUND_EXPECTED[ $round1 - 1 ];
                push( @errors,
                        "round $round1 pairings are @$got, "
                      . "expected @$expected" )
                  unless "@$got" eq "@$expected";
            }
            return @errors;
        },
    },
    {
        'name'        => 'multiround_capped_at_last_round',
        'description' => 'multiround pairings past the last round of the '
          . 'tournament are dropped',
        'build' => { 'players' => 6, 'rounds' => 2, 'rounds_played' => 0 },
        'commands'    => ['cop 0 a'],
        'path_prefix' => sub {
            fake_curl( $_[0], api_multiround_response(@MULTIROUND_ROUNDS), 0 );
        },
        'check' => sub {
            my ( $dir, $output ) = @_;
            my @errors = expect_success( $dir, $output, 1, 'rounds' => 2,
                'exact_rounds' => 2 );
            push( @errors, "no warning about the dropped round in:\n$output" )
              unless $output =~ /only 2 rounds remain/;
            for my $round1 ( 1 .. 2 ) {
                my $got      = round_pairings( $dir, $round1 );
                my $expected = $MULTIROUND_EXPECTED[ $round1 - 1 ];
                push( @errors,
                        "round $round1 pairings are @$got, "
                      . "expected @$expected" )
                  unless "@$got" eq "@$expected";
            }
            return @errors;
        },
    },

    # --- Which pair method COP asks for ---------------------------------------
    {
        'name'        => 'method_auto_when_division_empty',
        'description' => 'a division with no pairings and no results is '
          . 'paired with PAIR_AUTO',
        'build' => { 'players' => 6, 'rounds' => 6, 'rounds_played' => 0 },
        'commands'    => ['cop 0 a'],
        'path_prefix' => sub { fake_curl( $_[0], $API_SINGLE_ROUND, 0 ) },
        'check'       => sub {
            my ( $dir, $output ) = @_;
            my @errors = expect_success( $dir, $output, 1, 'exact_rounds' => 1 );
            push( @errors, check_pair_method( $dir, 'PAIR_AUTO' ) );
            return @errors;
        },
    },
    {
        'name'        => 'method_cop_when_pairings_exist',
        'description' => 'a division that is paired but has no results yet is '
          . 'paired with PAIR_COP, which the API requires',
        'build' => { 'players' => 6, 'rounds' => 6, 'rounds_played' => 0 },

        # Pair round 1 by another method first, so the division has pairings
        # but still no results, then let COP pair round 2 on top of it.
        'commands'    => [ 'rp 0 0 a', 'cop 0 a' ],
        'path_prefix' => sub { fake_curl( $_[0], $API_SINGLE_ROUND, 0 ) },
        'check'       => sub {
            my ( $dir, $output ) = @_;
            my @errors = expect_success( $dir, $output, 2, 'exact_rounds' => 2 );
            push( @errors, check_pair_method( $dir, 'PAIR_COP' ) );
            return @errors;
        },
    },

    # --- Error cases ---------------------------------------------------------
    {
        'name'        => 'error_round_out_of_range',
        'description' => 'refuse to pair past the last round',
        'build' => {
            'players'       => 20,
            'rounds'        => 8,
            'rounds_played' => 8
        },
        'commands' => ['cop 8 a'],
        'check'    => sub {
            my ( $dir, $output ) = @_;
            return expect_failure( $dir, $output, 'ebigrd' );
        },
    },
    {
        'name'        => 'error_no_gibson_spread',
        'description' => 'missing gibson_spread config',
        'build'       => {
            'players'       => 20,
            'rounds'        => 8,
            'rounds_played' => 4,
            'config'        => { 'gibson_spread' => undef },
        },
        'commands' => ['cop 4 a'],
        'check'    => sub {
            my ( $dir, $output ) = @_;
            return expect_failure( $dir, $output, 'ebadconfigarray', 5,
                'message' => qr/gibson_spread/ );
        },
    },
    {
        'name'        => 'error_no_simulations',
        'description' => 'missing simulations config',
        'build'       => {
            'players'       => 20,
            'rounds'        => 8,
            'rounds_played' => 4,
            'config'        => { 'simulations' => undef },
        },
        'commands' => ['cop 4 a'],
        'check'    => sub {
            my ( $dir, $output ) = @_;
            return expect_failure( $dir, $output, 'ebadconfigentry', 5,
                'message' => qr/simulations/ );
        },
    },
    {
        'name'        => 'error_no_always_wins_simulations',
        'description' => 'missing always_wins_simulations config',
        'build'       => {
            'players'       => 20,
            'rounds'        => 8,
            'rounds_played' => 4,
            'config'        => { 'always_wins_simulations' => undef },
        },
        'commands' => ['cop 4 a'],
        'check'    => sub {
            my ( $dir, $output ) = @_;
            return expect_failure( $dir, $output, 'ebadconfigentry', 5,
                'message' => qr/always_wins_simulations/ );
        },
    },
    {
        'name'        => 'error_no_control_loss_thresholds',
        'description' => 'missing control_loss_thresholds config',
        'build'       => {
            'players'       => 20,
            'rounds'        => 8,
            'rounds_played' => 4,
            'config'        => { 'control_loss_thresholds' => undef },
        },
        'commands' => ['cop 4 a'],
        'check'    => sub {
            my ( $dir, $output ) = @_;
            return expect_failure( $dir, $output, 'ebadconfigarray', 5,
                'message' => qr/control_loss_thresholds/ );
        },
    },
    {
        'name'        => 'error_empty_control_loss_thresholds',
        'description' => 'empty control_loss_thresholds array',
        'build'       => {
            'players'       => 20,
            'rounds'        => 8,
            'rounds_played' => 4,
            'config'        => { 'control_loss_thresholds' => '[]' },
        },
        'commands' => ['cop 4 a'],
        'check'    => sub {
            my ( $dir, $output ) = @_;
            return expect_failure( $dir, $output, 'ebadconfigarray', 5,
                'message' => qr/control_loss_thresholds/ );
        },
    },
    {
        'name'        => 'error_no_hopefulness',
        'description' => 'missing hopefulness config',
        'build'       => {
            'players'       => 20,
            'rounds'        => 8,
            'rounds_played' => 4,
            'config'        => { 'hopefulness' => undef },
        },
        'commands' => ['cop 4 a'],
        'check'    => sub {
            my ( $dir, $output ) = @_;
            return expect_failure( $dir, $output, 'ebadconfigarray', 5,
                'message' => qr/hopefulness/ );
        },
    },
    {
        'name'        => 'error_no_control_loss_activation_round',
        'description' => 'missing control_loss_activation_round config',
        'build'       => {
            'players'       => 20,
            'rounds'        => 8,
            'rounds_played' => 4,
            'config' => { 'control_loss_activation_round' => undef },
        },
        'commands' => ['cop 4 a'],
        'check'    => sub {
            my ( $dir, $output ) = @_;
            return expect_failure( $dir, $output, 'ebadconfigentry', 5,
                'message' => qr/control_loss_activation_round/ );
        },
    },
    {
        'name'        => 'error_no_prizes',
        'description' => 'no rank prizes configured for the division',
        'build'       => {
            'players'       => 20,
            'rounds'        => 8,
            'rounds_played' => 4,
            'prizes'        => [],
        },
        'commands' => ['cop 4 a'],
        'check'    => sub {
            my ( $dir, $output ) = @_;
            return expect_failure( $dir, $output, 'ebadconfigentry', 5,
                'message' => qr/prizes/ );
        },
    },
    {
        'name'        => 'error_curl_failed',
        'description' => 'the curl call to the COP API fails',
        'build'       => {
            'players'       => 20,
            'rounds'        => 8,
            'rounds_played' => 4
        },
        'commands'    => ['cop 4 a'],
        'path_prefix' => sub { fake_curl( $_[0], '', 7 ) },
        'check'       => sub {
            my ( $dir, $output ) = @_;
            my @errors = expect_failure( $dir, $output, 'eapfail', 5,
                'message' => qr/curl command for COP API failed/ );
            my ($log) = latest_cop_log($dir);
            push( @errors, 'COP log does not record the failed curl command' )
              unless defined $log && $log =~ /Failed curl command/;
            return @errors;
        },
    },
    {
        'name'        => 'error_bad_json',
        'description' => 'the COP API returns something that is not JSON',
        'build'       => {
            'players'       => 20,
            'rounds'        => 8,
            'rounds_played' => 4
        },
        'commands'    => ['cop 4 a'],
        'path_prefix' => sub { fake_curl( $_[0], '<html>502 Bad Gateway</html>', 0 ) },
        'check'       => sub {
            my ( $dir, $output ) = @_;
            my @errors = expect_failure( $dir, $output, 'eapfail', 5,
                'message' => qr/failed to decode JSON for COP API/ );
            my ($log) = latest_cop_log($dir);
            push( @errors, 'COP log does not record the undecodable response' )
              unless defined $log && $log =~ /Failed to decode response/;
            return @errors;
        },
    },
    {
        'name'        => 'error_empty_api_log',
        'description' => 'the COP API returns an empty log',
        'build'       => {
            'players'       => 20,
            'rounds'        => 8,
            'rounds_played' => 4
        },
        'commands'    => ['cop 4 a'],
        'path_prefix' => sub { fake_curl( $_[0], $API_OK_BUT_EMPTY, 0 ) },
        'check'       => sub {
            my ( $dir, $output ) = @_;
            my @errors = expect_failure( $dir, $output, 'eapfail', 5,
                'message' => qr/COP API failed/ );
            my ($log) = latest_cop_log($dir);
            push( @errors, 'COP log does not record the empty response' )
              unless defined $log && $log =~ /COP API failed/;
            return @errors;
        },
    },
    {
        'name'        => 'error_api_error_code',
        'description' => 'the COP API returns a non-SUCCESS error code',
        'build'       => {
            'players'       => 20,
            'rounds'        => 8,
            'rounds_played' => 4
        },
        'commands'    => ['cop 4 a'],
        'path_prefix' => sub { fake_curl( $_[0], $API_ERROR_CODE, 0 ) },
        'check'       => sub {
            my ( $dir, $output ) = @_;
            my @errors = expect_failure( $dir, $output, 'eapfail', 5,
                'message' => qr/COP API error code: TIMEOUT/ );
            my ($log) = latest_cop_log($dir);
            push( @errors, 'COP log does not record the API error code' )
              unless defined $log && $log =~ /COP API error code/;
            return @errors;
        },
    },
    {
        'name'        => 'error_multiround_wrong_length',
        'description' => 'multiround pairings that are not a whole number of '
          . 'rounds are rejected',
        'build' => { 'players' => 6, 'rounds' => 6, 'rounds_played' => 0 },
        'commands'    => ['cop 0 a'],
        'path_prefix' => sub {
            fake_curl(
                $_[0],
                '{"error_code":"SUCCESS", "error_message":"", '
                  . '"log":"fake multiround log. COP finished successfully.", "pairings":[1, 0, 3, 2, 5, 4], '
                  . '"gibsonized_players":[], '
                  . '"multiround_pairings":[1, 0, 3, 2, 5, 4, 2]}',
                0
            );
        },
        'check' => sub {
            my ( $dir, $output ) = @_;
            return expect_failure( $dir, $output, 'eapfail', 1,
                'message' => qr/not a multiple of the 6 players/ );
        },
    },
    {
        'name'        => 'error_log_directory',
        'description' => 'the cop_logs directory cannot be created',
        'build'       => {
            'players'       => 20,
            'rounds'        => 8,
            'rounds_played' => 4
        },
        'commands' => ['cop 4 a'],

        # tsh needs to write its lock file, so the lock is created first and
        # only then is the tournament directory made read-only.
        'before' => sub {
            my ($dir) = @_;
            open( my $fh, '>>', "$dir/tsh.lock" ) or die $!;
            close($fh);
            chmod( 0555, $dir ) or die $!;
        },
        'after' => sub {
            my ($dir) = @_;
            chmod( 0755, $dir );
        },
        'check' => sub {
            my ( $dir, $output ) = @_;
            return expect_failure( $dir, $output, 'eapfail', 5,
                'message' => qr/failed to create directory/ );
        },
    },
);

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

if ($list) {
    printf( "%-38s %s\n", $_->{'name'}, $_->{'description'} ) for @TESTS;
    exit 0;
}

die "no tsh.pl in $tsh_dir\n" unless -f "$tsh_dir/tsh.pl";
my $installed = "$tsh_dir/lib/perl/TSH/Command/COP.pm";
die "COP.pm is not installed in $tsh_dir\n" unless -e $installed;
printf( "COP.pm under test: %s\n", -l $installed ? readlink($installed) : $installed );

my $temporary_work_dir = 0;
if ( !$work_dir ) {
    $work_dir           = tempdir( 'cop_tests_XXXXXX', TMPDIR => 1 );
    $temporary_work_dir = 1;
}
make_path($work_dir);
print "work directory: $work_dir\n\n";

my @selected = @TESTS;
if (@filters) {
    @selected = grep {
        my $name = $_->{'name'};
        grep { $name =~ /\Q$_\E/ } @filters
    } @TESTS;
    die "no tests matched @filters\n" unless @selected;
}

my $failures = 0;
for my $test (@selected) {
    my $name = $test->{'name'};
    printf( "%-38s ", $name );

    my $dir = "$work_dir/$name";
    build_tournament( %{ $test->{'build'} }, 'dir' => $dir, 'name' => $name );

    my $path_prefix = '';
    $path_prefix = $test->{'path_prefix'}->($dir) if $test->{'path_prefix'};
    $test->{'before'}->($dir) if $test->{'before'};

    my $output =
      eval { run_tsh( $dir, $test->{'commands'}, 'path_prefix' => $path_prefix ) };
    my $run_error = $@;

    $test->{'after'}->($dir) if $test->{'after'};

    if ($run_error) {
        $failures++;
        print "FAIL\n";
        print "    could not run tsh: $run_error";
        print "    tournament kept at $dir\n";
        next;
    }

    my @errors = $test->{'check'}->( $dir, $output );

    if (@errors) {
        $failures++;
        print "FAIL\n";
        print "    $_\n" for @errors;
        print "    tournament kept at $dir\n";
    }
    else {
        print "ok\n";
        if ($clean) {
            remove_tree($dir);
            unlink("$dir.tsh_commands.txt");
            unlink("$dir.tsh_output.txt");
        }
    }
}

print "\n";
printf( "%d/%d tests passed\n", scalar(@selected) - $failures, scalar(@selected) );

if ( $clean && !$failures ) {
    remove_tree($work_dir) if $temporary_work_dir;
}
else {
    print <<"EOF";

Tournaments left in $work_dir, one directory per test:
  <test>/cop_logs/*.log   the COP log for each cop command
  <test>/html/*_cop.log   the copy COP makes for the html directory
  <test>/tsh_output.txt   everything tsh printed
  <test>/a.t              the division file after pairing
EOF
}

exit( $failures ? 1 : 0 );
