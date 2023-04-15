#!/usr/bin/perl

package TSH::Command::COP;

use strict;
use warnings;

use lib '/home/josh/TSH/lib/perl/';

use TSH::PairingCommand;
use TSH::Player;
use TSH::Utility qw(Debug);
use TSH::Utility qw(Debug DebugOn DebugOff);

# Needed by COP
use File::Basename;
use Data::Dumper;
use Graph::Matching qw(max_weight_matching);

our (@ISA) = qw(TSH::PairingCommand);

=pod

=head1 NAME

TSH::Command::COP - implement the C<tsh> COP command

=head1 SYNOPSIS

  my $command = new TSH::Command::COP;
  my $argsp = $command->ArgumentTypes();
  my $helptext = $command->Help();
  my (@names) = $command->Names();
  $command->Run($tournament, @parsed_arguments);
  
=head1 ABSTRACT

TSH::Command::COP is a subclass of TSH::Command.

=cut

=head1 DESCRIPTION

=over 4

=cut

sub initialise ($$$$);
sub new ($);
sub Run ($$@);

=item $parserp->initialise()

Used internally to (re)initialise the object.

=cut

sub initialise ($$$$) {
    my $this      = shift;
    my $path      = shift;
    my $namesp    = shift;
    my $argtypesp = shift;

    $this->{'help'} = <<'EOF';
Use the COP command to automatically pair a round.
EOF
    $this->{'names'}    = [qw(cop)];
    $this->{'argtypes'} = [qw(BasedOnRound Division)];

    # print "names=@$namesp argtypes=@$argtypesp\n";

    return $this;
}

sub new ($) { return TSH::Utility::new(@_); }

=item $command->Run($tournament, @parsed_args)

Should run the command in the context of the given
tournament with the specified parsed arguments.

=cut

sub Run ($$@) {
    my $this       = shift;
    my $tournament = shift;
    my ( $sr, $dp ) = @_;
    my $sr0 = $sr - 1;

    # Create log directory
    my $log_dir =
      sprintf( "%s/cop_logs/", $tournament->Config()->{root_directory} );

    mkdir $log_dir;

    if ( !-e $log_dir ) {
        $tournament->TellUser( 'eapfail',
            "failed to create directory %log_dir" );
        return 0;
    }

    my $timestamp = localtime();
    $timestamp =~ s/[\s\:]/_/g;
    my $division_name = $dp->Name();
    my $sr1           = $sr0 + 1;
    my $log_filename =
      "$log_dir$timestamp" . "_div_$division_name" . "_round_$sr1.log";

    my $max_round = $dp->MaxRound0();

    # Extract TSH config vars

    my $gibson_spread = $tournament->Config()->Value('gibson_spread');
    if ( !defined $gibson_spread || scalar @{$gibson_spread} == 0 ) {
        $tournament->TellUser( 'ebadconfigarray',
            'gibson_spread', $gibson_spread );
        return 0;
    }

    my $number_of_sims = $tournament->Config()->Value('simulations');
    if ( !defined $number_of_sims ) {
        $tournament->TellUser( 'ebadconfigentry', 'simulations' );
        return 0;
    }

    my $always_wins_number_of_sims =
      $tournament->Config()->Value('always_wins_simulations');
    if ( !defined $always_wins_number_of_sims ) {
        $tournament->TellUser( 'ebadconfigentry', 'always_wins_simulations' );
        return 0;
    }

    my $control_loss_thresholds =
      $tournament->Config()->Value('control_loss_thresholds');
    if (  !defined $control_loss_thresholds
        || scalar @{$control_loss_thresholds} == 0 )
    {
        $tournament->TellUser( 'ebadconfigarray', 'control_loss_thresholds',
            $control_loss_thresholds );
        return 0;
    }

    my $hopefulness = $tournament->Config()->Value('hopefulness');
    if ( !defined $hopefulness || scalar @{$hopefulness} == 0 ) {
        $tournament->TellUser( 'ebadconfigarray', 'hopefulness', $hopefulness );
        return 0;
    }

    my $lowest_ranked_payout =
      get_lowest_ranked_payout( $tournament->Config(), $division_name );
    if ( $lowest_ranked_payout < 0 ) {
        $tournament->TellUser( 'ebadconfigentry', 'prizes' );
        return 0;
    }

    # Create the special config for cop
    my $cop_config = {
        log_filename               => $log_filename,
        number_of_sims             => $number_of_sims,
        always_wins_number_of_sims => $always_wins_number_of_sims,
        control_loss_thresholds =>
          extend_tsh_config_array( $control_loss_thresholds, $max_round ),
        number_of_rounds_remaining => $max_round - $sr0,
        lowest_ranked_payout       => $lowest_ranked_payout,
        cumulative_gibson_spreads =>
          get_cumulative_gibson_spreads( $gibson_spread, $max_round ),
          gibson_spreads => extend_tsh_config_array($gibson_spread, $max_round),
        hopefulness => extend_tsh_config_array( $hopefulness, $max_round ),
    };

    my %times_played = ();

    # Iterate through the players in a division
    my @players            = $dp->Players();
    my $number_of_players  = scalar @players;
    my @tournament_players = ();
    for ( my $i = 0 ; $i < $number_of_players ; $i++ ) {
        my $player       = $players[$i];
        my $player_index = $player->ID() - 1;
        for ( my $j = $i + 1 ; $j < $number_of_players ; $j++ ) {
            my $opponent       = $players[$j];
            my $opponent_index = $opponent->ID() - 1;
            my $number_of_times_played =
              $player->CountRoundRepeats( $opponent, $sr0 );
            my $times_played_key =
              create_times_played_key( $player_index, $opponent_index );
            $times_played{$times_played_key} = $number_of_times_played;
        }

        my $times_given_bye_key = create_times_played_key( $player_index, $number_of_players );

        # Count the byes by up to the based on round
        # (There does not seem to be an existing Player method for this)
        my $byes = 0;
        for ( my $round = 0 ; $round <= $sr0 ; $round++ ) {
            my $opponent = $player->{pairings}->[$round];
            if ( ( defined $opponent ) && $opponent == 0 ) {
                $byes++;
            }
        }
        $times_played{$times_given_bye_key} = $byes;

        push @tournament_players, new_tournament_player(
            $player->PrettyName(), $player_index,
            $player_index,

            # Wins count as 2 and draws count as 1 to
            # keep everything in integers.
            $player->RoundWins($sr0) * 2,
            $player->RoundSpread($sr0), 0
        );
    }

    my $pairings = cop( $cop_config, \@tournament_players, \%times_played );

    my $setupp = $this->SetupForPairings(
        'division' => $dp,
        'source0'  => $sr0
    ) or return 0;

    my $target0 = $setupp->{'target0'};

    for ( my $i = 0 ; $i < scalar @{$pairings} ; $i++ ) {

        # Convert back to 1-indexed
        my $player_id   = $i + 1;
        my $opponent_id = $pairings->[$i] + 1;

        if ($opponent_id > $number_of_players) {
            # This is a bye
            $opponent_id = 0;
        }

        if ( $player_id > $opponent_id && $opponent_id != 0 ) {

            # We have already made this pairing
            next;
        }
        $dp->Pair( $player_id, $opponent_id, $target0, 1 );
    }

    $this->TidyAfterPairing($dp);
}

