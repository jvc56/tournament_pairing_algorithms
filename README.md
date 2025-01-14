# Upgrading to the COP API
If you already use COP on TSH, you can follow this section to upgrade to the new COP.pm version. If you do not already have COP on TSH, go to the 'Installing COP on TSH' section.

## Download the updated COP.pm file
Download the COP.pm file (not the legacy/COP.pm version) from this repository and save it in the following directory in your local TSH instance:

```TSH/lib/perl/TSH/Command```

## Install the JSON module
The updated COP module requires a new Perl module which can be installed with:

```cpan JSON```

## Update COP config values
A new COP config value named `use_cop_api` is used to determine if the COP module should make an API call over the internet or run natively. Set this value to `1` to use the newer code which makes an API call over the internet to run the COP algorithm:

```config use_cop_api = 1```

The updated COP module also introduces a new requirement that all hopefulness values be nonzero. Previously, hopefulness could be set to 0 and in practice hopefulness is often 0 for the last round for the old COP module. To run the new COP module, update all 0 values in the hopefulness array. Typically, using the next nonzero value in the array is a good idea. So the following config value:

```config hopefulness = [0, 0.1, 0.05, 0.02, 0.01]```

would become

```config hopefulness = [0.1, 0.1, 0.05, 0.02, 0.01]```

Since the COP API typically runs much faster than native, it is recommended to increase the values for `simulations` and `always_wins_simulations` for more accurate results. The following values are a reasonable starting point for most events:

```
config simulations = 100000
config always_wins_simulations = 10000
```

These may need to be adjusted based on the size and duration of the event.

## Run COP
After restarting TSH, you should now be able to run the new COP module.

# Installing COP on TSH
This guide walks through the required steps for installing the COP algorithm in your local TSH instance.

## Install the required modules
The COP pairing software requires two Perl modules. You can install them with the following terminal command:

```cpan Graph::Matching JSON```

The Graph::Matching module is used by the native COP algorithm that is implemented in the Perl code of the COP module itself. The JSON module is used to encode the API request sent over the internet where a server will run the COP algorithm instead of using your local machine. If you always run COP using the API request, the Graph::Matching module isn't strictly necessary but is good to have as a backup in case of network failures.

## Download the COP.pm file
Download the COP.pm file (not the legacy/COP.pm version) from this repository and save it in the following directory in your local TSH instance:

```TSH/lib/perl/TSH/Command```

## Required TSH config values for COP
COP requires several custom TSH config variables to run. The required variables are listed with example values below:

```
config use_cop_api = 1
config simulations = 100000
config always_wins_simulations = 10000
config gibson_spread = [250, 200]
config control_loss_thresholds = [0.25]
config hopefulness = [0.1, 0.1, 0.05, 0.02, 0.01]
config control_loss_activation_round =12
config cop_threads = 2
```

If you are having issues with the COP API call and want to run the native version of COP, comment out the `use_cop_api` config variable or set it to 0.

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

