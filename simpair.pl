#!/usr/bin/perl

use warnings;
use strict;
use Data::Dumper;
use File::Basename;
use Graph::Matching qw(max_weight_matching);

use constant HOPEFULNESS                => qw(0 0 0.1 0.05 0.01 0.0025);
use constant ALWAYS_WINS_NUMBER_OF_SIMS => 10000;
use constant CONTROL_LOSS_THRESHOLD     => 0.15;

# Subroutintes for tournament results

# Create new tournament results
# The tournament results are a 2-d array
# represented as a 1-d array. Each row
# represents a player and each column
# represents the place that player achieved
# by the end of the tournament. The count
# is the number of simulations performed.

sub new_tournament_results {
    my $number_of_players = shift;
    my $self              = {
        number_of_players => $number_of_players,
        array => [ (0) x ( $number_of_players * $number_of_players ) ],
        count => 0
    };
    return $self;
}

sub record_tournament_results {
    my ( $tournament_results, $tournament_players ) = @_;
    for ( my $i = 0 ; $i < $tournament_results->{number_of_players} ; $i++ ) {
        my $player = $tournament_players->[$i];
        $tournament_results->{array}
          ->[ ( $tournament_results->{number_of_players} * $player->{index} ) +
          $i ] += 1;
    }
    $tournament_results->{count} += 1;
}

sub get_tournament_result {
    my ( $tournament_results, $player, $place ) = @_;
    return $tournament_results->{array}
      ->[ ( $tournament_results->{number_of_players} * $player->{index} ) +
      $place ];
}

# Player scores

sub new_player_scores {
    my ( $name, $index, $opponent_indexes, $scores ) = @_;
    my $self = {
        name             => $name,
        index            => $index,
        opponent_indexes => $opponent_indexes,
        scores           => $scores
    };
    return $self;
}

# Tournament players

sub new_tournament_player {
    my ( $name, $index, $wins, $spread ) = @_;
    my $self = {
        name         => $name,
        index        => $index,
        start_wins   => $wins,
        wins         => $wins,
        start_spread => $spread,
        spread       => $spread
    };
    return $self;
}

sub reset_tournament_player {
    my $tournament_player = shift;
    $tournament_player->{wins}   = $tournament_player->{start_wins};
    $tournament_player->{spread} = $tournament_player->{start_spread};
}

# Pairing and simming

