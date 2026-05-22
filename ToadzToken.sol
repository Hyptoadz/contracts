// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
interface INFTStakingPool { function addToPoolDirect(uint256 amount) external; }

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title ToadzToken
 * @notice ERC-20 $TOADZ token with buy/sell tax mechanic
 *
 * Total Supply: 550,000,000 $TOADZ
 * ─────────────────────────────────
 * 180,000,000 → Mint Rewards     (32.7%)
 *  105,000,000 → Hypurr Airdrop   (19.1%)
 * 100,000,000 → Liquidity Pool   (18.2%)

 *  90,000,000 → NFT Staking      (16.4%)
 *  50,000,000 → $TOADZ Staking   ( 9.1%)
 *  25,000,000 → Revenue Share    ( 4.5%)
 *           0 → Team / VC
 *
 * Tax:
 *   Buy  5% → 3.0% staking | 1.0% burn | 1.0% LP
 *   Sell 5% → 3.0% staking | 1.0% burn | 1.0% LP
 */
contract ToadzToken is ERC20, Ownable {

    // ── Supply constants ───────────────────────────────────────
    uint256 public constant TOTAL_SUPPLY    = 550_000_000 * 1e18;
    uint256 public constant MINT_REWARDS    = 180_000_000 * 1e18;
    uint256 public constant LP_AMOUNT       =  100_000_000 * 1e18;
    uint256 public constant NFT_STAKING     =  90_000_000 * 1e18;
    uint256 public constant TOKEN_STAKING   =  50_000_000 * 1e18;
    uint256 public constant REV_SHARE       =  25_000_000 * 1e18;
    uint256 public constant AIRDROP_AMOUNT  = 105_000_000 * 1e18;

    // ── Tax constants ──────────────────────────────────────────
    uint256 public constant BUY_TAX         = 5;  // 5%
    uint256 public constant SELL_TAX        = 5;  // 5%
    uint256 public constant STAKING_SHARE   = 60; // 60% of tax → staking
    uint256 public constant BURN_SHARE      = 20; // 20% of tax → burn
    uint256 public constant LP_SHARE        = 20; // 20% of tax → LP

    // ── Addresses ──────────────────────────────────────────────
    address public dexPair;
    address public nftStakingContract;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ── State ──────────────────────────────────────────────────
    bool public taxEnabled;
    bool public tradingEnabled; // false until LP is added
    address public mintContract;  // set after deploy
    uint256 public totalTaxBurned;
    uint256 public totalTaxToStaking;
    uint256 public totalTaxToLP;

    mapping(address => bool) public isExcludedFromTax;
    mapping(address => bool) public isExcludedFromLock; // only system contracts

    // ── Events ─────────────────────────────────────────────────
    event TaxEnabled();
    event TradingEnabled();
    event DexPairSet(address indexed pair);
    event TaxExclusionSet(address indexed account, bool excluded);
    event TaxDistributed(
        uint256 stakingAmount,
        uint256 burnAmount,
        uint256 lpAmount
    );

    // ── Errors ─────────────────────────────────────────────────
    error TaxAlreadyEnabled();
    error ZeroAddress();

    // ── Constructor ────────────────────────────────────────────
    constructor(
        address _owner,
        address _mintContract,
        address _nftStakingContract,
        address _tokenStakingContract,
        address _revShareContract,
        address _airdropContract
    ) ERC20("$TOADZ", "TOADZ") Ownable(_owner) {
        if (_mintContract        == address(0)) revert ZeroAddress();
        if (_nftStakingContract  == address(0)) revert ZeroAddress();
        if (_tokenStakingContract == address(0)) revert ZeroAddress();
        if (_revShareContract    == address(0)) revert ZeroAddress();
        if (_airdropContract     == address(0)) revert ZeroAddress();

        nftStakingContract = _nftStakingContract;
        mintContract = _mintContract;

        // Mint all allocations
        _mint(_mintContract,          MINT_REWARDS);
        _mint(_mintContract,          LP_AMOUNT); // LP TOADZ minted to mint contract
        _mint(_nftStakingContract,    NFT_STAKING);
        _mint(_tokenStakingContract,  TOKEN_STAKING);
        _mint(_revShareContract,      REV_SHARE);
        _mint(_airdropContract,       AIRDROP_AMOUNT);

        // Exclude system contracts from tax
        isExcludedFromTax[_mintContract]          = true;
        isExcludedFromTax[_nftStakingContract]    = true;
        isExcludedFromTax[_tokenStakingContract]  = true;
        isExcludedFromTax[_revShareContract]      = true;
        isExcludedFromTax[_airdropContract]       = true;
        isExcludedFromTax[_owner]                 = true;
        isExcludedFromTax[address(this)]          = true;

        // Lock exclusions — only system contracts, NOT owner/regular wallets
        isExcludedFromLock[_mintContract]         = true;
        isExcludedFromLock[_nftStakingContract]   = true;
        isExcludedFromLock[_tokenStakingContract] = true;
        isExcludedFromLock[address(this)]         = true;
    }

    // ── Admin ──────────────────────────────────────────────────



    function enableTrading() external {
        require(msg.sender == mintContract || msg.sender == owner(), "Not authorized");
        require(!tradingEnabled, "Already enabled");
        tradingEnabled = true;
        emit TradingEnabled();
    }

    function setDexPair(address _pair) external {
        require(msg.sender == mintContract, "Only mint contract");
        require(dexPair == address(0), "Already set");
        if (_pair == address(0)) revert ZeroAddress();
        dexPair = _pair;
        emit DexPairSet(_pair);
    }

    function enableTax() external {
        require(msg.sender == mintContract || msg.sender == owner(), "Not authorized");
        if (taxEnabled) revert TaxAlreadyEnabled();
        taxEnabled = true;
        emit TaxEnabled();
    }

    function setTaxExclusion(address account, bool excluded) external onlyOwner {
        isExcludedFromTax[account] = excluded;
        emit TaxExclusionSet(account, excluded);
    }

    // ── Transfer with tax ──────────────────────────────────────

    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override {
        // Trading lock — block transfers until LP is added
        if (!tradingEnabled) {
            require(
                isExcludedFromLock[from] || isExcludedFromLock[to] || from == address(0),
                "Trading not yet enabled"
            );
        }
        // Skip tax if disabled or excluded
        if (
            !taxEnabled              ||
            from == address(0)       ||
            to   == address(0)       ||
            isExcludedFromTax[from]  ||
            isExcludedFromTax[to]
        ) {
            super._update(from, to, amount);
            return;
        }

        uint256 taxRate = 0;
        // Only apply tax if dexPair is set and matches
        if (dexPair != address(0)) {
            if (from == dexPair) taxRate = BUY_TAX;      // Buy
            else if (to == dexPair) taxRate = SELL_TAX;  // Sell
        }

        // No tax on wallet-to-wallet transfers
        if (taxRate == 0) {
            super._update(from, to, amount);
            return;
        }

        uint256 taxAmount    = amount * taxRate / 100;
        uint256 stakingAmt   = taxAmount * STAKING_SHARE / 100;
        uint256 burnAmt      = taxAmount * BURN_SHARE / 100;
        uint256 lpAmt        = taxAmount - stakingAmt - burnAmt;
        uint256 transferAmt  = amount - taxAmount;

        // Distribute tax
        super._update(from, nftStakingContract, stakingAmt);
        if (stakingAmt > 0) { try INFTStakingPool(nftStakingContract).addToPoolDirect(stakingAmt) {} catch {} }
        super._update(from, DEAD, burnAmt);
        super._update(from, mintContract, lpAmt);
        super._update(from, to, transferAmt);

        // Track stats
        totalTaxToStaking += stakingAmt;
        totalTaxBurned    += burnAmt;
        totalTaxToLP      += lpAmt;

        emit TaxDistributed(stakingAmt, burnAmt, lpAmt);
    }

    // ── Views ──────────────────────────────────────────────────

    function circulatingSupply() external view returns (uint256) {
        return totalSupply() - balanceOf(DEAD);
    }
}
