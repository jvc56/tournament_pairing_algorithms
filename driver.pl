#!/usr/bin/perl

use strict;
use warnings;

use Getopt::Long;
use LWP::Simple;

require "./simpair.pl";

my $payout;
my $start;
my $final;
my $tfile;
my $url;
my $sim;

GetOptions(
    "payout=s"  => \$payout,
    "start=s"   => \$start,
    "final=s"   => \$final,
    "tfile=s"   => \$tfile,
    "url=s"     => \$url,
    "sim=s"     => \$sim
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
    getstore($url, $filename);
}

my $number_of_sims = 100000;

if ($sim) {
    $number_of_sims = int($sim);
}

my $lowest_ranked_payout = 0;

if ($payout) {
    $lowest_ranked_payout = int($payout);
}

my ($tournament_players, $times_played_hash) = tournament_players_from_tfile($filename, $start);
print("Initial Standings:\n");
print_tournament_players($tournament_players);

my $pairings = pair($tournament_players, $times_played_hash, $start, $final, $lowest_ranked_payout, $number_of_sims);
printf("\n\nPairings for round %d\n\n", ($start + 1));
my %already_printed_pairings = ();
foreach my $player0 (keys %$pairings) {
    my $player1 = $pairings->{$player0};
    if (! exists $already_printed_pairings{$player0} and ! exists $already_printed_pairings{$player1} ) {
        $already_printed_pairings{$player0} = 1;
        $already_printed_pairings{$player1} = 1;
        my $times_played_key = create_times_played_key($tournament_players->[$player0]->{index}, $tournament_players->[$player1]->{index});
        my $times_played = 0;
        if (exists $times_played_hash->{$times_played_key}) {
            $times_played = $times_played_hash->{$times_played_key};
        }
        printf("%s vs. %s (%d)\n", $tournament_players->[$player0]->{name}, $tournament_players->[$player1]->{name}, $times_played);
    }
}