sub pair {
    my (
        $tournament_players, $times_played_hash,    $start_round,
        $final_round,        $lowest_ranked_payout, $number_of_sims
    ) = @_;
    @{$tournament_players} =
      sort { $b->{wins} <=> $a->{wins} or $b->{spread} <=> $a->{spread} }
      @{$tournament_players};
    my $factor_pair_results =
      sim_factor_pair( $tournament_players, $start_round, $final_round,
        100000 );
    my ( $always_wins_pair_player_with_first, $always_wins_factor_pair ) =
      sim_player_always_wins( $tournament_players, $start_round, $final_round,
        ALWAYS_WINS_NUMBER_OF_SIMS );
    my $lowest_ranked_always_wins = 0;
    for ( my $i = 1 ; $i < scalar @$tournament_players ; $i++ ) {
        if ( $always_wins_pair_player_with_first->[ $i - 1 ] ==
            ALWAYS_WINS_NUMBER_OF_SIMS )
        {
            $lowest_ranked_always_wins = $i;
        }
        else {
            last;
        }
    }
    my $control_loss =
      ( ALWAYS_WINS_NUMBER_OF_SIMS -
          $always_wins_factor_pair->[ $lowest_ranked_always_wins - 1 ] ) /
      ALWAYS_WINS_NUMBER_OF_SIMS;

    printf(
        "control loss for %s: %0.4f\n",
        $tournament_players->[$lowest_ranked_always_wins]->{name},
        $control_loss
    );

    print( "player always wins and plays player in first: ",
        join( ", ", @$always_wins_pair_player_with_first ), "\n" );
    print( "player always wins factor pair:               ",
        join( ", ", @$always_wins_factor_pair ), "\n" );
    print_results( $tournament_players, $factor_pair_results );
    @{$tournament_players} =
      sort { $b->{wins} <=> $a->{wins} or $b->{spread} <=> $a->{spread} }
      @{$tournament_players};

    my $number_of_rounds_remaining = $final_round - $start_round;

    my $adjusted_hopefulness = 0;
    my @hopefulness          = (HOPEFULNESS);
    if ( $number_of_rounds_remaining < scalar(@hopefulness) ) {
        $adjusted_hopefulness = $hopefulness[$number_of_rounds_remaining];
    }

    printf( "adjusted hopefulness for round %d: %0.6f\n",
        $start_round, $adjusted_hopefulness );

    my $number_of_players = scalar(@$tournament_players);
    my @lowest_ranked_placers =
      (0) x ( $number_of_players * $number_of_players );

    for my $i ( 0 .. $number_of_players - 1 ) {
        for my $rank_index ( 0 .. scalar(@$tournament_players) - 1 ) {
            my $player = $tournament_players->[$rank_index];
            if (
                (
                    get_tournament_result( $factor_pair_results, $player, $i ) / $number_of_sims
                ) > $adjusted_hopefulness
              )
            {
                $lowest_ranked_placers[$i] = $rank_index;
            }
        }        
    }

    for my $i ( 0 .. $number_of_players - 1 ) {
        printf(
            "lowest rankest possible winner: %d, %d, %s\n",
            $i + 1,
            $lowest_ranked_placers[$i],
            $tournament_players->[ $lowest_ranked_placers[$i] ]->{name}
        );
    }

    my $max_weight = 0;
    my @edges      = ();
    for my $i ( 0 .. ( $number_of_players - 1 ) ) {
        for my $j ( ( $i + 1 ) .. ( $number_of_players - 1 ) ) {
            my $player_i = $tournament_players->[$i];
            my $player_j = $tournament_players->[$j];
            my $times_played_key =
              create_times_played_key( $player_i->{index}, $player_j->{index} );
            my $number_of_times_played = 0;
            if ( exists $times_played_hash->{$times_played_key} ) {
                $number_of_times_played =
                  $times_played_hash->{$times_played_key};
            }

            my $repeat_weight = int (( $number_of_times_played * 2 ) *
              ( ( $number_of_players / 3 )**3 ));

            my $rank_difference_weight = ( $j - $i )**3;

            my $pair_with_placer = 0;
            if ( $i <= $lowest_ranked_payout ) {
                $pair_with_placer = 1000000;
                if ( ( $j <= $lowest_ranked_placers[$i] ) ) {
                    $pair_with_placer =
                      ( ( $lowest_ranked_placers[$i] - $j )**3 ) * 2;
                }
            }

            my $control_weight = 0;
            if ( $i == 0 ) {
                $control_weight = 1000000;
                if (   $j <= $lowest_ranked_always_wins
                    or $control_loss < CONTROL_LOSS_THRESHOLD )
                {
                    $control_weight = 0;
                }
            }

            my $weight =
              $repeat_weight +
              $rank_difference_weight +
              $pair_with_placer +
              $control_weight;
            if ( $weight > $max_weight ) {
                $max_weight = $weight;
            }
            print(
"weight for $player_i->{name} vs $player_j->{name} ($number_of_times_played) is $weight = $repeat_weight + $rank_difference_weight + $pair_with_placer + $control_weight\n"
            );
            push @edges, [ $i, $j, $weight ];
        }
    }
    return min_weight_matching( \@edges, $max_weight );
}

sub sim_factor_pair {
    my ( $tournament_players, $start_round, $final_round, $n ) = @_;
    my $results = new_tournament_results( scalar(@$tournament_players) );
    foreach my $i ( 1 .. $n ) {
        foreach my $current_round ( $start_round .. $final_round - 1 ) {
            my $pairings =
              factor_pair( $tournament_players, $final_round - $current_round );
            play_round( $pairings, $tournament_players, -1 );
        }
        record_tournament_results( $results, $tournament_players );

        foreach my $player (@$tournament_players) {
            reset_tournament_player($player);
        }
        @{$tournament_players} =
          sort { $b->{wins} <=> $a->{wins} or $b->{spread} <=> $a->{spread} }
          @{$tournament_players};
    }
    return $results;
}

