import argparse
import re
import os
import random
import urllib.request
import networkx as nx

hopefulness = [0, 0, 0.1, 0.05, 0.01, 0.0025]
class TournamentResults:
    def __init__(self, number_of_players):
        self.number_of_players = number_of_players
        self.array = [0] * (number_of_players * number_of_players)
        self.count = 0

    def record(self, tps):
        for i in range(self.number_of_players):
            player = tps[i]
            self.array[(self.number_of_players * player.index) + i] += 1
        self.count += 1
    
    def get(self, player, place):
        return self.array[(self.number_of_players * player.index) + place]

class PlayerScores:
    def __init__(self, name, index, opponent_indexes, scores):
        self.name = name
        self.index = index
        self.opponent_indexes = opponent_indexes
        self.scores = scores

class TournamentPlayer:
    def __init__(self, name, index, wins, spread):
        self.name = name
        self.index = index
        self.start_wins = wins
        self.wins = wins
        self.start_spread = spread
        self.spread = spread

    def reset(self):
        self.wins = self.start_wins
        self.spread = self.start_spread

def pair(tps, times_played_dict, start_round, final_round, lowest_ranked_payout):
    tps.sort(key = lambda c: - (c.wins * 10000 + c.spread))
    factor_pair_results = sim_factor_pair(tps, start_round, final_round, 100000)

    pair_player_with_first_wins = sim_pair_player_with_winner(tps, start_round, final_round, 10000)

    print("player always plays first and wins:", pair_player_with_first_wins)
    print_results(tps, factor_pair_results)
    tps.sort(key = lambda c: - (c.wins * 10000 + c.spread))

    number_of_rounds_remaining = final_round - start_round

    adjusted_hopefulness = 0

    if number_of_rounds_remaining < len(hopefulness):
        adjusted_hopefulness = hopefulness[number_of_rounds_remaining]

    print("adjusted hopefulness for round %d: %0.6f" % (start_round, adjusted_hopefulness))

    number_of_players = len(tps)
    lowest_ranked_placers = [0] * (number_of_players * number_of_players)
    for i in range(number_of_players):
        for rank_index in range(len(tps)):
            player = tps[rank_index]
            if (factor_pair_results.get(player, i) / number_of_sims) > adjusted_hopefulness:
                lowest_ranked_placers[i] = rank_index

    for i in range(number_of_players):
        print("lowest rankest possible winner: %d, %d, %s" % (i+1, lowest_ranked_placers[i], tps[lowest_ranked_placers[i]].name))

    edges = []
    for i in range(number_of_players):
        for j in range(i + 1, number_of_players):
            player_i = tps[i]
            player_j = tps[j]
            times_played_key = create_times_played_key(player_i.index, player_j.index)
            number_of_times_played = 0
            if times_played_key in times_played_dict:
                number_of_times_played = times_played_dict[times_played_key]

            repeat_weight = (number_of_times_played * 2) * ( (number_of_players / 3) ** 3)

            rank_difference_weight = (j - i) ** 3

            pair_with_placer = 0
            if i <= lowest_ranked_payout:
                pair_with_placer = 1000000
                if (j <= lowest_ranked_placers[i]):
                    pair_with_placer = ((lowest_ranked_placers[i] - j) ** 3) * 2

            weight = repeat_weight + rank_difference_weight + pair_with_placer
            print("weight for %s vs %s is %d = %d + %d + %d" % (player_i.name, player_j.name, weight, repeat_weight, rank_difference_weight, pair_with_placer))
            edges.append((i, j, weight))
    G = nx.Graph()
    G.add_weighted_edges_from(edges)
    return sorted(nx.min_weight_matching(G))

def sim_factor_pair(tps, start_round, final_round, n):
    results = TournamentResults(len(tps))
    for i in range(n):
        if (i < 10):
            print("\n\nNEW ITERATION\n\n")
        for current_round in range(start_round,final_round):
            pairings = factor_pair(tps, final_round-current_round)
            if i < 10:
                print("\n\n\nPairings for round %d" % (current_round))
                for j in range(len(pairings)):
                    print("%s vs. %s" % (tps[pairings[j][0]].name, tps[pairings[j][1]].name))
            play_round(pairings, tps, -1)

        results.record(tps)
        for player in tps:
            player.reset()
        tps.sort(key = lambda c: - (c.wins * 10000 + c.spread))

    return results

