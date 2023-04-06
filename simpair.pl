#!/usr/bin/perl

use warnings;
use strict;
use Data::Dumper;
use File::Basename;
use Graph::Matching qw(max_weight_matching);

use constant PROHIBITIVE_WEIGHT => 1000000;

sub log_info {
    my ( $config, $content ) = @_;
    $config->{log} .= $content;
}

sub log_config {
    my ($config) = @_;
    $config->{log} .= "CONFIG\n\n" . Dumper($config);
}

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
    my ( $config, $tournament_players, $times_played_hash ) = @_;

    log_config($config);

    # Lowest ranked payout was given as 1-indexed
    # To keep this consistent with the rest of the 0-indexed
    # code in these functions, we convert it to 0-indexed here.

    $config->{lowest_ranked_payout}--;

    if ( $config->{number_of_rounds_remaining} <= 0 ) {
        return sprintf( "Invalid rounds remaining: %d\n",
            $config->{number_of_rounds_remaining} );
    }

    sort_tournament_players_by_record($tournament_players);

    log_info(
        $config,
        sprintf( "\n\nSTANDINGS\n\n%s\n",
            tournament_players_string($tournament_players) )
    );

    my $number_of_players = scalar(@$tournament_players);

    my $factor_pair_results = sim_factor_pair( $config, $tournament_players );

    my ( $lowest_ranked_always_wins, $control_loss ) =
      get_control_loss( $config, $factor_pair_results, $tournament_players,
        $number_of_players );

    log_info( $config,
        results_string( $tournament_players, $factor_pair_results ) );

    sort_tournament_players_by_record($tournament_players);

    my $lowest_gibson_rank =
      get_lowest_gibson_rank( $config, $tournament_players,
        $number_of_players );

    my $lowest_ranked_placers =
      get_lowest_ranked_placers( $config, $factor_pair_results,
        $tournament_players, $number_of_players );

    my $lowest_ranked_player_within_payout =
      $lowest_ranked_placers->[ $config->{lowest_ranked_payout} ];

    log_info(
        $config,
        sprintf(
            "\nLowest ranked player who can still cash: %d (%s)",
            $lowest_ranked_player_within_payout,
            $tournament_players->[$lowest_ranked_player_within_payout]->{name}
        )
    );

    log_info( $config, "\n\nPAIRING WEIGHTS\n\n" );
    my $max_weight = 0;
    my @edges      = ();
    for my $i ( 0 .. ( $number_of_players - 1 ) ) {
        my $player_i = $tournament_players->[$i];
        for my $j ( ( $i + 1 ) .. ( $number_of_players - 1 ) ) {
            my $player_j = $tournament_players->[$j];

            my $number_of_times_played =
              get_number_of_times_played( $player_i, $player_j,
                $times_played_hash );

            my $repeat_weight = int( ( $number_of_times_played * 2 ) *
                  ( ( $number_of_players / 3 )**3 ) );

            my $rank_difference_weight = ( $j - $i )**3;

            # Pair with payout placers weight
            my $pair_with_placer_weight = 0;
            my $control_loss_weight     = 0;
            my $gibson_weight           = 0;
            my $koth_weight             = 0;

            if ( $config->{number_of_rounds_remaining} == 1 ) {

                # For the last round, just do KOTH for all players
                # eligible for a cash payout
                if ( $i <= $lowest_ranked_player_within_payout ) {
                    if ( $i % 2 == 1 or $i + 1 != $j ) {

                        # player i needs to paired with the player
                        # immediately after them in the rankings.
                        # If player i has a odd rank, then they have
                        # already been weight appropiately with the
                        # player above them.
                        $koth_weight = PROHIBITIVE_WEIGHT;
                    }
                }
            }
            else {
                # If neither of these blocks are true, that means both
                # players are gibsonized and we don't have to consider
                # control loss or placement.
                if (    $i <= $lowest_gibson_rank
                    and $j > $lowest_gibson_rank
                    and $j <= $lowest_ranked_player_within_payout )
                {
                    # player i is gibsonized and player j can still cash, they
                    # shouldn't be paired
                    $gibson_weight = PROHIBITIVE_WEIGHT;
                }
                elsif ( $i > $lowest_gibson_rank and $j > $lowest_gibson_rank )
                {
                    # Neither player is gibsonized
                    if ( $i <= $config->{lowest_ranked_payout} ) {

                        # player i is at a cash payout rank
                        if ( $j <= $lowest_ranked_placers->[$i] ) {

                            # player j can still can catch player i
                            # add a penalty for the distance of this pairing
                            $pair_with_placer_weight =
                              ( ( $lowest_ranked_placers->[$i] - $j )**3 ) * 2;
                        }
                        else {
                            # player j can't catch player i, so they should
                            # preferrable not be paired
                            $pair_with_placer_weight = PROHIBITIVE_WEIGHT;
                        }
                    }

                    # Control loss weight
                    # Only applies to the player in first
                    if (    $i == 0
                        and $j > $lowest_ranked_always_wins
                        and $control_loss >= $config->{control_loss_threshold} )
                    {
                        $control_loss_weight = PROHIBITIVE_WEIGHT;
                    }
                }
            }

            my $weight =
              $repeat_weight +
              $rank_difference_weight +
              $pair_with_placer_weight +
              $control_loss_weight +
              $gibson_weight +
              $koth_weight;
            if ( $weight > $max_weight ) {
                $max_weight = $weight;
            }
            log_info(
                $config,
                sprintf(
"Weight for pairing %20s vs %20s (%3d) = %7d = %7d + %7d + %7d + %7d + %7d + %7d\n",
                    $player_i->{name},        $player_j->{name},
                    $number_of_times_played,  $weight,
                    $repeat_weight,           $rank_difference_weight,
                    $pair_with_placer_weight, $control_loss_weight,
                    $gibson_weight,           $koth_weight
                )
            );
            push @edges, [ $i, $j, $weight ];
        }
    }

    my $pairings = min_weight_matching( \@edges, $max_weight );
    log_info( $config,
        pairings_string( $tournament_players, $pairings, $times_played_hash ) );
    return $pairings;
}