=back

=cut

=head1 BUGS

The number of byes each player has is based on the most recent
round as opposed to the provided based on round.

=cut

use constant PROHIBITIVE_WEIGHT => 1000000;

sub log_info {
    my ( $config, $content ) = @_;

    if ( !$config->{log_filename} ) {
        return;
    }

    my $fh;
    my $file_opened = open( $fh, '>>', $config->{log_filename} );

    if ( !$file_opened ) {
        printf( "could not write to file %s: %s\n",
            $config->{log_filename}, $! );
        return;
    }

    print $fh $content;

    close($fh);
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
    my ( $name, $index, $display_index, $wins, $spread, $is_bye ) = @_;
    my $self = {
        name  => $name,
        index => $index,

        # The display index is the original index of the player
        # for the full tournament. During simulation, players
        # need to be reindexed to properly record the results,
        # but when printing for debugging and human consumption,
        # should still use the original index to avoid confusion.
        display_index => $display_index,

        # The start_* fields are used to reset the players
        # to their original record when a simulation is finished.
        start_wins => $wins,

        # Wins are worth 2 and draws are worth 1, to keep everything
        # in integers.
        wins         => $wins,
        start_spread => $spread,
        spread       => $spread,
        is_bye       => $is_bye,
    };
    return $self;
}

sub reset_tournament_player {
    my $tournament_player = shift;
    $tournament_player->{wins}   = $tournament_player->{start_wins};
    $tournament_player->{spread} = $tournament_player->{start_spread};
}

sub add_bye_player {
    my ($tournament_players, $bye_player_index) = @_;

    # This display index can be the same as the original index
    push @{$tournament_players},
      new_tournament_player( 'BYE', $bye_player_index, $bye_player_index, 0, 0, 1 );
}

# Extract lowest payout rank

sub get_lowest_ranked_payout {
    my ( $tsh_config, $division_name ) = @_;

    my $prizes_config = $tsh_config->{prizes};

    my $lowest_ranked_payout = -1;
    for ( my $i = 0 ; $i < scalar @{$prizes_config} ; $i++ ) {
        my $prize_specification = $prizes_config->[$i];
        if (   $prize_specification->{division}
            && uc( $prize_specification->{division} ) eq uc($division_name)
            && $prize_specification->{type} eq 'rank'
            && !$prize_specification->{class}
            && $prize_specification->{subtype} > $lowest_ranked_payout )
        {
            $lowest_ranked_payout = $prize_specification->{subtype};
        }
    }
    return $lowest_ranked_payout;
}

