// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TokenStaking
 * @notice Stake $TOADZ to earn $TOADZ + weekly HYPE revenue share
 *
 * Revenue share:
 *   - 50% of secondary royalties (5% royalty rate) deposited here
 *   - Distributed weekly, proportional to stake amount
 *   - Paid in HYPE (not $TOADZ)
 */
contract TokenStaking is ReentrancyGuard, Ownable {

    // ── State ──────────────────────────────────────────────────
    IERC20 public immutable toadzToken;

    uint256 public toadzRewardPool;
    uint256 public hypeRewardPool;
    uint256 public totalStaked;

    uint256 public lastHypeDeposit;
    uint256 public constant DISTRIBUTION_INTERVAL = 7 days;

    // Per-token accumulated reward tracking (for gas efficient distribution)
    uint256 public accToadzPerShare;  // accumulated $TOADZ per staked token
    uint256 public accHypePerShare;   // accumulated HYPE per staked token
    uint256 private constant PRECISION = 1e12;

    struct UserInfo {
        uint256 amount;           // staked $TOADZ
        uint256 toadzRewardDebt;  // reward debt for $TOADZ
        uint256 hypeRewardDebt;   // reward debt for HYPE
        uint256 stakedAt;
    }

    mapping(address => UserInfo) public userInfo;

    // ── Events ─────────────────────────────────────────────────
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event ToadzRewardClaimed(address indexed user, uint256 amount);
    event HypeRewardClaimed(address indexed user, uint256 amount);
    event HypeDeposited(uint256 amount, address indexed from);
    event ToadzPoolAdded(uint256 amount);

    // ── Errors ─────────────────────────────────────────────────
    error ZeroAmount();
    error InsufficientStake();
    error TransferFailed();

    // ── Constructor ────────────────────────────────────────────
    constructor(
        address _toadzToken,
        address _owner
    ) Ownable(_owner) {
        toadzToken = IERC20(_toadzToken);
    }

    // ── Revenue deposit (called by royalty receiver) ────────────

    /**
     * @notice Deposit HYPE revenue share
     * @dev Called weekly by owner/royalty contract with 50% of royalties
     */
    receive() external payable {
        hypeRewardPool += msg.value;
        lastHypeDeposit = block.timestamp;

        // Update accumulated HYPE per share
        if (totalStaked > 0) {
            accHypePerShare += msg.value * PRECISION / totalStaked;
        }

        emit HypeDeposited(msg.value, msg.sender);
    }

    // ── Authorized callers ─────────────────────────────────────
    mapping(address => bool) public isAuthorizedCaller;
    error NotAuthorized();

    function setAuthorizedCaller(address caller, bool authorized) external onlyOwner {
        isAuthorizedCaller[caller] = authorized;
    }

    /**
     * @notice Add $TOADZ to reward pool
     * @dev Only authorized callers (tax contract, staking refill)
     *      Caller must approve this contract first
     */
    function addToadzPool(uint256 amount) external {
        if (!isAuthorizedCaller[msg.sender]) revert NotAuthorized();

        bool ok = toadzToken.transferFrom(msg.sender, address(this), amount);
        require(ok, "Transfer failed");

        toadzRewardPool += amount;
        if (totalStaked > 0) {
            accToadzPerShare += amount * PRECISION / totalStaked;
        }
        emit ToadzPoolAdded(amount);
    }

    // ── Staking ────────────────────────────────────────────────

    /**
     * @notice Stake $TOADZ tokens
     * @dev Approve this contract before calling
     */
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        UserInfo storage user = userInfo[msg.sender];

        // Claim pending rewards first
        _claimPending(msg.sender);

        // Transfer $TOADZ from user
        bool ok = toadzToken.transferFrom(msg.sender, address(this), amount);
        if (!ok) revert TransferFailed();

        user.amount    += amount;
        user.stakedAt   = block.timestamp;
        totalStaked    += amount;

        // Update reward debt
        user.toadzRewardDebt = user.amount * accToadzPerShare / PRECISION;
        user.hypeRewardDebt  = user.amount * accHypePerShare  / PRECISION;

        emit Staked(msg.sender, amount);
    }

    /**
     * @notice Unstake $TOADZ tokens
     */
    function unstake(uint256 amount) external nonReentrant {
        UserInfo storage user = userInfo[msg.sender];
        if (amount == 0) revert ZeroAmount();
        if (user.amount < amount) revert InsufficientStake();

        // Claim pending rewards
        _claimPending(msg.sender);

        user.amount -= amount;
        totalStaked -= amount;

        // Update reward debt
        user.toadzRewardDebt = user.amount * accToadzPerShare / PRECISION;
        user.hypeRewardDebt  = user.amount * accHypePerShare  / PRECISION;

        toadzToken.transfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    /**
     * @notice Claim all pending rewards
     */
    function claimRewards() external nonReentrant {
        _claimPending(msg.sender);

        UserInfo storage user = userInfo[msg.sender];
        user.toadzRewardDebt = user.amount * accToadzPerShare / PRECISION;
        user.hypeRewardDebt  = user.amount * accHypePerShare  / PRECISION;
    }

    // ── Views ──────────────────────────────────────────────────

    function pendingToadz(address _user) external view returns (uint256) {
        UserInfo memory user = userInfo[_user];
        if (user.amount == 0) return 0;
        uint256 pending = user.amount * accToadzPerShare / PRECISION;
        if (pending <= user.toadzRewardDebt) return 0;
        return pending - user.toadzRewardDebt;
    }

    function pendingHype(address _user) external view returns (uint256) {
        UserInfo memory user = userInfo[_user];
        if (user.amount == 0) return 0;
        uint256 pending = user.amount * accHypePerShare / PRECISION;
        if (pending <= user.hypeRewardDebt) return 0;
        return pending - user.hypeRewardDebt;
    }

    function userShare(address _user) external view returns (uint256 pct) {
        if (totalStaked == 0) return 0;
        return userInfo[_user].amount * 10_000 / totalStaked; // basis points
    }

    function nextDistribution() external view returns (uint256) {
        if (lastHypeDeposit == 0) return 0;
        uint256 next = lastHypeDeposit + DISTRIBUTION_INTERVAL;
        if (block.timestamp >= next) return 0;
        return next - block.timestamp;
    }

    // ── Internal ───────────────────────────────────────────────

    function _claimPending(address _user) internal {
        UserInfo storage user = userInfo[_user];
        if (user.amount == 0) return;

        // $TOADZ reward
        uint256 toadzPending = user.amount * accToadzPerShare / PRECISION;
        if (toadzPending > user.toadzRewardDebt) {
            uint256 toadzReward = toadzPending - user.toadzRewardDebt;
            if (toadzReward > 0 && toadzRewardPool >= toadzReward) {
                toadzRewardPool -= toadzReward;
                bool toadzOk = toadzToken.transfer(_user, toadzReward);
                require(toadzOk, "TOADZ transfer failed");
                user.toadzRewardDebt = toadzPending; // update debt only after success
                emit ToadzRewardClaimed(_user, toadzReward);
            }
        }

        // HYPE reward
        uint256 hypePending = user.amount * accHypePerShare / PRECISION;
        if (hypePending > user.hypeRewardDebt) {
            uint256 hypeReward = hypePending - user.hypeRewardDebt;
            if (hypeReward > 0 && hypeRewardPool >= hypeReward) {
                hypeRewardPool -= hypeReward;
                (bool ok, ) = payable(_user).call{value: hypeReward}("");
                require(ok, "HYPE transfer failed");
                user.hypeRewardDebt = hypePending; // update debt only after success
                emit HypeRewardClaimed(_user, hypeReward);
            }
        }
    }
}
