#!/usr/bin/perl

package TSH::Command::COP;

use strict;
use warnings;
use threads;
use Data::Dumper;

use File::Basename;
use TSH::Command::ShowPairings;
use TSH::PairingCommand;
use File::Copy;

our (@ISA) = qw(TSH::PairingCommand);

# Forward declarations so the JSON::true/JSON::false barewords used
# below resolve at compile time; the subs themselves are defined with
# the rest of the JSON replacement code near the end of this file.
sub JSON::true;
sub JSON::false;

use constant PROHIBITIVE_WEIGHT              => 1000000;
use constant BYE_PLAYER_ID                   => 0;
use constant INITIAL_FACTOR                  => 1000000;
use constant SINGULAR_CHILD_ROUNDS_REMAINING => 2;
use constant UNDEFINED_CLASS                 => 'UNDEFINED_CLASS';

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
    my $round_to_pair0     = $dp->FirstUnpairedRound0();

    my $timestamp     = get_timestamp();
    my $division_name = $dp->Name();
    my $sr1           = $sr0 + 1;

    # +2 because:
    #  0-index to 1-index for humans, and
    #  TSH pairs the next available round
    my $round_to_pair1   = $round_to_pair0 + 1;
    my $number_of_rounds = $dp->MaxRound0() + 1;

    if ( $round_to_pair1 > $number_of_rounds ) {
        $tournament->TellUser( 'ebigrd', $round_to_pair1, $number_of_rounds );
        return 0;
    }

    my $log_filename =
        "$log_dir$timestamp"
      . "_$division_name"
      . "_round_"
      . $round_to_pair1
      . "_based_on_$sr1" . ".log";
    my $html_log_filename =
      $log_dir . '../html/' . "$division_name$round_to_pair1" . '_cop.log';

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
    # Convert from 1-index to 0-index
    $control_loss_activation_round--;

    my $disallow_repeat_byes = !!$tournament->Config()->Value('disallow_repeat_byes');

    my $top_down_byes = !!$tournament->Config()->Value('top_down_byes');

    if ($tournament->Config()->Value('use_cop_api')) {
        my $underclass_count = 0;
        my %tsh_class_to_api_class = ();
        my @class_prizes = ();
        foreach my $class ( keys %{ $lowest_ranked_class_payouts } ) {
            if (!(defined $lowest_ranked_class_payouts->{$class})) {
                next;
            }
            # Convert the lowest ranked class prizer into number of class prizes
            push( @class_prizes, $lowest_ranked_class_payouts->{$class} + 1);
            $underclass_count++;
            $tsh_class_to_api_class{ $class } = $underclass_count;
        }
        
        my @players            = $dp->Players();
        my $number_of_players  = scalar @players;

        my @player_names = ();
        my @player_classes = ();
        my @removed_players = ();
        my %tsh_id_to_api_id = ();
        for ( my $i = 0 ; $i < $number_of_players ; $i++ ) {
            $tsh_id_to_api_id{ $players[$i]->ID() } = $i;
            push( @player_names, $players[$i]->PrettyName() =~ s/[^a-zA-Z0-9\s]//gr );
            my $player_api_class = 0;
            if ($players[$i]->Class()) {
                my $api_class = $tsh_class_to_api_class{ $players[$i]->Class() };
                if ($api_class) {
                    $player_api_class = $api_class;
                }
            }
            push( @player_classes, $player_api_class );
            if ( !$players[$i]->Active() ) {
                push( @removed_players, $i );
            }
        }

        my @division_pairings = ();
        my $last_paired_round0 = $dp->LastPairedRound0();

        for ( my $round = 0 ; $round <= $last_paired_round0 ; $round++ ) {
            my @round_pairings = ();
            for ( my $i = 0 ; $i < $number_of_players ; $i++ ) {
                my $player = $players[$i];
                my $oppID = $player->OpponentID($round);
                my $api_opp_id;
                if (!defined $oppID) {
                    $api_opp_id = -1;
                } elsif ($oppID == 0) {
                    $api_opp_id = $i;
                } else {
                    $api_opp_id = $tsh_id_to_api_id{ $oppID };
                }
                if (($api_opp_id < -1) || ($api_opp_id >= $number_of_players)) {
                    $tournament->TellUser(
                        'eapfail',
                        sprintf("player %s has invalid opponent for round %d", $player->PrettyName(), $round)
                    );
                    return 0;
                }
                push ( @round_pairings, $api_opp_id );
            }
            push( @division_pairings, { pairings => \@round_pairings } );
        }

        my @division_results = ();
        my $last_paired_score_round0 = $dp->LastPairedScoreRound0();
        
        for ( my $round = 0 ; $round <= $last_paired_score_round0 ; $round++ ) {
            my @round_results = ();
            for ( my $i = 0 ; $i < $number_of_players ; $i++ ) {
                my $player = $players[$i];
                # Use a score of 0 for players with pending results
                my $player_score = $player->Score($round);
                if (!$player_score) {
                    $player_score = 0;
                }
                push ( @round_results, $player_score );
            }
            push( @division_results, { results => \@round_results } );
        }
        
        my $rounds_remaining  = ($number_of_rounds - $last_paired_round0) - 1;

        my $api_control_loss_threshold = $control_loss_thresholds->[-1];
        if ($rounds_remaining < scalar(@$control_loss_thresholds)) {
            $api_control_loss_threshold = $control_loss_thresholds->[$rounds_remaining - 1];
        }

        my $api_hopefulness = $hopefulness->[-1];
        if ($rounds_remaining < scalar(@$hopefulness)) {
            $api_hopefulness = $hopefulness->[$rounds_remaining - 1];
        }

        my $api_gibson_spread = $gibson_spread->[-1];
        if ($rounds_remaining < scalar(@$gibson_spread)) {
            $api_gibson_spread = $gibson_spread->[$rounds_remaining - 1];
        }

        my $request_hash = {
            pair_method                   => 'COP',
            player_names                  => \@player_names,
            player_classes                => \@player_classes,
            division_pairings             => \@division_pairings,
            division_results              => \@division_results,
            class_prizes                  => \@class_prizes,
            gibson_spread                 => $api_gibson_spread,
            control_loss_threshold        => $api_control_loss_threshold,
            hopefulness_threshold         => $api_hopefulness,
            all_players                   => $number_of_players,
            valid_players                 => $number_of_players - scalar @removed_players,
            rounds                        => $number_of_rounds,
            place_prizes                  => $lowest_ranked_payout + 1,
            division_sims                 => $number_of_sims,
            control_loss_sims             => $always_wins_number_of_sims,
            control_loss_activation_round => $control_loss_activation_round,
            allow_repeat_byes             => $disallow_repeat_byes ? JSON::false : JSON::true,
            removed_players               => \@removed_players,
            seed                          => 0,
            top_down_byes                 => $top_down_byes ? JSON::true : JSON::false,
        };

        my $json_request = encode_json($request_hash);

        my @partial_rounds = get_partial_rounds( $dp, $last_paired_round0 );
        if (@partial_rounds) {
            printf( "Warning: pairings computed with partial results in round(s): %s\n",
                join( ', ', @partial_rounds ) );
        }

        my $api_url = 'https://woogles.io/api/pair_service.PairService/HandlePairRequest';
        my $curl_command = "curl -s -H 'Content-Type: application/json' -d '" . $json_request . "' $api_url";
        my $response = `$curl_command`;

        my $cop_config_logs_only = {
            log_filename               => $log_filename,
            html_log_filename          => $html_log_filename,
        };

        if ($? != 0) {
            log_info($cop_config_logs_only, "Failed curl command:\n$curl_command");
            copy_log_to_html_directory($cop_config_logs_only);
            $tournament->TellUser('eapfail', sprintf("curl command for COP API failed with: $?"));
            return 0;
        }

        # Decode the JSON response
        my $response_data = eval { decode_json($response) };
        if ($@) {
            log_info($cop_config_logs_only, "Failed to decode response:\n$response");
            copy_log_to_html_directory($cop_config_logs_only);
            $tournament->TellUser('eapfail', sprintf("failed to decode JSON for COP API: $@"));
            return 0;
        }

        if ($response_data->{log} eq '') {
            log_info($cop_config_logs_only, "COP API failed:\n$response");
            copy_log_to_html_directory($cop_config_logs_only);
            $tournament->TellUser('eapfail', sprintf("COP API failed:\n" . $response));
            return 0;
        }

        log_info($cop_config_logs_only, $response_data->{log});
        copy_log_to_html_directory($cop_config_logs_only);

        if ($response_data->{error_code} ne 'SUCCESS') {
            log_info($cop_config_logs_only, "COP API error code:\n". $response_data->{error_code} . ": " . $response_data->{error_message});
            copy_log_to_html_directory($cop_config_logs_only);
            $tournament->TellUser('eapfail', sprintf("COP API error code: " . $response_data->{error_code} . ": " . $response_data->{error_message}));
            return 0;
        }

        my $setupp = $this->SetupForPairings(
            'division' => $dp,
            'source0'  => $sr0
        ) or return 0;

        my $target0 = $setupp->{'target0'};

        my $api_pairings = $response_data->{pairings};
        for ( my $i = 0 ; $i < scalar @{$api_pairings} ; $i++ ) {
            my $player_api_id = $i;
            my $player_id = $players[$i]->ID();
            my $opponent_api_id = $api_pairings->[$i];
            my $opponent_id = 0;
            if ($opponent_api_id < 0) {
                next;
            } elsif ($opponent_api_id != $player_api_id) {
                $opponent_id = $players[$opponent_api_id]->ID();
            }
            $dp->Pair( $player_id, $opponent_id, $target0, 1 );
        }

        $this->TidyAfterPairing($dp);

        if (@partial_rounds) {
            printf( "Warning: pairings computed with partial results in round(s): %s\n",
                join( ', ', @partial_rounds ) );
        }

        # Automatically show the pairings
        my $show_pairings_command =
            new TSH::Command::ShowPairings( 'noconsole' => 1 );
        $show_pairings_command->Run( $tournament, $round_to_pair1, $dp );
        return 1;
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
    my %prepaired_players = ();
    for ( my $i = 0 ; $i < $number_of_players ; $i++ ) {
        my $player       = $players[$i];
        my $player_class = $player->Class();
        if ( !defined $player_class ) {
            $player_class = UNDEFINED_CLASS;
        }
        my $player_id = $player->ID();
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
        for ( my $round = 0 ; $round <= $round_to_pair1 - 1 ; $round++ ) {
            my $opponent = $player->{pairings}->[$round];
            if ( ( defined $opponent ) && $opponent == 0 ) {
                $byes++;
            }
        }
        $times_played{$times_given_bye_key} = $byes;

        push @tournament_players, new_tournament_player(
            $player_id,
            $player->PrettyName(),
            $player_class,
            $player_index,

            # Wins count as 2 and draws count as 1 to
            # keep everything in integers.
            $player->RoundWins($sr0) * 2,
            $player->RoundSpread($sr0), 0
        );
        $player_index++;

        my $actual_opponent_id = $player->OpponentID($round_to_pair0);
        if ( defined $actual_opponent_id ) {
            $prepaired_players{$player_id} = $actual_opponent_id;
        }
    }

    # Create the special config for cop
    my $cop_config = {
        log_filename               => $log_filename,
        html_log_filename          => $html_log_filename,
        number_of_sims             => $number_of_sims,
        number_of_threads          => $number_of_threads,
        number_of_rounds           => $number_of_rounds,
        round_to_pair              => $round_to_pair0,
        prepaired_players          => \%prepaired_players,
        always_wins_number_of_sims => $always_wins_number_of_sims,
        control_loss_thresholds    => extend_tsh_config_array(
            $control_loss_thresholds, $number_of_rounds
        ),
        control_loss_activation_round => $control_loss_activation_round,
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
        disallow_repeat_byes => $disallow_repeat_byes,
    };

    my @partial_rounds = get_partial_rounds( $dp, $last_paired_round0 );
    if (@partial_rounds) {
        printf( "Warning: pairings computed with partial results in round(s): %s\n",
            join( ', ', @partial_rounds ) );
    }

    my ( $id_pairings, $warnings ) = cop(
        $cop_config,    \@tournament_players,
        \%times_played, \%previous_pairing_hash
    );

    for ( my $i = 0 ; $i < scalar @{$warnings} ; $i++ ) {
        $tournament->TellUser( 'eapfail', $warnings->[$i] );
    }

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

    if (@partial_rounds) {
        printf( "Warning: pairings computed with partial results in round(s): %s\n",
            join( ', ', @partial_rounds ) );
    }

    # Automatically show the pairings
    my $show_pairings_command =
      new TSH::Command::ShowPairings( 'noconsole' => 1 );
    $show_pairings_command->Run( $tournament, $round_to_pair1, $dp );
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

sub get_partial_rounds {
    my ( $dp, $last_paired_round0 ) = @_;
    my @players        = $dp->Players();
    my @partial_rounds = ();
    for ( my $round = 0 ; $round <= $last_paired_round0 ; $round++ ) {
        my $has_result     = 0;
        my $missing_result = 0;
        for my $player (@players) {
            next unless $player->Active();
            my $opp_id = $player->OpponentID($round);
            next unless defined $opp_id;
            next if $opp_id == 0;
            if ( $player->Score($round) ) {
                $has_result = 1;
            }
            else {
                $missing_result = 1;
            }
        }
        if ( $has_result && $missing_result ) {
            push @partial_rounds, $round + 1;
        }
    }
    return @partial_rounds;
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
      new_tournament_player( BYE_PLAYER_ID, 'BYE', 'X', $bye_player_index, 0,
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
        if (   $division
            && uc($division) eq uc($division_name)
            && $type eq 'rank' )
        {
            my $place = $prize_specification->{subtype} - 1;

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
    $ret .= sprintf( "%31s %s\n", "Pairing for Round:",
        $config->{round_to_pair} + 1 );
    $ret .= sprintf( "%31s %s\n",
        "Total Number of Rounds:",
        $config->{number_of_rounds} );
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
        $config->{control_loss_activation_round} );
    $ret .= sprintf( "%31s %s\n", "Threads:", $config->{number_of_threads} );

    my $active_bye_text = 'INACTIVE';
    if ( $config->{bye_active} ) {
        $active_bye_text = 'ACTIVE';
    }
    $ret .= sprintf( "%31s %s\n", "Bye Active:", $active_bye_text );

    my $active_drb_text = 'INACTIVE';
    if ( $config->{disallow_repeat_byes} ) {
        $active_drb_text = 'ACTIVE';
    }
    $ret .= sprintf( "%31s %s\n", "Disallow Repeat Byes:", $active_drb_text );


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

sub prepaired_players_to_string {
    my ( $config, $tournament_players ) = @_;
    if ( scalar keys %{ $config->{prepaired_players} } == 0 ) {
        return "\n\nThere are no prepaired players\n\n";
    }
    my %player_id_to_tournament_player = ();
    foreach my $player ( @{$tournament_players} ) {
        $player_id_to_tournament_player{ $player->{id} } = $player;
    }

    my $ret = "\n\nPrepaired Players:\n\n";
    foreach my $player_id ( sort keys %{ $config->{prepaired_players} } ) {
        my $player = $player_id_to_tournament_player{$player_id};
        my $opponent =
          $player_id_to_tournament_player{ $config->{prepaired_players}
              ->{$player_id} };
        if ( $player->{id} < $opponent->{id} ) {
            $ret .= sprintf( "%s vs %s\n",
                player_string( $player,   -2 ),
                player_string( $opponent, -2 ) );
        }
    }
    return $ret;
}

sub previous_pairings_to_string {
    my (
        $config,            $tournament_players,
        $number_of_players, $previous_pairing_hash
    ) = @_;
    my $res = "\nPrevious Pairings\n\n";
    for ( my $i = 0 ; $i < $number_of_players ; $i++ ) {
        my $player_i = $tournament_players->[$i];
        for ( my $j = $i + 1 ; $j < $number_of_players ; $j++ ) {
            my $player_j = $tournament_players->[$j];
            my $times_played_key =
              create_times_played_key( $player_i->{id}, $player_j->{id} );
            if ( $previous_pairing_hash->{$times_played_key} ) {
                $res .= sprintf( "%s vs %s\n",
                    player_string( $player_i, $i ),
                    player_string( $player_j, $j ) );
            }
        }
    }
    return $res . "\n\n";
}

# Pairing and simming

sub cop {
    my (
        $config,            $tournament_players,
        $times_played_hash, $previous_pairing_hash
    ) = @_;


    log_info( $config,
        prepaired_players_to_string( $config, $tournament_players ) );

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

    log_info( $config, config_to_string($config) );

    sort_tournament_players_by_record($tournament_players);

    log_info(
        $config,
        sprintf( "\n\nStandings\n\n%s\n",
            tournament_players_string($tournament_players) )
    );

    log_info(
        $config,
        previous_pairings_to_string(
            $config,            $tournament_players,
            $number_of_players, $previous_pairing_hash
        )
    );

    # Truncate the players for simulations.
    # We don't need to simulate anyone who can't cash and
    # having unnecessary players in the simulations
    # degrades performance.

    my $sim_tournament_players =
      get_sim_tournament_players( $config, $tournament_players );

    my $lowest_gibson_rank =
      get_lowest_gibson_rank( $config, $sim_tournament_players );

    # Use some large value for max factor
    # so that the number of rounds remaining
    # is always used as the factor.
    my $factor_pair_results =
      sim_factor_pair( $config, $sim_tournament_players, $lowest_gibson_rank,
        INITIAL_FACTOR );

    log_info(
        $config,
        results_string(
            $config,              $sim_tournament_players,
            $factor_pair_results, INITIAL_FACTOR
        )
    );

    my ( $stat_results, $abs_results, ) =
      get_lowest_ranked_players_who_can_finish_in_nth( $config,
        $factor_pair_results, $sim_tournament_players );

    # Make the max factor the difference in rank of the lowest player
    # who can get the highest ranked non-gibsonized rank and the rank
    # itself at least once in the sims.
    my $improved_factor_constant =
      $abs_results->[ $lowest_gibson_rank + 1 ] - ( $lowest_gibson_rank + 1 );
    my $improved_factor_pair_results = sim_factor_pair(
        $config,             $sim_tournament_players,
        $lowest_gibson_rank, $improved_factor_constant
    );

    log_info(
        $config,
        results_string(
            $config,                       $sim_tournament_players,
            $improved_factor_pair_results, $improved_factor_constant
        )
    );

    my $lowest_ranked_always_wins = -1;
    my $control_loss              = -1;

    if ( $lowest_gibson_rank < 0 ) {
        ( $lowest_ranked_always_wins, $control_loss ) =
          get_control_loss( $config, $improved_factor_pair_results,
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
        $improved_factor_pair_results, $sim_tournament_players );

    my $lowest_ranked_player_who_can_cash_statistically =
      $lowest_ranked_players_who_can_finish_in_nth_statistically
      ->[ $config->{lowest_ranked_payout} ];

    my $lowest_ranked_player_who_can_cash_absolutely =
      $lowest_ranked_players_who_can_finish_in_nth_absolutely
      ->[ $config->{lowest_ranked_payout} ];

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
    my $control_loss_active =
      $config->{round_to_pair} >= $config->{control_loss_activation_round};

    my $control_status_text = 'ACTIVE';

    if ( !$control_loss_active ) {
        $control_status_text = 'DISABLED';
    }

    # Get the number of repeats for each individual player
    my %number_of_repeats        = ();
    my $destinys_child           = -1;
    my $control_loss_weight_used = 0;
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

            if ( $config->{number_of_rounds_remaining} == 1 ) {

                # do nothing
            }
            elsif ( !$player_j->{is_bye} ) {

                # If neither of these blocks are true, that means both
                # players are gibsonized and we don't have to consider
                # control loss or placement.
                my $i_gibson_j_cash =
                     $i <= $lowest_gibson_rank
                  && $j > $lowest_gibson_rank
                  && $j <= $lowest_ranked_player_who_can_cash_absolutely
                  && $j != ( $number_of_players - 1 );
                my $neither_player_gibson =
                  $i > $lowest_gibson_rank && $j > $lowest_gibson_rank;
                if ($i_gibson_j_cash) {

                    # do nothing
                }
                elsif ($neither_player_gibson) {

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

                    # Enforce destiny control for two players if there
                    # are more than 2 rounds left.
                    if (   $control_loss_active
                        && $i == 0 )
                    {
                        if (
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
                        {
                            $control_loss_weight_used = 1;

                        }
                        else {
                            $destinys_child = $j;
                        }

                        # Prohibitive weights are applied later
                    }
                }
            }
        }
    }

    if ( $destinys_child >= 0 ) {
        log_info(
            $config,
            sprintf(
                "\nDestiny's child is %s\n\n",
                player_string(
                    $tournament_players->[$destinys_child],
                    $destinys_child
                )
            )
        );
    }
    else {
        log_info( $config, sprintf("\nThere is no destiny's child\n\n") );
    }

    my $class_prize_pairings =
      get_class_prize_pairings( $config, $tournament_players,
        $lowest_ranked_player_who_can_cash_absolutely,
        $lowest_gibson_rank, $number_of_players );

    if ( $config->{number_of_rounds_remaining} == 1
        && scalar keys %{$class_prize_pairings} > 0 )
    {
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
"\n\nWeights\n\n%-94s | %-3s = %7s = %7s + %7s + %7s + %7s + %7s + %7s + %7s\n",
            "Pairing", "Rpt",     "Total",  "Repeats", "RankDif",
            "CanCtch", "Control", "Gibson", "KOTH",    "Prepair"
        )
    );

    my $max_weight  = 0;
    my @edges       = ();
    my %weight_hash = ();
    for ( my $i = 0 ; $i < $number_of_players ; $i++ ) {
        my $player_i = $tournament_players->[$i];
        for ( my $j = $i + 1 ; $j < $number_of_players ; $j++ ) {
            my $player_j         = $tournament_players->[$j];
            my $prepaired_weight = 0;
            if (
                (
                    defined $config->{prepaired_players}->{ $player_i->{id} }
                    && $config->{prepaired_players}->{ $player_i->{id} } ne
                    $player_j->{id}
                )
                || ( defined $config->{prepaired_players}->{ $player_j->{id} }
                    && $config->{prepaired_players}->{ $player_j->{id} } ne
                    $player_i->{id} )
              )
            {
                # If this player already has a pairing with someone other than
                # player j, then this pairing shouldn't be made. Technically,
                # we could skip the rest of the calculations below since this
                # weight is prohibitive, but this part of the code is not
                # on the critical path.
                $prepaired_weight = PROHIBITIVE_WEIGHT;
            }
            my $both_cannot_get_payout_absolutely =
                 $i > $lowest_ranked_player_who_can_cash_absolutely
              && $j > $lowest_ranked_player_who_can_cash_absolutely;

            my $both_cannot_get_payout_statistically =
                 $i > $lowest_ranked_player_who_can_cash_statistically
              && $j > $lowest_ranked_player_who_can_cash_statistically;

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
            elsif ($both_cannot_get_payout_statistically
                && $previous_pairing_hash->{$times_played_key} )
            {
              # If both players are out of the money avoid a back to back repeat
                $repeat_weight += ( PROHIBITIVE_WEIGHT / 10 );
            }
            elsif ( $number_of_times_played > 0 ) {
                $repeat_weight += ( $number_of_repeats{ $player_i->{id} } +
                      $number_of_repeats{ $player_j->{id} } ) * 2;
            }

            # If the player has had a bye and repeat byes are not allowed,
            # prevent this pairing
            if ($player_j->{is_bye} && $number_of_times_played > 0 && $config->{disallow_repeat_byes}) {
                $repeat_weight += PROHIBITIVE_WEIGHT;
            }

            my $rank_difference_weight;

            # If neither player can cash or player i is gibsonized,
            # rank difference weight should count for very little.
            if (   $both_cannot_get_payout_absolutely
                || $i <= $lowest_gibson_rank )
            {
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
                my $i_gibson_j_cash =
                     $i <= $lowest_gibson_rank
                  && $j > $lowest_gibson_rank
                  && $j <= $lowest_ranked_player_who_can_cash_absolutely
                  && $j != ( $number_of_players - 1 );
                my $neither_player_gibson =
                  $i > $lowest_gibson_rank && $j > $lowest_gibson_rank;
                if ($i_gibson_j_cash) {

                    # player i is gibsonized and player j can still cash, they
                    # shouldn't be paired
                    $gibson_weight = PROHIBITIVE_WEIGHT;
                }
                elsif ($neither_player_gibson) {

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
                   # player j can't catch player i, so they should not be paired
                            $pair_with_placer_weight = PROHIBITIVE_WEIGHT;
                        }
                    }

                    # Enforce destiny control for two players if there
                    # are more than 2 rounds left.
                    if (
                           $control_loss_active
                        && $i == 0
                        && (
                            (
                                (
                                       $j != $destinys_child
                                    && $config->{number_of_rounds_remaining} <=
                                    SINGULAR_CHILD_ROUNDS_REMAINING
                                )
                            )
                            || (
                                (
                                       $j == $destinys_child
                                    || $j == $destinys_child - 1
                                )
                                && $config->{number_of_rounds_remaining} >
                                SINGULAR_CHILD_ROUNDS_REMAINING
                                && $previous_pairing_hash->{$times_played_key}

                                # If destinys child is second place,
                                # they are the only player who can play first
                                && $destinys_child != 1
                            )
                            || (   $j != $destinys_child
                                && $j != $destinys_child - 1
                                && $config->{number_of_rounds_remaining} >
                                SINGULAR_CHILD_ROUNDS_REMAINING )
                        )
                      )
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
              $koth_weight +
              $prepaired_weight;
            if ( $weight > $max_weight ) {
                $max_weight = $weight;
            }

            log_info(
                $config,
                sprintf(
"%s vs %s | %3d = %7d = %7d + %7d + %7d + %7d + %7d + %7d + %7d\n",
                    player_string( $player_i, $i ),
                    player_string( $player_j, $j ),
                    $number_of_times_played,
                    $weight,
                    $repeat_weight,
                    $rank_difference_weight,
                    $pair_with_placer_weight,
                    $control_loss_weight,
                    $gibson_weight,
                    $koth_weight,
                    $prepaired_weight
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
    my @warnings   = ();
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
                my $warning = sprintf(
"WARNING: Pairing exceeds prohibitive weight (%d): %s vs %s\n",
                    $pairing_weight,
                    player_string( $player_i, $i ),
                    player_string( $player_j, $j )
                );
                log_info(
                    $config, $warning

                );
                push @warnings, $warning;
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

    return $id_pairings, \@warnings;
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
    my ( $config, $improved_factor_pair_results, $sim_tournament_players ) = @_;

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
                  get_tournament_result( $improved_factor_pair_results,
                    $player, $i );
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
    log_info( $config, "\n\n *** END PRINTING LOWEST FINISHERS *** \n\n" );
    return \@lowest_ranked_players_who_can_finish_in_nth_statistically,
      \@lowest_ranked_players_who_can_finish_in_nth_absolutely;
}

sub get_control_loss {
    my ( $config, $improved_factor_pair_results, $sim_tournament_players ) = @_;

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

sub log_ineligible_classes {
    my ( $config, $ineligible_classes, $reason ) = @_;
    my $ineliglbe_classes_log = "Ineligible classes ($reason): ";
    foreach my $class ( sort keys %{$ineligible_classes} ) {
        $ineliglbe_classes_log .= "$class,";
    }
    chop($ineliglbe_classes_log);
    $ineliglbe_classes_log .= "\n";
    log_info( $config, $ineliglbe_classes_log );
}

sub get_class_prize_pairings {
    my ( $config, $tournament_players,
        $lowest_ranked_player_who_can_cash_absolutely,
        $lowest_gibson_rank, $number_of_players )
      = @_;

    my %class_pairings_remaining = ();
    foreach my $class ( keys %{ $config->{lowest_ranked_class_payouts} } ) {
        $class_pairings_remaining{$class} =
          $config->{lowest_ranked_class_payouts}->{$class} + 1;
    }
    my %previous_class_player_ranks = ();
    my %class_prize_pairings        = ();

    # Do not make any forced pairings
    # if any player in that class can cash.
    my %ineligible_classes = ();
    for (
        my $i = 0 ;
        $i <= $lowest_ranked_player_who_can_cash_absolutely ;
        $i++
      )
    {
        $ineligible_classes{ $tournament_players->[$i]->{class} } = 1;
    }

    log_ineligible_classes( $config, \%ineligible_classes, 'Can cash' );

    # Determine if any players are dragged into the KOTH
    # win group. If they are, that class should not be
    # paired with class prizes as a priority.
    for ( my $i = 0 ; $i < $number_of_players ; $i++ ) {
        for ( my $j = $i + 1 ; $j < $number_of_players ; $j++ ) {

            if (   $i > $lowest_gibson_rank
                && $i <= $lowest_ranked_player_who_can_cash_absolutely
                && $lowest_gibson_rank % 2 != $i % 2
                && $i + 1 == $j )
            {
                $ineligible_classes{ $tournament_players->[$j]->{class} } = 1;
            }
        }
    }

    log_ineligible_classes( $config, \%ineligible_classes,
        'Even the odd win group' );

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
                && !$ineligible_classes{ $player_i->{class} }
                && $class_pairings_remaining{ $player_i->{class} } > 0
                && ( !defined $class_prize_pairings{$i} )
                && ( !defined $class_prize_pairings{$j} )
                && (
                    (
                        !defined
                        $previous_class_player_ranks{ $player_i->{class} }
                    )
                    || can_player_reach_rank(
                        $config,
                        $tournament_players,
                        $tournament_players->[$i],
                        $previous_class_player_ranks{ $player_i->{class} }
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
                $previous_class_player_ranks{ $player_i->{class} } = $j;
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
        $number_of_sims, $max_factor )
      = @_;
    my $results = new_tournament_results( scalar(@$sim_tournament_players) );
    for ( my $i = 0 ; $i < $number_of_sims ; $i++ ) {
        for (
            my $remaining_rounds = $config->{number_of_rounds_remaining} ;
            $remaining_rounds >= 1 ;
            $remaining_rounds--
          )
        {
            my $pairings = factor_pair(
                $sim_tournament_players, $remaining_rounds,
                $lowest_gibson_rank,     $max_factor
            );
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
    my ( $config, $sim_tournament_players, $lowest_gibson_rank, $max_factor ) =
      @_;

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
            $number_of_sims_for_thread, $max_factor
          );
    }

    my $improved_factor_pair_results =
      new_tournament_results( scalar(@$sim_tournament_players) );

    # Wait for the threads to finish and collect the results
    foreach my $thread (@threads) {
        my $thread_result = $thread->join();
        for (
            my $i = 0 ;
            $i < scalar( @{ $improved_factor_pair_results->{array} } ) ;
            $i++
          )
        {
            $improved_factor_pair_results->{array}->[$i] +=
              $thread_result->{array}->[$i];
        }
    }
    $improved_factor_pair_results->{count} = $config->{number_of_sims};
    return $improved_factor_pair_results;
}

sub sim_factor_pair {
    my ( $config, $sim_tournament_players, $lowest_gibson_rank, $max_factor ) =
      @_;
    if ( $config->{number_of_threads} > 1 ) {
        log_info(
            $config,
            sprintf( "Multithreading factor pair with %d threads\n",
                $config->{number_of_threads} )
        );
        return sim_factor_pair_manager( $config, $sim_tournament_players,
            $lowest_gibson_rank, $max_factor );
    }
    else {
        log_info( $config, sprintf("Single threading factor pair\n") );
        return sim_factor_pair_worker( $config, $sim_tournament_players,
            $lowest_gibson_rank, $config->{number_of_sims}, $max_factor );
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

              # use initial factor here since we are only
              # concerned about if this player can get first or
              # not as opposed to equitable pairings for all players
              factor_pair( $sim_tournament_players, $remaining_rounds, -1,
                INITIAL_FACTOR );
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

    my $improved_factor_pair_results =
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
              sim_player_always_wins_manager( $config,
                $sim_tournament_players, $player_in_nth_index );
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
                $tournament_players->[ $pairing->[ 1 - $j ] ]->{spread} +=
                  50;
                $tournament_players->[ $pairing->[ 1 - $j ] ]->{wins} += 2;
                next outer;
            }
        }
        my $spread = $max_spread - int( rand( ( $max_spread * 2 ) + 1 ) );
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
    my ( $sim_tournament_players, $nrl, $lowest_gibson_rank, $max_factor ) = @_;

    my $number_of_players = scalar(@$sim_tournament_players);

    my $number_of_players_to_factor  = $number_of_players;
    my $number_of_gibsonized_players = ( $lowest_gibson_rank + 1 );

    if ( $lowest_gibson_rank >= 0 ) {
        $number_of_players_to_factor -= $number_of_gibsonized_players;
    }

    if ( $nrl > $number_of_players_to_factor / 2 ) {
        $nrl = $number_of_players_to_factor / 2;
    }

    if ( $nrl > $max_factor ) {
        $nrl = $max_factor;
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
    my $player_class = $player->{class};
    if ( $player_class eq UNDEFINED_CLASS ) {
        $player_class = '';
    }
    my $name_and_index = sprintf( "%-6s %-23s",
        '(#' . ( $player->{id} ) . ($player_class) . ')',
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
    my ( $config, $tournament_players, $results, $factor_constant ) = @_;
    sort_tournament_players_by_record($tournament_players);
    my $number_of_players = scalar @{$tournament_players};
    my $factor_strategy   = 'number of rounds remaining';
    if ( $factor_constant != INITIAL_FACTOR ) {
        $factor_strategy =
          "minimum of number of rounds remaining and $factor_constant";
    }
    my $result = sprintf( "\n\nResults (factor = %s)\n\n", $factor_strategy );
    $result .= sprintf( "%47s", ("") );
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
    $result .= sprintf("\n\n *** END PRINTING RESULTS ***\n\n");
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

# ---------------------------------------------------------------------------
# Maximum weight matching
#
# Ported by hand from the networkx implementation of Galil's blossom /
# primal-dual algorithm for maximum-weighted matching in general graphs:
#
#   https://networkx.org/documentation/stable/_modules/networkx/algorithms/matching.html
#
# This replaces the CPAN Graph::Matching module, which implemented the
# same algorithm (the variable and function names below are deliberately
# kept close to both the networkx source and Graph::Matching for ease of
# cross-reference).
# ---------------------------------------------------------------------------

package TSH::Command::COP::Blossom;

# Representation of a non-trivial blossom or sub-blossom.
#
# childs is an ordered list of the blossom's sub-blossoms, starting with
# the base and going round the blossom.
#
# edges is the list of the blossom's connecting edges, such that
# edges->[$i] = [ $v, $w ] where $v is a vertex in childs->[$i] and $w is
# a vertex in childs->[wrap($i+1)].
#
# If the blossom is a top-level S-blossom, mybestedges is a list of
# least-slack edges to neighboring S-blossoms, or undef if no such list
# has been computed yet. This is used for efficient computation of
# delta3.

sub new {
    my ($class) = @_;
    return bless { childs => [], edges => [], mybestedges => undef }, $class;
}

# Generate the blossom's leaf vertices.
sub leaves {
    my ($self) = @_;
    my @stack = @{ $self->{childs} };
    my @out;
    while (@stack) {
        my $t = pop @stack;
        if ( ref($t) ) {
            push @stack, @{ $t->{childs} };
        }
        else {
            push @out, $t;
        }
    }
    return @out;
}

package TSH::Command::COP;

# Dummy value which is different from any node, used to mark that
# scanBlossom() found an augmenting path rather than a new blossom base.
my $NO_NODE = bless {}, 'TSH::Command::COP::NoNode';

sub _is_blossom {
    my ($x) = @_;
    return ref($x) eq 'TSH::Command::COP::Blossom';
}

sub _is_no_node {
    my ($x) = @_;
    return ref($x) eq 'TSH::Command::COP::NoNode';
}

sub _index_of {
    my ( $arrayref, $item ) = @_;
    for ( my $i = 0 ; $i < scalar @{$arrayref} ; $i++ ) {
        return $i if $arrayref->[$i] eq $item;
    }
    return -1;
}

sub _min_values {
    my $m;
    foreach my $x (@_) {
        $m = $x if !defined($m) || $x < $m;
    }
    return $m;
}

=item %matching = max_weight_matching($edges, $maxcardinality)

Compute a maximum-weighted matching of an undirected graph.

A matching is a subset of edges in which no node occurs more than once.
The weight of a matching is the sum of the weights of its edges. This
function takes time O(number_of_nodes ** 3).

$edges is a reference to an array of edges. An edge is described by an
arrayref [ $v, $w, $weight ], containing the two nodes (plain scalars,
not references) and the weight of the edge. Edges are undirected
(usable in both directions). A pair of nodes may have at most one edge
between them.

If $maxcardinality is true, compute the maximum-cardinality matching
with maximum weight among all maximum-cardinality matchings.

The matching is returned as a hash %m, such that $m{$v} == $w if node
$v is matched to node $w. Unmatched nodes will not occur as keys of %m.

If all edge weights are integers, the algorithm uses only integer
computations. If floating point weights are used, the algorithm could
return a slightly suboptimal matching due to numeric precision errors.

This method is based on the "blossom" method for finding augmenting
paths and the "primal-dual" method for finding a matching of maximum
weight, both methods invented by Jack Edmonds. See "Efficient
Algorithms for Finding Maximum Matching in Graphs" by Zvi Galil, ACM
Computing Surveys, 1986.

=cut

sub max_weight_matching {
    my ( $edges, $maxcardinality ) = @_;

    return () if !@{$edges};

    # Get a list of vertices (in order of first appearance, mirroring
    # the node order of a networkx Graph built from this edge list), and
    # build an adjacency list and edge-weight lookup.
    my @gnodes;
    my %seen;
    my %adj;
    my %ew;
    foreach my $e ( @{$edges} ) {
        my ( $v, $w, $wt ) = @{$e};
        next if $v eq $w;    # ignore self-loops
        foreach my $u ( $v, $w ) {
            if ( !$seen{$u} ) {
                $seen{$u} = 1;
                push @gnodes, $u;
                $adj{$u} = [];
            }
        }
        push @{ $adj{$v} }, $w;
        push @{ $adj{$w} }, $v;
        $ew{$v}{$w} = $wt;
        $ew{$w}{$v} = $wt;
    }

    return () if !@gnodes;

    # Find the maximum edge weight.
    my $maxweight  = 0;
    my $allinteger = 1;
    foreach my $e ( @{$edges} ) {
        my ( $v, $w, $wt ) = @{$e};
        next if $v eq $w;
        $maxweight = $wt if $wt > $maxweight;
        $allinteger = 0 if $wt != int($wt);
    }

    # If v is a matched vertex, mate{v} is its partner vertex.
    # If v is a single vertex, v does not occur as a key in mate.
    # Initially all vertices are single; updated during augmentation.
    my %mate;

    # If b is a top-level blossom, label{b} is undef if b is unlabeled
    # (free), 1 if b is an S-blossom, 2 if b is a T-blossom.
    # The label of a vertex is found by looking at the label of its
    # top-level containing blossom. If v is a vertex inside a T-blossom,
    # label{v} is 2 iff v is reachable from an S-vertex outside the
    # blossom. Labels are assigned during a stage and reset after each
    # augmentation.
    my %label;

    # If b is a labeled top-level blossom, labeledge{b} = [ v, w ] is the
    # edge through which b obtained its label such that w is a vertex in
    # b, or undef if b's base vertex is single.
    my %labeledge;

    # If v is a vertex, inblossom{v} is the top-level blossom to which v
    # belongs. If v is a top-level vertex, v is itself a (trivial)
    # top-level blossom, so inblossom{v} == v.
    my %inblossom;
    foreach my $v (@gnodes) { $inblossom{$v} = $v; }

    # If b is a sub-blossom, blossomparent{b} is its immediate parent
    # (sub-)blossom. If b is a top-level blossom, blossomparent{b} is
    # undef.
    my %blossomparent;
    foreach my $v (@gnodes) { $blossomparent{$v} = undef; }

    # If b is a (sub-)blossom, blossombase{b} is its base vertex.
    my %blossombase;
    foreach my $v (@gnodes) { $blossombase{$v} = $v; }

    # If w is a free vertex (or an unreached vertex inside a T-blossom),
    # bestedge{w} = [ v, w ] is the least-slack edge from an S-vertex, or
    # undef if there is no such edge. If b is a (possibly trivial)
    # top-level S-blossom, bestedge{b} = [ v, w ] is the least-slack edge
    # to a different S-blossom (v inside b), or undef if there is no such
    # edge. This is used for efficient computation of delta2 and delta3.
    my %bestedge;

    # dualvar{v} = 2 * u(v), where u(v) is v's variable in the dual
    # optimization problem (multiplication by two ensures integer values
    # throughout the algorithm if all edge weights are integers).
    my %dualvar;
    foreach my $v (@gnodes) { $dualvar{$v} = $maxweight; }

    # If b is a non-trivial blossom, blossomdual{b} = z(b), b's variable
    # in the dual optimization problem.
    my %blossomdual;

    # Blossoms are Perl objects, and can't be recovered from a
    # stringified hash key, so keep them in an array in creation order
    # (mirroring the insertion order of a Python dict) along with a
    # liveness flag so they can be iterated like blossomparent/
    # blossomdual keys without losing the reference.
    my @blossom_order;
    my %blossom_alive;

    # If ("$v,$w") or ("$w,$v") is a key in allowedge, then the edge
    # (v, w) is known to have zero slack in the optimization problem;
    # otherwise the edge may or may not have zero slack.
    my %allowedge;

    # Queue of newly discovered S-vertices.
    my @queue;

    # Return 2 * slack of edge (v, w) (does not work inside blossoms).
    my $slack = sub {
        my ( $v, $w ) = @_;
        return $dualvar{$v} + $dualvar{$w} - 2 * $ew{$v}{$w};
    };

    # Assign label t to the top-level blossom containing vertex w,
    # coming through an edge from vertex v (or undef).
    my $assignLabel;
    $assignLabel = sub {
        my ( $w, $t, $v ) = @_;
        my $b = $inblossom{$w};
        $label{$w} = $label{$b} = $t;
        if ( defined $v ) {
            $labeledge{$w} = $labeledge{$b} = [ $v, $w ];
        }
        else {
            $labeledge{$w} = $labeledge{$b} = undef;
        }
        $bestedge{$w} = $bestedge{$b} = undef;
        if ( $t == 1 ) {

            # b became an S-vertex/blossom; add it(s vertices) to the queue.
            if ( _is_blossom($b) ) {
                push @queue, $b->leaves();
            }
            else {
                push @queue, $b;
            }
        }
        elsif ( $t == 2 ) {

            # b became a T-vertex/blossom; assign label S to its mate.
            # (If b is a non-trivial blossom, its base is the only
            # vertex with an external mate.)
            my $base = $blossombase{$b};
            $assignLabel->( $mate{$base}, 1, $base );
        }
    };

    # Trace back from vertices v and w to discover either a new blossom
    # or an augmenting path. Return the base vertex of the new blossom,
    # or $NO_NODE if an augmenting path was found.
    my $scanBlossom = sub {
        my ( $v, $w ) = @_;
        my @path;
        my $base = $NO_NODE;
        while ( !_is_no_node($v) ) {

            # Look for a breadcrumb in v's blossom or put a new breadcrumb.
            my $b = $inblossom{$v};
            if ( $label{$b} & 4 ) {
                $base = $blossombase{$b};
                last;
            }
            push @path, $b;
            $label{$b} = 5;

            # Trace one step back.
            if ( !defined $labeledge{$b} ) {

                # The base of blossom b is single; stop tracing this path.
                $v = $NO_NODE;
            }
            else {
                $v = $labeledge{$b}[0];
                $b = $inblossom{$v};

                # b is a T-blossom; trace one more step back.
                $v = $labeledge{$b}[0];
            }

            # Swap v and w so that we alternate between both paths.
            if ( !_is_no_node($w) ) {
                ( $v, $w ) = ( $w, $v );
            }
        }

        # Remove breadcrumbs.
        foreach my $b (@path) { $label{$b} = 1; }

        # Return base vertex, if we found one.
        return $base;
    };

    # Construct a new blossom with given base, through S-vertices v and
    # w. Label the new blossom as S; set its dual variable to zero;
    # relabel its T-vertices to S and add them to the queue.
    my $addBlossom = sub {
        my ( $base, $v, $w ) = @_;
        my $bb = $inblossom{$base};
        my $bv = $inblossom{$v};
        my $bw = $inblossom{$w};

        # Create blossom.
        my $b = TSH::Command::COP::Blossom::new('TSH::Command::COP::Blossom');
        $blossombase{$b}    = $base;
        $blossomparent{$b}  = undef;
        $blossomparent{$bb} = $b;
        push @blossom_order, $b;
        $blossom_alive{$b} = 1;

        # Make list of sub-blossoms and their interconnecting edge
        # endpoints.
        my @path;
        my @edgs = ( [ $v, $w ] );

        # Trace back from v to base.
        while ( $bv ne $bb ) {
            $blossomparent{$bv} = $b;
            push @path, $bv;
            push @edgs, $labeledge{$bv};
            $v  = $labeledge{$bv}[0];
            $bv = $inblossom{$v};
        }

        # Add base sub-blossom; reverse lists.
        push @path, $bb;
        @path = reverse @path;
        @edgs = reverse @edgs;

        # Trace back from w to base.
        while ( $bw ne $bb ) {
            $blossomparent{$bw} = $b;
            push @path, $bw;
            push @edgs, [ $labeledge{$bw}[1], $labeledge{$bw}[0] ];
            $w  = $labeledge{$bw}[0];
            $bw = $inblossom{$w};
        }

        $b->{childs} = \@path;
        $b->{edges}  = \@edgs;

        # Set label to S.
        $label{$b}     = 1;
        $labeledge{$b} = $labeledge{$bb};

        # Set dual variable to zero.
        $blossomdual{$b} = 0;

        # Relabel vertices.
        foreach my $leaf ( $b->leaves() ) {
            if ( defined( $label{ $inblossom{$leaf} } )
                && $label{ $inblossom{$leaf} } == 2 )
            {
                # This T-vertex now turns into an S-vertex because it
                # becomes part of an S-blossom; add it to the queue.
                push @queue, $leaf;
            }
            $inblossom{$leaf} = $b;
        }

        # Compute b's list of least-slack edges to neighboring blossoms.
        my %bestedgeto;
        my @bestedgeto_order;
        foreach my $bv_child (@path) {
            my @nblist;
            if ( _is_blossom($bv_child) ) {
                if ( defined $bv_child->{mybestedges} ) {

                    # Walk this subblossom's least-slack edges.
                    @nblist = @{ $bv_child->{mybestedges} };

                    # The sub-blossom won't need this data again.
                    $bv_child->{mybestedges} = undef;
                }
                else {
                    # This subblossom does not have a list of
                    # least-slack edges; get the information from the
                    # vertices.
                    foreach my $leaf ( $bv_child->leaves() ) {
                        foreach my $nb ( @{ $adj{$leaf} } ) {
                            next if $leaf eq $nb;
                            push @nblist, [ $leaf, $nb ];
                        }
                    }
                }
            }
            else {
                foreach my $nb ( @{ $adj{$bv_child} } ) {
                    next if $bv_child eq $nb;
                    push @nblist, [ $bv_child, $nb ];
                }
            }
            foreach my $k (@nblist) {
                my ( $i, $j ) = @{$k};
                if ( $inblossom{$j} eq $b ) {
                    ( $i, $j ) = ( $j, $i );
                }
                my $bj = $inblossom{$j};
                if (   $bj ne $b
                    && defined( $label{$bj} )
                    && $label{$bj} == 1
                    && ( !exists( $bestedgeto{$bj} )
                        || $slack->( $i, $j ) < $slack->( @{ $bestedgeto{$bj} } ) )
                  )
                {
                    push @bestedgeto_order, $bj if !exists( $bestedgeto{$bj} );
                    $bestedgeto{$bj} = [ $i, $j ];
                }
            }

            # Forget about least-slack edge of the subblossom.
            $bestedge{$bv_child} = undef;
        }
        $b->{mybestedges} = [ map { $bestedgeto{$_} } @bestedgeto_order ];

        # Select bestedge{b}.
        my $mybestedge;
        my $mybestslack;
        $bestedge{$b} = undef;
        foreach my $k ( @{ $b->{mybestedges} } ) {
            my $kslack = $slack->( @{$k} );
            if ( !defined($mybestedge) || $kslack < $mybestslack ) {
                $mybestedge  = $k;
                $mybestslack = $kslack;
            }
        }
        $bestedge{$b} = $mybestedge;
    };

    # Expand the given top-level blossom.
    my $expandBlossom;
    $expandBlossom = sub {
        my ( $b, $endstage ) = @_;

        # Convert sub-blossoms into top-level blossoms.
        foreach my $s ( @{ $b->{childs} } ) {
            $blossomparent{$s} = undef;
            if ( _is_blossom($s) ) {
                if ( $endstage && $blossomdual{$s} == 0 ) {

                    # Recursively expand this sub-blossom.
                    $expandBlossom->( $s, $endstage );
                }
                else {
                    foreach my $leaf ( $s->leaves() ) { $inblossom{$leaf} = $s; }
                }
            }
            else {
                $inblossom{$s} = $s;
            }
        }

        # If we expand a T-blossom during a stage, its sub-blossoms must
        # be relabeled.
        if ( !$endstage && defined( $label{$b} ) && $label{$b} == 2 ) {

            # Start at the sub-blossom through which the expanding
            # blossom obtained its label, and relabel sub-blossoms until
            # we reach the base. Figure out through which sub-blossom
            # the expanding blossom obtained its label initially.
            my $entrychild = $inblossom{ $labeledge{$b}[1] };

            # Decide in which direction we will go round the blossom.
            my $j = _index_of( $b->{childs}, $entrychild );
            my $jstep;
            if ( $j & 1 ) {

                # Start index is odd; go forward and wrap.
                $j -= scalar( @{ $b->{childs} } );
                $jstep = 1;
            }
            else {
                # Start index is even; go backward.
                $jstep = -1;
            }

            # Move along the blossom until we get to the base.
            my ( $v, $w ) = @{ $labeledge{$b} };
            while ( $j != 0 ) {

                # Relabel the T-sub-blossom.
                my ( $p, $q );
                if ( $jstep == 1 ) {
                    ( $p, $q ) = @{ $b->{edges}[$j] };
                }
                else {
                    ( $q, $p ) = @{ $b->{edges}[ $j - 1 ] };
                }
                $label{$w} = undef;
                $label{$q} = undef;
                $assignLabel->( $w, 2, $v );

                # Step to the next S-sub-blossom and note its forward edge.
                $allowedge{"$p,$q"} = 1;
                $allowedge{"$q,$p"} = 1;
                $j += $jstep;
                if ( $jstep == 1 ) {
                    ( $v, $w ) = @{ $b->{edges}[$j] };
                }
                else {
                    ( $w, $v ) = @{ $b->{edges}[ $j - 1 ] };
                }

                # Step to the next T-sub-blossom.
                $allowedge{"$v,$w"} = 1;
                $allowedge{"$w,$v"} = 1;
                $j += $jstep;
            }

            # Relabel the base T-sub-blossom WITHOUT stepping through to
            # its mate (so don't call assignLabel).
            my $bw = $b->{childs}[$j];
            $label{$w}     = $label{$bw}     = 2;
            $labeledge{$w} = $labeledge{$bw} = [ $v, $w ];
            $bestedge{$bw} = undef;

            # Continue along the blossom until we get back to entrychild.
            $j += $jstep;
            while ( $b->{childs}[$j] ne $entrychild ) {

                # Examine the vertices of the sub-blossom to see whether
                # it is reachable from a neighboring S-vertex outside the
                # expanding blossom.
                my $bv = $b->{childs}[$j];
                if ( defined( $label{$bv} ) && $label{$bv} == 1 ) {

                    # This sub-blossom just got label S through one of
                    # its neighbors; leave it be.
                    $j += $jstep;
                    next;
                }
                my $reachable;
                if ( _is_blossom($bv) ) {
                    foreach my $leaf ( $bv->leaves() ) {
                        if ( $label{$leaf} ) {
                            $reachable = $leaf;
                            last;
                        }
                    }
                }
                else {
                    $reachable = $bv;
                }

                # If the sub-blossom contains a reachable vertex, assign
                # label T to the sub-blossom.
                if ( defined($reachable) && $label{$reachable} ) {
                    $label{$reachable} = undef;
                    $label{ $mate{ $blossombase{$bv} } } = undef;
                    $assignLabel->( $reachable, 2, $labeledge{$reachable}[0] );
                }
                $j += $jstep;
            }
        }

        # Remove the expanded blossom entirely.
        delete $label{$b};
        delete $labeledge{$b};
        delete $bestedge{$b};
        delete $blossomparent{$b};
        delete $blossombase{$b};
        delete $blossomdual{$b};
        delete $blossom_alive{$b};
    };

    # Swap matched/unmatched edges over an alternating path through
    # blossom b between vertex v and the base vertex. Keep blossom
    # bookkeeping consistent.
    my $augmentBlossom;
    $augmentBlossom = sub {
        my ( $b, $v ) = @_;

        # Bubble up through the blossom tree from vertex v to an
        # immediate sub-blossom of b.
        my $t = $v;
        while ( ( $blossomparent{$t} // '' ) ne $b ) {
            $t = $blossomparent{$t};
        }

        # Recursively deal with the first sub-blossom.
        $augmentBlossom->( $t, $v ) if _is_blossom($t);

        # Decide in which direction we will go round the blossom.
        my $i = _index_of( $b->{childs}, $t );
        my $j = $i;
        my $jstep;
        if ( $i & 1 ) {
            $j -= scalar( @{ $b->{childs} } );
            $jstep = 1;
        }
        else {
            $jstep = -1;
        }

        # Move along the blossom until we get to the base.
        while ( $j != 0 ) {

            # Step to the next sub-blossom and augment it recursively.
            $j += $jstep;
            $t = $b->{childs}[$j];
            my ( $w, $x );
            if ( $jstep == 1 ) {
                ( $w, $x ) = @{ $b->{edges}[$j] };
            }
            else {
                ( $x, $w ) = @{ $b->{edges}[ $j - 1 ] };
            }
            $augmentBlossom->( $t, $w ) if _is_blossom($t);

            # Step to the next sub-blossom and augment it recursively.
            $j += $jstep;
            $t = $b->{childs}[$j];
            $augmentBlossom->( $t, $x ) if _is_blossom($t);

            # Match the edge connecting those sub-blossoms.
            $mate{$w} = $x;
            $mate{$x} = $w;
        }

        # Rotate the list of sub-blossoms to put the new base at the front.
        my @childs = @{ $b->{childs} };
        my @edges  = @{ $b->{edges} };
        $b->{childs} = [ @childs[ $i .. $#childs ], @childs[ 0 .. $i - 1 ] ];
        $b->{edges}  = [ @edges[ $i .. $#edges ],   @edges[ 0 .. $i - 1 ] ];
        $blossombase{$b} = $blossombase{ $b->{childs}[0] };
    };

    # Swap matched/unmatched edges over an alternating path between two
    # single vertices. The augmenting path runs through S-vertices v and w.
    my $augmentMatching = sub {
        my ( $v, $w ) = @_;
        foreach my $pair ( [ $v, $w ], [ $w, $v ] ) {
            my ( $s, $j ) = @{$pair};

            # Match vertex s to vertex j. Then trace back from s until we
            # find a single vertex, swapping matched and unmatched edges
            # as we go.
            while (1) {
                my $bs = $inblossom{$s};

                # Augment through the S-blossom from s to base.
                $augmentBlossom->( $bs, $s ) if _is_blossom($bs);

                # Update mate{s}.
                $mate{$s} = $j;

                # Trace one step back.
                if ( !defined $labeledge{$bs} ) {

                    # Reached single vertex; stop.
                    last;
                }
                my $t  = $labeledge{$bs}[0];
                my $bt = $inblossom{$t};

                # Trace one more step back.
                ( $s, $j ) = @{ $labeledge{$bt} };

                # Augment through the T-blossom from j to base.
                $augmentBlossom->( $bt, $j ) if _is_blossom($bt);

                # Update mate{j}.
                $mate{$j} = $s;
            }
        }
    };

    # Verify that the optimum solution has been reached.
    my $verifyOptimum = sub {
        my $vdualoffset = 0;
        if ($maxcardinality) {

            # Vertices may have negative dual; find a constant
            # non-negative number to add to all vertex duals.
            my $mindual = _min_values( values %dualvar );
            $vdualoffset = ( -$mindual > 0 ) ? -$mindual : 0;
        }

        # 0. all dual variables are non-negative
        die "max_weight_matching: negative vertex dual variable"
          if ( _min_values( values %dualvar ) + $vdualoffset < 0 );
        if (%blossomdual) {
            die "max_weight_matching: negative blossom dual variable"
              if ( _min_values( values %blossomdual ) < 0 );
        }

        # 0. all edges have non-negative slack and
        # 1. all matched edges have zero slack;
        foreach my $e ( @{$edges} ) {
            my ( $i, $j, $wt ) = @{$e};
            next if $i eq $j;    # ignore self-loops
            my $s = $dualvar{$i} + $dualvar{$j} - 2 * $wt;
            my @iblossoms = ($i);
            my @jblossoms = ($j);
            while ( defined( $blossomparent{ $iblossoms[-1] } ) ) {
                push @iblossoms, $blossomparent{ $iblossoms[-1] };
            }
            while ( defined( $blossomparent{ $jblossoms[-1] } ) ) {
                push @jblossoms, $blossomparent{ $jblossoms[-1] };
            }
            @iblossoms = reverse @iblossoms;
            @jblossoms = reverse @jblossoms;
            my $lim =
              ( $#iblossoms < $#jblossoms ) ? $#iblossoms : $#jblossoms;
            for my $idx ( 0 .. $lim ) {
                my $bi = $iblossoms[$idx];
                my $bj = $jblossoms[$idx];
                last if $bi ne $bj;
                $s += 2 * $blossomdual{$bi};
            }
            die "max_weight_matching: negative slack on edge $i-$j"
              if $s < 0;
            if (   ( exists( $mate{$i} ) && $mate{$i} eq $j )
                || ( exists( $mate{$j} ) && $mate{$j} eq $i ) )
            {
                die "max_weight_matching: matched edge $i-$j has non-zero slack"
                  if $s != 0;
            }
        }

        # 2. all single vertices have zero dual value;
        foreach my $v (@gnodes) {
            die "max_weight_matching: unmatched vertex $v has non-zero dual"
              unless ( exists( $mate{$v} ) || $dualvar{$v} + $vdualoffset == 0 );
        }

        # 3. all blossoms with positive dual value are full.
        foreach my $bkey (@blossom_order) {
            next unless $blossom_alive{$bkey};
            if ( $blossomdual{$bkey} > 0 ) {
                die "max_weight_matching: full blossom has even number of edges"
                  if ( scalar( @{ $bkey->{edges} } ) % 2 == 0 );
                for ( my $idx = 1 ; $idx < scalar( @{ $bkey->{edges} } ) ; $idx += 2 )
                {
                    my ( $i, $j ) = @{ $bkey->{edges}[$idx] };
                    die "max_weight_matching: blossom edge not matched"
                      unless ( $mate{$i} eq $j && $mate{$j} eq $i );
                }
            }
        }
    };

    # Main loop: continue until no further improvement is possible.
    while (1) {

        # Each iteration of this loop is a "stage".
        # A stage finds an augmenting path and uses that to improve the
        # matching.

        # Remove labels from top-level blossoms/vertices.
        %label     = ();
        %labeledge = ();

        # Forget all about least-slack edges.
        %bestedge = ();
        foreach my $bkey (@blossom_order) {
            next unless $blossom_alive{$bkey};
            $bkey->{mybestedges} = undef;
        }

        # Loss of labeling means that we can not be sure that currently
        # allowable edges remain allowable throughout this stage.
        %allowedge = ();

        # Make queue empty.
        @queue = ();

        # Label single blossoms/vertices with S and put them in the queue.
        foreach my $v (@gnodes) {
            if ( !exists( $mate{$v} ) && !defined( $label{ $inblossom{$v} } ) ) {
                $assignLabel->( $v, 1, undef );
            }
        }

        # Loop until we succeed in augmenting the matching.
        my $augmented = 0;
        while (1) {

            # Each iteration of this loop is a "substage".
            # A substage tries to find an augmenting path; if found, the
            # path is used to improve the matching and the stage ends.
            # If there is no augmenting path, the primal-dual method is
            # used to pump some slack out of the dual variables.

            # Continue labeling until all vertices which are reachable
            # through an alternating path have got a label.
            while ( @queue && !$augmented ) {

                # Take an S vertex from the queue.
                my $v = pop @queue;

                # Scan its neighbors:
                foreach my $w ( @{ $adj{$v} } ) {
                    next if $w eq $v;    # ignore self-loops

                    my $bv = $inblossom{$v};
                    my $bw = $inblossom{$w};
                    if ( $bv eq $bw ) {

                        # this edge is internal to a blossom; ignore it
                        next;
                    }
                    my $kslack;
                    if ( !$allowedge{"$v,$w"} ) {
                        $kslack = $slack->( $v, $w );
                        if ( $kslack <= 0 ) {

                            # edge k has zero slack => it is allowable
                            $allowedge{"$v,$w"} = 1;
                            $allowedge{"$w,$v"} = 1;
                        }
                    }
                    if ( $allowedge{"$v,$w"} ) {
                        if ( !defined( $label{$bw} ) ) {

                            # (C1) w is a free vertex;
                            # label w with T and label its mate with S (R12).
                            $assignLabel->( $w, 2, $v );
                        }
                        elsif ( $label{$bw} == 1 ) {

                            # (C2) w is an S-vertex (not in the same
                            # blossom); follow back-links to discover
                            # either an augmenting path or a new blossom.
                            my $base = $scanBlossom->( $v, $w );
                            if ( !_is_no_node($base) ) {

                                # Found a new blossom; add it to the
                                # blossom bookkeeping and turn it into an
                                # S-blossom.
                                $addBlossom->( $base, $v, $w );
                            }
                            else {
                                # Found an augmenting path; augment the
                                # matching and end this stage.
                                $augmentMatching->( $v, $w );
                                $augmented = 1;
                                last;
                            }
                        }
                        elsif ( !defined( $label{$w} ) ) {

                            # w is inside a T-blossom, but w itself has
                            # not yet been reached from outside the
                            # blossom; mark it as reached (we need this
                            # to relabel during T-blossom expansion).
                            $label{$w}     = 2;
                            $labeledge{$w} = [ $v, $w ];
                        }
                    }
                    elsif ( defined( $label{$bw} ) && $label{$bw} == 1 ) {

                        # keep track of the least-slack non-allowable
                        # edge to a different S-blossom.
                        if ( !defined( $bestedge{$bv} )
                            || $kslack < $slack->( @{ $bestedge{$bv} } ) )
                        {
                            $bestedge{$bv} = [ $v, $w ];
                        }
                    }
                    elsif ( !defined( $label{$w} ) ) {

                        # w is a free vertex (or an unreached vertex
                        # inside a T-blossom) but we can not reach it
                        # yet; keep track of the least-slack edge that
                        # reaches w.
                        if ( !defined( $bestedge{$w} )
                            || $kslack < $slack->( @{ $bestedge{$w} } ) )
                        {
                            $bestedge{$w} = [ $v, $w ];
                        }
                    }
                }
            }

            last if $augmented;

            # There is no augmenting path under these constraints;
            # compute delta and reduce slack in the optimization
            # problem. (Note that our vertex dual variables, edge slacks
            # and delta's are pre-multiplied by two.)
            my $deltatype = -1;
            my ( $delta, $deltaedge, $deltablossom );

            # Compute delta1: the minimum value of any vertex dual.
            if ( !$maxcardinality ) {
                $deltatype = 1;
                $delta     = _min_values( values %dualvar );
            }

            # Compute delta2: the minimum slack on any edge between an
            # S-vertex and a free vertex.
            foreach my $v (@gnodes) {
                if ( !defined( $label{ $inblossom{$v} } )
                    && defined( $bestedge{$v} ) )
                {
                    my $d = $slack->( @{ $bestedge{$v} } );
                    if ( $deltatype == -1 || $d < $delta ) {
                        $delta     = $d;
                        $deltatype = 2;
                        $deltaedge = $bestedge{$v};
                    }
                }
            }

            # Compute delta3: half the minimum slack on any edge between
            # a pair of S-blossoms.
            foreach my $bkey ( @gnodes, @blossom_order ) {
                next if ref($bkey) && !$blossom_alive{$bkey};
                next if defined( $blossomparent{$bkey} );
                next unless defined( $label{$bkey} ) && $label{$bkey} == 1;
                next unless defined( $bestedge{$bkey} );
                my $kslack = $slack->( @{ $bestedge{$bkey} } );
                my $d = $allinteger ? $kslack / 2 : $kslack / 2.0;
                if ( $deltatype == -1 || $d < $delta ) {
                    $delta     = $d;
                    $deltatype = 3;
                    $deltaedge = $bestedge{$bkey};
                }
            }

            # Compute delta4: minimum z variable of any T-blossom.
            foreach my $bkey (@blossom_order) {
                next unless $blossom_alive{$bkey};
                next if defined( $blossomparent{$bkey} );
                next unless defined( $label{$bkey} ) && $label{$bkey} == 2;
                if ( $deltatype == -1 || $blossomdual{$bkey} < $delta ) {
                    $delta        = $blossomdual{$bkey};
                    $deltatype    = 4;
                    $deltablossom = $bkey;
                }
            }

            if ( $deltatype == -1 ) {

                # No further improvement possible; max-cardinality
                # optimum reached. Do a final delta update to make the
                # optimum verifiable.
                $deltatype = 1;
                my $mn = _min_values( values %dualvar );
                $delta = ( $mn > 0 ) ? $mn : 0;
            }

            # Update dual variables according to delta.
            foreach my $v (@gnodes) {
                if ( defined( $label{ $inblossom{$v} } )
                    && $label{ $inblossom{$v} } == 1 )
                {
                    # S-vertex: 2*u = 2*u - 2*delta
                    $dualvar{$v} -= $delta;
                }
                elsif ( defined( $label{ $inblossom{$v} } )
                    && $label{ $inblossom{$v} } == 2 )
                {
                    # T-vertex: 2*u = 2*u + 2*delta
                    $dualvar{$v} += $delta;
                }
            }
            foreach my $bkey (@blossom_order) {
                next unless $blossom_alive{$bkey};
                next if defined( $blossomparent{$bkey} );
                if ( defined( $label{$bkey} ) && $label{$bkey} == 1 ) {

                    # top-level S-blossom: z = z + 2*delta
                    $blossomdual{$bkey} += $delta;
                }
                elsif ( defined( $label{$bkey} ) && $label{$bkey} == 2 ) {

                    # top-level T-blossom: z = z - 2*delta
                    $blossomdual{$bkey} -= $delta;
                }
            }

            # Take action at the point where minimum delta occurred.
            if ( $deltatype == 1 ) {

                # No further improvement possible; optimum reached.
                last;
            }
            elsif ( $deltatype == 2 ) {

                # Use the least-slack edge to continue the search.
                my ( $v, $w ) = @{$deltaedge};
                $allowedge{"$v,$w"} = 1;
                $allowedge{"$w,$v"} = 1;
                push @queue, $v;
            }
            elsif ( $deltatype == 3 ) {

                # Use the least-slack edge to continue the search.
                my ( $v, $w ) = @{$deltaedge};
                $allowedge{"$v,$w"} = 1;
                $allowedge{"$w,$v"} = 1;
                push @queue, $v;
            }
            elsif ( $deltatype == 4 ) {

                # Expand the least-z blossom.
                $expandBlossom->( $deltablossom, 0 );
            }

            # End of this substage.
        }

        # Stop when no more augmenting path can be found.
        last if !$augmented;

        # End of a stage; expand all S-blossoms which have zero dual.
        my @snapshot = grep { $blossom_alive{$_} } @blossom_order;
        foreach my $bkey (@snapshot) {
            next unless $blossom_alive{$bkey};    # already expanded
            next if defined( $blossomparent{$bkey} );
            next unless defined( $label{$bkey} ) && $label{$bkey} == 1;
            next unless $blossomdual{$bkey} == 0;
            $expandBlossom->( $bkey, 1 );
        }
    }

    # Verify that we reached the optimum solution (only for integer weights).
    $verifyOptimum->() if $allinteger;

    return %mate;
}

# ---------------------------------------------------------------------------
# JSON encoding/decoding
#
# A small, dependency-free replacement for the CPAN JSON module, covering
# just what the COP API request/response needs: encode_json() and
# decode_json() (matching the JSON module's functional interface), plus
# JSON::true / JSON::false boolean singletons.
# ---------------------------------------------------------------------------

package JSON;

# Singleton objects representing the JSON literals true/false. Any other
# value is encoded as a JSON object/array/string/number/null.
my $TRUE  = bless( \( my $json_true_flag  = 1 ), 'JSON::Boolean' );
my $FALSE = bless( \( my $json_false_flag = 0 ), 'JSON::Boolean' );

sub true  { return $TRUE; }
sub false { return $FALSE; }

package TSH::Command::COP;

=item $json_text = encode_json($data)

Encode a Perl data structure (nested hashrefs, arrayrefs, plain
scalars, undef, and JSON::true/JSON::false) as a JSON string.

=cut

sub encode_json {
    my ($data) = @_;
    return _json_encode_value($data);
}

sub _json_encode_value {
    my ($v) = @_;

    return 'null' if !defined($v);

    my $ref = ref($v);
    if ( $ref eq 'HASH' ) {
        return _json_encode_object($v);
    }
    elsif ( $ref eq 'ARRAY' ) {
        return _json_encode_array($v);
    }
    elsif ( $ref eq 'JSON::Boolean' ) {
        return $$v ? 'true' : 'false';
    }
    elsif ($ref) {

        # Not a type this encoder understands; fall back to stringifying.
        return _json_encode_string("$v");
    }
    elsif ( _looks_like_json_number($v) ) {
        return $v + 0;
    }
    else {
        return _json_encode_string($v);
    }
}

sub _json_encode_object {
    my ($h) = @_;
    return '{'
      . join( ',',
        map { _json_encode_string($_) . ':' . _json_encode_value( $h->{$_} ) }
          sort keys %{$h} )
      . '}';
}

sub _json_encode_array {
    my ($a) = @_;
    return '[' . join( ',', map { _json_encode_value($_) } @{$a} ) . ']';
}

my %JSON_ESCAPE = (
    "\\" => '\\\\',
    "\"" => '\\"',
    "\n" => '\\n',
    "\r" => '\\r',
    "\t" => '\\t',
    "\b" => '\\b',
    "\f" => '\\f',
);

sub _json_encode_string {
    my ($s) = @_;
    $s = '' if !defined($s);
    $s =~ s/([\\"\n\r\t\b\f])/$JSON_ESCAPE{$1}/ge;
    $s =~ s/([\x00-\x1f])/sprintf('\\u%04x', ord($1))/ge;
    return '"' . $s . '"';
}

# A conservative, JSON::PP-style duck-typed check for whether a plain
# scalar should be encoded as a JSON number rather than a JSON string.
sub _looks_like_json_number {
    my ($s) = @_;
    return 0 if !defined($s) || $s eq '';
    return $s =~ /^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$/;
}

=item $data = decode_json($json_text)

Decode a JSON string into Perl data structures: hashrefs for objects,
arrayrefs for arrays, plain scalars for strings/numbers, 1/0 for
true/false, and undef for null. Dies on malformed input.

=cut

sub decode_json {
    my ($text) = @_;
    $text = '' if !defined($text);
    my $pos = 0;
    my $len = length($text);

    my (
        $skip_ws,     $parse_value,  $parse_string,
        $parse_number, $parse_array, $parse_object
    );

    $skip_ws = sub {
        $pos++
          while ( $pos < $len && substr( $text, $pos, 1 ) =~ /[ \t\r\n]/ );
    };

    $parse_string = sub {
        die "decode_json: expected string at position $pos"
          unless substr( $text, $pos, 1 ) eq '"';
        $pos++;
        my $out = '';
        while (1) {
            die "decode_json: unterminated string" if $pos >= $len;
            my $c = substr( $text, $pos, 1 );
            if ( $c eq '"' ) {
                $pos++;
                last;
            }
            elsif ( $c eq '\\' ) {
                $pos++;
                my $esc = substr( $text, $pos, 1 );
                if    ( $esc eq '"' )  { $out .= '"'; }
                elsif ( $esc eq '\\' ) { $out .= '\\'; }
                elsif ( $esc eq '/' )  { $out .= '/'; }
                elsif ( $esc eq 'n' )  { $out .= "\n"; }
                elsif ( $esc eq 't' )  { $out .= "\t"; }
                elsif ( $esc eq 'r' )  { $out .= "\r"; }
                elsif ( $esc eq 'b' )  { $out .= "\b"; }
                elsif ( $esc eq 'f' )  { $out .= "\f"; }
                elsif ( $esc eq 'u' ) {
                    my $hex = substr( $text, $pos + 1, 4 );
                    die "decode_json: bad \\u escape"
                      unless $hex =~ /^[0-9a-fA-F]{4}$/;
                    $out .= chr( hex($hex) );
                    $pos += 4;
                }
                else {
                    die "decode_json: bad escape '\\$esc'";
                }
                $pos++;
            }
            else {
                $out .= $c;
                $pos++;
            }
        }
        return $out;
    };

    $parse_number = sub {
        my $start = $pos;
        $pos++ if substr( $text, $pos, 1 ) eq '-';
        $pos++ while ( $pos < $len && substr( $text, $pos, 1 ) =~ /[0-9]/ );
        if ( $pos < $len && substr( $text, $pos, 1 ) eq '.' ) {
            $pos++;
            $pos++
              while ( $pos < $len && substr( $text, $pos, 1 ) =~ /[0-9]/ );
        }
        if ( $pos < $len && substr( $text, $pos, 1 ) =~ /[eE]/ ) {
            $pos++;
            $pos++
              if ( $pos < $len && substr( $text, $pos, 1 ) =~ /[+-]/ );
            $pos++
              while ( $pos < $len && substr( $text, $pos, 1 ) =~ /[0-9]/ );
        }
        my $numstr = substr( $text, $start, $pos - $start );
        die "decode_json: invalid number at position $start"
          if ( $numstr eq '' || $numstr eq '-' );
        return $numstr + 0;
    };

    $parse_array = sub {
        $pos++;    # skip '['
        my @out;
        $skip_ws->();
        if ( substr( $text, $pos, 1 ) eq ']' ) {
            $pos++;
            return \@out;
        }
        while (1) {
            $skip_ws->();
            push @out, $parse_value->();
            $skip_ws->();
            my $c = substr( $text, $pos, 1 );
            if ( $c eq ',' ) {
                $pos++;
                next;
            }
            elsif ( $c eq ']' ) {
                $pos++;
                last;
            }
            else {
                die "decode_json: expected ',' or ']' at position $pos";
            }
        }
        return \@out;
    };

    $parse_object = sub {
        $pos++;    # skip '{'
        my %out;
        $skip_ws->();
        if ( substr( $text, $pos, 1 ) eq '}' ) {
            $pos++;
            return \%out;
        }
        while (1) {
            $skip_ws->();
            my $key = $parse_string->();
            $skip_ws->();
            die "decode_json: expected ':' at position $pos"
              unless substr( $text, $pos, 1 ) eq ':';
            $pos++;
            $skip_ws->();
            $out{$key} = $parse_value->();
            $skip_ws->();
            my $c = substr( $text, $pos, 1 );
            if ( $c eq ',' ) {
                $pos++;
                next;
            }
            elsif ( $c eq '}' ) {
                $pos++;
                last;
            }
            else {
                die "decode_json: expected ',' or '}' at position $pos";
            }
        }
        return \%out;
    };

    $parse_value = sub {
        $skip_ws->();
        die "decode_json: unexpected end of input" if $pos >= $len;
        my $c = substr( $text, $pos, 1 );
        if ( $c eq '{' ) {
            return $parse_object->();
        }
        elsif ( $c eq '[' ) {
            return $parse_array->();
        }
        elsif ( $c eq '"' ) {
            return $parse_string->();
        }
        elsif ( substr( $text, $pos, 4 ) eq 'true' ) {
            $pos += 4;
            return 1;
        }
        elsif ( substr( $text, $pos, 5 ) eq 'false' ) {
            $pos += 5;
            return 0;
        }
        elsif ( substr( $text, $pos, 4 ) eq 'null' ) {
            $pos += 4;
            return undef;
        }
        elsif ( $c eq '-' || $c =~ /[0-9]/ ) {
            return $parse_number->();
        }
        else {
            die "decode_json: unexpected character '$c' at position $pos";
        }
    };

    my $result = $parse_value->();
    $skip_ws->();
    die "decode_json: trailing garbage after JSON value" if $pos < $len;
    return $result;
}

1;