sub get_number_of_times_played {
    my ( $player_i, $player_j, $times_played_hash ) = @_;
    my $times_played_key =
      create_times_played_key( $player_i->{index}, $player_j->{index} );
    my $number_of_times_played = 0;
    if ( exists $times_played_hash->{$times_played_key} ) {
        $number_of_times_played = $times_played_hash->{$times_played_key};
    }
    return $number_of_times_played;
}

sub get_lowest_ranked_placers {
    my ( $config, $factor_pair_results, $tournament_players,
        $number_of_players ) = @_;

    my $adjusted_hopefulness = 0;
    if ( $config->{number_of_rounds_remaining} <
        scalar( @{ $config->{hopefulness} } ) )
    {
        $adjusted_hopefulness =
          $config->{hopefulness}->[ $config->{number_of_rounds_remaining} ];
    }

    log_info( $config,
        "\n\nLOWEST RANKED PLACERS\n\n"
          . sprintf( "\nAdjusted hopefulness: %0.6f\n\n",
            $adjusted_hopefulness ) );

    my @lowest_ranked_placers =
      (0) x ( $number_of_players * $number_of_players );

    for my $i ( 0 .. $number_of_players - 1 ) {
        for my $rank_index ( 0 .. $number_of_players - 1 ) {
            my $player = $tournament_players->[$rank_index];
            my $place_percentage =
              get_tournament_result( $factor_pair_results, $player, $i ) /
              $config->{number_of_sims};
            if ( $place_percentage > $adjusted_hopefulness ) {
                $lowest_ranked_placers[$i] = $rank_index;
            }
        }
    }

    for my $i ( 0 .. $number_of_players - 1 ) {
        log_info(
            $config,
            sprintf(
                "Lowest rankest possible winner for rank %d: %d (%s)\n",
                $i + 1,
                $lowest_ranked_placers[$i] + 1,
                $tournament_players->[ $lowest_ranked_placers[$i] ]->{name}
            )
        );
    }
    return \@lowest_ranked_placers;
}

sub get_control_loss {
    my ( $config, $factor_pair_results, $tournament_players,
        $number_of_players ) = @_;

    my ( $always_wins_pair_player_with_first, $always_wins_factor_pair ) =
      sim_player_always_wins( $config, $tournament_players );

    my $lowest_ranked_always_wins = 0;
    for my $i ( 1 .. $number_of_players - 1 ) {
        if ( $always_wins_pair_player_with_first->[ $i - 1 ] ==
            $config->{always_wins_number_of_sims} )
        {
            $lowest_ranked_always_wins = $i;
        }
        else {
            last;
        }
    }
    my $control_loss =
      ( $config->{always_wins_number_of_sims} -
          $always_wins_factor_pair->[ $lowest_ranked_always_wins - 1 ] ) /
      $config->{always_wins_number_of_sims};

    log_info( $config, "\n\nCONTROL LOSS\n\n" );

    log_info(
        $config,
        sprintf(
            "Lowest ranked always winning player: %d (%s), %f\n",
            $lowest_ranked_always_wins + 1,
            $tournament_players->[$lowest_ranked_always_wins]->{name},
            $control_loss
        )
    );
    log_info(
        $config,
        sprintf(
            "Tournaments won while repeatedly winning against first:  %s\n",
            join( ",",
                map { sprintf( "%6s", $_ ) }
                  @$always_wins_pair_player_with_first )
        )
    );
    log_info(
        $config,
        sprintf(
            "Tournaments won while repeatedly winning in factor pair: %s\n\n",
            join( ",", map { sprintf( "%6s", $_ ) } @$always_wins_factor_pair )
        )
    );
    return $lowest_ranked_always_wins, $control_loss;
}