sub sim_player_always_wins {
    my ( $tournament_players, $start_round, $final_round, $n ) = @_;

    my @pair_with_first_tournament_wins;
    my @factor_pair_tournament_wins;
    my $player_in_first_wins = $tournament_players->[0]->{wins};

    for my $player_in_nth ( 1 .. scalar(@$tournament_players) - 1 ) {

        # This player cannot win
        if (
            (
                $player_in_first_wins -
                $tournament_players->[$player_in_nth]->{wins}
            ) / 2 > ( $final_round - $start_round )
          )
        {
            last;
        }

        my $pwf_wins = 0;
        my $fp_wins  = 0;
        my $player_in_nth_index =
          $tournament_players->[$player_in_nth]->{index};

        for ( my $i = 0 ; $i < $n ; $i++ ) {
            for my $current_round ( $start_round .. $final_round - 1 ) {
                my %player_index_to_rank =
                  map { $tournament_players->[$_]->{index} => $_ }
                  0 .. scalar(@$tournament_players) - 1;
                my $pairings = factor_pair_minus_player(
                    $tournament_players,  $final_round - $current_round,
                    $player_in_nth_index, \%player_index_to_rank
                );
                play_round( $pairings, $tournament_players,
                    $player_index_to_rank{$player_in_nth_index} );

                if ( $tournament_players->[0]->{index} == $player_in_nth_index )
                {
                    $pwf_wins++;
                    last;
                }
            }

            for my $player (@$tournament_players) {
                reset_tournament_player($player);
            }
            @$tournament_players = sort {
                -( $a->{wins} * 10000 + $a->{spread} )
                  <=> -( $b->{wins} * 10000 + $b->{spread} )
            } @$tournament_players;

            for my $current_round ( $start_round .. $final_round - 1 ) {
                my %player_index_to_rank =
                  map { $tournament_players->[$_]->{index} => $_ }
                  0 .. scalar(@$tournament_players) - 1;
                my $pairings = factor_pair( $tournament_players,
                    $final_round - $current_round );

                play_round( $pairings, $tournament_players,
                    $player_index_to_rank{$player_in_nth_index} );

                if ( $tournament_players->[0]->{index} == $player_in_nth_index )
                {
                    $fp_wins++;
                    last;
                }
            }

            for my $player (@$tournament_players) {
                reset_tournament_player($player);
            }

            @{$tournament_players} = sort {
                     $b->{wins} <=> $a->{wins}
                  or $b->{spread} <=> $a->{spread}
            } @{$tournament_players};
        }

        push @pair_with_first_tournament_wins, $pwf_wins;
        push @factor_pair_tournament_wins,     $fp_wins;
    }
    return \@pair_with_first_tournament_wins, \@factor_pair_tournament_wins;
}

sub play_round {
    my ( $pairings, $tournament_players, $forced_win_player ) = @_;

    foreach my $pairing (@$pairings) {
        if ( $pairing->[1] == -1 ) {

            # Player gets a bye
            $tournament_players->[ $pairing->[0] ]->{"spread"} += 50;
            $tournament_players->[ $pairing->[0] ]->{"wins"}   += 2;
            next;
        }
        my $spread = 200 - int( rand(401) );
        if ( $forced_win_player >= 0 ) {
            if ( $pairing->[0] == $forced_win_player ) {
                $spread = abs($spread) + 1;
            }
            elsif ( $pairing->[1] == $forced_win_player ) {
                $spread = -abs($spread) - 1;
            }
        }
        my $p1win = 1;
        my $p2win = 1;
        if ( $spread > 0 ) {
            $p1win = 2;
            $p2win = 0;
        }
        elsif ( $spread < 0 ) {
            $p1win = 0;
            $p2win = 2;
        }
        $tournament_players->[ $pairing->[0] ]->{"spread"} += $spread;
        $tournament_players->[ $pairing->[0] ]->{"wins"}   += $p1win;
        $tournament_players->[ $pairing->[1] ]->{"spread"} += -$spread;
        $tournament_players->[ $pairing->[1] ]->{"wins"}   += $p2win;
    }
    @{$tournament_players} =
      sort { $b->{wins} <=> $a->{wins} or $b->{spread} <=> $a->{spread} }
      @{$tournament_players};
}

sub create_times_played_key {
    my ( $p1, $p2 ) = @_;
    my ( $a, $b ) = ( $p1, $p2 );
    if ( $b < $a ) {
        ( $a, $b ) = ( $p2, $p1 );
    }
    return "$a:$b";
}

sub factor_pair {
    my ( $tournament_players, $nrl ) = @_;

    # For now, just implement KOTH
    # This assumes players are already sorted
    my @pairings;
    for ( my $i = 0 ; $i < $nrl ; $i++ ) {
        push @pairings, [ $i, $i + $nrl ];
    }
    for ( my $i = $nrl * 2 ; $i < scalar(@$tournament_players) ; $i += 2 ) {
        push @pairings, [ $i, $i + 1 ];
    }

    return \@pairings;
}

