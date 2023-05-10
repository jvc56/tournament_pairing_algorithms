#!/usr/bin/perl

package TSH::Command::COP;

use strict;
use warnings;

use Getopt::Long;
use LWP::Simple;

require "./COP.pm";

# Parsing the t file

use constant LOG_DIRECTORY       => 'logs';
use constant TEST_DATA_DIRECTORY => 'test_data';
use constant TSH_CONFIG_FILENAME => 'config.tsh';

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
        my ( $name, $opponent_indexes_string, $scores_string ) =
          ( $line =~ /^(\D+)\d+([^;]+);([^;]+)/ );
        unless ( $name
            && $opponent_indexes_string
            && $scores_string )
        {
            return
"match not found (>$name< >$opponent_indexes_string< >$scores_string<) for\n>$line<\n";
        }

        my $full_name = $name;
        if ( index( $name, "," ) != -1 ) {
            my @first_name_and_last_name = split( ',', $name );
            if ( scalar @first_name_and_last_name != 2 ) {
                return "invalid name part for $line\n";
            }
            my $first_name = $first_name_and_last_name[1];
            my $last_name  = $first_name_and_last_name[0];
            $first_name =~ s/^\s+|\s+$//g;
            $last_name  =~ s/^\s+|\s+$//g;
            $full_name = $first_name . " " . $last_name;
        }

        $full_name               =~ s/^\s+|\s+$//g;
        $opponent_indexes_string =~ s/^\s+|\s+$//g;
        $scores_string           =~ s/^\s+|\s+$//g;

        my @scores = split( ' ', $scores_string );
        my @opponent_indexes =
          map { $_ - 1 } split( ' ', $opponent_indexes_string );

        if ( scalar @scores != scalar @opponent_indexes ) {
            return "scores and opponents are not the same size for $line\n";
        }

        if ( $start_round >= scalar @scores ) {
            return
              sprintf(
                "start round %d is greater than number of current rounds %d\n",
                $start_round, scalar @scores );
        }

        splice( @scores,           $start_round );
        splice( @opponent_indexes, $start_round );

        push @players_scores,
          new_player_scores( $full_name, $index, \@opponent_indexes, \@scores );
        $index++;
    }
    close($fh);
    return \@players_scores;
}