# Gibson spread

sub get_cumulative_gibson_spreads {
    my ( $gibson_spread, $max_round ) = @_;

    my $number_of_gibson_spreads  = scalar @{$gibson_spread};
    my @cumulative_gibson_spreads = (0) x ( $max_round + 1 );

    my $last_gibson_spread;
    for ( my $i = 0 ; $i <= $max_round ; $i++ ) {
        if ( $i == 0 ) {
            $cumulative_gibson_spreads[$i] = $gibson_spread->[$i] * 2;
            $last_gibson_spread = $gibson_spread->[$i] * 2;
        }
        else {
            $cumulative_gibson_spreads[$i] =
              $cumulative_gibson_spreads[ $i - 1 ];
            if ( $i < $number_of_gibson_spreads ) {
                $cumulative_gibson_spreads[$i] += $gibson_spread->[$i] * 2;
                $last_gibson_spread = $gibson_spread->[$i] * 2;
            }
            else {
                $cumulative_gibson_spreads[$i] += $last_gibson_spread;
            }
        }
    }
    return \@cumulative_gibson_spreads;
}

# Control loss

sub extend_tsh_config_array {
    my ( $array, $max_round ) = @_;

    my $number_of_entries = scalar @{$array};
    my @full_array        = (0) x ( $max_round + 1 );

    my $last_entry;
    for ( my $i = 0 ; $i <= $max_round ; $i++ ) {
        if ( $i < $number_of_entries ) {
            $full_array[$i] = $array->[$i];
            $last_entry = $array->[$i];
        }
        else {
            $full_array[$i] = $last_entry;
        }
    }
    return \@full_array;
}

# Pairing and simming

