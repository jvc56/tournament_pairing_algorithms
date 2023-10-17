# Using COP for TSH
This guide assumes you are using a Unix based operating system such as Linux or MacOS. All of the following steps are performed on a terminal window.
## Install the Graph::Matching module
The COP pairing software uses a [maximum weight matching algorithm](https://en.wikipedia.org/wiki/Maximum_weight_matching) to find
the most desirable pairings. This algorithm is implemented by the Graph::Matching module. Install the module with the following command:

`cpan Graph::Matching`

## Download the COP.pm file
Download the COP.pm file from this repository and save it in the following directory in your local TSH instance:

`TSH/lib/perl/TSH/Command`

## Run COP
Once the COP.pm is copied to the Command directory, TSH must be restarted for the changes to take effect.
You should now be able to run the COP pairing command. The COP pairing command needs a based-on round
number and a division. For example, the following command:

`cop 7 a`

Will pair the next round in division 'a' based on the results after round 7. Note that any changes
made to the COP.pm module will require you to restart the TSH program for the changes to take effect.
