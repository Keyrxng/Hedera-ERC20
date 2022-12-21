pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract Vesting is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

            
    struct VestingSchedule {
        address beneficiary;
        uint256 amount;
        uint256 start;
        uint256 cliff;
        uint256 cliffAmount;
        uint256 duration;
        uint256 interval;
        uint256 withdrawn;
        bool revocable;
        bool revoked;
    }

    IERC20 public reviveToken;
    mapping(address => VestingSchedule) public vestingSchedules;
    mapping(address => uint256) public totalVested;
    mapping(address => uint256) public totalWithdrawn;
    mapping(address => uint256) public totalReleased;
    mapping(address => uint256) public totalRevoked;
    mapping(address => uint256) public heldTokens;

    event Vested(address indexed beneficiary, uint256 amount);
    event Withdrawn(address indexed beneficiary, uint256 amount);
    event Released(address indexed beneficiary, uint256 amount);
    event Claimed(address indexed beneficiary, uint256 amount);
    event Revoked(address indexed beneficiary, uint256 amount);

    error BeneficiaryAlreadyHasAVestingSchedule();
    error NoVestingSchedule();
    error InsufficientBalance(uint256 amount);
    error InsufficientVestedBalance(uint256 amount);
    error InsufficientWithdrawnBalance(uint256 amount);
    error InsufficientReleasedBalance();
    error InsufficientClaimedBalance(uint256 amount);
    error InsufficientRevokedBalance(uint256 amount);
    error InsufficientHeldBalance(uint256 amount);
    error VestingNotRevocable();
    error VestingAlreadyRevoked();
    error VestingAlreadyWithdrawn();
    error VestingAlreadyReleased();
    error VestingAlreadyClaimed();
    error InputError();

    constructor(IERC20 _token) {
        reviveToken = _token;
    }

    /// @notice Creates a vesting schedule for a beneficiary
    /// @param beneficiary address of the beneficiary
    /// @param amount amount of tokens to be vested
    /// @param cliff cliff time of the vesting schedule (x% of the tokens are released after this time)
    /// @param duration duration of the vesting schedule (total time for which the tokens are vested)
    /// @param interval interval between each release
    /// @param revocable whether the vesting is revocable or not
    function vest(
        address beneficiary, // address of the beneficiary
        uint256 amount, // amount of tokens to be vested
        uint256 cliff, // cliff time of the vesting schedule (x% of the tokens are released after this time)
        uint256 cliffAmount, // cliff amount of the vesting schedule (x% of the tokens to release after the cliff time)
        uint256 duration, // duration of the vesting schedule (total time for which the tokens are vested)
        uint256 interval, // interval between each release
        bool revocable // whether the vesting is revocable or not
    ) external onlyOwner {
        if (beneficiary == address(0)) {
            revert InputError();
        }
        if (amount == 0) {
            revert InputError();
        }
        if (duration == 0) {
            revert InputError();
        }
        if (interval == 0) {
            revert InputError();
        }
        if (vestingSchedules[beneficiary].amount > 0) {
            revert BeneficiaryAlreadyHasAVestingSchedule();
        }

        vestingSchedules[beneficiary] = VestingSchedule(
            beneficiary,
            amount,
            currentBlock,
            cliff,
            cliffAmount,
            duration,
            interval,
            0,
            revocable,
            false
        );

        // Update the total vested amount
        totalVested[beneficiary] = amount;
        // Update the held tokens
        heldTokens[address(this)] = heldTokens[address(this)] + amount;
        // Transfer the tokens to the contract from the owner
        reviveToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Vested(beneficiary, amount);
    }

    /// @notice Withdraws the vested tokens
    /// @param amount of tokens to be withdrawn
    function withdraw(uint256 amount) external nonReentrant {
        if (totalReleased[msg.sender] == 0) {
            revert InsufficientReleasedBalance();
        }
        if (amount == 0) {
            revert InputError();
        }

        VestingSchedule storage vestingSchedule = vestingSchedules[msg.sender];

        // Check if the beneficiary is the same as the sender
        if(msg.sender != vestingSchedule.beneficiary) {
            revert NoVestingSchedule();
        }

        // Check if the amount to withdraw is less than the total released amount
        if (amount > totalReleased[msg.sender]) {
            revert InsufficientBalance(amount);
        }

        uint256 balance = reviveToken.balanceOf(address(this));

        // Check if the contract has enough balance to withdraw
        if (balance < amount) {
            revert InsufficientVestedBalance(amount);
        }

        // Check how much of the amount is unlocked
        uint256 unlocked = totalReleased[msg.sender];
        
        if (amount > unlocked) {
            revert InsufficientWithdrawnBalance(amount);
        }

        // Update the schedule | amount withdrawn
        vestingSchedule.withdrawn = vestingSchedule.withdrawn + amount;
        // Update the total withdrawn amount | total amount withdrawn by the beneficiary
        totalWithdrawn[msg.sender] = totalWithdrawn[msg.sender] + amount;
        // Update the total vested amount | total amount held by the contract still to be claimed
        totalVested[msg.sender] = totalVested[msg.sender] - amount;
        // Update the held tokens | total amount held by the contract still to be claimed by all beneficiaries
        heldTokens[address(this)] = heldTokens[address(this)] - amount;
        totalReleased[msg.sender] = 0;
        // Transfer the tokens
        reviveToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    function release() external nonReentrant {
        VestingSchedule storage vestingSchedule = vestingSchedules[msg.sender];
        
        // Check if the beneficiary has a vesting schedule
        if (vestingSchedule.amount == 0) {
            revert NoVestingSchedule();
        }

        uint256 balance = reviveToken.balanceOf(address(this));

        // Check if the contract has enough balance to release
        if (balance == 0) {
            revert InsufficientReleasedBalance();
        }

        // Check how much of the amount is unlocked
        uint256 unlocked = _testUnlockedAmount(vestingSchedule);

        // Check if the unlocked amount is greater than the balance
        if (unlocked > balance) {
            revert InsufficientReleasedBalance();
        }

        // Update the schedule
        uint256 amount = Math.min(balance, unlocked);
        // Update the schedule | amount to release minus the unlocked amount
        vestingSchedule.amount = vestingSchedule.amount - amount;
        // Update the schedule | total amount released including the unlocked amount
        totalReleased[msg.sender] = totalReleased[msg.sender] + amount;
        

        emit Released(msg.sender, amount);
    }



    
        uint currentBlock = 1671640809;
        uint block2mnth = 1676824809;
        uint block4mnth = 1682008809;
        uint block6mnth = 1687452009;
        uint block8mnth = 1692376809;
        uint block9mnth =1694968809;
        uint block12mnth =1703176809 ;
        uint bloc15mnth =1713544095 ;
        uint block16mnth =1713544809 ;
        uint block18mnth =1718728809 ;
        uint block24mnth =1734280809 ;



    function testRelease() external nonReentrant {
        VestingSchedule storage vestingSchedule = vestingSchedules[msg.sender];
        
        // Check if the beneficiary has a vesting schedule
        if (vestingSchedule.amount == 0) {
            revert NoVestingSchedule();
        }

        uint256 balance = reviveToken.balanceOf(address(this));

        // Check if the contract has enough balance to release
        if (balance == 0) {
            revert InsufficientReleasedBalance();
        }

        // Check how much of the amount is unlocked
        uint256 unlocked = _testUnlockedAmount(vestingSchedule);

        // Check if the unlocked amount is greater than the balance
        if (unlocked > balance) {
            revert InsufficientReleasedBalance();
        }

        // Update the schedule
        uint256 amount = Math.min(balance, unlocked);
        // Update the schedule | amount to release minus the unlocked amount
        vestingSchedule.amount = vestingSchedule.amount - amount;
        // Update the schedule | total amount released including the unlocked amount
        totalReleased[msg.sender] = totalReleased[msg.sender] + amount;

        emit Released(msg.sender, amount);
    }

    function _testUnlockedAmount(VestingSchedule memory vestingSchedule)
        internal
        view
        returns (uint256)
    {
        // If the vesting has not started yet
        if (block4mnth < vestingSchedule.cliff) {
            return 0;
        } else if 
        (
            block4mnth >= vestingSchedule.cliff && block4mnth < vestingSchedule.start + vestingSchedule.duration
        ) {
            return vestingSchedule.amount - vestingSchedule.cliffAmount;
        } else {
            uint256 timeSinceCliff = block4mnth - vestingSchedule.cliff;
            uint256 periods = timeSinceCliff / vestingSchedule.interval;
            return
                (vestingSchedule.amount * vestingSchedule.interval) / vestingSchedule.duration * periods;
        }
    }

    /// @notice Revokes the vesting schedule
    /// @param _who of tokens to be revoked
    /// @dev this will revoke the vesting schedule for the beneficiary claiming their locked up tokens back to the owner
    /// @dev confirms revocable is true, zeros their balance, tracks balances, and transfers tokens back to owner
    /// @dev tracks totalRevoked for that address to compare claimed vs revoked
    function revoke(address _who) external nonReentrant onlyOwner {
        VestingSchedule storage vestingSchedule = vestingSchedules[msg.sender];

        // Check if the beneficiary has a vesting schedule
        if (vestingSchedule.amount == 0) {
            revert NoVestingSchedule();
        }
        // Check if the vesting is revocable
        if (!vestingSchedule.revocable) {
            revert VestingNotRevocable();
        }
        // Check if the vesting is already revoked
        if (vestingSchedule.revoked) {
            revert VestingAlreadyRevoked();
        }

        uint amt = vestingSchedule.amount;
        
        vestingSchedule.amount = 0;
        // Update the schedule
        vestingSchedule.revoked = true;
        // Update the total vested amount | total held by the contract still to be claimed
        totalVested[_who] = totalVested[_who] - amt;
        // Update the total revoked amount | total amount revoked by the beneficiary
        totalRevoked[_who] = totalRevoked[_who] + amt;
        // Update the held tokens | total amount held by the contract still to be claimed by all beneficiaries
        heldTokens[address(this)] = heldTokens[address(this)] - amt;


        // Transfer the tokens
        reviveToken.safeTransfer(msg.sender, amt);


        emit Revoked(msg.sender, amt);
    }

    /// @notice Returns the amount of tokens that have already vested
    /// @param vestingSchedule vesting schedule of the beneficiary
    /// @return the amount of tokens that have already vested


    function _unlockedAmount(VestingSchedule memory vestingSchedule)
        internal
        view
        returns (uint256)
    {
        // If the vesting has not started yet
        if (currentBlock < vestingSchedule.cliff) {
            return 0;
        } else if 
        (

            currentBlock >= vestingSchedule.cliff && currentBlock < vestingSchedule.start + vestingSchedule.duration
            // If now is after the cliff date but before vesting end | now > start + duration
        ) {
            // Calculate the amount of tokens to emit after the cliff date | amount - cliffAmount

            return vestingSchedule.amount - vestingSchedule.cliffAmount;
        } else {
            // Calculate the amount of time that have passed | now - start
            //  TestCase1: 10% 2mnthCliff 9mnth linear
            //  TestCase1: block4mnth - block2mnth = 5183980
            //  TestCase1: 2 months have passed since the cliff payout
            //  TestCase1: 1,000,000,000 - 800,000,000 = 200,000,000 20% release


            //  TestCase2: 15% 12mnthCliff 18mnth linear
            //  TestCase2: block16mnth - block12mnth = 10,368,000
            //  TestCase2: 4 months have passed since the cliff payout
            //  TestCase2: 1,500,000,000 - 1,050,000,000 = 450,000,000 30% release

            uint256 timeSinceCliff = currentBlock - vestingSchedule.cliff;
            // Calculate the amount of periods | timeSinceStart / interval 
            // TestCase1: interval = 2,408,000 = 1 month
            // TestCase1: 5183980 / 2,408,000 = 2.14 periods
            // TestCase1: "interval between each release" = 1 month therefor 2.14 periods

            //  TestCase2: interval = 2,408,000 = 1 month
            //  TestCase2: 10,368,000 / 2,408,000 = 4.3 periods
            //  TestCase2: "interval between each release" = 1 month therefor 4.3 periods

            uint256 periods = timeSinceCliff / vestingSchedule.interval;
            // Calculate the amount of tokens that have vested | (amount * periods * interval) / duration
            return
                //                   x = (a * p * i) / d * p 
                // TestCase1 Marketing: (800,000,000 * 2,408,000) / 21,672,000 = 88,888,888 * 9 = 800,000,000
                // Explain. Amount left after cliff release * 1 month / by linear unlock time i.e 9 months for Marketing
                // Explained. After 2.14 months the released amount would be 190,222,220

                // TestCase2 Team: (1,050,000,000 * 2,408,000) / 43,344,000 = 58,333,333 * 18 = 1,050,000,000
                // Explain. Amount left after cliff release * 1 month / by linear unlock time i.e 18 months for Team
                // Explained. After 4.3 months the released amount would be 250,833,333
                (vestingSchedule.amount * vestingSchedule.interval) / vestingSchedule.duration * periods;
        }
    }
}