sub cop {
    my ( $config, $tournament_players, $times_played_hash ) = @_;

    log_info( $config, "\n\nCOP Config:\n\n" . Dumper($config) );

    # Lowest ranked payout was given as 1-indexed
    # To keep this consistent with the rest of the 0-indexed
    # code in these functions, we convert it to 0-indexed here.

    $config->{lowest_ranked_payout}--;

    if ( $config->{number_of_rounds_remaining} <= 0 ) {
        return sprintf( "Invalid rounds remaining: %d\n",
            $config->{number_of_rounds_remaining} );
    }

    my $number_of_players = scalar(@$tournament_players);

    if ( $number_of_players % 2 == 1 ) {
        add_bye_player($tournament_players, $number_of_players);
        $number_of_players = scalar(@$tournament_players);
    }

    sort_tournament_players_by_record($tournament_players);

    log_info(
        $config,
        sprintf( "\n\nStandings\n\n%s\n",
            tournament_players_string($tournament_players) )
    );

    # Truncate the players for simulations.
    # We don't need to simulate anyone who can't cash and
    # having unnecessary players in the simulations
    # degrades performance.

    my $sim_tournament_players =
      get_sim_tournament_players( $config, $tournament_players );

    my $factor_pair_results =
      sim_factor_pair( $config, $sim_tournament_players );

    my $lowest_gibson_rank =
      get_lowest_gibson_rank( $config, $sim_tournament_players );

    my $lowest_ranked_always_wins = -1;
    my $control_loss              = -1;

    if ( $lowest_gibson_rank < 0 ) {
        ( $lowest_ranked_always_wins, $control_loss ) =
          get_control_loss( $config, $factor_pair_results,
            $sim_tournament_players );
    }

    my $adjusted_control_loss_threshold = 0;
    if ( ( $config->{number_of_rounds_remaining} - 1 ) <
        scalar( @{ $config->{control_loss_thresholds} } ) )
    {
        $adjusted_control_loss_threshold =
          $config->{control_loss_thresholds}
          ->[ $config->{number_of_rounds_remaining} - 1 ];
    }

    log_info(
        $config,
        sprintf( "\nAdjusted control loss threshold: %f\n",
            $adjusted_control_loss_threshold,
        )
    );

    log_info( $config, "\n\nGibsons\n\n" );

    if ( $lowest_gibson_rank >= 0 ) {
        log_info(
            $config,
            sprintf(
                "\nLowest ranked gibsonized player: %d (%s)\n",
                $lowest_gibson_rank,
                $tournament_players->[$lowest_gibson_rank]->{name}
            )
        );
    }
    else {
        log_info( $config, "\nNo one is gibsonized\n" );
    }

    sort_tournament_players_by_record($sim_tournament_players);

    my $lowest_ranked_placers =
      get_lowest_ranked_placers( $config, $factor_pair_results,
        $sim_tournament_players );

    my $lowest_ranked_player_within_payout =
      $lowest_ranked_placers->[ $config->{lowest_ranked_payout} ];

    log_info(
        $config,
        results_string(
            $config, $sim_tournament_players, $factor_pair_results
        )
    );

    log_info(
        $config,
        sprintf(
            "\nLowest ranked player who can still cash: %d (%s)",
            $lowest_ranked_player_within_payout,
            $sim_tournament_players->[$lowest_ranked_player_within_payout]
              ->{name}
        )
    );

    log_info(
        $config,
        sprintf(
"\n\nWeights\n\n%-92s | %-3s = %7s = %7s + %7s + %7s + %7s + %7s + %7s\n",
            "Pairing", "Rpt",     "Total",  "Repeats", "RankDif",
            "RankPr",  "Control", "Gibson", "KOTH"
        )
    );

    # For the min weight matching, switch back to
    # using all of the tournament players since
    # everyone needs to be paired

    my $max_weight  = 0;
    my @edges       = ();
    my %weight_hash = ();
    for ( my $i = 0 ; $i < $number_of_players ; $i++ ) {
        my $player_i = $tournament_players->[$i];
        for ( my $j = $i + 1 ; $j < $number_of_players ; $j++ ) {
            my $player_j = $tournament_players->[$j];

            my $number_of_times_played =
              get_number_of_times_played( $player_i->{index},
                $player_j->{index}, $times_played_hash );

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
                    if ( $i % 2 == 1 || $i + 1 != $j ) {

                        # player i needs to paired with the player
                        # immediately after them in the rankings.
                        # If player i has a odd rank, then they have
                        # already been weight appropiately with the
                        # player above them.
                        $koth_weight = PROHIBITIVE_WEIGHT;
                    }
                }
            }
            elsif ( !$player_j->{is_bye} ) {

                # If neither of these blocks are true, that means both
                # players are gibsonized and we don't have to consider
                # control loss or placement.
                if (   $i <= $lowest_gibson_rank
                    && $j > $lowest_gibson_rank
                    && $j <= $lowest_ranked_player_within_payout )
                {
                    # player i is gibsonized and player j can still cash, they
                    # shouldn't be paired
                    $gibson_weight = PROHIBITIVE_WEIGHT;
                }
                elsif ( $i > $lowest_gibson_rank && $j > $lowest_gibson_rank ) {

                    # Neither player is gibsonized
                    if ( $i <= $lowest_ranked_player_within_payout ) {

                        # player i can still cash
                        if (
                            $j <= $lowest_ranked_placers->[$i]
                            || (   $i == $lowest_ranked_placers->[$i]
                                && $i == $j - 1 )
                          )
                        {

                            # player j can still can catch player i
                            # or
                            # no one in the simulations catch up to player i
                            # but player i isn't gibsonized, so player i can
                            # play player j if i = j - 1

                            # add a penalty for the distance of this pairing
                            $pair_with_placer_weight =
                              ( ( abs( $lowest_ranked_placers->[$i] - $j ) )
                                **3 ) * 2;
                        }
                        else {
                            # player j can't catch player i, so they should
                            # preferrably not be paired
                            $pair_with_placer_weight = PROHIBITIVE_WEIGHT;
                        }
                    }

                    # Control loss weight
                    # Only applies to the player in first
                    if (   $i == 0
                        && $j > $lowest_ranked_always_wins
                        && $control_loss > $adjusted_control_loss_threshold )
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
"%s vs %s | %3d = %7d = %7d + %7d + %7d + %7d + %7d + %7d\n",
                    player_string( $player_i, $i ),
                    player_string( $player_j, $j ),
                    $number_of_times_played,
                    $weight,
                    $repeat_weight,
                    $rank_difference_weight,
                    $pair_with_placer_weight,
                    $control_loss_weight,
                    $gibson_weight,
                    $koth_weight
                )
            );
            $weight_hash{
                create_weight_hash_key(
                    $player_i->{index}, $player_j->{index}
                )
            } = $weight;
            push @edges, [ $i, $j, $weight ];
        }
    }

    my $matching = min_weight_matching( \@edges, $max_weight );
    my $pairings =
      convert_matching_to_index_pairings( $matching, $tournament_players );

    my $weight_sum = 0;
    for ( my $i = 0 ; $i < scalar @{$pairings} ; $i++ ) {
        my $j = $pairings->[$i];

        # Use $j == -1 to detect the index of the bye player
        if ( $i < $j || $j == -1 ) {
            my $weight_hash_key = create_weight_hash_key( $i, $j );
            my $pairing_weight  = $weight_hash{$weight_hash_key};
            if ( $pairing_weight > PROHIBITIVE_WEIGHT ) {
                log_info(
                    $config,
                    sprintf(
"WARNING: Pairing exceeds prohibitive weight (%d): %s vs %s\n",
                        $pairing_weight,
                        player_string( $tournament_players->[$i], $i ),
                        player_string( $tournament_players->[$j], $j )
                    )
                );
            }
            $weight_sum += $pairing_weight;
        }
    }

    log_info( $config, sprintf( "\nTotal Weight: %d\n", $weight_sum ) );

    # Remove 'bye' players before displaying pairings
    @{$tournament_players} = grep { !$_->{is_bye} } @{$tournament_players};

    log_info( $config,
        pairings_string( $tournament_players, $pairings, $times_played_hash ) );
    return $pairings;
}

