// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IHyptoadzNFT {
    function mintPublic(address to, uint256 tokenId) external;
    function airdropBatch(address[] calldata recipients, uint256[] calldata nftCounts, uint256[] calldata toadzAmounts) external;
    function recordUnsoldBurn(uint256 amount) external;
    function totalPublicMinted() external view returns (uint256);
    function totalAirdropped() external view returns (uint256);
    function isBaseURISet() external view returns (bool);
    function enableTransfers() external;
    function transfersEnabled() external view returns (bool);
}

interface IToadzToken {
    function enableTrading() external;
    function enableTax() external;
    function setDexPair(address _pair) external;
}
interface IDEXFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface INFTStaking {
    function addToPoolDirect(uint256 amount) external;
}

interface IDEXRouter2 {
    function WETH() external pure returns (address);
}
interface IDEXRouter {
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
}

/**
 * @title HyptoadzMint
 * @notice Core mint contract for Hyptoadz
 *
 * ═══════════════════════════════════════════════════════
 * DYNAMIC SPLIT MECHANIC
 * Every 1,500 NFTs minted → Creator share drops -5%, min 20%
 *
 * NFTs minted  Creator%   LP%
 * 1 - 1,500    40%        60%
 * 1,501-3,000  35%        65%
 * 3,001-4,500  30%        70%
 * 4,501-6,000  25%        75%
 * 6,001-6,462  20%        80%  ← min creator
 *
 * More mints → deeper liquidity pool
 * ═══════════════════════════════════════════════════════
 *
 * RANDOM MINT: Token IDs (#3,539 → #10,000) randomly assigned
 * INSTANT REVEAL: baseURI must be set before startMint()
 *
 * POST-MINT FLOW (anyone can call after 48h):
 * 1. splitFunds() → creator gets accumulated share, leftover $TOADZ → staking
 * 2. addLiquidity() → lpAccumulated HYPE + 100M $TOADZ → HyperSwap V2, LP burned to 0xDead
 */
