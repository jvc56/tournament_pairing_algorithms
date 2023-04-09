#!/usr/bin/perl

package TSH::Command::XYZPAIR;

use strict;
use warnings;

use Getopt::Long;
use LWP::Simple;

require "./XYZPAIR.pm";

# Parsing the t file

sub players_scores_from_tfile {
    my ( $tfile, $start_round ) = @_;
    unless ( -e $tfile ) {
        print "tfile does not exist: $tfile\n";
        exit(-1);
    }
    my @players_scores;
    my $index = 0;
    open( my $fh, '<', $tfile ) or die "Could not open file '$tfile': $!";
    while ( my $line = <$fh> ) {
        chomp($line);
        my ( $last_name, $first_name, $opponent_indexes_string, $scores_string )
          = ( $line =~ /^([^,]+),(\D+)\d+([^;]+);([^;]+)/ );
        unless ( $last_name
            && $first_name
            && $opponent_indexes_string
            && $scores_string )
        {
            print "match not found for $line\n";
            exit(-1);
        }

        $first_name              =~ s/^\s+|\s+$//g;
        $last_name               =~ s/^\s+|\s+$//g;
        $opponent_indexes_string =~ s/^\s+|\s+$//g;
        $scores_string           =~ s/^\s+|\s+$//g;

        my @scores = split( ' ', $scores_string );
        my @opponent_indexes =
          map { $_ - 1 } split( ' ', $opponent_indexes_string );

        if ( scalar @scores != scalar @opponent_indexes ) {
            print "scores and opponents are not the same size for $line\n";
            exit(-1);
        }

        if ( $start_round >= scalar @scores ) {
            printf(
                "start round %d is greater than number of current rounds %d\n",
                $start_round, scalar @scores );
            exit(-1);
        }

        splice( @scores,           $start_round );
        splice( @opponent_indexes, $start_round );

        my $name = $first_name . " " . $last_name;

        push @players_scores,
          new_player_scores( $name, $index, \@opponent_indexes, \@scores );
        $index++;
    }
    close($fh);
    return \@players_scores;
}

sub tournament_players_from_players_scores {
    my ($players_scores) = @_;
    my @tournament_players;
    my %times_played_hash;
    my $number_of_scores_per_player = -1;
    my $number_of_players           = scalar @{$players_scores};
    for (
        my $player_index = 0 ;
        $player_index < $number_of_players ;
        $player_index++
      )
    {
        my $pscores                 = $players_scores->[$player_index];
        my $wins                    = 0;
        my $spread                  = 0;
        my $player_number_of_scores = scalar @{ $pscores->{scores} };
        if ( $number_of_scores_per_player < 0 ) {
            $number_of_scores_per_player = $player_number_of_scores;
        }
        elsif ( $number_of_scores_per_player != $player_number_of_scores ) {
            printf( "inconsistent number of scores for %s: %d\n",
                $pscores->{name}, $player_number_of_scores );
            exit(-1);
        }
        for ( my $round = 0 ; $round < $player_number_of_scores ; $round++ ) {
            my $opponent_index = $pscores->{opponent_indexes}[$round];

            my $times_played_key =
              create_times_played_key( $player_index, $opponent_index );

            if ( exists $times_played_hash{$times_played_key} ) {
                $times_played_hash{$times_played_key} += 1;
            }
            else {
                $times_played_hash{$times_played_key} = 1;
            }

            my $opponent_score = 0;

            # Byes have already been converted from 0 to -1
            # when reading from the t file.
            if ( $opponent_index == -1 ) {

                # Account for the bye "pairing" only
                # occurring once since the bye is not a real player.
                # Later, all of the values in this hash will be
                # divided by 2 to account for this. Increment
                # here so that the value for the number of byes
                # the player has is correct after division by 2.
                $times_played_hash{$times_played_key}++;
            }
            else {
                $opponent_score =
                  $players_scores->[$opponent_index]->{scores}[$round];
            }

            my $game_spread = $pscores->{scores}[$round] - $opponent_score;

            if ( $game_spread > 0 ) {
                $wins += 2;
            }
            elsif ( $game_spread == 0 ) {
                $wins += 1;
            }

            $spread += $game_spread;
        }

        push @tournament_players,
          new_tournament_player( $pscores->{name}, $pscores->{index},
            $pscores->{index}, $wins, $spread, 0 );
    }

    for my $times_played_key ( keys %times_played_hash ) {
        $times_played_hash{$times_played_key} /= 2;
    }

    sort_tournament_players_by_record( \@tournament_players );

    return ( \@tournament_players, \%times_played_hash );
}

