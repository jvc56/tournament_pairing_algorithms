#!/usr/bin/perl

# Testing:
# gibsonized players get the bye
# odd contender groups
# class prize contenders in last round
# pair around an existing pairing

package TSH::Command::COP;

use strict;
use warnings;
use threads;
use Data::Dumper;

use File::Basename;
use Graph::Matching qw(max_weight_matching);
use TSH::Command::ShowPairings;
use TSH::PairingCommand;
use File::Copy;

our (@ISA) = qw(TSH::PairingCommand);

use constant PROHIBITIVE_WEIGHT => 1000000;
use constant BYE_PLAYER_ID      => 0;

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
            "failed to create directory $log_dir" );
        return 0;
    }

    my $last_paired_round0 = $dp->LastPairedRound0();

    my $timestamp     = get_timestamp();
    my $division_name = $dp->Name();
    my $sr1           = $sr0 + 1;

    # +2 because:
    #  0-index to 1-index for humans, and
    #  TSH pairs the next available round
    my $cop_paired_round1 = $last_paired_round0 + 2;
    my $number_of_rounds  = $dp->MaxRound0() + 1;

    if ( $cop_paired_round1 > $number_of_rounds ) {
        $tournament->TellUser( 'ebigrd', $cop_paired_round1,
            $number_of_rounds );
        return 0;
    }

    my $log_filename =
        "$log_dir$timestamp"
      . "_$division_name"
      . "_round_"
      . $cop_paired_round1
      . "_based_on_$sr1" . ".log";
    my $html_log_filename =
      $log_dir . '../html/' . "$division_name$cop_paired_round1" . '_cop.log';

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

    my ( $lowest_ranked_payout, $lowest_ranked_class_payouts ) =
      get_lowest_ranked_payouts( $tournament->Config(), $division_name );
    if ( $lowest_ranked_payout < 0 ) {
        $tournament->TellUser( 'ebadconfigentry', 'prizes' );
        return 0;
    }

    my $control_loss_activation_round =
      $tournament->Config()->Value('control_loss_activation_round');
    if ( !defined $control_loss_activation_round ) {
        $tournament->TellUser( 'ebadconfigentry',
            'control_loss_activation_round' );
        return 0;
    }

    my $number_of_threads = $tournament->Config()->Value('cop_threads');
    if ( ( !( defined $number_of_threads ) ) || $number_of_threads < 1 ) {
        $number_of_threads = 1;
    }

    my %times_played          = ();
    my %previous_pairing_hash = ();

    # Iterate through the players in a division
    my @players            = $dp->Players();
    my $number_of_players  = scalar @players;
    my @tournament_players = ();
    my $player_index       = 0;
    my $top_class;
    for ( my $i = 0 ; $i < $number_of_players ; $i++ ) {
        my $player       = $players[$i];
        my $player_class = $player->Class();
        my $player_id    = $player->ID();
        if ( $player_id == 1 ) {
            $top_class = $player_class;
        }
        if ( !$player->Active() ) {
            next;
        }
        for ( my $j = $i + 1 ; $j < $number_of_players ; $j++ ) {
            my $opponent = $players[$j];
            if ( !$opponent->Active() ) {
                next;
            }
            my $opponent_id = $opponent->ID();
            my $number_of_times_played =
              $player->CountRoundRepeats( $opponent, $last_paired_round0 );
            my $number_of_times_played_excluding_last_round =
              $player->CountRoundRepeats( $opponent, $last_paired_round0 - 1 );

            my $played_last_round = $number_of_times_played -
              $number_of_times_played_excluding_last_round;
            if ( $played_last_round > 1 ) {
                $tournament->TellUser(
                    'eapfail',
                    sprintf(
"these players played more than once last round: %s and %s (%d)",
                        $player->PrettyName(), $opponent->PrettyName(),
                        $played_last_round
                    )
                );
                return 0;
            }
            my $times_played_key =
              create_times_played_key( $player_id, $opponent_id );
            $times_played{$times_played_key} = $number_of_times_played;
            if ( $played_last_round == 1 ) {
                $previous_pairing_hash{$times_played_key} = 1;
            }
        }

        my $times_given_bye_key =
          create_times_played_key( $player_id, BYE_PLAYER_ID );

        # Count the byes by up to the based on round
        # (There does not seem to be an existing Player method for this)
        my $byes = 0;
        for ( my $round = 0 ; $round <= $last_paired_round0 ; $round++ ) {
            my $opponent = $player->{pairings}->[$round];
            if ( ( defined $opponent ) && $opponent == 0 ) {
                $byes++;
            }
        }
        $times_played{$times_given_bye_key} = $byes;

        push @tournament_players, new_tournament_player(
            $player_id,
            $player->PrettyName(),
            $player->Class(),
            $player_index,

            # Wins count as 2 and draws count as 1 to
            # keep everything in integers.
            $player->RoundWins($sr0) * 2,
            $player->RoundSpread($sr0), 0
        );
        $player_index++;
    }

    # Create the special config for cop
    my $cop_config = {
        log_filename               => $log_filename,
        html_log_filename          => $html_log_filename,
        number_of_sims             => $number_of_sims,
        number_of_threads          => $number_of_threads,
        number_of_rounds           => $number_of_rounds,
        last_paired_round          => $last_paired_round0,
        always_wins_number_of_sims => $always_wins_number_of_sims,
        control_loss_thresholds    => extend_tsh_config_array(
            $control_loss_thresholds, $number_of_rounds
        ),
        control_loss_activation_round => $control_loss_activation_round - 1,
        number_of_rounds_remaining    => ( $number_of_rounds - 1 ) - $sr0,
        lowest_ranked_payout          => $lowest_ranked_payout,
        lowest_ranked_class_payouts   => $lowest_ranked_class_payouts,
        top_class                     => $top_class,
        cumulative_gibson_spreads =>
          get_cumulative_gibson_spreads( $gibson_spread, $number_of_rounds ),
        gibson_spreads =>
          extend_tsh_config_array( $gibson_spread, $number_of_rounds ),
        hopefulness =>
          extend_tsh_config_array( $hopefulness, $number_of_rounds ),
        bye_active => 0,
    };

    my $id_pairings = cop(
        $cop_config,    \@tournament_players,
        \%times_played, \%previous_pairing_hash
    );

    my $setupp = $this->SetupForPairings(
        'division' => $dp,
        'source0'  => $sr0
    ) or return 0;

    my $target0 = $setupp->{'target0'};

    for ( my $i = 0 ; $i < scalar @{$id_pairings} ; $i++ ) {
        my $player_id   = $id_pairings->[$i]->[0];
        my $opponent_id = $id_pairings->[$i]->[1];
        $dp->Pair( $player_id, $opponent_id, $target0, 1 );
    }

    $this->TidyAfterPairing($dp);

    # Automatically show the pairings
    my $show_pairings_command =
      new TSH::Command::ShowPairings( 'noconsole' => 1 );
    $show_pairings_command->Run( $tournament, $cop_paired_round1, $dp );
}