contract HyptoadzMint is ReentrancyGuard, Ownable {

    // ── Constants ──────────────────────────────────────────────
    uint256 public constant MINT_PRICE         = 0.077 ether;
    uint256 public constant MINT_DURATION = 48 hours;
    uint256 public constant MAX_PUBLIC         = 6_400;
    uint256 public constant AIRDROP_SUPPLY     = 3_600;
    uint256 public constant GIVEAWAY_SUPPLY    = 9;    // Reserved for community events
    uint256 public constant LP_TOADZ_AMOUNT    = 100_000_000 * 1e18;
    uint256 public constant TOADZ_PER_MINT     = 27_855 * 1e18;
    uint256 public constant MINT_REWARDS_TOTAL = 180_000_000 * 1e18;

    // Dynamic split constants
    // Creator starts 40%, drops -5% every 1,500 mints, min 20%
    // NFTs minted  Creator%   LP%
    // 1 - 1,500    40%        60%
    // 1,501-3,000  35%        65%
    // 3,001-4,500  30%        70%
    // 4,501-6,000  25%        75%
    // 6,001+       20%        80%  ← min creator
    uint256 public constant SPLIT_THRESHOLD  = 1_500; // every 1500 mints
    uint256 public constant CREATOR_DROP_PCT = 5;     // drops -5% per threshold
    uint256 public constant CREATOR_INITIAL  = 40;    // starts at 40%
    uint256 public constant CREATOR_MINIMUM  = 20;    // never below 20%

    // Token ID ranges
    uint256 private constant PUBLIC_ID_START   = AIRDROP_SUPPLY + 1; // 3,539
    uint256 private constant AIRDROP_ID_START  = 1;

    address public constant DEAD_ADDRESS =
        0x000000000000000000000000000000000000dEaD;

    // ── Immutables ─────────────────────────────────────────────
    address public immutable creatorWallet;
    address public immutable nftContract;
    address public immutable toadzToken;
    address public immutable dexRouter;
    address public immutable dexFactory;
    address public immutable nftStakingContract;

    // ── Mint state ─────────────────────────────────────────────
    uint256 public mintStart;
    uint256 public publicMinted;
    uint256 private _nextAirdropId = AIRDROP_ID_START;

    bool public airdropDone;
    bool public fundsSplit;
    bool public liquidityAdded;

    // Accumulated HYPE (split tracked per-mint dynamically)
    uint256 public creatorAccumulated;
    uint256 public lpAccumulated;

    // ── Random pool ────────────────────────────────────────────
    mapping(uint256 => uint256) private _availableIds; // slot => tokenId (0 = unset)
    uint256   private _remainingSupply;

    // ── Events ─────────────────────────────────────────────────
    event MintStarted(uint256 startTime, uint256 endTime);
    event AirdropBatchSent(uint256 count, uint256 totalSoFar);
    event PublicMint(
        address indexed minter,
        uint256 tokenId,
        uint256 toadzAmount,
        uint256 creatorPct,
        uint256 lpPct
    );
    event FundsSplit(
        uint256 creatorAmount,
        uint256 lpAmount,
        uint256 unsoldNFT,
        uint256 leftoverToadz
    );
    event LiquidityAdded(uint256 hypeAmount, uint256 toadzAmount);
    event DexPairSet(address pair);
    event AirdropCompleted(uint256 totalWallets, uint256 totalToadz);

    // ── Errors ─────────────────────────────────────────────────
    error MintNotStarted();
    error MintClosed();
    error MintStillOpen();
    error WrongPrice();
    error SoldOut();
    error AirdropAlreadyDone();
    error AirdropNotDone();
    error FundsAlreadySplit();
    error FundsNotSplitYet();
    error LiquidityAlreadyAdded();
    error InsufficientToadz();
    error ZeroAddress();
    error TransferFailed();

    // ── Constructor ────────────────────────────────────────────
    constructor(
        address _creatorWallet,
        address _nftContract,
        address _toadzToken,
        address _dexRouter,
        address _dexFactory,
        address _nftStakingContract
    ) Ownable(msg.sender) {
        if (_creatorWallet      == address(0)) revert ZeroAddress();
        if (_nftContract        == address(0)) revert ZeroAddress();
        if (_toadzToken         == address(0)) revert ZeroAddress();
        if (_dexRouter          == address(0)) revert ZeroAddress();
        if (_dexFactory         == address(0)) revert ZeroAddress();
        if (_nftStakingContract == address(0)) revert ZeroAddress();

        creatorWallet      = _creatorWallet;
        nftContract        = _nftContract;
        toadzToken         = _toadzToken;
        dexRouter          = _dexRouter;
        dexFactory         = _dexFactory;
        nftStakingContract = _nftStakingContract;
    }

    // ══════════════════════════════════════════════════════════
    // DYNAMIC SPLIT
    // ══════════════════════════════════════════════════════════

    /**
     * @notice Get current creator % based on how many have been minted
     * @dev Every 1,500 mints → creator share drops -5%, min 20%
     *
     * publicMinted  creatorPct  lpPct
     * 0             30%         70%
     * 1,500         35%         65%
     * 3,000         40%         60%
     * 4,500         45%         55%
     * 6,000         50%         50%
     */
    function currentCreatorPct() public view returns (uint256) {
        uint256 tiers = publicMinted / SPLIT_THRESHOLD;
        uint256 drop  = tiers * CREATOR_DROP_PCT;
        if (drop >= CREATOR_INITIAL - CREATOR_MINIMUM) {
            return CREATOR_MINIMUM;
        }
        return CREATOR_INITIAL - drop;
    }

    function currentLpPct() public view returns (uint256) {
        return 100 - currentCreatorPct();
    }

    /**
     * @notice Preview split for next mint
     */
    function nextMintSplit() external view returns (
        uint256 creatorPct,
        uint256 lpPct,
        uint256 creatorAmount,
        uint256 lpAmount
    ) {
        creatorPct    = currentCreatorPct();
        lpPct         = 100 - creatorPct;
        creatorAmount = MINT_PRICE * creatorPct / 100;
        lpAmount      = MINT_PRICE - creatorAmount;
    }

    // ══════════════════════════════════════════════════════════
    // SETUP
    // ══════════════════════════════════════════════════════════

    /**
     * @notice Start 48h mint window
     * @dev Checks:
     *      ① 50M $TOADZ in this contract (for LP)
     *      ② baseURI set on NFT (instant reveal)
     */
    function startMint() external onlyOwner {
        require(mintStart == 0, "Already started");
        require(
            IERC20(toadzToken).balanceOf(address(this)) >= LP_TOADZ_AMOUNT + MINT_REWARDS_TOTAL,
            "Transfer 280M TOADZ first"
        );
        require(
            IHyptoadzNFT(nftContract).isBaseURISet(),
            "Set baseURI on NFT contract first"
        );

        _remainingSupply = MAX_PUBLIC;
        mintStart = block.timestamp;
        emit MintStarted(mintStart, mintStart + MINT_DURATION);
    }

    // ══════════════════════════════════════════════════════════
    // AIRDROP
    // ══════════════════════════════════════════════════════════

    /**
     * @notice Airdrop to Hypurr holders — call in batches (~300/tx)
     * @dev Uses sequential IDs: 1 → 3,538
     *      Must complete BEFORE splitFunds() can be called
     */
    function airdropBatch(
        address[] calldata recipients,
        uint256[] calldata nftCounts,
        uint256[] calldata toadzAmounts
    ) external onlyOwner {
        if (airdropDone) revert AirdropAlreadyDone();
        require(recipients.length == nftCounts.length, "Length mismatch");
        require(recipients.length == toadzAmounts.length, "Length mismatch");

        uint256 len = recipients.length;

        // Batch mint NFTs via NFT contract
        IHyptoadzNFT(nftContract).airdropBatch(recipients, nftCounts, toadzAmounts);

        // Transfer $TOADZ per recipient
        for (uint256 i = 0; i < len; ) {
            if (toadzAmounts[i] > 0) {
                IERC20(toadzToken).transfer(recipients[i], toadzAmounts[i]);
            }
            unchecked { i++; }
        }

        emit AirdropBatchSent(len, _nextAirdropId - AIRDROP_ID_START);
    }

    /// @notice Mark airdrop as done — call after all batches sent

    /// @notice Mint reserved giveaway NFTs (max 9 total, from airdrop surplus)
    function markAirdropDone() external {
        require(!airdropDone, "Already done");
        require(
            IHyptoadzNFT(nftContract).totalAirdropped() >= AIRDROP_SUPPLY - GIVEAWAY_SUPPLY,
            "Airdrop not complete"
        );
        airdropDone = true;
        emit AirdropCompleted(IHyptoadzNFT(nftContract).totalAirdropped(), 0);
    }

    function mintGiveaway(address[] calldata recipients) external onlyOwner {
        if (!airdropDone) revert AirdropNotDone();
        require(recipients.length <= GIVEAWAY_SUPPLY, "Exceeds giveaway supply");
        require(_nextAirdropId - 1 + recipients.length <= AIRDROP_SUPPLY, "Exceeds airdrop supply");

        uint256[] memory nftCounts = new uint256[](recipients.length);
        uint256[] memory toadzAmounts = new uint256[](recipients.length);
        for (uint256 i = 0; i < recipients.length; ) {
            nftCounts[i] = 1;
            toadzAmounts[i] = 0; // giveaway NFTs — no $TOADZ attached
            unchecked { i++; }
        }
        IHyptoadzNFT(nftContract).airdropBatch(recipients, nftCounts, toadzAmounts);
    }

    
    function airdropRemaining() external view returns (uint256) {
        return AIRDROP_SUPPLY - (_nextAirdropId - 1);
    }

    // ══════════════════════════════════════════════════════════
    // PUBLIC MINT
    // ══════════════════════════════════════════════════════════

    /**
     * @notice Mint 1 Hyptoadz NFT + 10,500 $TOADZ
     * @dev - Random token ID assigned from pool
     *      - Dynamic split: creator% increases every 1,500 mints
     *      - HYPE accumulates in contract until T+48h
     */
    function mint() external payable nonReentrant {
        if (mintStart == 0)                                  revert MintNotStarted();
        if (block.timestamp >= mintStart + MINT_DURATION)   revert MintClosed();
        if (msg.value != MINT_PRICE)                        revert WrongPrice();
        if (publicMinted >= MAX_PUBLIC)                     revert SoldOut();

        // Get current split BEFORE incrementing publicMinted
        uint256 creatorPct = currentCreatorPct();
        uint256 lpPct      = 100 - creatorPct;

        publicMinted++;

        // Apply dynamic split
        uint256 creatorCut = msg.value * creatorPct / 100;
        uint256 lpCut      = msg.value - creatorCut;
        creatorAccumulated += creatorCut;
        lpAccumulated      += lpCut;

        // Random token ID
        uint256 tokenId = _randomTokenId();

        // Mint NFT
        IHyptoadzNFT(nftContract).mintPublic(msg.sender, tokenId);

        // Send $TOADZ
        bool sent = IERC20(toadzToken).transfer(msg.sender, TOADZ_PER_MINT);
        if (!sent) revert TransferFailed();

        emit PublicMint(msg.sender, tokenId, TOADZ_PER_MINT, creatorPct, lpPct);
    }

    // ══════════════════════════════════════════════════════════
    // RANDOM ID ENGINE
    // ══════════════════════════════════════════════════════════

    /**
     * @notice Pick random token ID using swap-and-pop Fisher-Yates
     * @dev Entropy: blockhash + timestamp + sender + counter
     *      Pseudo-random — sufficient for NFT minting
     *      No meaningful exploit incentive for miners
     */
    function _randomTokenId() private returns (uint256) {
        uint256 remaining = _remainingSupply;
        _remainingSupply--;

        if (remaining == 1) {
            uint256 lastId = _availableIds[0] != 0 ? _availableIds[0] : PUBLIC_ID_START;
            return lastId;
        }

        uint256 randomIndex = uint256(
            keccak256(abi.encodePacked(
                blockhash(block.number - 1),
                block.timestamp,
                msg.sender,
                publicMinted,
                remaining
            ))
        ) % remaining;

        uint256 tokenIdAtIndex = _availableIds[randomIndex] != 0
            ? _availableIds[randomIndex]
            : PUBLIC_ID_START + randomIndex;

        uint256 lastIndex   = remaining - 1;
        uint256 lastTokenId = _availableIds[lastIndex] != 0
            ? _availableIds[lastIndex]
            : PUBLIC_ID_START + lastIndex;

        if (randomIndex != lastIndex) {
            _availableIds[randomIndex] = lastTokenId;
        }
        // No need to zero lastIndex — mapping just stays, won't be accessed again

        return tokenIdAtIndex;
    }

    // _ensureSlot removed — using mapping instead

    // ══════════════════════════════════════════════════════════
    // POST-MINT — ANYONE CAN CALL AFTER 48H
    // ══════════════════════════════════════════════════════════

    /**
     * @notice STEP 1: Split accumulated funds + handle unsold
     * @dev Anyone can call after T+48h
     *      ① Records unsold NFTs as burned
     *      ② Sends leftover $TOADZ mint rewards → NFT staking pool
     *      ③ Sends creator's accumulated HYPE → creator wallet
     */
    function splitFunds() external nonReentrant {
        if (mintStart == 0)                                revert MintNotStarted();
        if (block.timestamp < mintStart + MINT_DURATION)  revert MintStillOpen();
        if (!airdropDone)                                  revert AirdropNotDone();
        if (fundsSplit)                                    revert FundsAlreadySplit();
        fundsSplit = true;

        // ① Record unsold NFT burn
        uint256 unsoldNFT = MAX_PUBLIC - publicMinted;
        if (unsoldNFT > 0) {
            IHyptoadzNFT(nftContract).recordUnsoldBurn(unsoldNFT);
        }

        // ② Leftover $TOADZ mint rewards → NFT staking pool
        uint256 toadzDistributed = publicMinted * TOADZ_PER_MINT;
        uint256 leftoverToadz    = MINT_REWARDS_TOTAL - toadzDistributed;
        if (leftoverToadz > 0) {
            bool toadzSent = IERC20(toadzToken).transfer(nftStakingContract, leftoverToadz);
            if (!toadzSent) revert TransferFailed();
            INFTStaking(nftStakingContract).addToPoolDirect(leftoverToadz);
        }

        // ③ Creator gets accumulated HYPE
        uint256 creatorAmount  = creatorAccumulated;
        creatorAccumulated = 0;
        (bool ok, ) = payable(creatorWallet).call{value: creatorAmount}("");
        if (!ok) revert TransferFailed();

        emit FundsSplit(creatorAmount, lpAccumulated, unsoldNFT, leftoverToadz);
    }

    /**
     * @notice STEP 2: Add liquidity to DEX
     * @dev Anyone can call after splitFunds()
     *      Accumulated LP HYPE + 50M $TOADZ → DEX
     *      LP token → 0xDEAD (permanent burn, no rug possible)
     */
    function addLiquidity() external nonReentrant {
        if (!fundsSplit)       revert FundsNotSplitYet();
        if (liquidityAdded)    revert LiquidityAlreadyAdded();
        liquidityAdded = true;

        uint256 hypeForLP = lpAccumulated;
        lpAccumulated = 0;

        // Verify $TOADZ balance
        uint256 toadzBal = IERC20(toadzToken).balanceOf(address(this));
        if (toadzBal < LP_TOADZ_AMOUNT) revert InsufficientToadz();

        // Safe approve pattern: reset to 0 first, then set amount
        IERC20(toadzToken).approve(dexRouter, 0);
        IERC20(toadzToken).approve(dexRouter, LP_TOADZ_AMOUNT);

        // Add LP — burn LP token to DEAD
        IDEXRouter(dexRouter).addLiquidityETH{value: hypeForLP}(
            toadzToken,
            LP_TOADZ_AMOUNT,
            LP_TOADZ_AMOUNT * 95 / 100, // 5% slippage max
            hypeForLP        * 95 / 100,
            DEAD_ADDRESS,               // LP token burned permanently
            block.timestamp + 300
        );

        emit LiquidityAdded(hypeForLP, LP_TOADZ_AMOUNT);
        // Auto set dex pair so tax activates
        address weth = IDEXRouter2(dexRouter).WETH();
        address pair = IDEXFactory(dexFactory).getPair(toadzToken, weth);
        if (pair != address(0)) {
            IToadzToken(toadzToken).setDexPair(pair);
            emit DexPairSet(pair);
        }

        // Unlock NFT transfers and $TOADZ trading
        IHyptoadzNFT(nftContract).enableTransfers();
        IToadzToken(toadzToken).enableTrading();
        IToadzToken(toadzToken).enableTax();
    }

    /**
     * @notice Split funds + add liquidity in one tx (convenience)
     * @dev Anyone can call after T+48h
     */
    function splitFundsAndAddLiquidity() external nonReentrant {
        // Step 1: splitFunds logic inline
        if (mintStart == 0)                                revert MintNotStarted();
        if (block.timestamp < mintStart + MINT_DURATION)  revert MintStillOpen();
        if (!airdropDone)                                  revert AirdropNotDone();
        if (!fundsSplit) {
            fundsSplit = true;
            uint256 unsoldNFT = MAX_PUBLIC - publicMinted;
            if (unsoldNFT > 0) {
                IHyptoadzNFT(nftContract).recordUnsoldBurn(unsoldNFT);
            }
            uint256 toadzDistributed = publicMinted * TOADZ_PER_MINT;
            uint256 toadzLeftover    = MINT_REWARDS_TOTAL > toadzDistributed
                ? MINT_REWARDS_TOTAL - toadzDistributed : 0;
            if (toadzLeftover > 0) {
                bool ok = IERC20(toadzToken).transfer(nftStakingContract, toadzLeftover);
                require(ok, "Leftover transfer failed");
                INFTStaking(nftStakingContract).addToPoolDirect(toadzLeftover);
            }
            uint256 creatorSend = creatorAccumulated;
            if (creatorSend > 0) {
                creatorAccumulated = 0;
                (bool ok,) = creatorWallet.call{value: creatorSend}("");
                if (!ok) revert TransferFailed();
            }
            emit FundsSplit(creatorSend, lpAccumulated, MAX_PUBLIC - publicMinted, toadzLeftover);
        }
        // Step 2: addLiquidity logic inline
        // Always enable transfers/trading even if no LP accumulated
        if (!IHyptoadzNFT(nftContract).transfersEnabled()) {
            IHyptoadzNFT(nftContract).enableTransfers();
            IToadzToken(toadzToken).enableTrading();
            IToadzToken(toadzToken).enableTax();
        }
        if (!liquidityAdded && lpAccumulated > 0) {
            uint256 hypeForLP = lpAccumulated;
            lpAccumulated = 0;
            uint256 toadzBal = IERC20(toadzToken).balanceOf(address(this));
            if (toadzBal >= LP_TOADZ_AMOUNT) {
                liquidityAdded = true; // set true only after balance check passes
                IERC20(toadzToken).approve(dexRouter, 0);
                IERC20(toadzToken).approve(dexRouter, LP_TOADZ_AMOUNT);
                IDEXRouter(dexRouter).addLiquidityETH{value: hypeForLP}(
                    toadzToken,
                    LP_TOADZ_AMOUNT,
                    LP_TOADZ_AMOUNT * 95 / 100,
                    hypeForLP        * 95 / 100,
                    DEAD_ADDRESS,
                    block.timestamp + 300
                );
                emit LiquidityAdded(hypeForLP, LP_TOADZ_AMOUNT);
                // Auto set dex pair so tax activates
                address weth2 = IDEXRouter2(dexRouter).WETH();
                address pair2 = IDEXFactory(dexFactory).getPair(toadzToken, weth2);
                if (pair2 != address(0)) {
                    IToadzToken(toadzToken).setDexPair(pair2);
                    emit DexPairSet(pair2);
                }
                // Unlock NFT transfers and $TOADZ trading
                IHyptoadzNFT(nftContract).enableTransfers();
                IToadzToken(toadzToken).enableTrading();
        IToadzToken(toadzToken).enableTax();
            }
        }
    }

    // ══════════════════════════════════════════════════════════
    // VIEWS
    // ══════════════════════════════════════════════════════════

    function mintTimeRemaining() external view returns (uint256) {
        if (mintStart == 0) return MINT_DURATION;
        uint256 end = mintStart + MINT_DURATION;
        if (block.timestamp >= end) return 0;
        return end - block.timestamp;
    }

    function isMintOpen() external view returns (bool) {
        return mintStart > 0
            && block.timestamp < mintStart + MINT_DURATION
            && publicMinted < MAX_PUBLIC;
    }

    function isSoldOut() external view returns (bool) {
        return publicMinted >= MAX_PUBLIC;
    }

    function remainingPublicSupply() external view returns (uint256) {
        return MAX_PUBLIC - publicMinted;
    }

    function totalHypeAccumulated() external view returns (uint256) {
        return creatorAccumulated + lpAccumulated;
    }

    function mintProgress() external view returns (uint256 minted, uint256 max) {
        return (publicMinted, MAX_PUBLIC);
    }

    /**
     * @notice Full split summary — useful for dashboard/website
     */
    function splitSummary() external view returns (
        uint256 currentCreator,
        uint256 currentLP,
        uint256 nextThresholdAt,
        uint256 creatorTotal,
        uint256 lpTotal
    ) {
        currentCreator  = currentCreatorPct();
        currentLP       = 100 - currentCreator;
        uint256 tier    = publicMinted / SPLIT_THRESHOLD;
        nextThresholdAt = (tier + 1) * SPLIT_THRESHOLD;
        if (nextThresholdAt > MAX_PUBLIC) nextThresholdAt = MAX_PUBLIC;
        creatorTotal    = creatorAccumulated;
        lpTotal         = lpAccumulated;
    }

    receive() external payable {}
}