def sim_pair_player_with_winner(tps, start_round, final_round, n):
    tournament_wins = []
    player_in_first_wins = tps[0].wins
    for player_in_nth in range(1, len(tps)):
        # This player cannot win
        if (player_in_first_wins - tps[player_in_nth].wins) / 2 > (final_round - start_round) + 1:
            print("%s cannot win: %d - %d > (%d - %d) + 1" % (tps[player_in_nth].name, player_in_first_wins, tps[player_in_nth].wins, final_round, start_round))
            break
        twins = 0
        player_in_nth_index = tps[player_in_nth].index
        for i in range(n):
            if (i < 10):
                print("\n\nNEW ITERATION FOR PAIR WITH FIRST\n\n")
            for current_round in range(start_round,final_round):
                pairings = factor_pair_minus_player(tps, final_round-current_round, player_in_nth_index)
                if i < 10:
                    print("\n\n\nPairings for round %d" % (current_round))
                    for j in range(len(pairings)):
                        print("%s vs. %s" % (tps[pairings[j][0]].name, tps[pairings[j][1]].name))
                play_round(pairings, tps, player_in_nth)
                if tps[0].index == player_in_nth_index:
                    twins += 1
                    break
            for player in tps:
                player.reset()
            tps.sort(key = lambda c: - (c.wins * 10000 + c.spread))
        tournament_wins.append(twins / n)

    return tournament_wins

def play_round(pairings, tps, forced_win_player):
    for pairing in pairings:
        if pairing[1] == -1:
            # Player gets a bye
            tps[pairing[0]].spread += 50
            tps[pairing[0]].wins += 2
            continue
        spread = 200 - random.randint(0, 401)
        if forced_win_player >= 0:
            if pairing[0] == forced_win_player:
                spread = abs(spread) + 1
            elif pairing[1] == forced_win_player:
                spread = -abs(spread) - 1
        p1win = 1
        p2win = 1
        if spread > 0:
            p1win = 2
            p2win = 0
        elif spread < 0:
            p1win = 0
            p2win = 2
        tps[pairing[0]].spread += spread
        tps[pairing[0]].wins += p1win
        tps[pairing[1]].spread += -spread
        tps[pairing[1]].wins += p2win
    tps.sort(key = lambda c: - (c.wins * 10000 + c.spread))
    
def create_times_played_key(p1, p2):
    a = p1
    b = p2
    if b < a:
        a = p2
        b = p1
    return "%s:%s" % (a, b)

def factor_pair(tps, nrl):
    # For now, just implement KOTH
    # This assumes players are already sorted
    pairings = []
    for i in range(nrl):
        pairings.append([i, i+nrl])
    for i in range(nrl*2,len(tps),2):
        pairings.append([i, i+1])

    return pairings

def factor_pair_minus_player(tps, nrl, player_index):
    # For now, just implement KOTH
    # This assumes players are already sorted
    player_index_to_rank = {}
    for i in range(len(tps)):
        player_index_to_rank[tps[i].index] = i

    # Pop in descending order to ensure player_rank_index
    # removes the correct player
    player_rank_index = player_index_to_rank[player_index]
    player_in_nth = tps.pop(player_rank_index)
    player_in_first = tps.pop(0)

    if nrl * 2 > len(tps):
        nrl = len(tps) / 2

    pairings = [[0, player_rank_index]]
    for i in range(nrl):
        i_player = player_index_to_rank[tps[i].index]
        nrl_player = player_index_to_rank[tps[i+nrl].index]
        pairings.append([i_player, nrl_player])
    for i in range(nrl*2,len(tps),2):
        i_player = player_index_to_rank[tps[i].index]
        i_plus_one_player = player_index_to_rank[tps[i+1].index]
        pairings.append([i_player, i_plus_one_player])

    tps.insert(0, player_in_first)
    tps.insert(player_rank_index, player_in_nth)

    return pairings

def tournament_players_from_players_scores(players_scores):
    tournament_players = []
    times_played_dict = {}
    for player_index in range(len(players_scores)):
        pscores = players_scores[player_index]
        wins = 0
        spread = 0
        for round in range(len(pscores.scores)):
            opponent_index = pscores.opponent_indexes[round]
            times_played_key = create_times_played_key(player_index, opponent_index)
            if times_played_key in times_played_dict:
                times_played_dict[times_played_key] += 1
            else:
                times_played_dict[times_played_key] = 1
            game_spread = pscores.scores[round] - players_scores[opponent_index].scores[round]
            if game_spread > 0:
                wins += 2
            elif game_spread == 0:
                wins += 1
            spread += game_spread
        tournament_players.append(TournamentPlayer(pscores.name, pscores.index, wins, spread))
    for times_played_key in times_played_dict:
        times_played_dict[times_played_key] = times_played_dict[times_played_key] / 2
    tournament_players.sort(key = lambda c: - (c.wins * 10000 + c.spread))
    return tournament_players, times_played_dict

