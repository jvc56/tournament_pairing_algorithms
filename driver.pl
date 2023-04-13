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

sub create_cop_config {
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

    return cop( $config, $tournament_players, $times_played_hash );
}

sub create_cop_config_and_get_pairings {
    my (
        $start_round,             $final_round,
        $number_of_sims,          $always_wins_number_of_sims,
        $lowest_ranked_payout,    $gibson_spreads,
        $control_loss_thresholds, $hopefulness,
        $log_filename,            $filename
    ) = @_;

    # Test cases for cop
    my $config = create_cop_config(
        $start_round,             $final_round,
        $number_of_sims,          $always_wins_number_of_sims,
        $lowest_ranked_payout,    $gibson_spreads,
        $control_loss_thresholds, $hopefulness,
        $log_filename
    );

    my ( $tournament_players, $times_played_hash ) =
      tournament_players_from_tfile( $filename, $start_round );

    return cop( $config, $tournament_players, $times_played_hash );
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
    open( my $fh, '<', $filename ) || die "Can't open file $filename: $!";

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

    my $log_file_prefix = $t_file_directory . '.' . $t_file_basename;
    my $division_name =
      uc( substr( $t_file_basename, 0, length($t_file_basename) - 2 ) );
    my $lowest_ranked_payout = $lowest_ranked_payouts->{$division_name};

    return $final_round, $lowest_ranked_payout,
      LOG_DIRECTORY . '/' . $log_file_prefix . '.' . $start_round . '.log';
}

sub get_config_for_t_file_round {
    my ( $t_file, $start_round ) = @_;

    my ( $final_round, $lowest_ranked_payout, $log_filename ) =
      get_tsh_config_info_and_log_filename( $t_file, $start_round );

    return create_cop_config(
        $start_round, $final_round,
        1_000,        1_000,
        $lowest_ranked_payout, [ 300, 250, 200 ],
        [0.15], [ 0, 0.1, 0.05, 0.01 ],
        $log_filename
    );
}

sub test_t_file_for_start_round {
    my ( $t_file, $start_round ) = @_;

    my $cop_config = get_config_for_t_file_round( $t_file, $start_round );

    printf( "Logging to %s\n", $cop_config->{log_filename} );
    my ( $tournament_players, $times_played_hash ) =
      tournament_players_from_tfile( $t_file, $start_round );
    cop( $cop_config, $tournament_players, $times_played_hash );
}

sub test_t_file_for_all_rounds {
    my ( $t_file, $final_round ) = @_;
    for ( my $i = 0 ; $i < $final_round ; $i++ ) {
        test_t_file_for_start_round( $t_file, $i );
    }
}

sub test_cop {
    my $test_directories = get_all_test_directories();

    for ( my $i = 0 ; $i < scalar @{$test_directories} ; $i++ ) {
        my $test_directory = $test_directories->[$i];

        my ( $lowest_ranked_payouts, $final_round ) = get_tsh_config_info(
            join( '/', $test_directory, TSH_CONFIG_FILENAME ) );

        my $t_files = get_t_files($test_directory);
        for ( my $j = 0 ; $j < scalar @{$t_files} ; $j++ ) {
            test_t_file_for_all_rounds( $t_files->[$j], $final_round );
        }
    }
}

sub main {

    my $payout = -1;
    my $start  = -1;
    my $final;
    my $t_file;
    my $url;
    my $sim     = 100000;
    my $testall = 0;

    GetOptions(
        "start=s" => \$start,
        "tfile=s" => \$t_file,
        "testall" => \$testall
    );

    mkdir LOG_DIRECTORY;

    if ($testall) {
        test_cop();
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
