import re
import argparse
import asyncio
from watchfiles import awatch

def get_gcg_info(gcg_filename):
    with open(gcg_filename, 'r') as f:
        lines = f.readlines()

    final_scores = {}

    bag = {
        "A": 9, "B": 2, "C": 2, "D": 4, "E": 12, "F": 2, "G": 3, "H": 2, 
        "I": 9, "J": 1, "K": 1, "L": 4, "M": 2, "N": 6, "O": 8, "P": 2, 
        "Q": 1, "R": 6, "S": 4, "T": 6, "U": 4, "V": 2, "W": 2, "X": 1, 
        "Y": 2, "Z": 1, "?": 2
    }

    team_going_first = ""
    previous_played_tiles = ""
    for line in lines:
            print("\n\nline: ", line.strip())
            match = re.search("#player1\s+(\w+)", line)
            if match is not None and match.group(1) is not None and team_going_first == "":
                name = match.group(1).strip()
                team_going_first = name
                final_scores[name] = 0
                print("team going first: " + team_going_first)

            match = re.search("#player2\s+(\w+)", line)
            if match is not None and match.group(1) is not None:
                name = match.group(1).strip()
                final_scores[name] = 0
                print("team going second: " + name)
            
            match = re.search("^>(\w+).*\D(\d+)$", line)
            if match is not None and match.group(1) is not None and match.group(2) is not None:
                name = match.group(1).strip()
                score = match.group(2).strip()
                final_scores[name] = int(score)
                print("final score: %s has %s" % (name, score))

            match = re.search("^>\w+:\s+[\w\?]+\s+\w+\s+([\w\.]+)", line)
            if match is not None and match.group(1) is not None:
                played_tiles = match.group(1).strip()
                print("played_tiles: ", played_tiles)
                for letter in played_tiles:
                    if letter != ".":
                        if letter.islower():
                            bag["?"] -= 1
                        else:
                            bag[letter] -= 1
                previous_played_tiles = played_tiles

            match = re.search("^>\w+:\s+[\w\?]+\s+--", line)
            if match is not None:
                print("lost challenge detected, adding tiles back")
                print("previous_played_tiles: ", previous_played_tiles)
                for letter in previous_played_tiles:
                    if letter != ".":
                        if letter.islower():
                            bag["?"] += 1
                        else:
                            bag[letter] += 1

            match = re.search("^#rack\d\s([\w\?]+)", line)
            if match is not None and match.group(1) is not None:
                tiles_on_rack = match.group(1).strip()
                print("tiles_on_rack: ", tiles_on_rack)
                for letter in tiles_on_rack:
                    if letter != ".":
                        if letter.islower():
                            bag["?"] -= 1
                        else:
                            bag[letter] -= 1

    bag_string = ""
    for letter in bag:
        letter_was_present = False
        for _ in range(bag[letter]):
            letter_was_present = True
            bag_string += letter
        if letter_was_present:
            bag_string += " "
    bag_string.strip()
    return final_scores, team_going_first, bag_string


async def main(gcg_filename, score_output_filename, unseen_output_filename):
    async for _ in awatch(gcg_filename):
        print("\n\n\nPARSING GCG\n\n\n")
        final_scores, team_going_first, bag_string = get_gcg_info(gcg_filename)
        final_scores_string = ""
        for team_name in final_scores:
            if team_name == team_going_first:
                final_scores_string += str(final_scores[team_name]).rjust(3) + " - "
            else:
                final_scores_string += str(final_scores[team_name]).ljust(3)

        print(">" + team_going_first + "<")
        print(">" + final_scores_string + "<")
        print(">" + bag_string + "<")
        with open(score_output_filename, "w") as score_file:
            score_file.write(final_scores_string)
    
        with open(unseen_output_filename, "w") as unseen_file:
            unseen_file.write(bag_string)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--gcg", type=str, help="the gcg file to monitor")
    parser.add_argument("--score", type=str, help="the output file to write the score")
    parser.add_argument("--unseen", type=str, help="the output file to write the unseen tiles")
    args = parser.parse_args()

    if not args.gcg:
        print("required: gcg")
        exit(-1)

    if not args.score:
        print("required: score")
        exit(-1)

    if not args.unseen:
        print("required: unseen")
        exit(-1)

    asyncio.run(main(args.gcg, args.score, args.unseen))