# Hyptoadz Smart Contracts

> HyperEVM Mainnet (Chain ID 999) · Solidity ^0.8.20 · OpenZeppelin v5

10,000 grumpy toads on HyperEVM. Mint for 0.077 HYPE, get 27,855 $TOADZ back. Stake to earn more. Everything is on-chain, permissionless, and transparent.

---

## Contract Addresses

> ⚠️ Addresses will be published immediately after mainnet deploy. Do not interact with unverified contracts.

| Contract | Address | Description |
|----------|---------|-------------|
| HyptoadzNFT | `— pending —` | ERC-721 NFT collection |
| ToadzToken | `— pending —` | ERC-20 $TOADZ token |
| HyptoadzMint | `— pending —` | Core mint + liquidity logic |
| NFTStaking | `— pending —` | NFT staking rewards |
| TokenStaking | `— pending —` | $TOADZ token staking |

**Network:** HyperEVM mainnet · **Chain ID:** 999 · **RPC:** `rpc.hyperliquid.xyz/evm`  
**DEX:** HyperSwap V2 · **Royalty:** 2.5% (ERC-2981)

---

## Contracts Overview

### HyptoadzNFT.sol — ERC-721

Standard ERC-721 with ERC-2981 royalty support.

**Key mechanics:**
- `MAX_SUPPLY = 10,000` — hard-coded, cannot be changed
- `AIRDROP_SUPPLY = 3,600` — IDs #1–#3,600 reserved for Hypurr airdrop
- `PUBLIC_SUPPLY = 6,400` — IDs #3,601–#10,000 for public mint
- **Instant reveal** — `baseURI` must be set before mint starts, metadata visible immediately
- **baseURI lock** — once `lockBaseURI()` is called, metadata cannot ever be changed
- **Transfer lock** — NFTs non-transferable until mint window ends and LP is added; enforced by `transfersEnabled` flag set only by `HyptoadzMint`
- **Rarity on-chain** — `rarityOf[tokenId]` stores 0–4 (Common/Uncommon/Rare/Legendary/Genesis), set by owner after generation

```solidity
// Rarity tiers
// 0 = Common    (~4,500 NFTs)
// 1 = Uncommon  (~3,500 NFTs)
// 2 = Rare      (~1,500 NFTs)
// 3 = Legendary (~400 NFTs)
// 4 = Genesis   (~100 NFTs) — top 1%
```

**Admin functions:**
| Function | Description | Callable by |
|----------|-------------|-------------|
| `setMintContract(address)` | Set mint contract — one-time only | Owner |
| `setBaseURI(string)` | Set IPFS metadata URI | Owner (before lock) |
| `lockBaseURI()` | Permanently lock metadata URI | Owner |
| `setRarityBatch(ids, rarities)` | Assign rarity to tokens in batches | Owner |

---

### ToadzToken.sol — ERC-20

Fixed supply ERC-20 with buy/sell tax mechanic.

**Supply: 550,000,000 $TOADZ — minted once at deploy, fixed forever.**

| Allocation | Amount | % | Destination |
|------------|--------|---|-------------|
| Mint rewards | 180,000,000 | 32.7% | HyptoadzMint contract |
| Hypurr airdrop | 105,000,000 | 19.1% | Airdrop contract |
| LP pool | 100,000,000 | 18.2% | LP contract (burned to 0xDead) |
| NFT staking | 90,000,000 | 16.4% | NFTStaking contract |
| Token staking | 50,000,000 | 9.1% | TokenStaking contract |
| Revenue share | 25,000,000 | 4.5% | RevShare contract |
| **Team / VC** | **0** | **0%** | **None** |

**Tax mechanic (5% buy/sell on DEX only):**
```
Buy  5% → 3.0% NFT staking pool | 1.0% burned to 0xDead | 1.0% LP
Sell 5% → 3.0% NFT staking pool | 1.0% burned to 0xDead | 1.0% LP
```

- Tax only applies to DEX trades — wallet-to-wallet transfers are **not taxed**
- Tax is disabled until `enableTax()` is called (after LP creation)
- System contracts (mint, staking) are permanently excluded from tax

**Transfer lock:** `tradingEnabled = false` until `addLiquidity()` is called by HyptoadzMint. Nobody can trade or transfer $TOADZ before LP is live — enforced on-chain.

---

### HyptoadzMint.sol — Core Mint Logic

The heart of the system. Handles airdrop, public mint, fund splitting, and LP creation.

**Mint price:** `0.077 HYPE`  
**$TOADZ per mint:** `27,855`  
**Max public supply:** `6,400`

#### Dynamic Split Mechanic

Every 1,500 NFTs minted, the creator share decreases by 5%, ensuring more HYPE flows to LP as mint progresses.

| NFTs minted | Creator % | LP % |
|-------------|-----------|------|
| 1 – 1,500 | 40% | 60% |
| 1,501 – 3,000 | 35% | 65% |
| 3,001 – 4,500 | 30% | 70% |
| 4,501 – 6,000 | 25% | 75% |
| 6,001 – 6,400 | 20% | 80% |

**At sold out:** ~157 HYPE to creator, ~340 HYPE to LP.

#### Random Token ID