sub factor_pair_minus_player {
    my ( $tournament_players, $nrl, $player_index, $player_index_to_rank ) = @_;

    # Pop in descending order to ensure player_rank_index
    # removes the correct player
    my $player_rank_index = $player_index_to_rank->{$player_index};
    my $player_in_nth   = splice( @$tournament_players, $player_rank_index, 1 );
    my $player_in_first = shift @$tournament_players;

    if ( $nrl * 2 > scalar(@$tournament_players) ) {
        $nrl = scalar(@$tournament_players) / 2;
    }

    my @pairings = ( [ 0, $player_rank_index ] );
    for ( my $i = 0 ; $i < $nrl ; $i++ ) {
        my $i_player =
          $player_index_to_rank->{ $tournament_players->[$i]->{index} };
        my $nrl_player =
          $player_index_to_rank->{ $tournament_players->[ $i + $nrl ]->{index}
          };
        push @pairings, [ $i_player, $nrl_player ];
    }
    for ( my $i = $nrl * 2 ; $i < scalar(@$tournament_players) ; $i += 2 ) {
        my $i_player =
          $player_index_to_rank->{ $tournament_players->[$i]->{index} };
        my $i_plus_one_player =
          $player_index_to_rank->{ $tournament_players->[ $i + 1 ]->{index} };
        push @pairings, [ $i_player, $i_plus_one_player ];
    }

    unshift @$tournament_players, $player_in_first;
    splice( @$tournament_players, $player_rank_index, 0, $player_in_nth );

    return \@pairings;
}

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

        splice( @scores,           $start_round );
        splice( @opponent_indexes, $start_round );

        if ( @scores != @opponent_indexes ) {
            print "scores and opponents are not the same size for $line\n";
            exit(-1);
        }
        my $name          = $first_name . " " . $last_name;
        my %player_scores = (
            name             => $name,
            index            => $index,
            opponent_indexes => \@opponent_indexes,
            scores           => \@scores
        );
        push @players_scores, \%player_scores;
        $index++;
    }
    close($fh);
    return \@players_scores;
}

sub tournament_players_from_players_scores {
    my ($players_scores) = @_;
    my @tournament_players;
    my %times_played_hash;
    for my $player_index ( 0 .. $#{$players_scores} ) {
        my $pscores = $players_scores->[$player_index];
        my $wins    = 0;
        my $spread  = 0;

        for my $round ( 0 .. $#{ $pscores->{scores} } ) {
            my $opponent_index = $pscores->{opponent_indexes}[$round];
            my $times_played_key =
              create_times_played_key( $player_index, $opponent_index );

            if ( exists $times_played_hash{$times_played_key} ) {
                $times_played_hash{$times_played_key} += 1;
            }
            else {
                $times_played_hash{$times_played_key} = 1;
            }

            my $game_spread = $pscores->{scores}[$round] -
              $players_scores->[$opponent_index]->{scores}[$round];

            if ( $game_spread > 0 ) {
                $wins += 2;
            }
            elsif ( $game_spread == 0 ) {
                $wins += 1;
            }

            $spread += $game_spread;
        }

        push @tournament_players,
          {
            name         => $pscores->{name},
            index        => $pscores->{index},
            start_wins   => $wins,
            wins         => $wins,
            start_spread => $spread,
            spread       => $spread
          };
    }

    for my $times_played_key ( keys %times_played_hash ) {
        $times_played_hash{$times_played_key} /= 2;
    }

    @tournament_players =
      sort { $b->{wins} <=> $a->{wins} or $b->{spread} <=> $a->{spread} }
      @tournament_players;

    return ( \@tournament_players, \%times_played_hash );
}

sub tournament_players_from_tfile {
    my ( $filename, $start_round ) = @_;
    my $players_scores = players_scores_from_tfile( $filename, $start_round );
    my ( $tournament_players, $times_played_hash ) =
      tournament_players_from_players_scores($players_scores);
    return ( $tournament_players, $times_played_hash );
}

# Min weight matching

sub min_weight_matching {
    my ( $edges, $max_weight ) = @_;
    for my $i ( 0 .. $#{$edges} ) {
        $edges->[$i]->[2] = ( $max_weight + 1 ) - $edges->[$i]->[2];
    }

    # Pass 1 for max cardinality
    my %matching = max_weight_matching( $edges, 1 );
    return \%matching;
}

# Printing

sub print_tournament_players {
    my ($tournament_players) = @_;
    for ( my $i = 0 ; $i < @$tournament_players ; $i++ ) {
        my $tp = $tournament_players->[$i];
        printf(
            "%-3s %-30s %0.1f %d\n",
            ( $i + 1 ),
            $tp->{name}, ( $tp->{wins} / 2 ),
            $tp->{spread}
        );
    }
}

sub print_results {
    my ( $tournament_players, $results ) = @_;
    @$tournament_players =
      sort { $a->{index} <=> $b->{index} } @$tournament_players;
    printf( "%30s", ("") );
    for ( my $i = 0 ; $i < $results->{number_of_players} ; $i++ ) {
        printf( "%-7s", ( $i + 1 ) );
    }
    printf("\n");
    foreach my $player (@$tournament_players) {
        printf( "%-30s", ( $player->{name} ) );
        for ( my $j = 0 ; $j < $results->{number_of_players} ; $j++ ) {
            printf( "%-7s",
                ( get_tournament_result( $results, $player, $j ) ) );
        }
        printf("\n");
    }
}

1;