=back

=cut

=head1 BUGS

The number of byes each player has is based on the most recent
round as opposed to the provided based on round.

=cut

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

sub copy_log_to_html_directory {
    my ($config) = @_;

    if ( !$config->{log_filename} ) {
        log_info( $config,
            "Could not copy to html directory: no html log filename specified\n"
        );
        return;
    }

    my $success = copy( $config->{log_filename}, $config->{html_log_filename} );
    if ( !$success ) {
        log_info(
            $config,
            sprintf(
                "\nCould not copy %s to %s: %s\n",
                $config->{log_filename},
                $config->{html_log_filename}, $!
            )
        );
    }
    else {
        log_info(
            $config,
            sprintf(
                "\nSuccessfully copied %s to %s\n",
                $config->{log_filename},
                $config->{html_log_filename}
            )
        );
    }
}

sub get_timestamp {
    my ( $sec, $min, $hour, $day, $month, $year ) = localtime();

    $year += 1900;
    $month = sprintf( "%02d", $month + 1 );
    $day   = sprintf( "%02d", $day );
    $hour  = sprintf( "%02d", $hour );
    $min   = sprintf( "%02d", $min );
    $sec   = sprintf( "%02d", $sec );

    my $timestamp = "$year\_$month\_$day\_$hour\_$min\_$sec";
    return $timestamp;
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
    my ( $id, $name, $class, $index, $wins, $spread, $is_bye ) = @_;
    my $self = {
        id    => $id,
        name  => $name,
        class => $class,
        index => $index,

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

sub copy_tournament_players {
    my ($tournament_players)   = @_;
    my $number_of_players      = scalar(@$tournament_players);
    my @new_tournament_players = ();
    for ( my $i = 0 ; $i < $number_of_players ; $i++ ) {
        my $tournament_player = $tournament_players->[$i];
        push @new_tournament_players,
          new_tournament_player(
            $tournament_player->{id},    $tournament_player->{name},
            $tournament_player->{class}, $tournament_player->{index},
            $tournament_player->{wins},  $tournament_player->{spread},
            $tournament_player->{is_bye}
          );
    }
    return \@new_tournament_players;
}

sub reset_tournament_player {
    my $tournament_player = shift;
    $tournament_player->{wins}   = $tournament_player->{start_wins};
    $tournament_player->{spread} = $tournament_player->{start_spread};
}

sub add_bye_player {
    my ( $tournament_players, $bye_player_index ) = @_;

    # This display index can be the same as the original index
    push @{$tournament_players},
      new_tournament_player( BYE_PLAYER_ID, 'BYE', 'BYE', $bye_player_index, 0,
        0, 1 );
}

# Extract lowest payout rank

sub get_lowest_ranked_payouts {
    my ( $tsh_config, $division_name ) = @_;

    my $prizes_config = $tsh_config->{prizes};

    my $lowest_ranked_payout        = -1;
    my %lowest_ranked_class_payouts = ();
    for ( my $i = 0 ; $i < scalar @{$prizes_config} ; $i++ ) {
        my $prize_specification = $prizes_config->[$i];
        my $class               = $prize_specification->{class};
        my $division            = $prize_specification->{division};
        my $type                = $prize_specification->{type};

        # Convert from 1-index to 0-index
        my $place = $prize_specification->{subtype} - 1;
        if (   $division
            && uc($division) eq uc($division_name)
            && $type eq 'rank' )
        {
            # This is a place or class prize
            if (
                ( defined $class )
                && ( !defined $lowest_ranked_class_payouts{$class}
                    || $place > $lowest_ranked_class_payouts{$class} )
              )
            {
                $lowest_ranked_class_payouts{$class} = $place;
            }
            elsif ( ( !defined $class ) && $place > $lowest_ranked_payout ) {
                $lowest_ranked_payout = $place;
            }
        }
    }
    return $lowest_ranked_payout, \%lowest_ranked_class_payouts;
}

# Gibson spread

sub get_cumulative_gibson_spreads {
    my ( $gibson_spread, $number_of_rounds ) = @_;

    my $number_of_gibson_spreads  = scalar @{$gibson_spread};
    my @cumulative_gibson_spreads = (0) x ($number_of_rounds);

    my $last_gibson_spread;
    for ( my $i = 0 ; $i < $number_of_rounds ; $i++ ) {
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
    my ( $array, $number_of_rounds ) = @_;

    my $number_of_entries = scalar @{$array};
    my @full_array        = (0) x ($number_of_rounds);

    my $last_entry;
    for ( my $i = 0 ; $i < $number_of_rounds ; $i++ ) {
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

sub config_array_to_string {
    my ($array_ref) = @_;
    my $ret = '[';
    for ( my $i = 0 ; $i < scalar(@$array_ref) ; $i++ ) {
        $ret .= sprintf( "%4s", $array_ref->[$i] ) . ', ';
    }
    $ret = substr( $ret, 0, -2 );
    $ret .= ']';
    return $ret;
}

sub config_to_string {
    my ($config) = @_;
    my $ret = "COP Config:\n\n";
    $ret .= sprintf( "%31s %s\n", "Log Filename:", $config->{log_filename} );
    $ret .= sprintf( "%31s %s\n",
        "Last Paired Round:",
        $config->{last_paired_round} + 1 );
    $ret .= sprintf( "%31s %s\n", "Rounds:", $config->{number_of_rounds} );
    $ret .= sprintf( "%31s %s\n",
        "Rounds Remaining:",
        $config->{number_of_rounds_remaining} );
    $ret .= sprintf( "%31s %s\n", "Simulations:", $config->{number_of_sims} );
    $ret .= sprintf( "%31s %s\n",
        "Always Wins Simulations:",
        $config->{always_wins_number_of_sims} );
    $ret .= sprintf( "%31s %s\n",
        "Lowest Ranked Cash Payout:",
        $config->{lowest_ranked_payout} + 1 );

    foreach my $class ( sort keys %{ $config->{lowest_ranked_class_payouts} } )
    {
        $ret .= sprintf( "%31s %s\n",
            sprintf( "Lowest Ranked Class Payout %s:", $class ),
            $config->{lowest_ranked_class_payouts}->{$class} + 1 );
    }
    $ret .= sprintf( "%31s %s\n",
        "Control Loss Activation Round:",
        $config->{control_loss_activation_round} + 1 );
    $ret .= sprintf( "%31s %s\n", "Threads:", $config->{number_of_threads} );

    my $active_bye_text = 'FALSE';
    if ( $config->{bye_active} ) {
        $active_bye_text = 'ACTIVE';
    }
    $ret .= sprintf( "%31s %s\n", "Bye Active:", $active_bye_text );

    # Write a marker designating which array values are being used
    # for this round.
    $ret .= sprintf( "%31s %s",
        '(* denotes values in use)',
        ( '      ' x ( $config->{number_of_rounds_remaining} - 1 ) )
          . "   *\n" );

    $ret .= sprintf( "%31s %s\n",
        "Cumulative Gibson Spreads:",
        config_array_to_string( $config->{cumulative_gibson_spreads} ) );
    $ret .= sprintf( "%31s %s\n",
        "Gibson Spreads:",
        config_array_to_string( $config->{gibson_spreads} ) );
    $ret .= sprintf( "%31s %s\n",
        "Control Loss Thresholds:",
        config_array_to_string( $config->{control_loss_thresholds} ) );
    $ret .= sprintf( "%31s %s\n",
        "Hopefulness:", config_array_to_string( $config->{hopefulness} ) );
    return $ret;
}

# Pairing and simming

sub cop {
    my (
        $config,            $tournament_players,
        $times_played_hash, $previous_pairing_hash
    ) = @_;

    log_info( $config, config_to_string($config) );

    if ( $config->{number_of_rounds_remaining} <= 0 ) {
        return sprintf( "Invalid rounds remaining: %d\n",
            $config->{number_of_rounds_remaining} );
    }

    my $number_of_players = scalar(@$tournament_players);

    if ( $number_of_players % 2 == 1 ) {
        add_bye_player( $tournament_players, $number_of_players );
        $number_of_players = scalar(@$tournament_players);
        $config->{bye_active} = 1;
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

    my $lowest_gibson_rank =
      get_lowest_gibson_rank( $config, $sim_tournament_players );

    my $factor_pair_results =
      sim_factor_pair( $config, $sim_tournament_players, $lowest_gibson_rank );

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

    my (
        $lowest_ranked_players_who_can_finish_in_nth_statistically,
        $lowest_ranked_players_who_can_finish_in_nth_absolutely
      )
      = get_lowest_ranked_players_who_can_finish_in_nth( $config,
        $factor_pair_results, $sim_tournament_players );

    my $lowest_ranked_player_who_can_cash_statistically =
      $lowest_ranked_players_who_can_finish_in_nth_statistically
      ->[ $config->{lowest_ranked_payout} ];

    my $lowest_ranked_player_who_can_cash_absolutely =
      $lowest_ranked_players_who_can_finish_in_nth_absolutely
      ->[ $config->{lowest_ranked_payout} ];

    log_info(
        $config,
        results_string(
            $config, $sim_tournament_players, $factor_pair_results
        )
    );

    log_info(
        $config,
        sprintf(
            "\nLowest ranked player who can still cash statistically: %d (%s)",
            $lowest_ranked_player_who_can_cash_statistically + 1,
            $sim_tournament_players
              ->[$lowest_ranked_player_who_can_cash_statistically]->{name}
        )
    );

    log_info(
        $config,
        sprintf(
            "\nLowest ranked player who can still cash absolutely: %d (%s)",
            $lowest_ranked_player_who_can_cash_absolutely + 1,
            $sim_tournament_players
              ->[$lowest_ranked_player_who_can_cash_absolutely]->{name}
        )
    );

    # Add 1 because TSH will pair the round after the last paired round
    my $control_loss_active = ( $config->{last_paired_round} + 1 ) >=
      $config->{control_loss_activation_round};

    my $control_status_text = 'ACTIVE';

    if ( !$control_loss_active ) {
        $control_status_text = 'DISABLED';
    }

    # Get the number of repeats for each individual player
    my %number_of_repeats = ();

    for ( my $i = 0 ; $i < $number_of_players ; $i++ ) {
        my $player_i = $tournament_players->[$i];
        for ( my $j = $i + 1 ; $j < $number_of_players ; $j++ ) {
            my $player_j = $tournament_players->[$j];
            my $number_of_times_played =
              get_number_of_times_played( $player_i->{id},
                $player_j->{id}, $times_played_hash );

            if ( !exists $number_of_repeats{ $player_i->{id} } ) {
                $number_of_repeats{ $player_i->{id} } = 0;
            }

            if ( !exists $number_of_repeats{ $player_j->{id} } ) {
                $number_of_repeats{ $player_j->{id} } = 0;
            }

            if ( $number_of_times_played > 1 ) {
                my $repeats = $number_of_times_played - 1;
                $number_of_repeats{ $player_i->{id} } += $repeats;
                $number_of_repeats{ $player_j->{id} } += $repeats;
            }
        }
    }

    my $class_prize_pairings =
      get_class_prize_pairings( $config, $tournament_players,
        $lowest_ranked_player_who_can_cash_absolutely,
        $number_of_players );

    if ( scalar keys %{$class_prize_pairings} > 0 ) {
        my %logged_players = ();
        log_info( $config, "\n\nForced KOTH Class Prize Pairings:\n" );
        foreach my $player ( sort keys %{$class_prize_pairings} ) {
            my $opponent = $class_prize_pairings->{$player};
            if (   defined $logged_players{$player}
                || defined $logged_players{$opponent} )
            {
                next;
            }
            log_info(
                $config,
                sprintf(
                    "%s vs %s\n",
                    player_string( $tournament_players->[$player], $player ),
                    player_string(
                        $tournament_players->[$opponent], $opponent
                    )
                )
            );
            $logged_players{$player}   = 1;
            $logged_players{$opponent} = 1;
        }
    }

    # For the min weight matching, switch back to
    # using all of the tournament players since
    # everyone needs to be paired

    log_info( $config,
        sprintf( "\n\nControl loss is %s\n\n", $control_status_text ) );

    log_info(
        $config,
        sprintf(
"\n\nWeights\n\n%-94s | %-3s = %7s = %7s + %7s + %7s + %7s + %7s + %7s\n",
            "Pairing", "Rpt",     "Total",  "Repeats", "RankDif",
            "RankPla", "Control", "Gibson", "KOTH"
        )
    );

    my $max_weight               = 0;
    my @edges                    = ();
    my %weight_hash              = ();
    my $destinys_child           = -1;
    my $control_loss_weight_used = 0;
    for ( my $i = 0 ; $i < $number_of_players ; $i++ ) {
        my $player_i = $tournament_players->[$i];
        for ( my $j = $i + 1 ; $j < $number_of_players ; $j++ ) {
            my $player_j = $tournament_players->[$j];
            my $both_cannot_get_payout =
                 $i > $lowest_ranked_player_who_can_cash_absolutely
              && $j > $lowest_ranked_player_who_can_cash_absolutely;

            my $number_of_times_played =
              get_number_of_times_played( $player_i->{id},
                $player_j->{id}, $times_played_hash );

            my $repeat_weight = int( ( $number_of_times_played * 2 ) *
                  ( ( $number_of_players / 3 )**3 ) );

            my $gibson_weight = 0;
            my $times_played_key =
              create_times_played_key( $player_i->{id}, $player_j->{id} );
            if (   $config->{bye_active}
                && $player_j->{is_bye}
                && $lowest_gibson_rank > 0
                && $i > $lowest_gibson_rank )
            {
          # If byes are active and at least one person is gibsonized,
          # the gibsonized players should receive the bye instead of anyone else
                $gibson_weight += PROHIBITIVE_WEIGHT;
            }
            elsif ($both_cannot_get_payout
                && $previous_pairing_hash->{$times_played_key} )
            {
              # If both players are out of the money avoid a back to back repeat
                $repeat_weight += ( PROHIBITIVE_WEIGHT / 10 );
            }
            elsif ( $number_of_times_played > 0 ) {
                $repeat_weight += ( $number_of_repeats{ $player_i->{id} } +
                      $number_of_repeats{ $player_j->{id} } ) * 2;
            }

            my $rank_difference_weight;

            # If neither player can cash or player i is gibsonized,
            # rank difference weight should count for very little.
            if ( $both_cannot_get_payout || $i <= $lowest_gibson_rank ) {
                $rank_difference_weight = ( $j - $i );
            }
            else {
                $rank_difference_weight = ( $j - $i )**3;
            }

            # Pair with payout placers weight
            my $pair_with_placer_weight = 0;
            my $control_loss_weight     = 0;
            my $koth_weight             = 0;

            if ( $config->{number_of_rounds_remaining} == 1 ) {

                # For the last round, just do KOTH for all players
                # eligible for a cash payout
                if (
                    (
                           $i <= $lowest_gibson_rank
                        && $j <= $lowest_ranked_player_who_can_cash_absolutely
                        && $j > $lowest_gibson_rank
                        && !$player_j->{is_bye}
                    )
                    || (   $i > $lowest_gibson_rank
                        && $i <= $lowest_ranked_player_who_can_cash_absolutely
                        && ( $lowest_gibson_rank % 2 == $i % 2 || $i + 1 != $j )
                    )
                    || (   ( defined $class_prize_pairings->{$i} )
                        && ( $class_prize_pairings->{$i} != $j ) )
                    || (   ( defined $class_prize_pairings->{$j} )
                        && ( $class_prize_pairings->{$j} != $i ) )
                  )
                {
                    # Gibsonized players should not play anyone in contention
                    # for a cash payout that isn't also gibsonized.

                    # player i needs to paired with the player
                    # immediately after them in the rankings.
                    # If player i has a odd rank, then they have
                    # already been weight appropiately with the
                    # player above them.

                    # Enforce KOTH for players eligible for a class prize
                    $koth_weight = PROHIBITIVE_WEIGHT;
                }
            }
            elsif ( !$player_j->{is_bye} ) {

                # If neither of these blocks are true, that means both
                # players are gibsonized and we don't have to consider
                # control loss or placement.
                if (   $i <= $lowest_gibson_rank
                    && $j > $lowest_gibson_rank
                    && $j <= $lowest_ranked_player_who_can_cash_absolutely
                    && $j != ( $number_of_players - 1 ) )
                {
                    # player i is gibsonized and player j can still cash, they
                    # shouldn't be paired
                    $gibson_weight = PROHIBITIVE_WEIGHT;
                }
                elsif ( $i > $lowest_gibson_rank && $j > $lowest_gibson_rank ) {

                    # Neither player is gibsonized
                    if (
                        $i <= $lowest_ranked_player_who_can_cash_statistically )
                    {
                        # player i can still cash
                        if (
                            $j <=
                            $lowest_ranked_players_who_can_finish_in_nth_statistically
                            ->[$i]
                            || ( $i ==
                                $lowest_ranked_players_who_can_finish_in_nth_statistically
                                ->[$i]
                                && $i == $j - 1 )
                            || (
                                # Control loss is being applied
                                $control_loss_weight_used &&

                                # The contender group is odd
                                $destinys_child % 2 == 0 &&

                                # Player i is in the contender group
                                $i < $destinys_child &&

                                # Player j is one below destinys child
                                $j == $destinys_child + 1
                            )
                          )
                        {
                            # player j can still can catch player i
                            # or
                            # no one in the simulations catch up to player i
                            # but player i isn't gibsonized, so player i can
                            # play player j if i = j - 1
                            # or
                            # the forced pairing with first and destinys child
                            # creates an odd contender group and we need to pull
                            # in the player one rank below destinys child to
                            # avoid an odd number

                            # add a penalty for the distance of this pairing
                            $pair_with_placer_weight = (
                                (
                                    abs(
                                        $lowest_ranked_players_who_can_finish_in_nth_statistically
                                          ->[$i] - $j
                                    )
                                )**3
                            ) * 2;
                        }
                        else {
                            # player j can't catch player i, so they should
                            # preferrably not be paired
                            $pair_with_placer_weight =
                              ( PROHIBITIVE_WEIGHT / 2 );
                        }
                    }

                    # Control loss weight
                    # Only applies to the player in first

                  # If:
                  #  Control loss is active for this part of the tournament, and
                  #  We are considering the player in first, and
                  #    the control loss meets the threshold, and
                  #    the opponent is lower ranked than the minimum of:
                  #      the person who can get first in the sims and
                  #      the lowest ranked always winning person
                  #    or, if control loss threshold isn't met
                  #       the person who can get first in the sims and
                    my $lowest_ranked_person_who_can_win =
                      $lowest_ranked_players_who_can_finish_in_nth_statistically
                      ->[0];
                    if ( $lowest_ranked_person_who_can_win == 0 ) {

                        # This player is not gibsonized, but no one reached
                        # them in the simulations, so just make the lowest
                        # ranked person who can win the player in 2nd
                        $lowest_ranked_person_who_can_win = 1;
                    }
                    if (
                           $control_loss_active
                        && $i == 0
                        && (
                            (
                                $control_loss >
                                $adjusted_control_loss_threshold && $j != min(
                                    $lowest_ranked_person_who_can_win,
                                    $lowest_ranked_always_wins
                                )
                            )
                            || ( $control_loss <=
                                   $adjusted_control_loss_threshold
                                && $j != $lowest_ranked_person_who_can_win )
                        )
                      )
                    {
                        $control_loss_weight      = PROHIBITIVE_WEIGHT;
                        $control_loss_weight_used = 1;
                    }
                    else {
                        $destinys_child = $j;
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
            $weight_hash{ create_weight_hash_key( $player_i->{id},
                    $player_j->{id} ) } = $weight;
            push @edges, [ $i, $j, $weight ];
        }
    }

    my $matching = min_weight_matching( \@edges, $max_weight );
    my $pairings =
      convert_matching_to_index_pairings( $matching, $tournament_players );

    sort_tournament_players_by_index($tournament_players);

    my $weight_sum = 0;
    for ( my $i = 0 ; $i < scalar @{$pairings} ; $i++ ) {
        my $j        = $pairings->[$i];
        my $player_i = $tournament_players->[$i];
        my $player_j = $tournament_players->[$j];

        # Use $j == -1 to detect the index of the bye player
        if ( $i < $j || $j == -1 ) {
            my $weight_hash_key =
              create_weight_hash_key( $player_i->{id}, $player_j->{id} );
            my $pairing_weight = $weight_hash{$weight_hash_key};
            if ( $pairing_weight > PROHIBITIVE_WEIGHT ) {
                log_info(
                    $config,
                    sprintf(
"WARNING: Pairing exceeds prohibitive weight (%d): %s vs %s\n",
                        $pairing_weight,
                        player_string( $player_i, $i ),
                        player_string( $player_j, $j )
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

    my $id_pairings =
      convert_pairings_to_id_pairings( $tournament_players, $pairings );

    copy_log_to_html_directory($config);

    return $id_pairings;
}

sub create_weight_hash_key {
    my ( $i, $j ) = @_;
    return create_times_played_key( $i, $j );
}

sub get_number_of_times_played {
    my ( $player_i_id, $player_j_id, $times_played_hash ) = @_;
    my $times_played_key =
      create_times_played_key( $player_i_id, $player_j_id );
    my $number_of_times_played = 0;
    if ( exists $times_played_hash->{$times_played_key} ) {
        $number_of_times_played = $times_played_hash->{$times_played_key};
    }
    return $number_of_times_played;
}

sub get_lowest_ranked_players_who_can_finish_in_nth {
    my ( $config, $factor_pair_results, $sim_tournament_players ) = @_;

    my $sim_number_of_players = scalar @{$sim_tournament_players};

    # use -1 because number of rounds remaining is 1-indexed and
    # perl arrays are 0-indexed.
    my $adjusted_hopefulness =
      $config->{hopefulness}->[ $config->{number_of_rounds_remaining} - 1 ];

    my @lowest_ranked_players_who_can_finish_in_nth_statistically =
      (0) x ( $sim_number_of_players * $sim_number_of_players );

    my @lowest_ranked_players_who_can_finish_in_nth_absolutely =
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
                $lowest_ranked_players_who_can_finish_in_nth_statistically
                  [$final_rank_index] = $player_current_rank_index;
            }

            if ( $sum > 0 ) {
                $lowest_ranked_players_who_can_finish_in_nth_absolutely
                  [$final_rank_index] = $player_current_rank_index;
            }
        }
    }

    log_info( $config,
        "\n\nLowest ranked finishers statistically\n\n"
          . sprintf( "\nAdjusted hopefulness: %0.6f\n\n",
            $adjusted_hopefulness ) );

    for ( my $i = 0 ; $i <= $config->{lowest_ranked_payout} ; $i++ ) {
        log_info(
            $config,
            sprintf(
                "Lowest ranked possible winner for rank %d: %s\n",
                $i + 1,
                player_string(
                    $sim_tournament_players->[
                      $lowest_ranked_players_who_can_finish_in_nth_statistically
                      [$i]
                    ],
                    $lowest_ranked_players_who_can_finish_in_nth_statistically
                      [$i]
                )
            )
        );
    }

    log_info( $config,
        "\n\nLowest ranked finishers absolutely\n\n"
          . sprintf( "\nAdjusted hopefulness: %0.6f\n\n",
            $adjusted_hopefulness ) );

    for ( my $i = 0 ; $i <= $config->{lowest_ranked_payout} ; $i++ ) {
        log_info(
            $config,
            sprintf(
                "Lowest ranked possible winner for rank %d: %s\n",
                $i + 1,
                player_string(
                    $sim_tournament_players->[
                      $lowest_ranked_players_who_can_finish_in_nth_absolutely
                      [$i]
                    ],
                    $lowest_ranked_players_who_can_finish_in_nth_absolutely[$i]
                )
            )
        );
    }

    return \@lowest_ranked_players_who_can_finish_in_nth_statistically,
      \@lowest_ranked_players_who_can_finish_in_nth_absolutely;
}

sub get_control_loss {
    my ( $config, $factor_pair_results, $sim_tournament_players ) = @_;

    my $sim_number_of_players = scalar @{$sim_tournament_players};

    my ( $always_wins_pair_player_with_first, $always_wins_factor_pair ) =
      sim_player_always_wins( $config, $sim_tournament_players );

    my $lowest_ranked_always_wins = 0;
    for ( my $i = 0 ;
        $i < scalar @{$always_wins_pair_player_with_first} ; $i++ )
    {
        if ( $always_wins_pair_player_with_first->[$i] ==
            $config->{always_wins_number_of_sims} )
        {
            $lowest_ranked_always_wins = $i + 1;
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
    my $max_rank =
      min( $sim_number_of_players, $config->{lowest_ranked_payout} + 1 );
    for (
        my $player_in_nth_rank_index = 0 ;
        $player_in_nth_rank_index < $max_rank ;
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

sub can_player_reach_rank {
    my ( $config, $tournament_players, $player, $rank ) = @_;

    # Divide wins by 2 because wins are worth 2 and draws are worth 1
    return ( ( $tournament_players->[$rank]->{wins} - $player->{wins} ) / 2 )
      <= $config->{number_of_rounds_remaining};
}

sub get_class_prize_pairings {
    my ( $config, $tournament_players,
        $lowest_ranked_player_who_can_cash_absolutely,
        $number_of_players )
      = @_;

    my %class_pairings_remaining = ();
    foreach my $class ( keys %{ $config->{lowest_ranked_class_payouts} } ) {
        $class_pairings_remaining{$class} =
          $config->{lowest_ranked_class_payouts}->{$class} + 1;
    }
    my %previous_class_player_ranks = ();
    my %class_prize_pairings        = ();
    for (
        my $i = $lowest_ranked_player_who_can_cash_absolutely + 1 ;
        $i < $number_of_players ;
        $i++
      )
    {
        my $player_i = $tournament_players->[$i];
        for ( my $j = $i + 1 ; $j < $number_of_players ; $j++ ) {
            my $player_j = $tournament_players->[$j];
            if (
                   $player_i->{class} ne $config->{top_class}
                && $player_i->{class} eq $player_j->{class}
                && $class_pairings_remaining{ $player_i->{class} } > 0
                && ( !defined $class_prize_pairings{$i} )
                && ( !defined $class_prize_pairings{$j} )
                && (
                    ( !defined $previous_class_player_ranks{$player_i->{class}} )
                    || can_player_reach_rank(
                        $config,
                        $tournament_players,
                        $tournament_players->[$i],
                        $previous_class_player_ranks{$player_i->{class}}
                    )
                )
                && can_player_reach_rank(
                    $config,                   $tournament_players,
                    $tournament_players->[$j], $i
                )
              )
            {
                $class_prize_pairings{$i} = $j;
                $class_prize_pairings{$j} = $i;
                $class_pairings_remaining{ $player_i->{class} }--;
                $previous_class_player_ranks{$player_i->{class}} = $j;
            }
        }
    }
    return \%class_prize_pairings;
}

sub get_sim_tournament_players {
    my ( $config, $tournament_players ) = @_;
    my @sim_tournament_players = ();
    my $number_of_players      = scalar @{$tournament_players};
    my $break                  = 0;
    for ( my $i = 0 ; $i < $number_of_players ; $i++ ) {
        my $player = $tournament_players->[$i];

        my $can_technically_cash = $i <= $config->{lowest_ranked_payout}
          || can_player_reach_rank(
            $config, $tournament_players,
            $player, $config->{lowest_ranked_payout}
          );
        if ( $can_technically_cash || ( $i % 2 == 1 ) ) {

            # The sim players are given new indexes that
            # might be different from their original indexes.
            # This index is used to record the simmed players final
            # rank when a simulation is finished.
            push @sim_tournament_players,
              new_tournament_player( $player->{id}, $player->{name},
                $player->{class}, $i,
                $player->{wins}, $player->{spread}, $player->{is_bye} );
        }
        if ( !$can_technically_cash ) {
            last;
        }
    }
    return \@sim_tournament_players;
}

sub get_number_of_sims_for_thread {
    my ( $number_of_sims, $number_of_threads, $thread_index ) = @_;
    my $remainder             = $number_of_sims % $number_of_threads;
    my $thread_number_of_sims = int( $number_of_sims / $number_of_threads );
    if ( $thread_index < $remainder ) {
        $thread_number_of_sims++;
    }
    return $thread_number_of_sims;
}

sub sim_factor_pair_worker {
    my ( $config, $sim_tournament_players, $lowest_gibson_rank,
        $number_of_sims ) = @_;
    my $results = new_tournament_results( scalar(@$sim_tournament_players) );
    for ( my $i = 0 ; $i < $number_of_sims ; $i++ ) {
        for (
            my $remaining_rounds = $config->{number_of_rounds_remaining} ;
            $remaining_rounds >= 1 ;
            $remaining_rounds--
          )
        {
            my $pairings =
              factor_pair( $sim_tournament_players, $remaining_rounds,
                $lowest_gibson_rank );
            my $max_spread =
              $config->{gibson_spreads}->[ $remaining_rounds - 1 ];
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

sub sim_factor_pair_manager {
    my ( $config, $sim_tournament_players, $lowest_gibson_rank ) = @_;

    # Create an array to hold the thread objects
    my @threads = ();

    # Create the threads
    for ( my $i = 0 ; $i < $config->{number_of_threads} ; $i++ ) {
        my $number_of_sims_for_thread =
          get_number_of_sims_for_thread( $config->{number_of_sims},
            $config->{number_of_threads}, $i );
        my $copied_tournament_players =
          copy_tournament_players($sim_tournament_players);
        push @threads,
          threads->create(
            \&sim_factor_pair_worker,   $config,
            $copied_tournament_players, $lowest_gibson_rank,
            $number_of_sims_for_thread
          );
    }

    my $factor_pair_results =
      new_tournament_results( scalar(@$sim_tournament_players) );

    # Wait for the threads to finish and collect the results
    foreach my $thread (@threads) {
        my $thread_result = $thread->join();
        for (
            my $i = 0 ;
            $i < scalar( @{ $factor_pair_results->{array} } ) ;
            $i++
          )
        {
            $factor_pair_results->{array}->[$i] +=
              $thread_result->{array}->[$i];
        }
    }
    $factor_pair_results->{count} = $config->{number_of_sims};
    return $factor_pair_results;
}

sub sim_factor_pair {
    my ( $config, $sim_tournament_players, $lowest_gibson_rank ) = @_;
    if ( $config->{number_of_threads} > 1 ) {
        log_info(
            $config,
            sprintf( "Multithreading factor pair with %d threads\n",
                $config->{number_of_threads} )
        );
        return sim_factor_pair_manager( $config, $sim_tournament_players,
            $lowest_gibson_rank );
    }
    else {
        log_info( $config, sprintf("Single threading factor pair\n") );
        return sim_factor_pair_worker(
            $config,             $sim_tournament_players,
            $lowest_gibson_rank, $config->{number_of_sims}
        );
    }
}

sub sim_player_always_wins_worker {
    my (
        $config,              $sim_tournament_players,
        $player_in_nth_index, $number_of_sims_for_thread
    ) = @_;
    my $pwf_wins = 0;
    my $fp_wins  = 0;
    for ( my $i = 0 ; $i < $number_of_sims_for_thread ; $i++ ) {
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
            my $max_spread = $config->{gibson_spreads}->[ -$remaining_rounds ];
            play_round( $pairings, $sim_tournament_players,
                $player_index_to_rank{$player_in_nth_index}, $max_spread );

            if ( $sim_tournament_players->[0]->{index} == $player_in_nth_index )
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
              factor_pair( $sim_tournament_players, $remaining_rounds, -1 );
            my $max_spread = $config->{gibson_spreads}->[ -$remaining_rounds ];
            play_round( $pairings, $sim_tournament_players,
                $player_index_to_rank{$player_in_nth_index}, $max_spread );

            if ( $sim_tournament_players->[0]->{index} == $player_in_nth_index )
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
    return $pwf_wins, $fp_wins;
}

sub sim_player_always_wins_manager {
    my ( $config, $sim_tournament_players, $player_in_nth_index ) = @_;

    # Create an array to hold the thread objects
    my @threads = ();

    # Create the threads
    for ( my $i = 0 ; $i < $config->{number_of_threads} ; $i++ ) {
        my $number_of_sims_for_thread =
          get_number_of_sims_for_thread( $config->{always_wins_number_of_sims},
            $config->{number_of_threads}, $i );
        my $copied_sim_tournament_players =
          copy_tournament_players($sim_tournament_players);
        push @threads,
          threads->create(
            \&sim_player_always_wins_worker, $config,
            $copied_sim_tournament_players,  $player_in_nth_index,
            $number_of_sims_for_thread
          );
    }

    my $factor_pair_results =
      new_tournament_results( scalar(@$sim_tournament_players) );

    my $pwf_wins = 0;
    my $fp_wins  = 0;

    # Wait for the threads to finish and collect the results
    foreach my $thread (@threads) {
        my ( $thread_pwf_wins, $thread_fp_wins ) = $thread->join();
        $pwf_wins += $thread_pwf_wins;
        $fp_wins  += $thread_fp_wins;
    }
    return $pwf_wins, $fp_wins;
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

        my $pwf_wins;
        my $fp_wins;

        if ( $config->{number_of_threads} > 1 ) {
            if ( $player_in_nth_rank_index == 1 ) {
                log_info(
                    $config,
                    sprintf(
"Multithreading always wins factor pair with %d threads\n",
                        $config->{number_of_threads},
                    )
                );
            }
            ( $pwf_wins, $fp_wins ) =
              sim_player_always_wins_manager( $config, $sim_tournament_players,
                $player_in_nth_index );
        }
        else {
            if ( $player_in_nth_rank_index == 1 ) {
                log_info( $config,
                    "Single threading always wins factor pair\n" );
            }
            ( $pwf_wins, $fp_wins ) =
              sim_player_always_wins_worker( $config, $sim_tournament_players,
                $player_in_nth_index, $config->{always_wins_number_of_sims} );
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
        my $spread = int( $max_spread / 2 ) - int( rand( $max_spread + 1 ) );
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
    if ( $b lt $a ) {
        ( $a, $b ) = ( $p2, $p1 );
    }
    return "$a:$b";
}

sub factor_pair {
    my ( $sim_tournament_players, $nrl, $lowest_gibson_rank ) = @_;

    my $number_of_players = scalar(@$sim_tournament_players);

    my $number_of_players_to_factor  = $number_of_players;
    my $number_of_gibsonized_players = ( $lowest_gibson_rank + 1 );

    if ( $lowest_gibson_rank >= 0 ) {
        $number_of_players_to_factor -= $number_of_gibsonized_players;
    }

    if ( $nrl > $number_of_players_to_factor / 2 ) {
        $nrl = $number_of_players_to_factor / 2;
    }

    # This assumes players are already sorted
    my @pairings = ();

    # For gibsonized players pair with the bottom
    for ( my $i = 0 ; $i <= $lowest_gibson_rank ; $i++ ) {
        push @pairings, [ $i, ( $number_of_players - 1 ) - $i ];
    }
    for (
        my $i = $number_of_gibsonized_players ;
        $i < $nrl + $number_of_gibsonized_players ;
        $i++
      )
    {
        push @pairings, [ $i, $i + $nrl ];
    }
    for (
        my $i = $nrl * 2 + $number_of_gibsonized_players ;
        $i < $number_of_players - $number_of_gibsonized_players ;
        $i += 2
      )
    {
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
          || $a->{index} <=> $b->{index}
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

sub convert_pairings_to_id_pairings {
    my ( $tournament_players, $pairings ) = @_;
    my $number_of_players = scalar @{$tournament_players};
    my @id_pairings       = ();
    for ( my $i = 0 ; $i < scalar @{$pairings} ; $i++ ) {
        my $player_index   = $i;
        my $opponent_index = $pairings->[$i];

        my $player_id;
        my $opponent_id;

        if ( $player_index >= $number_of_players ) {

            # This is a bye
            $player_id = BYE_PLAYER_ID;
        }
        else {
            $player_id = $tournament_players->[$player_index]->{id};
        }

        if ( $opponent_index >= $number_of_players ) {

            # This is a bye
            $opponent_id = BYE_PLAYER_ID;
        }
        else {
            $opponent_id = $tournament_players->[$opponent_index]->{id};
        }

        if (   $player_index > $opponent_index
            && $opponent_index != BYE_PLAYER_ID )
        {
            # We have already made this pairing
            next;
        }
        push @id_pairings, [ $player_id, $opponent_id ];
    }
    return \@id_pairings;
}

# For logging only

sub player_string {
    my ( $player, $rank_index ) = @_;
    my $name_and_index = sprintf( "%-6s %-23s",
        '(#' . ( $player->{id} ) . ( $player->{class} ) . ')',
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
        my $opponent_id = BYE_PLAYER_ID;
        if ( $opponent_index < $number_of_players ) {
            $opponent_id = $tournament_players->[$opponent_index]->{id};
        }
        my $number_of_times_played =
          get_number_of_times_played( $player->{id}, $opponent_id,
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

sub min {
    my ( $x, $y ) = @_;
    if ( $x < $y ) {
        return $x;
    }
    return $y;
}

1;