sub create_weight_hash_key {

    # It is assumed that $i < $j
    my ( $i, $j ) = @_;
    return create_times_played_key( $i, $j );
}

sub get_number_of_times_played {
    my ( $player_i_index, $player_j_index, $times_played_hash ) = @_;
    my $times_played_key =
      create_times_played_key( $player_i_index, $player_j_index );
    my $number_of_times_played = 0;
    if ( exists $times_played_hash->{$times_played_key} ) {
        $number_of_times_played = $times_played_hash->{$times_played_key};
    }
    return $number_of_times_played;
}

sub get_lowest_ranked_placers {
    my ( $config, $factor_pair_results, $sim_tournament_players ) = @_;

    my $sim_number_of_players = scalar @{$sim_tournament_players};

    my $adjusted_hopefulness = 0;
    if ( ( $config->{number_of_rounds_remaining} ) <
        scalar( @{ $config->{hopefulness} } ) )
    {
        $adjusted_hopefulness =
          $config->{hopefulness}->[ $config->{number_of_rounds_remaining} ];
    }

    my @lowest_ranked_placers =
      (0) x ( $sim_number_of_players * $sim_number_of_players );

    for (
        my $final_rank_index = 0 ;
        $final_rank_index < $sim_number_of_players ;
        $final_rank_index++
      )
    {
        for (
            my $player_current_rank_index = 0 ;
            $player_current_rank_index < $sim_number_of_players ;
            $player_current_rank_index++
          )
        {
            my $player = $sim_tournament_players->[$player_current_rank_index];

            # Calculate the number of sims where this player placed
            # at or above the given rank.
            my $sum = 0;
            for ( my $i = 0 ; $i <= $final_rank_index ; $i++ ) {
                $sum +=
                  get_tournament_result( $factor_pair_results, $player, $i );
            }
            my $place_percentage = $sum / $config->{number_of_sims};
            if ( $place_percentage > $adjusted_hopefulness ) {
                $lowest_ranked_placers[$final_rank_index] =
                  $player_current_rank_index;
            }
        }
    }

    log_info( $config,
        "\n\nLowest ranked placers\n\n"
          . sprintf( "\nAdjusted hopefulness: %0.6f\n\n",
            $adjusted_hopefulness ) );

    for ( my $i = 0 ; $i <= $config->{lowest_ranked_payout} ; $i++ ) {
        log_info(
            $config,
            sprintf(
                "Lowest ranked possible winner for rank %d: %s\n",
                $i + 1,
                player_string(
                    $sim_tournament_players->[ $lowest_ranked_placers[$i] ],
                    $lowest_ranked_placers[$i]
                )
            )
        );
    }
    return \@lowest_ranked_placers;
}

sub get_control_loss {
    my ( $config, $factor_pair_results, $sim_tournament_players ) = @_;

    my $sim_number_of_players = scalar @{$sim_tournament_players};

    my ( $always_wins_pair_player_with_first, $always_wins_factor_pair ) =
      sim_player_always_wins( $config, $sim_tournament_players );

    my $lowest_ranked_always_wins = 0;
    for ( my $i = 1 ; $i < $sim_number_of_players ; $i++ ) {
        if ( $always_wins_pair_player_with_first->[ $i - 1 ] ==
            $config->{always_wins_number_of_sims} )
        {
            $lowest_ranked_always_wins = $i;
        }
        else {
            last;
        }
    }

    my $control_loss = 0;

    if ( $lowest_ranked_always_wins > 0 ) {
        $control_loss =
          ( $config->{always_wins_number_of_sims} -
              $always_wins_factor_pair->[ $lowest_ranked_always_wins - 1 ] ) /
          $config->{always_wins_number_of_sims};
    }

    log_info( $config, "\n\nControl loss\n\n" );

    log_info(
        $config,
        sprintf(
"Lowest ranked always winning player: %s with a control loss of %f\n\n",
            player_string(
                $sim_tournament_players->[$lowest_ranked_always_wins],
                $lowest_ranked_always_wins
            ),
            $control_loss
        )
    );

    log_info(
        $config,
        sprintf(
            "Always wins table out of %d sims\n\n%-50s%-20s%-20s\n",
            $config->{always_wins_number_of_sims}, "Player",
            "Always wins vs 1st",                  "Always wins factor"
        )
    );

    for ( my $i = 0 ; $i < scalar @$always_wins_pair_player_with_first ; $i++ )
    {
        if ( $sim_tournament_players->[ $i + 1 ]->{is_bye} ) {
            next;
        }
        log_info(
            $config,
            sprintf(
                "%-50s%-20s%-20s\n",
                player_string( $sim_tournament_players->[ $i + 1 ], $i + 1 ),
                $always_wins_pair_player_with_first->[$i],
                $always_wins_factor_pair->[$i]
            )
        );
    }
    return $lowest_ranked_always_wins, $control_loss;
}

