# Revive Vesting 
<h2>This allows you to create vesting schedules for beneficiaries and manage the release of vested tokens.

<hr/>

## Features: 


* Creates vesting schedules for a beneficiary, with a specified amount of tokens, cliff time (when a certain percentage of the tokens are released), cliff amount (percentage of tokens to release after the cliff time), duration (total time for which the tokens are vested), interval (time between each release), and a flag indicating whether the vesting schedule is revocable or not.
* Allows the beneficiary to withdraw a specified amount of released tokens.
* Releases a specified amount of vested tokens.
* Allows the owner to revoke a vesting schedule, provided it is revocable.

## Logic

The vesting contract uses several equations and maths to calculate the vesting schedules and release of tokens.

* Cliff: The cliff is the time after which a certain percentage of the tokens are released. For example, if the vesting schedule has a cliff of 1 month and a cliff amount of 25%, then 25% of the tokens will be released after 1 month.

* Linear vesting: The vesting of tokens is done in a linear fashion, meaning that the tokens are released evenly over the duration of the vesting schedule. For example, if the vesting schedule has a duration of 3 months and an interval of 1 week, then the tokens will be released in equal amounts every week for 3 months.


## Usage: 
The vesting contract has several functions that interact with each other to manage the vesting schedules and release of tokens.

* ```vest():``` This function creates a vesting schedule for a beneficiary, with a specified amount of tokens, cliff time, cliff amount, duration, interval, and revocability. It checks that the input values are valid, and that the beneficiary does not already have a vesting schedule. It then adds the vesting schedule to the vestingSchedules mapping, and transfers the specified amount of tokens from the owner's account to the contract.

* ```withdraw():``` This function allows the beneficiary to withdraw a specified amount of released tokens. It checks that the beneficiary has a vesting schedule, and that the specified amount is less than or equal to the amount of released tokens. It then transfers the specified amount of tokens from the contract to the beneficiary's account, and updates the totalWithdrawn mapping for the beneficiary.

* ```release():``` This function releases a specified amount of vested tokens. It checks that the beneficiary has a vesting schedule, and that the specified amount is less than or equal to the amount of unlocked tokens. It then updates the totalReleased mapping for the beneficiary ready to be withdrawn.

* ```revoke():``` This function allows the owner to revoke a vesting schedule if it is revocable. It checks that the vesting schedule is revocable and has not already been revoked, and then updates the revoked flag in the vestingSchedules mapping. This withdraws the remaining tokens (locked,unlocked,released) to the msg.sender which can only be the owner due to onlyOwner().