sub get_lowest_gibson_rank {
    my ( $config, $tournament_players, $number_of_players ) = @_;
    my $lowest_gibson_rank = -1;
    for my $player_in_nth_rank_index ( 0 .. $number_of_players - 1 ) {
        if ( $player_in_nth_rank_index == $number_of_players - 1 ) {

            # Somehow, everyone is gibsonized
            # IRL, this should never happen, but for this code
            # it will prevent index out-of-bounds errors.
            $lowest_gibson_rank = $number_of_players - 1;
            last;
        }
        my $player_in_nth = $tournament_players->[$player_in_nth_rank_index];
        my $player_in_nplus1th =
          $tournament_players->[ $player_in_nth_rank_index + 1 ];
        if (
            ( $player_in_nth->{wins} - $player_in_nplus1th->{wins} ) / 2 >
            $config->{number_of_rounds_remaining}
            or ( ( $player_in_nth->{wins} - $player_in_nplus1th->{wins} ) /
                2 == $config->{number_of_rounds_remaining}
                and $player_in_nth->{spread} - $player_in_nplus1th->{spread} >
                $config->{gibson_spread_per_game} *
                $config->{number_of_rounds_remaining} )
          )
        {
            # Player in nth is gibsonized for nth place
            $lowest_gibson_rank = $player_in_nth_rank_index;
        }
        else {
            last;
        }
    }
    return $lowest_gibson_rank;
}

sub sim_factor_pair {
    my ( $config, $tournament_players ) = @_;
    my $results = new_tournament_results( scalar(@$tournament_players) );
    for ( 0 .. ( $config->{number_of_sims} - 1 ) ) {
        for (
            my $remaining_rounds = $config->{number_of_rounds_remaining} ;
            $remaining_rounds >= 1 ;
            $remaining_rounds--
          )
        {
            my $pairings =
              factor_pair( $tournament_players, $remaining_rounds );
            play_round( $pairings, $tournament_players, -1 );
        }
        record_tournament_results( $results, $tournament_players );

        foreach my $player (@$tournament_players) {
            reset_tournament_player($player);
        }
        sort_tournament_players_by_record($tournament_players);
    }
    return $results;
}