sub get_lowest_gibson_rank {
    my ( $config, $sim_tournament_players ) = @_;

    my $sim_number_of_players = scalar @{$sim_tournament_players};

    my $lowest_gibson_rank = -1;
    for (
        my $player_in_nth_rank_index = 0 ;
        $player_in_nth_rank_index < $sim_number_of_players ;
        $player_in_nth_rank_index++
      )
    {
        if ( $player_in_nth_rank_index == $sim_number_of_players - 1 ) {

            # Somehow, everyone is gibsonized
            # IRL, this should never happen, but for this code
            # it will prevent index out-of-bounds errors.
            $lowest_gibson_rank = $sim_number_of_players - 1;
            last;
        }
        my $player_in_nth =
          $sim_tournament_players->[$player_in_nth_rank_index];
        my $player_in_nplus1th =
          $sim_tournament_players->[ $player_in_nth_rank_index + 1 ];
        if (
            ( $player_in_nth->{wins} - $player_in_nplus1th->{wins} ) / 2 >
            $config->{number_of_rounds_remaining}
            || ( ( $player_in_nth->{wins} - $player_in_nplus1th->{wins} ) / 2 ==
                   $config->{number_of_rounds_remaining}
                && $player_in_nth->{spread} - $player_in_nplus1th->{spread} >
                $config->{cumulative_gibson_spreads}
                ->[ $config->{number_of_rounds_remaining} - 1 ] )
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

sub get_sim_tournament_players {
    my ( $config, $tournament_players ) = @_;
    my @sim_tournament_players = ();
    my $number_of_players      = scalar @{$tournament_players};
    my $break                  = 0;
    for ( my $i = 0 ; $i < $number_of_players ; $i++ ) {
        my $player = $tournament_players->[$i];

        # # Divide wins by 2 because wins are worth 2 and draws are worth 1
        my $can_technically_cash = $i <= $config->{lowest_ranked_payout}
          || (
            $tournament_players->[ $config->{lowest_ranked_payout} ]->{wins} -
            $player->{wins} ) / 2 <= $config->{number_of_rounds_remaining};
        if ( $can_technically_cash || ( $i % 2 == 1 ) ) {

            # The sim players are given new indexes that
            # might be different from their original indexes.
            # This index is used to record the simmed players final
            # rank when a simulation is finished.
            push @sim_tournament_players,
              new_tournament_player( $player->{name}, $i,
                $player->{display_index},
                $player->{wins}, $player->{spread}, $player->{is_bye} );
        }
        if ( !$can_technically_cash ) {
            last;
        }
    }
    return \@sim_tournament_players;
}

sub sim_factor_pair {
    my ( $config, $sim_tournament_players ) = @_;
    my $results = new_tournament_results( scalar(@$sim_tournament_players) );
    for ( my $i = 0 ; $i < $config->{number_of_sims} ; $i++ ) {
        for (
            my $remaining_rounds = $config->{number_of_rounds_remaining} ;
            $remaining_rounds >= 1 ;
            $remaining_rounds--
          )
        {
            my $pairings =
              factor_pair( $sim_tournament_players, $remaining_rounds );
            my $max_spread = $config->{gibson_spreads}->[-$remaining_rounds];
            play_round( $pairings, $sim_tournament_players, -1, $max_spread );
        }
        record_tournament_results( $results, $sim_tournament_players );

        foreach my $player (@$sim_tournament_players) {
            reset_tournament_player($player);
        }
        sort_tournament_players_by_record($sim_tournament_players);
    }
    return $results;
}

sub sim_player_always_wins {
    my ( $config, $sim_tournament_players ) = @_;

    my @pair_with_first_tournament_wins;
    my @factor_pair_tournament_wins;
    my $player_in_first_wins = $sim_tournament_players->[0]->{wins};

    for (
        my $player_in_nth_rank_index = 1 ;
        $player_in_nth_rank_index < scalar(@$sim_tournament_players) ;
        $player_in_nth_rank_index++
      )
    {
        my $win_diff =
          ( $player_in_first_wins -
              $sim_tournament_players->[$player_in_nth_rank_index]->{wins} ) /
          2;

        # This player cannot win
        if ( $win_diff > $config->{number_of_rounds_remaining} ) {
            last;
        }

        my $pwf_wins = 0;
        my $fp_wins  = 0;
        my $player_in_nth =
          $sim_tournament_players->[$player_in_nth_rank_index];

        if ( $player_in_nth->{is_bye} ) {

            # Push zeroes so that the ranked players align with the index
            # This shouldn't strictly be necessary anyway since byes
            # should always be last
            push @pair_with_first_tournament_wins, 0;
            push @factor_pair_tournament_wins,     0;
            next;
        }

        my $player_in_nth_index = $player_in_nth->{index};

        for ( my $i = 0 ; $i < $config->{always_wins_number_of_sims} ; $i++ ) {
            for (
                my $remaining_rounds = $config->{number_of_rounds_remaining} ;
                $remaining_rounds >= 1 ;
                $remaining_rounds--
              )
            {
                my %player_index_to_rank =
                  map { $sim_tournament_players->[$_]->{index} => $_ }
                  0 .. scalar(@$sim_tournament_players) - 1;
                my $pairings = factor_pair_minus_player(
                    $sim_tournament_players, $remaining_rounds,
                    $player_in_nth_index,    \%player_index_to_rank
                );
                my $max_spread = $config->{gibson_spreads}->[-$remaining_rounds];
                play_round( $pairings, $sim_tournament_players,
                    $player_index_to_rank{$player_in_nth_index}, $max_spread );

                if ( $sim_tournament_players->[0]->{index} ==
                    $player_in_nth_index )
                {
                    $pwf_wins++;
                    last;
                }
            }

            for my $player (@$sim_tournament_players) {
                reset_tournament_player($player);
            }

            sort_tournament_players_by_record($sim_tournament_players);

            for (
                my $remaining_rounds = $config->{number_of_rounds_remaining} ;
                $remaining_rounds >= 1 ;
                $remaining_rounds--
              )
            {
                my %player_index_to_rank =
                  map { $sim_tournament_players->[$_]->{index} => $_ }
                  0 .. scalar(@$sim_tournament_players) - 1;
                my $pairings =
                  factor_pair( $sim_tournament_players, $remaining_rounds );
                my $max_spread = $config->{gibson_spreads}->[-$remaining_rounds];
                play_round( $pairings, $sim_tournament_players,
                    $player_index_to_rank{$player_in_nth_index}, $max_spread );

                if ( $sim_tournament_players->[0]->{index} ==
                    $player_in_nth_index )
                {
                    $fp_wins++;
                    last;
                }
            }

            for my $player (@$sim_tournament_players) {
                reset_tournament_player($player);
            }

            sort_tournament_players_by_record($sim_tournament_players);
        }

        push @pair_with_first_tournament_wins, $pwf_wins;
        push @factor_pair_tournament_wins,     $fp_wins;
    }
    return \@pair_with_first_tournament_wins, \@factor_pair_tournament_wins;
}

sub play_round {
    my ( $pairings, $tournament_players, $forced_win_player, $max_spread ) = @_;

  outer: for ( my $i = 0 ; $i < scalar @$pairings ; $i++ ) {
        my $pairing = $pairings->[$i];
        for ( my $j = 0 ; $j < 2 ; $j++ ) {
            if ( $tournament_players->[ $pairing->[$j] ]->{is_bye} ) {

                # Player gets a bye
                $tournament_players->[ $pairing->[ 1 - $j ] ]->{spread} += 50;
                $tournament_players->[ $pairing->[ 1 - $j ] ]->{wins}   += 2;
                next outer;
            }
        }
        my $spread = int($max_spread / 2) - int( rand($max_spread + 1) );
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
    my ( $sim_tournament_players, $nrl ) = @_;

    my $number_of_players = scalar(@$sim_tournament_players);

    if ( $nrl > $number_of_players / 2 ) {
        $nrl = $number_of_players / 2;
    }

    # This assumes players are already sorted
    my @pairings;
    for ( my $i = 0 ; $i < $nrl ; $i++ ) {
        push @pairings, [ $i, $i + $nrl ];
    }
    for ( my $i = $nrl * 2 ; $i < scalar(@$sim_tournament_players) ; $i += 2 ) {
        push @pairings, [ $i, $i + 1 ];
    }

    return \@pairings;
}

sub factor_pair_minus_player {
    my ( $sim_tournament_players, $nrl, $player_index, $player_index_to_rank )
      = @_;

    # Pop in descending order to ensure player_rank_index
    # removes the correct player
    my $player_rank_index = $player_index_to_rank->{$player_index};
    my $player_in_nth_rank_index =
      splice( @$sim_tournament_players, $player_rank_index, 1 );
    my $player_in_first = shift @$sim_tournament_players;

    if ( $nrl * 2 > scalar(@$sim_tournament_players) ) {
        $nrl = scalar(@$sim_tournament_players) / 2;
    }

    my @pairings = ( [ 0, $player_rank_index ] );
    for ( my $i = 0 ; $i < $nrl ; $i++ ) {
        my $i_player =
          $player_index_to_rank->{ $sim_tournament_players->[$i]->{index} };
        my $nrl_player =
          $player_index_to_rank->{ $sim_tournament_players->[ $i + $nrl ]
              ->{index} };
        push @pairings, [ $i_player, $nrl_player ];
    }
    for ( my $i = $nrl * 2 ; $i < scalar(@$sim_tournament_players) ; $i += 2 ) {
        my $i_player =
          $player_index_to_rank->{ $sim_tournament_players->[$i]->{index} };
        my $i_plus_one_player =
          $player_index_to_rank->{ $sim_tournament_players->[ $i + 1 ]->{index}
          };
        push @pairings, [ $i_player, $i_plus_one_player ];
    }

    unshift @$sim_tournament_players, $player_in_first;
    splice( @$sim_tournament_players, $player_rank_index, 0,
        $player_in_nth_rank_index );

    return \@pairings;
}

sub sort_tournament_players_by_record {
    my $tournament_players = shift;
    @{$tournament_players} =
      sort {
             $a->{is_bye} <=> $b->{is_bye}
          || $b->{wins} <=> $a->{wins}
          || $b->{spread} <=> $a->{spread}
      } @{$tournament_players};
}

sub sort_tournament_players_by_index {
    my $tournament_players = shift;
    @{$tournament_players} =
      sort { $a->{index} <=> $b->{index} } @{$tournament_players};
}

# Min weight matching

sub min_weight_matching {
    my ( $edges, $max_weight ) = @_;
    for ( my $i = 0 ; $i < scalar @{$edges} ; $i++ ) {
        $edges->[$i]->[2] = ( $max_weight + 1 ) - $edges->[$i]->[2];
    }

    # Pass 1 for max cardinality
    my %matching = max_weight_matching( $edges, 1 );
    return \%matching;
}

sub convert_matching_to_index_pairings {
    my ( $matching, $tournament_players ) = @_;

    sort_tournament_players_by_record($tournament_players);

    my $number_of_players = scalar @{$tournament_players};
    my @pairings          = (0) x $number_of_players;
    for (
        my $player_rank = 0 ;
        $player_rank < $number_of_players ;
        $player_rank++
      )
    {
        my $player   = $tournament_players->[$player_rank];
        my $opp_rank = $matching->{$player_rank};
        if ( $opp_rank < $player_rank ) {
            next;
        }
        my $opponent = $tournament_players->[$opp_rank];

        if ( $player->{is_bye} ) {
            $pairings[ $opponent->{index} ] = $player->{index};
        }
        else {
            $pairings[ $player->{index} ]   = $opponent->{index};
            $pairings[ $opponent->{index} ] = $player->{index};
        }
    }
    return \@pairings;
}

# For logging only

sub player_string {
    my ( $player, $rank_index ) = @_;
    my $name_and_index = sprintf( "%-6s %-22s",
        '(#' . ( $player->{display_index} + 1 ) . ')',
        $player->{name} );
    my $wins_string = sprintf( "%0.1f", $player->{wins} / 2 );
    my $sign        = '+';
    if ( $player->{spread} < 0 ) {
        $sign = '';
    }
    my $rank_string = $rank_index + 1;
    if ( $rank_index < 0 ) {
        $rank_string = '';
    }
    return sprintf(
        "%-3s %s %-4s %-5s",
        $rank_string, $name_and_index,
        $wins_string, $sign . $player->{spread}
    );
}

sub results_string {
    my ( $config, $tournament_players, $results ) = @_;
    sort_tournament_players_by_record($tournament_players);
    my $number_of_players = scalar @{$tournament_players};
    my $result            = "\n\nResults\n\n";
    $result .= sprintf( "%46s", ("") );
    for ( my $i = 0 ; $i < $number_of_players ; $i++ ) {
        $result .= sprintf( "%-7s", ( $i + 1 ) );
    }
    $result .= sprintf("\n");
    for ( my $i = 0 ; $i < $number_of_players ; $i++ ) {
        my $player = $tournament_players->[$i];
        $result .= player_string( $player, $i ) . '  ';
        for ( my $j = 0 ; $j < $number_of_players ; $j++ ) {
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
        my $tournament_player = $tournament_players->[$i];
        if ( $tournament_player->{is_bye} ) {
            next;
        }
        $result .= player_string( $tournament_player, $i ) . "\n";
    }
    return $result;
}

sub pairings_string {
    my ( $tournament_players, $pairings, $times_played_hash ) = @_;

    # Pairings are an array of player indexes
    # order by index, so order by index before formatting
    # to a string.
    sort_tournament_players_by_index($tournament_players);

    my $number_of_players = scalar @{$tournament_players};
    my $result            = "\n\nPairings:\n\n";
    for (
        my $player_index = 0 ;
        $player_index < $number_of_players ;
        $player_index++
      )
    {
        my $player         = $tournament_players->[$player_index];
        my $opponent_index = $pairings->[$player_index];
        if ( $player_index > $opponent_index ) {
            next;
        }
        my $number_of_times_played =
          get_number_of_times_played( $player_index, $opponent_index,
            $times_played_hash );
        if ( $opponent_index == $number_of_players ) {
            $result .= sprintf(
                "%s has a bye (%d)\n",
                player_string( $player, -1 ),
                $number_of_times_played
            );
        }
        else {
            my $opponent = $tournament_players->[$opponent_index];

            $result .= sprintf( "%s vs %s (%d)\n",
                player_string( $player,   -1 ),
                player_string( $opponent, -1 ),
                $number_of_times_played );
        }
    }
    return $result;
}

1;