def players_scores_from_tfile(tfile, start_round):
    if not os.path.isfile(tfile):
        print("tfile does not exist: {}".format(tfile))
        exit(-1)
    players_scores = []
    index = 0
    with open(tfile) as my_file:
        for line in my_file:
            match = re.search("^([^,]+),(\D+)\d+([^;]+);([^;]+)", line)
            if match.group(1) is None or match.group(2) is None or match.group(3) is None or match.group(4) is None:
                print("match not found for {}".format(line))
                exit(-1)

            last_name = match.group(1).strip()
            first_name = match.group(2).strip()
            opponent_indexes_string = match.group(3).strip()
            scores_string = match.group(4).strip()
            scores = [int(x) for x in scores_string.split()]
            opponent_indexes = [int(x) - 1 for x in opponent_indexes_string.split()]

            del scores[start_round:]
            del opponent_indexes[start_round:]

            if len(scores) != len(opponent_indexes):
                print("scores and opponents are not the same size for {}".format(line))
                exit(-1)

            name = first_name + " " + last_name
            player_scores = PlayerScores(name, index, opponent_indexes, scores)
            players_scores.append(player_scores)
            index += 1
    return players_scores

def tournament_players_from_tfile(filename, start_round):
    players_scores = players_scores_from_tfile(filename, start_round)
    return tournament_players_from_players_scores(players_scores)

def print_tournament_players(tps):
    for i in range(len(tps)):
        tp = tps[i]
        print("%-3s %-30s %0.1f %d" % (str(i+1), tp.name, (tp.wins/2), tp.spread))

def print_results(tps, results):
    tps.sort(key = lambda c: c.index)
    print("%30s" % (""), end='')
    for i in range(results.number_of_players):
        print("%-7s" % (i+1), end='')
    print()
    for i in range(len(tps)):
        player = tps[i]
        print("%-30s" % (player.name), end='')
        for j in range(results.number_of_players):
            print("%-7s" % (str(results.get(player, j))), end='')
        print()

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("command", type=str, help="command to execute, either sim or pair")
    parser.add_argument("--payout", type=str, help="lowest ranked payout")
    parser.add_argument("--start", type=str, help="the round at which simulations start")
    parser.add_argument("--final", type=str, help="the final round of the simulation")
    parser.add_argument("--tfile", type=str, help=".t file")
    parser.add_argument("--url", type=str, help="URL for .t file")
    parser.add_argument("--sim", type=str, help="number of sims")
    args = parser.parse_args()

    if args.command != "sim" and args.command != "pair":
        print("command must be one of: sim, pair")
        exit(-1)
    if not args.final:
        print("required: final")
        exit(-1)
    if (not args.tfile and not args.url) or (args.tfile and args.url):
        print("required: exactly one of: tfile, url")
        exit(-1)

    filename = "a.t"

    if args.tfile:
        print("Reading from %s" % args.tfile)
        filename = args.tfile

    if args.url:
        print("Downloading %s to %s" % (args.url, filename))
        urllib.request.urlretrieve(args.url, filename)

    number_of_sims = 100000

    if args.sim:
        number_of_sims = int(args.sim)

    lowest_ranked_payout = 0

    if args.payout:
        lowest_ranked_payout = int(args.payout)
    
    tournament_players, times_played_dict = tournament_players_from_tfile(filename, int(args.start))
    print("Initial Standings:")
    print_tournament_players(tournament_players)
    if args.command == "sim":
        results = sim(tournament_players, int(args.start), int(args.final), number_of_sims)
        print_results(tournament_players, results)
    else:
        pairings = pair(tournament_players, times_played_dict, int(args.start), int(args.final), lowest_ranked_payout)
        print("\n\nPairings for round %d" % (int(args.start) + 1))
        for pairing in pairings:
            times_played_key = create_times_played_key(tournament_players[pairing[0]].index, tournament_players[pairing[1]].index)
            times_played = 0
            if times_played_key in times_played_dict:
                times_played = times_played_dict[times_played_key]
            print("%s vs. %s (%d)" % (tournament_players[pairing[0]].name, tournament_players[pairing[1]].name, times_played))
