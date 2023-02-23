import argparse
import re
import os

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
        self.wins = wins
        self.spread = spread
        self.sort_value = wins * 10000 + spread    

def print_tournament_players(tps):
    for tp in tps:
        print(tp.name, (tp.wins/2), tp.spread)

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
    tournament_players.sort(key = lambda c: - c.sort_value)
    return tournament_players

def players_scores_from_tfile(tfile):
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

            if len(scores) != len(opponent_indexes):
                print("scores and opponents are not the same size for {}".format(line))
                exit(-1)

            name = first_name + " " + last_name
            player_scores = PlayerScores(name, index, opponent_indexes, scores)
            players_scores.append(player_scores)
            index += 1
    return players_scores

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--hope", type=str, help="hopefulness factor")
    parser.add_argument("--tfile", type=str, help=".t file")
    args = parser.parse_args()
    if not args.hope or not args.tfile:
        print("required: hope and tfile")
        exit(-1)

    players_scores = players_scores_from_tfile(args.tfile)
    tournament_players = tournament_players_from_players_scores(players_scores)
    print_tournament_players(tournament_players)