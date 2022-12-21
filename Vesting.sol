pragma solidity ^0.8.13;

import "./node_modules/@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./node_modules/@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./node_modules/@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./node_modules/@openzeppelin/contracts/access/Ownable.sol";
import "./node_modules/@openzeppelin/contracts/utils/math/Math.sol";
import "./node_modules/@openzeppelin/contracts/utils/math/SafeMath.sol";

contract Vesting is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct VestingSchedule {
        uint256 amount;
        uint256 start;
        uint256 cliff;
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
    mapping(address => uint256) public totalClaimed;
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
            amount,
            block.timestamp,
            cliff,
            duration,
            interval,
            0,
            revocable,
            false
        );

        // Update the total vested amount
        totalVested[beneficiary] = amount;
        heldTokens[address(this)] = heldTokens[address(this)] + amount;
        reviveToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Vested(beneficiary, amount);
    }

    /// @notice Withdraws the vested tokens
    /// @param amount of tokens to be withdrawn
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) {
            revert InputError();
        }

        VestingSchedule storage vestingSchedule = vestingSchedules[msg.sender];

        // Check if the beneficiary has a vesting schedule
        if (vestingSchedule.amount == 0) {
            revert NoVestingSchedule();
        }
        // Check if the amount to withdraw is less than the schedule total amount
        if (amount > vestingSchedule.amount) {
            revert InsufficientBalance(amount);
        }

        uint256 balance = reviveToken.balanceOf(address(this));

        // Check if the contract has enough balance to withdraw
        if (balance < amount) {
            revert InsufficientVestedBalance(amount);
        }

        // Check how much of the amount is unlocked
        uint256 unlocked = _unlockedAmount(vestingSchedule);
        
        if (amount > unlocked) {
            revert InsufficientWithdrawnBalance(amount);
        }

        // Update the schedule
        vestingSchedule.withdrawn = vestingSchedule.withdrawn + amount;
        // Update the total withdrawn amount
        totalWithdrawn[msg.sender] = totalWithdrawn[msg.sender] + amount;
        // Update the total vested amount
        totalVested[msg.sender] = totalVested[msg.sender] - amount;
        // Update the held tokens
        heldTokens[address(this)] = heldTokens[address(this)] - amount;

        // Transfer the tokens
        reviveToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Releases the vested tokens

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
        uint256 unlocked = _unlockedAmount(vestingSchedule);

        // Check if there are any unlocked tokens
        if (unlocked == 0) {
            revert InsufficientReleasedBalance();
        }

        // Update the schedule
        uint256 amount = Math.min(balance, unlocked);
        vestingSchedule.amount = vestingSchedule.amount - amount;
        totalReleased[msg.sender] = totalReleased[msg.sender] + amount;

        emit Released(msg.sender, amount);
    }

    /// @notice Revokes the vesting schedule
    /// @param _who of tokens to be revoked
    function revoke(address _who) external nonReentrant {
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

        // Update the schedule
        vestingSchedule.revoked = true;
        totalVested[_who] = totalVested[_who] - vestingSchedule.amount;
        totalRevoked[_who] = totalRevoked[_who] + vestingSchedule.amount;
        heldTokens[address(this)] = heldTokens[address(this)] - vestingSchedule.amount;

        // Transfer the tokens
        reviveToken.safeTransfer(msg.sender, vestingSchedule.amount);

        emit Revoked(msg.sender, vestingSchedule.amount);
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
        if (block.timestamp < vestingSchedule.cliff) {
            return 0;
        // If the vesting has already ended
        } else if 
        (
            // If now is after the vesting end date
            block.timestamp >= vestingSchedule.start + vestingSchedule.duration
        ) {
            // Return the total amount - previowsly withdrawn
            return vestingSchedule.amount - vestingSchedule.withdrawn;
        } else {
            // Calculate the amount of periods that have passed
            uint256 timeSinceStart = block.timestamp - vestingSchedule.start;
            // Calculate the amount of periods
            uint256 periods = timeSinceStart / vestingSchedule.interval;
            // Calculate the amount of tokens that have vested
            return
                (vestingSchedule.amount * periods * vestingSchedule.interval) /
                vestingSchedule.duration -
                vestingSchedule.withdrawn;
        }
    }

    /// @notice Returns the total amount of tokens vested for a beneficiary
    /// @param beneficiary address of the beneficiary to query
    /// @return the total amount of tokens vested for the beneficiary
    function vestedAmount(address beneficiary) public view returns (uint256) {
        VestingSchedule memory vestingSchedule = vestingSchedules[beneficiary];
        return _unlockedAmount(vestingSchedule);
    }

    /// @notice Returns the current amount of tokens still to be vested for a beneficiary
    /// @param beneficiary address of the beneficiary to query
    /// @return the current amount of tokens still to be vested for the beneficiary
    function vestedBalance(address beneficiary) public view returns (uint256) {
        VestingSchedule memory vestingSchedule = vestingSchedules[beneficiary];
        return
            vestingSchedule.amount -
            vestingSchedule.withdrawn +
            _unlockedAmount(vestingSchedule);
    }

    /// @notice Returns the total amount of tokens vested for a beneficiary at a specific time
    /// @param beneficiary address of the beneficiary to query
    /// @param timestamp the timestamp to query the vested amount for
    /// @return the total amount of tokens vested for the beneficiary at the specific time
    function vestedBalanceOfAt(address beneficiary, uint256 timestamp)
        public
        view
        returns (uint256)
    {
        VestingSchedule storage vestingSchedule = vestingSchedules[beneficiary];
        // If the vesting has not started yet
        if (timestamp < vestingSchedule.cliff) {
            return 0;
        } else if 
        (   // If now is after the vesting end date
            timestamp >= vestingSchedule.start + vestingSchedule.duration
        ) {
            // Return the total amount + previowsly withdrawn
            return vestingSchedule.amount + vestingSchedule.withdrawn;
        } else {
            // Calculate the amount of periods that have passed
            uint256 timeSinceStart = timestamp - vestingSchedule.start;
            // Calculate the amount of periods
            uint256 periods = timeSinceStart / vestingSchedule.interval;
            // Calculate the amount of tokens that have vested
            return
                (vestingSchedule.amount * periods * vestingSchedule.interval) /
                vestingSchedule.duration -
                vestingSchedule.withdrawn;
        }
    }
}
