# Installing COP on TSH
This guide walks through the required steps for installing the COP algorithm in your local TSH instance. Commands that start with `$` should be invoked in the terminal and commands that start with `tsh>` should be invoked in TSH.

## Install the required modules
The COP pairing software requires two Perl modules. You can install them with the following command:

`$cpan Graph::Matching JSON`

The Graph::Matching module is used by the native COP algorithm that is implemented in the Perl code of the COP module itself. The JSON module is used to encode the API request sent over the network where a server will run the COP algorithm instead of using your local machine. If you always run COP using the API request, the Graph::Matching module isn't strictly necessary but is good to have as a backup in case of network failures.

## Download the COP.pm file
Download the COP.pm file from this repository and save it in the following directory in your local TSH instance:

`TSH/lib/perl/TSH/Command`

## Required TSH config values for COP
COP requires several custom TSH config variables to run. The required variables are listed with example values below:

```
config use_cop_api = 1
config simulations = 10000
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
number and a division. For example, the following command:

`cop 7 a`

Will pair the next round in division 'a' based on the results after round 7. Note that any changes
made to the COP.pm module will require you to restart the TSH program for the changes to take effect.