sub sim_player_always_wins {
    my ( $config, $tournament_players ) = @_;

    my @pair_with_first_tournament_wins;
    my @factor_pair_tournament_wins;
    my $player_in_first_wins = $tournament_players->[0]->{wins};

    for my $player_in_nth_rank_index ( 1 .. scalar(@$tournament_players) - 1 ) {
        my $win_diff = ( $player_in_first_wins -
              $tournament_players->[$player_in_nth_rank_index]->{wins} ) / 2;

        # This player cannot win
        if ( $win_diff > $config->{number_of_rounds_remaining} ) {
            last;
        }

        my $pwf_wins = 0;
        my $fp_wins  = 0;
        my $player_in_nth_rank_index_index =
          $tournament_players->[$player_in_nth_rank_index]->{index};

        for my $i ( 1 .. $config->{always_wins_number_of_sims} ) {
            for (
                my $remaining_rounds = $config->{number_of_rounds_remaining} ;
                $remaining_rounds >= 1 ;
                $remaining_rounds--
              )
            {
                my %player_index_to_rank =
                  map { $tournament_players->[$_]->{index} => $_ }
                  0 .. scalar(@$tournament_players) - 1;
                my $pairings = factor_pair_minus_player(
                    $tournament_players,             $remaining_rounds,
                    $player_in_nth_rank_index_index, \%player_index_to_rank
                );
                play_round( $pairings, $tournament_players,
                    $player_index_to_rank{$player_in_nth_rank_index_index} );

                if ( $tournament_players->[0]->{index} ==
                    $player_in_nth_rank_index_index )
                {
                    $pwf_wins++;
                    last;
                }
            }

            for my $player (@$tournament_players) {
                reset_tournament_player($player);
            }

            sort_tournament_players_by_record($tournament_players);

            for (
                my $remaining_rounds = $config->{number_of_rounds_remaining} ;
                $remaining_rounds >= 1 ;
                $remaining_rounds--
              )
            {
                my %player_index_to_rank =
                  map { $tournament_players->[$_]->{index} => $_ }
                  0 .. scalar(@$tournament_players) - 1;
                my $pairings =
                  factor_pair( $tournament_players, $remaining_rounds );
                play_round( $pairings, $tournament_players,
                    $player_index_to_rank{$player_in_nth_rank_index_index} );

                if ( $tournament_players->[0]->{index} ==
                    $player_in_nth_rank_index_index )
                {
                    $fp_wins++;
                    last;
                }
            }

            for my $player (@$tournament_players) {
                reset_tournament_player($player);
            }

            sort_tournament_players_by_record($tournament_players);
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
            $tournament_players->[ $pairing->[0] ]->{spread} += 50;
            $tournament_players->[ $pairing->[0] ]->{wins}   += 2;
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
        $tournament_players->[ $pairing->[0] ]->{spread} += $spread;
        $tournament_players->[ $pairing->[0] ]->{wins}   += $p1win;
        $tournament_players->[ $pairing->[1] ]->{spread} += -$spread;
        $tournament_players->[ $pairing->[1] ]->{wins}   += $p2win;
    }

    sort_tournament_players_by_record($tournament_players);
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
    my $player_in_nth_rank_index =
      splice( @$tournament_players, $player_rank_index, 1 );
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
    splice( @$tournament_players, $player_rank_index, 0,
        $player_in_nth_rank_index );

    return \@pairings;
}

sub sort_tournament_players_by_record {
    my $tournament_players = shift;
    @{$tournament_players} =
      sort { $b->{wins} <=> $a->{wins} or $b->{spread} <=> $a->{spread} }
      @{$tournament_players};
}

sub sort_tournament_players_by_index {
    my $tournament_players = shift;
    @{$tournament_players} =
      sort { $a->{index} <=> $b->{index} } @{$tournament_players};
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

# For logging only
sub results_string {
    my ( $tournament_players, $results ) = @_;
    sort_tournament_players_by_record($tournament_players);
    my $result = "\n\nRESULTS\n\n";
    $result .= sprintf( "%30s", ("") );
    for ( my $i = 0 ; $i < $results->{number_of_players} ; $i++ ) {
        $result .= sprintf( "%-7s", ( $i + 1 ) );
    }
    $result .= sprintf("\n");
    foreach my $player (@$tournament_players) {
        $result .= sprintf( "%-30s", ( $player->{name} ) );
        for ( my $j = 0 ; $j < $results->{number_of_players} ; $j++ ) {
            $result .= sprintf( "%-7s",
                ( get_tournament_result( $results, $player, $j ) ) );
        }
        $result .= sprintf("\n");
    }
    return $result;
}

sub tournament_players_string {
    my $tournament_players = shift;
    my $result             = '';
    for ( my $i = 0 ; $i < @$tournament_players ; $i++ ) {
        my $tp = $tournament_players->[$i];
        $result .= sprintf(
            "%-3s %-20s %0.1f %d\n",
            ( $i + 1 ),
            $tp->{name}, ( $tp->{wins} / 2 ),
            $tp->{spread}
        );
    }
    return $result;
}

sub pairings_string {
    my ( $players, $pairings, $times_played_hash ) = @_;

    my $result     = "\n\nPAIRINGS\n\n";
    my %used_pairs = ();
    foreach my $i ( 0 .. $#$players ) {
        my $player    = $players->[$i];
        my $opp_index = $pairings->{$i};
        next
          if $used_pairs{"$i:$opp_index"}
          || $used_pairs{"$opp_index:$i"}
          || !defined($opp_index);
        $used_pairs{"$i:$opp_index"} = 1;
        $used_pairs{"$opp_index:$i"} = 1;

        my $opponent = $players->[$opp_index];

        my $times_played_key =
          create_times_played_key( $player->{index}, $opponent->{index} );
        my $number_of_times_played = 0;
        if ( exists $times_played_hash->{$times_played_key} ) {
            $number_of_times_played = $times_played_hash->{$times_played_key};
        }

        $result .= sprintf(
            "%s (%d, %d, %d) vs %s (%d, %d, %d) (%d)\n",
            $player->{name},       $i + 1,
            $player->{wins} / 2,   $player->{spread},
            $opponent->{name},     $opp_index + 1,
            $opponent->{wins} / 2, $opponent->{spread},
            $number_of_times_played
        );
    }

    return $result;
}

1;