sub tournament_players_from_tfile {
    my ( $filename, $start_round ) = @_;
    my $players_scores = players_scores_from_tfile( $filename, $start_round );
    my ( $tournament_players, $times_played_hash ) =
      tournament_players_from_players_scores($players_scores);
    return ( $tournament_players, $times_played_hash );
}

sub create_xyzpair_config {
    my (
        $start_round,             $final_round,
        $number_of_sims,          $always_wins_number_of_sims,
        $lowest_ranked_payout,    $gibson_spreads,
        $control_loss_thresholds, $hopefulness,
        $log_filename
    ) = @_;

    return {
        log_filename               => $log_filename,
        number_of_sims             => $number_of_sims,
        always_wins_number_of_sims => $always_wins_number_of_sims,
        number_of_rounds_remaining => $final_round - $start_round,
        lowest_ranked_payout       => $lowest_ranked_payout,
        cumulative_gibson_spreads =>
          get_cumulative_gibson_spreads( $gibson_spreads, $final_round - 1 ),
        control_loss_thresholds =>
          extend_tsh_config_array( $control_loss_thresholds, $final_round - 1 ),
        hopefulness =>
          extend_tsh_config_array( $hopefulness, $final_round - 1 ),
    };
}

sub get_pairings {
    my ( $filename, $config, $start_round ) = @_;

    my ( $tournament_players, $times_played_hash ) =
      tournament_players_from_tfile( $filename, $start_round );

    return xyzpair( $config, $tournament_players, $times_played_hash );
}

sub create_xyzpair_config_and_get_pairings {
    my (
        $start_round,             $final_round,
        $number_of_sims,          $always_wins_number_of_sims,
        $lowest_ranked_payout,    $gibson_spreads,
        $control_loss_thresholds, $hopefulness,
        $log_filename, $filename
    ) = @_;

    # Test cases for xyzpair
    my $config =
      create_xyzpair_config( $start_round, $final_round, $number_of_sims, $always_wins_number_of_sims, $lowest_ranked_payout,
      $gibson_spreads, $control_loss_thresholds, $hopefulness, $log_filename);

    my ( $tournament_players, $times_played_hash ) =
      tournament_players_from_tfile( $filename, $start_round );

    return xyzpair( $config, $tournament_players, $times_played_hash );
}

sub test_xyzpair {
    # Test cases for xyzpair
    my $pairings =
      create_xyzpair_config_and_get_pairings( 21, 23, 100_000, 10_000, 4, [ 250, 200, 200 ],
        [0.15], [ 0, 0.0025, 0.01, 0.05, 0.1 ], "xyzpair_logs/yeet.log", "a.t" );
}

sub main {

    my $payout = 1;
    my $start  = 1;
    my $final;
    my $tfile;
    my $url;
    my $sim  = 100000;
    my $test = 0;

    GetOptions(
        "payout=s" => \$payout,
        "start=s"  => \$start,
        "final=s"  => \$final,
        "tfile=s"  => \$tfile,
        "url=s"    => \$url,
        "sim=s"    => \$sim,
        "test"     => \$test
    );

    if ($test) {
        test_xyzpair();
        return;
    }

    if ( !$final ) {
        print "required: final\n";
        exit(-1);
    }

    if ( ( !$tfile && !$url ) || ( $tfile && $url ) ) {
        print "required: exactly one of: tfile, url\n";
        exit(-1);
    }

    my $filename = "a.t";

    if ($tfile) {
        print "Reading from $tfile\n";
        $filename = $tfile;
    }

    if ($url) {
        print "Downloading $url to $filename\n";
        getstore( $url, $filename );
    }

    my $number_of_sims = 100000;

    if ($sim) {
        $number_of_sims = int($sim);
    }

    my $lowest_ranked_payout = 0;

    if ($payout) {
        $lowest_ranked_payout = int($payout);
    }

    my ( $tournament_players, $times_played_hash ) =
      tournament_players_from_tfile( $filename, $start );

    my $log_dir = "./xyzpair_logs/";

    mkdir $log_dir;

    if ( !-e $log_dir ) {
        die "$log_dir does not exist";
    }

    my $timestamp = localtime();
    $timestamp =~ s/[\s\:]/_/g;

    my $log_filename = "$log_dir$timestamp" . "_div_somediv_round_$start.log";

    my $config = create_xyzpair_config(
        $start,
        $final,
        $number_of_sims,
        10_000,
        $lowest_ranked_payout,
        [ 250, 200, 200 ],
        [0.15],
        [ 0, 0.0025, 0.01, 0.05, 0.1 ],
        "$log_dir$timestamp" . "_div_somediv_round_$start.log"
    );

    log_info( $config, Dumper($config) );

    xyzpair( $config, $tournament_players, $times_played_hash );
}

main();