sub tournament_players_from_players_scores {
    my ($players_scores) = @_;
    my @tournament_players;
    my %times_played_hash;
    my %previous_pairing_hash       = ();
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

            my $is_bye = 0;
            if ( $opponent_index < 0 ) {
                $opponent_index = $number_of_players;
                $is_bye         = 1;
            }

            my $times_played_key =
              create_times_played_key( $player_index, $opponent_index );

            if ( exists $times_played_hash{$times_played_key} ) {
                $times_played_hash{$times_played_key} += 1;
            }
            else {
                $times_played_hash{$times_played_key} = 1;
            }

            if ( $round == $player_number_of_scores - 1 ) {
                $previous_pairing_hash{$times_played_key} = 1;
            }

            my $opponent_score = 0;

            if ($is_bye) {

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

    return ( \@tournament_players, \%times_played_hash,
        \%previous_pairing_hash );
}

sub tournament_players_from_tfile {
    my ( $filename, $start_round ) = @_;
    my $players_scores = players_scores_from_tfile( $filename, $start_round );
    if ( ref($players_scores) ne 'ARRAY' ) {
        return $players_scores;
    }
    my ( $tournament_players, $times_played_hash, $previous_pairing_hash ) =
      tournament_players_from_players_scores($players_scores);
    return ( $tournament_players, $times_played_hash, $previous_pairing_hash );
}

sub create_cop_config {
    my (
        $start_round,             $final_round,
        $number_of_sims,          $always_wins_number_of_sims,
        $lowest_ranked_payout,    $gibson_spread,
        $control_loss_thresholds, $control_loss_activation_round,
        $hopefulness,             $log_filename
    ) = @_;

    return {
        log_filename               => $log_filename,
        number_of_threads          => 6,
        number_of_sims             => $number_of_sims,
        number_of_rounds           => $final_round,
        last_paired_round          => $start_round,
        always_wins_number_of_sims => $always_wins_number_of_sims,
        number_of_rounds_remaining => $final_round - $start_round,
        lowest_ranked_payout       => $lowest_ranked_payout - 1,
        cumulative_gibson_spreads =>
          get_cumulative_gibson_spreads( $gibson_spread, $final_round - 1 ),
        gibson_spreads =>
          extend_tsh_config_array( $gibson_spread, $final_round - 1 ),
        control_loss_thresholds =>
          extend_tsh_config_array( $control_loss_thresholds, $final_round - 1 ),
        control_loss_activation_round => $control_loss_activation_round,
        hopefulness =>
          extend_tsh_config_array( $hopefulness, $final_round - 1 ),
    };
}

sub get_pairings {
    my ( $filename, $config, $start_round ) = @_;

    my ( $tournament_players, $times_played_hash, $previous_pairing_hash ) =
      tournament_players_from_tfile( $filename, $start_round );

    if ( !defined $times_played_hash ) {
        return $tournament_players;
    }

    return cop(
        $config,            $tournament_players,
        $times_played_hash, $previous_pairing_hash
    );
}

sub create_cop_config_and_get_pairings {
    my (
        $start_round,             $final_round,
        $number_of_sims,          $always_wins_number_of_sims,
        $lowest_ranked_payout,    $gibson_spreads,
        $control_loss_thresholds, $control_loss_activation_round,
        $hopefulness,             $log_filename,
        $filename
    ) = @_;

    # Test cases for cop
    my $config = create_cop_config(
        $start_round,             $final_round,
        $number_of_sims,          $always_wins_number_of_sims,
        $lowest_ranked_payout,    $gibson_spreads,
        $control_loss_thresholds, $control_loss_activation_round,
        $hopefulness,             $log_filename
    );

    my ( $tournament_players, $times_played_hash, $previous_pairing_hash ) =
      tournament_players_from_tfile( $filename, $start_round );

    if ( !defined $times_played_hash ) {
        return $tournament_players;
    }

    return cop(
        $config,            $tournament_players,
        $times_played_hash, $previous_pairing_hash
    );
}

sub get_all_test_directories {
    my $dir = TEST_DATA_DIRECTORY;
    opendir( my $dh, $dir ) || die "Can't open directory $dir: $!";
    my @files = readdir($dh);
    closedir($dh);

    my @file_paths;
    foreach my $file (@files) {
        next if $file =~ /^\./;    # Skip hidden files
        my $file_path = "$dir/$file";
        push @file_paths, $file_path;
    }

    return \@file_paths;
}

sub get_t_files {
    my ($dir_name) = @_;
    opendir( my $dh, $dir_name ) || die "Can't open directory $dir_name: $!";
    my @files = readdir($dh);
    closedir($dh);

    my @t_files;
    foreach my $file (@files) {
        next if $file =~ /^\./;    # Skip hidden files
        my $file_path = "$dir_name/$file";
        if ( -f $file_path && $file =~ /\.t$/ ) {
            push @t_files, $file_path;
        }
    }

    return \@t_files;
}

sub get_tsh_config_info {
    my ($filename) = @_;
    open( my $fh, '<', $filename ) || return "Can't open file $filename: $!";

    my $final_round;
    my %lowest_ranked_payouts = ();
    while ( my $line = <$fh> ) {
        chomp $line;
        if ( $line =~ /^config\s+max_rounds\s+=\s+(\d+)/ ) {
            $final_round = $1;
        }
        elsif ( !( $line =~ /class/ )
            && $line =~ /^prize\s+rank\s+(\d+)\s+(\w+)/ )
        {
            my $rank                   = $1;
            my $division               = uc($2);
            my $number_of_times_played = 0;
            if ( !exists $lowest_ranked_payouts{$division}
                || ( $lowest_ranked_payouts{$division} < $rank ) )
            {
                $lowest_ranked_payouts{$division} = $rank;
            }
        }
    }

    close $fh;

    return \%lowest_ranked_payouts, $final_round;
}

sub get_filename_directory_and_rest_of_path {
    my ($filepath) = @_;

    my @split_filepath = split( '/', $filepath );
    my $filename       = $split_filepath[-1];
    my $directory      = $split_filepath[-2];
    pop @split_filepath;
    pop @split_filepath;
    my $rest_of_path = join( '/', @split_filepath );
    return $filename, $directory, $rest_of_path;
}

sub get_tsh_config_info_and_log_filename {
    my ( $t_file, $start_round ) = @_;

    my ( $t_file_basename, $t_file_directory, $rest_of_path ) =
      get_filename_directory_and_rest_of_path($t_file);

    my ( $lowest_ranked_payouts, $final_round ) = get_tsh_config_info(
        join( '/', $rest_of_path, $t_file_directory, TSH_CONFIG_FILENAME ) );

    if ( !defined $final_round ) {
        return $lowest_ranked_payouts;
    }

    my $log_file_prefix = $t_file_directory . '.' . $t_file_basename;
    my $division_name =
      uc( substr( $t_file_basename, 0, length($t_file_basename) - 2 ) );
    my $lowest_ranked_payout = $lowest_ranked_payouts->{$division_name};

    if ( !defined $lowest_ranked_payout ) {
        return
          sprintf(
"could not find lowest ranked payout for division %s in %s but found %s\n",
            $division_name, $t_file, Dumper($lowest_ranked_payouts) );
    }

    return $final_round, $lowest_ranked_payout,
      LOG_DIRECTORY . '/' . $log_file_prefix . '.' . $start_round . '.log';
}

sub get_config_for_t_file_round {
    my ( $t_file, $start_round ) = @_;

    my ( $final_round, $lowest_ranked_payout, $log_filename ) =
      get_tsh_config_info_and_log_filename( $t_file, $start_round );

    if ( !defined $log_filename ) {
        return $final_round;
    }

    return create_cop_config(
        $start_round, $final_round,
        1000,         1000,
        $lowest_ranked_payout, [ 300, 250, 200 ],
        [0.25], $final_round - 4,
        [ 0, 0.1, 0.05, 0.01 ], $log_filename
    );
}

sub test_t_file_for_start_round {
    my ( $t_file, $start_round ) = @_;

    my $cop_config = get_config_for_t_file_round( $t_file, $start_round );

    if ( ref($cop_config) ne 'HASH' ) {
        print($cop_config);
        return;
    }

    printf( "Logging to %s\n", $cop_config->{log_filename} );
    my ( $tournament_players, $times_played_hash, $previous_pairing_hash ) =
      tournament_players_from_tfile( $t_file, $start_round );
    if ( !defined $times_played_hash ) {
        print($tournament_players);
    }
    else {
        cop(
            $cop_config,        $tournament_players,
            $times_played_hash, $previous_pairing_hash
        );
    }
}

sub test_t_file_for_autoplay_round {
    my ( $t_file, $start_round, $tournament_players, $times_played_hash,
        $previous_pairing_hash )
      = @_;

    my $cop_config = get_config_for_t_file_round( $t_file, $start_round );
    if ( ref($cop_config) ne 'HASH' ) {
        print($cop_config);
        return;
    }
    $cop_config->{log_filename} .= '.autoplay';
    printf( "Logging to %s\n", $cop_config->{log_filename} );

    return cop(
        $cop_config,        $tournament_players,
        $times_played_hash, $previous_pairing_hash
    ), $cop_config;
}

sub test_t_file_play_round {
    my ( $pairings, $tournament_players, $times_played_hash,
        $previous_pairing_hash, $max_spread )
      = @_;

    # modify tournament players and times_played_hash
    # convert to index pairs

    # We must add a bye player for the play_round subroutine to work
    my $number_of_players = scalar @{$tournament_players};
    if ( $number_of_players % 2 == 1 ) {
        add_bye_player( $tournament_players, $number_of_players );
        $number_of_players = scalar {@$tournament_players};
    }

    sort_tournament_players_by_record($tournament_players);
    my %index_to_rank = ();
    for ( my $i = 0 ; $i < scalar @{$tournament_players} ; $i++ ) {
        $index_to_rank{ $tournament_players->[$i]->{index} } = $i;
    }
    sort_tournament_players_by_index($tournament_players);

    # Reset the previous pairing hash
    foreach my $key ( keys %{$previous_pairing_hash} ) {
        delete $previous_pairing_hash->{$key};
    }

    my @index_pairs = ();
    for ( my $i = 0 ; $i < scalar @{$pairings} ; $i++ ) {
        my $j = $pairings->[$i];
        if ( $i < $j || $j == -1 ) {
            my $player_i_index = $i;
            my $player_j_index = $number_of_players - 1;
            if ( $j != -1 ) {
                $player_j_index = $j;
            }

            # Update the times played hash here
            my $times_played_key =
              create_times_played_key( $player_i_index, $player_j_index );

            if ( exists $times_played_hash->{$times_played_key} ) {
                $times_played_hash->{$times_played_key}++;
            }
            else {
                $times_played_hash->{$times_played_key} = 1;
            }

            $previous_pairing_hash->{$times_played_key} = 1;

            push @index_pairs, [ $player_i_index, $player_j_index ];
        }
    }
    play_round( \@index_pairs, $tournament_players, -1, $max_spread );
}

sub test_t_file_autoplay {
    my ( $t_file, $start_round ) = @_;

    my ( $tournament_players, $times_played_hash, $previous_pairing_hash ) =
      tournament_players_from_tfile( $t_file, $start_round );

    if ( !defined $times_played_hash ) {
        print($tournament_players);
        return;
    }

    my ( $final_round, undef, undef ) =
      get_tsh_config_info_and_log_filename( $t_file, $start_round );

    my $repeats_started = 0;
    for ( my $round = $start_round ; $round < $final_round ; $round++ ) {
        my ( $pairings, $cop_config ) =
          test_t_file_for_autoplay_round( $t_file, $round, $tournament_players,
            $times_played_hash, $previous_pairing_hash );
        if ( !defined $cop_config ) {
            print($pairings);
            return;
        }
        my $max_spread = $cop_config->{gibson_spreads}->[$round];
        test_t_file_play_round( $pairings, $tournament_players,
            $times_played_hash, $previous_pairing_hash, $max_spread );

        if ( !$repeats_started ) {
            foreach my $key ( keys %{$times_played_hash} ) {
                if ( $times_played_hash->{$key} > 1 ) {
                    printf( "Repeats started in %s at round %d\n",
                        $t_file, $round + 1 );
                    $repeats_started = 1;
                    last;
                }
            }
        }
    }
}

sub test_t_file_for_all_rounds {
    my ( $t_file, $final_round ) = @_;
    for ( my $round = 0 ; $round < $final_round ; $round++ ) {
        test_t_file_for_start_round( $t_file, $round );
    }
}

sub test_cop {
    my $test_directories = get_all_test_directories();

    for ( my $i = 0 ; $i < scalar @{$test_directories} ; $i++ ) {
        my $test_directory = $test_directories->[$i];

        my ( $lowest_ranked_payouts, $final_round ) = get_tsh_config_info(
            join( '/', $test_directory, TSH_CONFIG_FILENAME ) );

        if ( !defined $final_round ) {
            return $lowest_ranked_payouts;
        }

        my $t_files = get_t_files($test_directory);
        for ( my $j = 0 ; $j < scalar @{$t_files} ; $j++ ) {
            test_t_file_for_all_rounds( $t_files->[$j], $final_round );
            test_t_file_autoplay( $t_files->[$j], 0 );
        }
    }
}

sub main {

    my $payout = -1;
    my $start  = -1;
    my $auto;
    my $final;
    my $t_file;
    my $url;
    my $sim     = 100000;
    my $testall = 0;

    GetOptions(
        "start=s" => \$start,
        "final=s" => \$final,
        "tfile=s" => \$t_file,
        "testall" => \$testall,
        "auto"    => \$auto
    );

    mkdir LOG_DIRECTORY;

    if ($testall) {
        test_cop();
    }
    elsif ( $auto && $start >= 0 && $t_file ) {
        test_t_file_autoplay( $t_file, $start );
    }
    elsif ( $start >= 0 && $t_file ) {
        test_t_file_for_start_round( $t_file, $start );
    }
    else {
        print(
"use --start and --tfile to test a single file or --testall to test everything\n"
        );
        exit(1);
    }
}

main();
