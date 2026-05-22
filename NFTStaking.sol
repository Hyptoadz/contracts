// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title NFTStaking
 * @notice Stake Hyptoadz NFT to earn daily $TOADZ rewards
 *
 * Lock tiers:
 *   0 = No lock   → 5  $TOADZ/day (1x)
 *   1 = 7 days    → 8  $TOADZ/day (1.6x)
 *   2 = 30 days   → 15 $TOADZ/day (3x)
 *   3 = 90 days   → 25 $TOADZ/day (5x)
 *   4 = 180 days  → 40 $TOADZ/day (8x)
 *
 * Rarity multipliers:
 *   Common    = 1x
 *   Uncommon  = 1.6x
 *   Rare      = 3x
 *   Legendary = 6x
 *   Genesis   = 10x
 *
 * Early unstake → forfeit ALL pending rewards
 */
contract NFTStaking is ReentrancyGuard, Ownable, IERC721Receiver {

    // ── Constants ──────────────────────────────────────────────
    uint256 private constant PRECISION = 1e18;

    uint256[5] public LOCK_DURATIONS  = [0, 7 days, 30 days, 90 days, 180 days];
    // Daily pool distributed proportionally to all stakers
    // More stakers = lower per-NFT reward (sustainable APY)
    uint256 public DAILY_POOL = 10_000 * PRECISION; // 10,000 $TOADZ/day total

    // Lock multipliers (x10 precision) — longer lock = bigger share
    uint256[5] public LOCK_WEIGHT_X10  = [10, 16, 30, 50, 80]; // 1x 1.6x 3x 5x 8x
    uint256[5] public RARITY_MULT_X10  = [10, 16, 30, 60, 100]; // common → genesis

    // Track total weighted stakes for proportional distribution
    uint256 public totalWeightedStakes;

    // ── Addresses ──────────────────────────────────────────────
    IERC721  public immutable nftContract;
    IERC20   public immutable toadzToken;

    // ── State ──────────────────────────────────────────────────
    uint256 public rewardPool;
    uint256 public totalStaked;

    struct StakeInfo {
        address owner;
        uint256 lockTier;
        uint256 stakedAt;
        uint256 lockUntil;   // 0 if no lock
        uint256 lastClaimed;
        uint8   rarity;      // 0-4
        uint256 weight;      // lockWeight * rarityMult / 10
    }

    mapping(uint256 => StakeInfo) public stakes;
    mapping(address => uint256[]) private _userTokens;

    // ── Events ─────────────────────────────────────────────────
    event Staked(address indexed user, uint256 indexed tokenId, uint256 lockTier, uint256 lockUntil);
    event Unstaked(address indexed user, uint256 indexed tokenId, uint256 rewardClaimed, bool forfeited);
    event Claimed(address indexed user, uint256 indexed tokenId, uint256 amount);
    event PoolAdded(uint256 amount, address indexed from);
    event RarityUpdated(uint256 indexed tokenId, uint8 rarity);

    // ── Errors ─────────────────────────────────────────────────
    error NotOwner();
    error AlreadyStaked();
    error NotStaked();
    error InvalidTier();
    error InvalidRarity();
    error PoolInsufficient();
    error ZeroReward();

    // ── Constructor ────────────────────────────────────────────
    constructor(
        address _nftContract,
        address _toadzToken,
        address _owner
    ) Ownable(_owner) {
        nftContract = IERC721(_nftContract);
        toadzToken  = IERC20(_toadzToken);
    }

    // ── Pool management ────────────────────────────────────────

    // Authorized callers that can add to pool
    mapping(address => bool) public isAuthorizedCaller;

    error NotAuthorized();

    function setAuthorizedCaller(address caller, bool authorized) external onlyOwner {
        isAuthorizedCaller[caller] = authorized;
    }

    /**
     * @notice Add $TOADZ to reward pool
     * @dev Called by mint contract (leftover) or tax refill
     *      Caller must have approved this contract to spend $TOADZ
     *      Only authorized callers (mint contract, tax contract) can call
     */
    function addToPool(uint256 amount) external {
        if (!isAuthorizedCaller[msg.sender]) revert NotAuthorized();

        // Pull tokens from caller — caller must have approved first
        bool ok = toadzToken.transferFrom(msg.sender, address(this), amount);
        require(ok, "Transfer failed");

        rewardPool += amount;
        emit PoolAdded(amount, msg.sender);
    }

    /**
     * @notice Internal add — for when tokens are already in contract
     * @dev Called after direct transfer (e.g. from mint contract)
     */
    function addToPoolDirect(uint256 amount) external {
        if (!isAuthorizedCaller[msg.sender]) revert NotAuthorized();
        // Tokens already transferred by caller — just increment pool
        // No balance check needed: caller is HyptoadzMint which already transferred
        rewardPool += amount;
        emit PoolAdded(amount, msg.sender);
    }

    // ── Staking ────────────────────────────────────────────────

    /**
     * @notice Stake your Hyptoadz NFT
     * @param tokenId NFT token ID to stake
     * @param lockTier 0=no lock, 1=7d, 2=30d, 3=90d, 4=180d
     */
    function stake(uint256 tokenId, uint256 lockTier) external nonReentrant {
        if (lockTier >= LOCK_DURATIONS.length) revert InvalidTier();
        if (nftContract.ownerOf(tokenId) != msg.sender) revert NotOwner();
        if (stakes[tokenId].owner != address(0)) revert AlreadyStaked();

        nftContract.transferFrom(msg.sender, address(this), tokenId);

        uint256 lockUntil = lockTier == 0
            ? 0
            : block.timestamp + LOCK_DURATIONS[lockTier];

        uint256 weight = _calcWeight(lockTier, 0);
        stakes[tokenId] = StakeInfo({
            owner:       msg.sender,
            lockTier:    lockTier,
            stakedAt:    block.timestamp,
            lockUntil:   lockUntil,
            lastClaimed: block.timestamp,
            rarity:      0,
            weight:      weight
        });

        _userTokens[msg.sender].push(tokenId);
        totalStaked++;
        totalWeightedStakes += weight;

        emit Staked(msg.sender, tokenId, lockTier, lockUntil);
    }

    /**
     * @notice Claim pending $TOADZ rewards
     */
    function claim(uint256 tokenId) external nonReentrant {
        StakeInfo storage s = stakes[tokenId];
        if (s.owner != msg.sender) revert NotOwner();

        uint256 reward = _pendingReward(tokenId);
        if (reward == 0) revert ZeroReward();
        if (rewardPool < reward) revert PoolInsufficient();

        s.lastClaimed = block.timestamp;
        rewardPool   -= reward;
        toadzToken.transfer(msg.sender, reward);

        emit Claimed(msg.sender, tokenId, reward);
    }

    /**
     * @notice Claim all pending rewards for all staked NFTs
     */
    function claimAll() external nonReentrant {
        uint256[] memory tokens = _userTokens[msg.sender];
        uint256 totalReward;

        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 tokenId = tokens[i];
            if (stakes[tokenId].owner != msg.sender) continue;

            uint256 reward = _pendingReward(tokenId);
            if (reward > 0 && rewardPool >= reward) {
                stakes[tokenId].lastClaimed = block.timestamp;
                rewardPool  -= reward;
                totalReward += reward;
                emit Claimed(msg.sender, tokenId, reward);
            }
        }

        if (totalReward > 0) {
            toadzToken.transfer(msg.sender, totalReward);
        }
    }

    /**
     * @notice Unstake your NFT
     * @dev If still locked → forfeits pending rewards (no penalty fee)
     *      If unlocked → claims all pending rewards first
     */
    function unstake(uint256 tokenId) external nonReentrant {
        StakeInfo storage s = stakes[tokenId];
        if (s.owner != msg.sender) revert NotOwner();

        bool lockStatus = s.lockUntil > 0 && block.timestamp < s.lockUntil;
        uint256 rewardClaimed = 0;

        if (!lockStatus) {
            // Claim pending rewards
            uint256 reward = _pendingReward(tokenId);
            if (reward > 0 && rewardPool >= reward) {
                rewardPool    -= reward;
                rewardClaimed  = reward;
                toadzToken.transfer(msg.sender, reward);
            }
        }
        // Locked = forfeit all pending rewards

        // Return NFT
        nftContract.transferFrom(address(this), msg.sender, tokenId);

        // Cleanup
        _removeUserToken(msg.sender, tokenId);
        if (totalWeightedStakes >= s.weight) totalWeightedStakes -= s.weight;
        delete stakes[tokenId];
        totalStaked--;

        emit Unstaked(msg.sender, tokenId, rewardClaimed, lockStatus);
    }

    // ── Admin ──────────────────────────────────────────────────

    /**
     * @notice Set rarity after metadata reveal
     */
    function setRarityBatch(
        uint256[] calldata tokenIds,
        uint8[]   calldata rarities
    ) external onlyOwner {
        require(tokenIds.length == rarities.length, "Length mismatch");
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (rarities[i] > 4) revert InvalidRarity();
            StakeInfo storage s = stakes[tokenIds[i]];
            if (s.owner != address(0)) {
                // Update totalWeightedStakes with new weight
                uint256 oldWeight = s.weight;
                uint256 newWeight = _calcWeight(s.lockTier, rarities[i]);
                totalWeightedStakes = totalWeightedStakes - oldWeight + newWeight;
                s.weight = newWeight;
            }
            s.rarity = rarities[i];
            emit RarityUpdated(tokenIds[i], rarities[i]);
        }
    }

    // ── Views ──────────────────────────────────────────────────

    function pendingReward(uint256 tokenId) external view returns (uint256) {
        return _pendingReward(tokenId);
    }

    function pendingRewardAll(address user) external view returns (uint256 total) {
        uint256[] memory tokens = _userTokens[user];
        for (uint256 i = 0; i < tokens.length; i++) {
            if (stakes[tokens[i]].owner == user) {
                total += _pendingReward(tokens[i]);
            }
        }
    }

    function userStakedTokens(address user) external view returns (uint256[] memory) {
        return _userTokens[user];
    }

    function isLocked(uint256 tokenId) external view returns (bool) {
        StakeInfo memory s = stakes[tokenId];
        return s.lockUntil > 0 && block.timestamp < s.lockUntil;
    }

    function timeUntilUnlock(uint256 tokenId) external view returns (uint256) {
        StakeInfo memory s = stakes[tokenId];
        if (s.lockUntil == 0 || block.timestamp >= s.lockUntil) return 0;
        return s.lockUntil - block.timestamp;
    }

    function dailyRewardFor(uint256 tokenId) external view returns (uint256) {
        StakeInfo memory s = stakes[tokenId];
        if (s.owner == address(0)) return 0;
        if (totalWeightedStakes == 0) return 0;
        return DAILY_POOL * s.weight / totalWeightedStakes;
    }

    function currentAPY() external view returns (uint256 dailyPerNFT) {
        if (totalStaked == 0 || totalWeightedStakes == 0) return DAILY_POOL / PRECISION;
        // Average daily reward per NFT (no lock, common rarity)
        uint256 baseWeight = LOCK_WEIGHT_X10[0] * RARITY_MULT_X10[0] / 10;
        return DAILY_POOL * baseWeight / totalWeightedStakes;
    }

    // ── Internal ───────────────────────────────────────────────

    function _calcWeight(uint256 lockTier, uint8 rarity) internal view returns (uint256) {
        return LOCK_WEIGHT_X10[lockTier] * RARITY_MULT_X10[rarity] / 10;
    }

    function _pendingReward(uint256 tokenId) internal view returns (uint256) {
        StakeInfo memory s = stakes[tokenId];
        if (s.owner == address(0)) return 0;
        if (totalWeightedStakes == 0) return 0;

        uint256 elapsed = block.timestamp - s.lastClaimed;

        // Proportional: userShare = DAILY_POOL * userWeight / totalWeightedStakes
        // reward = userShare * elapsed / 1 day
        return DAILY_POOL * s.weight / totalWeightedStakes * elapsed / 1 days;
    }

    function _removeUserToken(address user, uint256 tokenId) internal {
        uint256[] storage arr = _userTokens[user];
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == tokenId) {
                arr[i] = arr[arr.length - 1];
                arr.pop();
                return;
            }
        }
    }

    // ── ERC721Receiver ─────────────────────────────────────────

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
