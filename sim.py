import argparse
import re
import os
import random
import urllib.request
import networkx as nx
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

def pair(tps, remaining_rounds):
    G = nx.Graph()
    edges = []
    number_of_players = len(tps)
    for i in range(number_of_players):
        for j in range(i + 1, number_of_players):
            #player_i = tps[i]
            #player_j = tps[j]
            weight = i + j + remaining_rounds
            edges.append((i, j, weight))
    G.add_weighted_edges_from(edges)
    return sorted(nx.max_weight_matching(G))

def sim(tps, start_round, final_round, n):
    results = TournamentResults(len(tps))
    for _ in range(n):
        for current_round in range(start_round,final_round):
            pairings = pair_round_for_sim(tps, final_round-current_round)
            play_round(pairings, tps)
        results.record(tps)
        for player in tps:
            player.reset()

    tps.sort(key = lambda c: - (c.wins * 10000 + c.spread))
    print_results(tps, results)

def play_round(pairings, tps):
    for pairing in pairings:
        if pairing[1] == -1:
            # Player gets a bye
            tps[pairing[0]].spread += 50
            tps[pairing[0]].wins += 2
        spread = 100 - random.randint(0, 200)
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
    

def pair_round_for_sim(tps, nrl):
    # For now, just implement KOTH
    # This assumes players are already sorted
    pairings = []
    for i in range(nrl):
        pairings.append([i, i+nrl])
    for i in range(nrl*2,len(tps),2):
        pairings.append([i, i+1])

    return pairings

def tournament_players_from_players_scores(players_scores):
    tournament_players = []
    for pscores in players_scores:
        wins = 0
        spread = 0
        for round in range(len(pscores.scores)):
            game_spread = pscores.scores[round] - players_scores[pscores.opponent_indexes[round]].scores[round]
            if game_spread > 0:
                wins += 2
            elif game_spread == 0:
                wins += 1
            spread += game_spread
        tournament_players.append(TournamentPlayer(pscores.name, pscores.index, wins, spread))
    tournament_players.sort(key = lambda c: - (c.wins * 10000 + c.spread))
    return tournament_players

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
    parser.add_argument("--hope", type=str, help="hopefulness factor")
    parser.add_argument("--start", type=str, help="the round at which simulations start")
    parser.add_argument("--final", type=str, help="the final round of the simulation")
    parser.add_argument("--tfile", type=str, help=".t file")
    parser.add_argument("--url", type=str, help="URL for .t file")
    parser.add_argument("--sim", type=str, help="number of sims")
    args = parser.parse_args()

    if args.command != "sim" and args.command != "pair":
        print("command must be one of: sim, pair")
        exit(-1)
    if not args.hope or not args.final:
        print("required: hope and final")
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

    number_of_sims = 10

    if args.sim:
        number_of_sims = int(args.sim)
    
    tournament_players = tournament_players_from_tfile(filename, int(args.start))
    print("Initial Standings:")
    print_tournament_players(tournament_players)
    if args.command == "sim":
        sim(tournament_players, int(args.start), int(args.final), number_of_sims)
    else:
        pairings = pair(tournament_players, int(args.final) - int(args.start))
        print(pairings)