Public mint uses Fisher-Yates shuffle with on-chain entropy:
```solidity
keccak256(blockhash(block.number - 1), block.timestamp, msg.sender, publicMinted, remaining)
```
Each minter gets a unique, unpredictable token ID from #3,601–#10,000.

#### Post-Mint Flow (Permissionless — anyone can call after 48h)

```
T+0h    → startMint() — 48h window opens
T+48h   → splitFunds() — creator gets HYPE, unsold $TOADZ → staking pool
T+48h   → addLiquidity() — LP HYPE + 100M $TOADZ → HyperSwap V2, LP burned to 0xDead
          OR call splitFundsAndAddLiquidity() to do both in one tx
```

`splitFunds()` and `addLiquidity()` are **permissionless** — anyone can call them after T+48h. The team cannot delay or block trading.

**Unsold mint rewards:** Any of the 178M $TOADZ mint rewards not distributed (if mint doesn't sell out) flow automatically into the NFT staking pool.

---

### NFTStaking.sol — NFT Staking

Stake Hyptoadz NFTs to earn daily $TOADZ rewards from the 90M staking pool.

**Daily pool:** `10,000 $TOADZ/day` distributed proportionally to all stakers.

#### Lock Period Multipliers

| Lock | Weight | Notes |
|------|--------|-------|
| No lock | 1× | Unstake anytime |
| 7 days | 1.6× | Early unstake = forfeit ALL rewards |
| 30 days | 3× | Early unstake = forfeit ALL rewards |
| 90 days | 5× | Early unstake = forfeit ALL rewards |
| 180 days | 8× | Maximum rewards |

#### Rarity Multipliers

| Rarity | Multiplier |
|--------|-----------|
| Common | 1× |
| Uncommon | 1.6× |
| Rare | 3× |
| Legendary | 6× |
| Genesis | 10× |

**Reward formula:**
```
daily_reward = DAILY_POOL × (lockWeight × rarityMult) / totalWeightedStakes
```

Rewards are proportional — more stakers = lower per-NFT reward (sustainable model, not inflationary).

> ⚠️ **Early unstake forfeits ALL pending rewards.** No partial claims on locked stakes.

---

### TokenStaking.sol — $TOADZ Token Staking

Stake $TOADZ tokens to earn dual rewards: $TOADZ + HYPE revenue share.

**Pool:** 50,000,000 $TOADZ  
**No lock required** — stake and unstake anytime  
**Minimum stake:** Any amount

**Reward sources:**
1. **$TOADZ pool** — from the 50M allocation + 60% of buy/sell tax
2. **HYPE revenue share** — 50% of secondary royalties (2.5% royalty rate), distributed proportionally weekly

**Distribution:** Per-share accumulator model (gas efficient, no loops).

---

## Security Model

### No Rug Possible

```solidity
// LP tokens burned to 0xDead permanently — in HyptoadzMint.addLiquidity():
IDEXRouter(dexRouter).addLiquidityETH{value: hypeForLP}(
    toadzToken,
    LP_TOADZ_AMOUNT,
    LP_TOADZ_AMOUNT * 95 / 100,
    hypeForLP * 95 / 100,
    DEAD_ADDRESS,   // ← LP token burned here, cannot be removed
    block.timestamp + 300
);
```

- LP burned at creation — enforced by contract, not by trust
- No admin override for LP removal
- Owner role is limited to setup functions only

### Transfer Lock Enforcement

```solidity
// In HyptoadzNFT._update():
if (!transfersEnabled) {
    require(
        from == address(0) || from == mintContract,
        "Transfers locked until mint ends"
    );
}

// In ToadzToken._update():
if (!tradingEnabled) {
    require(
        isExcludedFromLock[from] || isExcludedFromLock[to] || from == address(0),
        "Trading not yet enabled"
    );
}
```

Both locks are released simultaneously when `addLiquidity()` is called — everyone unlocks at the same time.

### Owner Capabilities (Post-Deploy)

After deployment, the owner can:
- ✅ Set `baseURI` (once, before mint)
- ✅ Lock `baseURI` permanently
- ✅ Assign rarity scores after generation
- ✅ Start mint window
- ✅ Run airdrop batches
- ✅ Enable tax after LP creation

The owner **cannot:**
- ❌ Change mint price
- ❌ Change $TOADZ per mint
- ❌ Remove LP or change LP destination
- ❌ Mint extra tokens or NFTs
- ❌ Change token supply
- ❌ Override transfer lock timing
- ❌ Change tax rates or distribution percentages

---

## Dependencies

- [OpenZeppelin Contracts v5](https://github.com/OpenZeppelin/openzeppelin-contracts) — ERC721, ERC20, Ownable, ReentrancyGuard, ERC2981
- HyperSwap V2 Router/Factory (HyperEVM native DEX)

---

## License

MIT — see [LICENSE](LICENSE)

---

## Links

- Website: [hyptoadz.com](https://hyptoadz.com)
- Twitter: [@HyptoadzNFT](https://x.com/hyptoadznft)
- Docs: [hyptoadz.github.io/docs](https://hyptoadz.github.io/docs)
- Airdrop snapshot: [Gist ↗](https://gist.github.com/Hyptoadz/5286c9b27aced9ca62efe052b5978a95)
