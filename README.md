# Installing COP on TSH
This guide walks through the required steps for installing the COP algorithm in your local TSH instance.

## Download the COP.pm file
Download the COP.pm file from this repository and save it in the following directory in your local TSH instance:

```TSH/lib/perl/TSH/Command```

## Required TSH config values for COP
COP requires several custom TSH config variables to run. The required variables are listed with example values below:

```
config use_cop_api = 1
config simulations = 100000
config always_wins_simulations = 10000
config gibson_spread = [250, 200]
config control_loss_thresholds = [0.30]
config hopefulness = [0.2]
config control_loss_activation_round =12
config cop_threads = 2
```

If you are having issues with the COP API call and want to run the native version of COP, comment out the `use_cop_api` config variable or set it to 0.

Each value is described below. The values shown above are reasonable defaults and are a good
starting point for a typical event, except for the control loss activiation round, which needs to vary based on the length of the event.

### `use_cop_api`

Selects which implementation does the pairing. When set to 1, COP sends the division's pairings and
results over the internet to the COP API and applies the pairings it returns. This requires a working internet connection. When set to 0, or left out entirely, the pairings are computed by the Perl code in `COP.pm` on your own machine.

Default: `1`. The API is much faster and is actively supported. The native implementation is out of date. Use 0 only when the API is unreachable or you need to pair without a network connection.

### `simulations`

The number of Monte Carlo tournament simulations used to estimate how each player's remaining
rounds might play out. COP uses the resulting finishing-place distribution to decide which players
are still in contention for each prize rank, which is what `hopefulness` is compared against.

Default: `100000`. Higher values give more accurate results; lower values run
faster. If the API reports `TIMEOUT`, this is usually the first value to reduce. The native
implementation is far slower than the API, so drop this by an order of magnitude or more when
`use_cop_api` is 0.

### `always_wins_simulations`

The number of simulations used for the control loss calculation, which is a separate and more
targeted simulation than the one `simulations` controls. It repeatedly plays out the remaining
rounds with a particular contender winning every game, and counts how often that contender ends up
finishing first.

Default: `10000`. This can be an order of magnitude smaller than `simulations` and still be stable,
because it answers a narrower question. Reduce it alongside `simulations` if you hit `TIMEOUT`.

### `gibson_spread`

The spread cushion, in points per remaining round, that puts a player far enough ahead to be
considered gibsonized: mathematically certain of their position no matter what happens. Gibsonized
players are paired out of the contention group so they cannot influence who wins.

Note that this value is a game spread, not a spread between players. So when a value of 200 is used, this means that in each game a player is not expected to win by more than 200.

This is a list, and the entries are read from the end of the tournament backwards. The first entry
applies when one round remains, the second when two rounds remain, and so on. The last entry is
reused for every round earlier than the list covers.

The entry for a given round is doubled and accumulated across the remaining
rounds to determine how much spread a player needs to be gibsonized, because a single game moves the spread between two players in both directions: with
`[250, 200]`, the spread lead needed is 250 * 2 = 500 with one round to go and 200 * 2 * 2 = 800 with two.

Default: `[250, 200]`.

### `control_loss_thresholds`

How much control the tournament leader is allowed to lose before COP reaches further down the
standings for their opponent. Control loss measures how likely it is that the title gets settled
without the decisive game ever being played: COP simulates a contender winning all of their remaining
games, and control loss is the fraction of those simulations in which that contender still fails to
finish first under ordinary pairings, because they never got paired against the leader.

When control loss stays at or below the threshold, the leader is paired against the lowest ranked
player who can still catch them. When it rises above the threshold, COP also considers the lowest
ranked player who would take first by winning out, and pairs the leader against whichever of the
two is further down. A lower threshold therefore pairs the leader down more aggressively.

Like `gibson_spread`, this is a list read from the end of the tournament backwards: entry one for
the final round, entry two for the penultimate round, and the last entry for everything before
that. A single entry applies the same threshold to the whole event.

Default: `[0.30]`. Values must be greater than 0 and no greater than 1.

### `hopefulness`

The minimum probability at which a player is still treated as a contender for a given prize rank.
A player who finishes at or above that rank in more than this fraction of the simulations is paired
as a contender for it; anyone below the cutoff is not.

This is a list read from the end of the tournament backwards, in the same way as
`control_loss_thresholds`.

Default: `[0.2]`. Lowering it widens the contention group and pairs more players as though they
still have a chance. Values must be greater than 0 and no greater than 1; a value of 0 is rejected
with `INVALID_HOPEFULNESS_THRESHOLD`.

### `control_loss_activation_round`

The first round, counting from 1, for which control loss is considered at all. Before this round
COP pairs without the control loss constraint, on the grounds that there is still too much
tournament left for the leader's control to mean much.

This value should be set to the round during which 'hot pairings' begin, where pairings are decided based on the results of the previous round, as opposed to being based on the results of 2 rounds ago.

Default: `12`. Set this relative to the length of your event rather than copying the number: a
useful rule of thumb is about three quarters of the way through.

### `cop_threads`

The number of threads the native implementation uses to run its simulations.

Default: `2`. Set it to the number of cores you are willing to spend on pairing. This value is only
read when `use_cop_api` is 0; the API implementation ignores it, because the simulations run on the
server.

### Prize configuration

COP also needs to know how deep the prizes go in each division, so that it can tell which ranks are
worth contending for. This comes from your existing `prize` directives rather than a COP specific
config value, and COP will refuse to pair a division with no rank prizes, reporting
`Bad value for config entry: prizes`. Rank prizes look like this:

```
prize rank 1 a "$500"
prize rank 2 a "$300"
prize rank 3 a "$200"
```

Class prizes are picked up the same way and are passed to the API as class prizes:

```
prize rank 1 a "$250" class=B
```

## Run COP
Once the COP.pm is copied to the Command directory and the COP config values are set, TSH must be restarted for the changes to take effect. You should now be able to run the COP pairing command. The COP pairing command needs a based-on round
number and a division. For example, the following TSH command:

```cop 7 a```

Will pair the next round in division 'a' based on the results after round 7. Note that any changes
made to the COP.pm module will require you to restart the TSH program for the changes to take effect.

# Common Issues
## Timeout errors
If you are using the API and the COP pairings are taking too long, you might see this error:

```COP API error code: TIMEOUT: error computing required inputs: TIMEOUT```

This means you need to lower the `simulations` or `always_wins_simulations` config values so the request can complete in time. Currently, the time limit for the request is 15 seconds.
## Config value errors
If you see errors referencing one of the COP config values, it is likely that some required values are either missing or are invalid. For example, this error:

```COP API error code: INVALID_HOPEFULNESS_THRESHOLD: invalid hopefulness threshold 0.000000```

means that the hopefulness threshold used for this round has an invalid value of 0 and needs to have a value greater than 0 and less than or equal to 1.
## Other errors
If you continue to see COP errors you cannot resolve, try reverting back to native COP pairings by setting `use_cop_api` to 0 or commenting it out entirely. This will disable the API call and use the native Perl code in the COP module to make the pairings. You may need to lower the `simulations` or `always_wins_simulations` config values since the native code is generally much slower.

