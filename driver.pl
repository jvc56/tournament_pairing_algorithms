#!/usr/bin/perl

use strict;
use warnings;

use Getopt::Long;
use LWP::Simple;

require "./XYZpair.pm";

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

            my $opponent_score = 0;
            my $is_bye         = 0;

            # Handle the bye case
            if ( $opponent_index < 0 ) {

                # This round was a bye for this player
                $opponent_index = $number_of_players;
                $is_bye         = 1;
            }
            else {
                $opponent_score =
                  $players_scores->[$opponent_index]->{scores}[$round];
            }

            my $times_played_key =
              create_times_played_key( $player_index, $opponent_index );

            if ( exists $times_played_hash{$times_played_key} ) {
                $times_played_hash{$times_played_key} += 1;
            }
            else {
                $times_played_hash{$times_played_key} = 1;
            }

            # Account for the fact that the bye "pairing" only
            # occurs once since the bye is not a real player.
            # Later, all of the values in this hash will be
            # divided by 2 to account for this. Increment
            # here so that the value for the number of byes
            # the player has is correct after division by 2.
            $times_played_hash{$times_played_key} += $is_bye;

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
          new_tournament_player( $pscores->{name}, $pscores->{index}, $wins,
            $spread, 0 );
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

sub main {

    my $payout = 1;
    my $start  = 1;
    my $final;
    my $tfile;
    my $url;
    my $sim = 100000;

    GetOptions(
        "payout=s" => \$payout,
        "start=s"  => \$start,
        "final=s"  => \$final,
        "tfile=s"  => \$tfile,
        "url=s"    => \$url,
        "sim=s"    => \$sim
    );

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

    my $config = {
        log                        => '',
        number_of_sims             => $number_of_sims,
        always_wins_number_of_sims => 10_000,
        control_loss_threshold     => 0.15,
        number_of_rounds_remaining => $final - $start,
        lowest_ranked_payout       => $lowest_ranked_payout,
        gibson_spread_per_game     => 500,

        # Padded with a 0 at the beginning to account for the
        # last round always being KOTH
        hopefulness => [ 0, 0, 0.1, 0.05, 0.01, 0.0025 ]
    };

    xyzpair( $config, $tournament_players, $times_played_hash );

    printf( $config->{log} );
}

main();
