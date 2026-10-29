# STARDUST Energy contracts (Foundry)

Stake STARDUST or pay USDG to get **ENERGY**, a normal ERC-20 in your wallet. **Deposit** it into your **EnergyVault**
account: that on-chain balance is what the API spends, and usage is charged (burned) on-chain in batches.
Dashboard: `/dashboard/stake`, `/dashboard/buy-energy`, `/dashboard/liquidity-pool`, `/dashboard/vault`.

```
 stake STARDUST ──claim()──▶ mint ─┐                                            API requests (instant, reserved off-chain)
                                   ├─▶ ENERGY ──deposit()──▶ EnergyVault ◀──────────────┘
 pay USDG ──────buy()──────▶ ──────┘   (wallet)  ◀─withdraw()─ (per wallet) ──charge() every hour: burn what was used
     └─ USDG: lpFeeBps (1–10%, now 10%) -> EnergyLiquidityPool (ENERGY stakers), the rest -> treasury (deployer),
        same transaction. Staked ENERGY is never sold: LPs only earn.
```

```
contract/stake/
├─ src/EnergyToken.sol         ENERGY: ERC-20 + permit, MINTER_ROLE (staking + store), topUp() burns (AccessControlDefaultAdminRules)
├─ src/StardustStaking.sol     stake STARDUST, Energy pool per day; claim() mints ENERGY (SafeERC20, Ownable2Step, ReentrancyGuard, Pausable)
├─ src/EnergyStore.sol         pay USDG -> buy() mints ENERGY; USDG split: stakers (lpFeeBps) / treasury
├─ src/EnergyLiquidityPool.sol stake ENERGY (never sold), earn the stakers' USDG share pro rata (1 day lock)
├─ src/EnergyVault.sol         the on-chain Energy account: deposit / delayed withdraw / batched charge() that burns usage
├─ src/StardustToken.sol       TESTNET ONLY stand-in for STARDUST (fixed 1B supply, no mint)
├─ src/TestUSDG.sol            TESTNET ONLY stand-in for USDG (6 decimals, faucet 1,000/day)
├─ script/DeployEnergy.s.sol   deploys token + staking + store, grants MINTER_ROLE (testnet: test tokens, mainnet: real ones)
├─ script/DeployVault.s.sol    deploys EnergyVault for the token, gives the backend's settler wallet SETTLER_ROLE
├─ script/DeployPool.s.sol     deploys pool + new store, moves MINTER_ROLE from the old store and pauses it; mints and
│                              stakes nothing (the pool starts empty). DeployEnergy mints DEV_MINT (100,000) to the dev wallet
├─ test/                       99 tests: unit + fuzz (2,000 runs) + invariant (256 runs x 120 calls, fail on revert)
└─ deployments/                46630-energy.json, 46630-vault.json, 46630-pool.json (current); older: 46630*.json
```

## How it works

**ENERGY token** (`EnergyToken.sol`)
- Name "Stardust Energy", symbol ENERGY, 18 decimals. Transferable; shows in MetaMask after "Import token" (the dashboard
  has an "Add ENERGY to wallet" button).
- **Unlimited supply, controlled issuance:** there is no cap. New ENERGY only comes from the two minters (MINTER_ROLE):
  the staking pool (a fixed amount per day) and the store (only against USDG paid). The admin grants/revokes the role but
  cannot mint or move tokens itself; admin hand-over has a 1 day delay.
- `topUp(amount)` burns ENERGY (event `EnergyToppedUp`). The vault uses it to burn charged usage; a holder calling it
  directly gets the amount credited off-chain (legacy path, spent before the vault). Circulating supply = minted − burned.

**Vault** (`EnergyVault.sol`): the account the API spends
- `deposit(amount)` / `depositFor(user, amount)` move ENERGY in. `spendable` = balance − pending withdrawal.
- `charge(batchId, users, amounts)` (SETTLER_ROLE = the backend's settlement wallet) lowers balances by metered usage and
  burns the total. `batchId` must equal `nextBatchId`, so a batch is never applied twice; a charge never takes more than a
  balance, and never more than `maxChargePerUser` (1,000,000) per batch, which limits a leaked settler key.
- `requestWithdraw(amount)` → `withdraw()` after `withdrawDelay` (2 hours, longer than the settlement period): usage made
  before the request is always charged first; payout is capped at what is left. `cancelWithdraw()` anytime.
- The backend can only lower balances by usage; it can never raise one or move ENERGY elsewhere. Admin: settler role,
  delay (1 h–7 d), charge cap, pause (new deposits only), with a 1 day admin hand-over delay.
- Measured: a settlement costs ~2,640 gas per user (1,000 users ≈ 2.6M gas, ~8% of a block).

**Staking** (`StardustStaking.sol`)
- Every second `dailyPool / 86400` Energy (default 100,000/day) is shared by all earning positions by weight
  (amount × tier multiplier: 1 day 1x, 7 days 1.25x, 30 days 1.6x). Time with nobody staked issues nothing.
- `claim()` mints what you earned as ENERGY into your wallet. STARDUST comes back 100% on `unstake()` after the lock.
- Exact expiry: lock ends round up to the next full hour, and the position leaves the pool exactly then (no keeper needed).
- No dust: minimum stake 1 STARDUST, at most 100 open positions per wallet (claim with 100 positions ≈ 2.7M gas, ~8% of a
  block), 1e30 precision with rounding always down, fee-on-transfer safe.
- Owner: `setDailyPool` (≤ 1e12/day, from now on), `setTier` (new stakes only), `pause` (new stakes only; unstake and claim
  always work), `rescueToken` (never staked STARDUST). Two-step ownership, renounce disabled.

**Store** (`EnergyStore.sol`)
- `buy(amount, minEnergy)`: 1 USDG = 1,000 ENERGY, min 5 / max 100,000 USDG, +10% from 50 USDG, +20% from 200 USDG.
  The Energy is minted as ENERGY into the buyer's wallet.
- USDG split, in the same transaction: `lpFeeBps` (default 200 = 2%, owner sets 100–1,000 with `setLpFee`; testnet: 1,000
  = 10%) goes to the liquidity pool for the ENERGY stakers (nothing while nobody stakes); everything else goes to
  `treasury` (the deployer wallet). `lpUsdg + treasuryUsdg == received` exactly and the store's USDG balance is the same before and after (invariant-tested);
  the treasury can never be set to the pool. `previewSplit(amount)` shows the split; event `PurchaseSplit`.
- `minEnergy` (the frontend passes `quote()`) reverts the purchase if the price changes while it is pending.

**Liquidity pool** (`EnergyLiquidityPool.sol`): stake ENERGY, earn USDG
- `deposit(amount)` stakes ENERGY. It is never sold or spent: `withdraw(amount)` returns exactly that, 24 h after the
  LP's last deposit (so nobody can stake right before a big purchase and leave right after with its fee).
- Every purchase sends `lpFeeBps` of its USDG here and shares it right away between everyone staked, by stake
  (`earned(lp)`, paid by `claim()` and on deposit/withdraw). More ENERGY staked = smaller share each; the total is always
  `lpFeeBps` of sales.
- No admin: nobody can move staked ENERGY or the LPs' USDG elsewhere. Rounding dust (< 1 USDG unit) stays in the pool.

## Test

```bash
forge test                                   # 115 tests
FOUNDRY_PROFILE=ci forge test                # heavier fuzz (20,000 runs) and invariants (1,000 runs x 200)
forge coverage --no-match-coverage "(test|script)/" --report summary
```

### Coverage

2026-10-29, `forge 1.7.1`: 115 tests in 14 suites, 115 passed, 0 failed.

| File                        | % Lines           | % Statements      | % Branches       | % Funcs           |
| --------------------------- | ----------------- | ----------------- | ---------------- | ----------------- |
| src/EnergyLiquidityPool.sol | 100.00% (66/66)   | 100.00% (83/83)   | 100.00% (12/12)  | 100.00% (9/9)     |
| src/EnergyStore.sol         | 100.00% (100/100) | 100.00% (120/120) | 100.00% (17/17)  | 100.00% (20/20)   |
| src/EnergyToken.sol         | 100.00% (7/7)     | 100.00% (6/6)     | 100.00% (1/1)    | 100.00% (2/2)     |
| src/EnergyVault.sol         | 100.00% (75/75)   | 100.00% (92/92)   | 100.00% (17/17)  | 100.00% (13/13)   |
| src/StardustArt.sol         | 100.00% (139/139) | 99.49% (194/195)  | 95.83% (23/24)   | 100.00% (25/25)   |
| src/StardustStaking.sol     | 99.48% (193/194)  | 99.59% (241/242)  | 100.00% (37/37)  | 100.00% (26/26)   |
| src/StardustToken.sol       | 100.00% (2/2)     | 100.00% (1/1)     | 100.00% (0/0)    | 100.00% (1/1)     |
| src/TestEthUsdFeed.sol      | 100.00% (14/14)   | 100.00% (8/8)     | 100.00% (0/0)    | 100.00% (6/6)     |
| src/TestUSDG.sol            | 100.00% (9/9)     | 100.00% (10/10)   | 100.00% (1/1)    | 100.00% (3/3)     |
| **Total**                   | **99.83% (605/606)** | **99.74% (755/757)** | **99.08% (108/109)** | **100.00% (105/105)** |

The one uncovered line in StardustStaking is an unreachable `return`. Invariants include: vault holds exactly the sum of balances; charged ENERGY is burned; pending
withdrawal ≤ balance; USDG paid = LP part + treasury part, treasury balance = its part, store keeps 0; LP USDG = in pool +
claimed, and the pool can always pay everything owed; LP ENERGY = LP wallets + staked (never lost); ENERGY supply =
LP ENERGY + sold; Energy issued ≤ pool × time.

## Deploy

| | Testnet | Mainnet |
|---|---|---|
| Chain ID | 46630 | 4663 |
| RPC | `https://rpc.testnet.chain.robinhood.com/rpc` | `https://rpc.mainnet.chain.robinhood.com/rpc` |
| Explorer | https://explorer.testnet.chain.robinhood.com | |

> ⚠️ If the RPC does not answer, your network may be blocking `*.robinhood.com`: try another DNS resolver or a VPN, and check
> with `cast chain-id --rpc-url robinhood_testnet` (must print 46630).

```bash
cast wallet import stardust-deployer --interactive            # once; the key is never written to a file
forge script script/DeployEnergy.s.sol --rpc-url robinhood_testnet --account stardust-deployer \
  --broadcast --slow --gas-estimate-multiplier 400
```

- Env: `STARDUST_TOKEN`, `USDG_TOKEN` (reuse existing tokens; empty on testnet = deploy test ones), `TREASURY`, `OWNER`,
  `TEST_WALLET`, `DAILY_POOL`, `MIN_STAKE`, `DEV_MINT` (the dev wallet's ENERGY at the token's first minting, default
  100,000: minted once with a temporary MINTER_ROLE that is revoked in the same broadcast; nothing is staked, the
  liquidity pool always starts at 0). Mainnet requires `STARDUST_TOKEN` (launchpad token) and `TREASURY` (multisig)
  and always uses the real USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`. With `OWNER` ≠ deployer the ENERGY admin is
  handed over with a 1 day delay (`acceptDefaultAdminTransfer`).
- Arbitrum-based chains add an L1 data fee: forge's gas estimate is too low without `--gas-estimate-multiplier 400`.
- Verify: `forge verify-contract <addr> <src:Name> --verifier blockscout --verifier-url https://explorer.testnet.chain.robinhood.com/api/ --chain 46630`.

### Deployed on mainnet (Robinhood Chain 4663, 2026-10-29, verified on Sourcify)

| Contract | Address | Notes |
|---|---|---|
| **ENERGY** (EnergyToken) | [`0x5a0Fc967F2b3398110AEb010026dBb1A80ca2d6a`](https://robinhoodchain.blockscout.com/address/0x5a0Fc967F2b3398110AEb010026dBb1A80ca2d6a) | block 100886866; 100,000 dev mint to the deployer, minter role given up again |
| **EnergyLiquidityPool** | [`0x93dcF00243D4F00aB95930433fE825fF863422BC`](https://robinhoodchain.blockscout.com/address/0x93dcF00243D4F00aB95930433fE825fF863422BC) | starts empty, no owner |
| **EnergyStore** | [`0x55241EDbAd565105B3C4d7C24B7c702Aa0F89c73`](https://robinhoodchain.blockscout.com/address/0x55241EDbAd565105B3C4d7C24B7c702Aa0F89c73) | real USDG `0x5fc5…d168`, stakers' share 10%, treasury = deployer |
| **EnergyVault** | [`0xE46AFB181728c5d227034e79A89bEC8E191b2A5e`](https://robinhoodchain.blockscout.com/address/0xE46AFB181728c5d227034e79A89bEC8E191b2A5e) | block 100889386; settler `0xA1d6F59E4cA2EFeeaEf643637b4EC0c609534459` (key only on the server) |
| **StardustArt** (Stardust Genesis / SGEN) | [`0x7084541C1eF9eF328535936fedadA34666DA18d0`](https://robinhoodchain.blockscout.com/address/0x7084541C1eF9eF328535936fedadA34666DA18d0) | block 100890202; Chainlink ETH/USD, metadata `https://stardustllm.xyz/api/art/` |
| **StardustStaking** | not yet | deployed after the STARDUST launchpad token exists, see below |

Owner / treasury of everything: `0x4D6D25f667D5Ab10815317575Eb9A575A4064A01`.

**Adding staking once STARDUST is live** (the broadcaster must be the ENERGY admin):

```
STARDUST_TOKEN=<launchpad token> ENERGY_TOKEN=0x5a0Fc967F2b3398110AEb010026dBb1A80ca2d6a \
  forge script script/DeployStaking.s.sol:DeployStaking --rpc-url robinhood_mainnet --private-key <key> \
  --broadcast --slow --gas-estimate-multiplier 400
forge verify-contract <staking> src/StardustStaking.sol:StardustStaking --chain 4663 --verifier sourcify \
  --rpc-url robinhood_mainnet --guess-constructor-args
```

Then set `NEXT_PUBLIC_STAKING_ADDRESS`, `NEXT_PUBLIC_STAKING_FROM_BLOCK`, `NEXT_PUBLIC_STARDUST_ADDRESS` (frontend) and
`STAKE_CONTRACT`, `STAKE_FROM_BLOCK` (backend) and rebuild.

Verification: Blockscout's API is behind a Cloudflare challenge, so verify through Sourcify (`--verifier sourcify`);
Blockscout reads Sourcify matches.

### Deployed on testnet (all verified on the explorer)

| Contract | Address | |
|---|---|---|
| **ENERGY** (EnergyToken) | [`0x33422316E207efC56b46f01F33FcDB39cD46AA73`](https://explorer.testnet.chain.robinhood.com/address/0x33422316E207efC56b46f01F33FcDB39cD46AA73) | block 144454271 |
| **StardustStaking v3** | [`0x0a8f9fcAa10da55EBe234e555789Ea1ECd0a5FAF`](https://explorer.testnet.chain.robinhood.com/address/0x0a8f9fcAa10da55EBe234e555789Ea1ECd0a5FAF) | claim mints ENERGY |
| **EnergyStore v5** | [`0x7d8444a11b2C5C55EffA9f6407f5e703f0B0afF1`](https://explorer.testnet.chain.robinhood.com/address/0x7d8444a11b2C5C55EffA9f6407f5e703f0B0afF1) | mints ENERGY; 10% of USDG to stakers, 90% to deployer `0x4D6D…4A01` |
| **EnergyLiquidityPool** | [`0x3b77790978E3d3c785950bf7cc0649aaa10533BD`](https://explorer.testnet.chain.robinhood.com/address/0x3b77790978E3d3c785950bf7cc0649aaa10533BD) | block 144607488; started **empty** (nothing staked by the team) |
| STARDUST (test) | [`0x5a0Fc967F2b3398110AEb010026dBb1A80ca2d6a`](https://explorer.testnet.chain.robinhood.com/address/0x5a0Fc967F2b3398110AEb010026dBb1A80ca2d6a) | 1B fixed supply |
| USDG (TestUSDG) | [`0x6fD90569C386B1359F43353a097A06B416Ea7a87`](https://explorer.testnet.chain.robinhood.com/address/0x6fD90569C386B1359F43353a097A06B416Ea7a87) | 6 decimals, faucet |
| **EnergyVault** | [`0xA9f655a93258852318d9325c0fec676d6F955D47`](https://explorer.testnet.chain.robinhood.com/address/0xA9f655a93258852318d9325c0fec676d6F955D47) | block 144469815; settler `0x332C…6e87` (backend hot wallet) |
| Owner / ENERGY + vault admin | `0x4D6D25f667D5Ab10815317575Eb9A575A4064A01` | |

Older deployments (credited the account directly, before ENERGY was a token), **paused** on 2026-10-29:
staking v2 `0xd5E5…949d` (unstake/claim still work; still indexed by the backend as a legacy source until its last
position is withdrawn), store v1 `0x6b03…dC48`, staking v1 `0x93dc…22BC` (retired). Store v2 `0xe526…333B` (minted
everything, treasury `0x7334…a5BF`) was paused and lost MINTER_ROLE when v3 went live. Store v4 `0x15c3…3D01` + pool `0xCD9c…3D56` (100,000 ENERGY pre-staked by the deployer) were replaced on 2026-10-29
by v5 + a pool that starts empty, for transparency; the deployer withdraws its stake from the old pool after its lock
(2026-10-30 02:36 UTC). Store v3 `0x09D0…Bb69` + its
sell-from-pool pool `0xF6D0…3C64` (LPs' ENERGY was sold, so LPs lost value) were replaced the same day: v3 paused and
lost MINTER_ROLE; the deployer's 110,000 ENERGY in that old pool can be withdrawn from 2026-10-30 02:05 UTC.

End-to-end on testnet (2026-10-29): stake 1,000 STARDUST on v3 → claim → 20.83 ENERGY in the wallet; buy 10 USDG →
+10,000 ENERGY; `topUp(5,000)` → 5,000 ENERGY burned → the backend credited **+5,000 Energy** to the account a few seconds
later (tx `0x62dd…e1db`). Claims and purchases on the new contracts are never credited directly (no double counting).

Vault on testnet (2026-10-29): the off-chain balances from before the vault (129,725 + 992 Energy) were minted once and
deposited with `depositFor` into their owners' vaults (the deployer's temporary MINTER_ROLE was revoked right after), then
removed from the database. End-to-end: 3 paid API requests from the 992 vault → reserved off-chain → batch #0
`charge()` signed by the backend settler: vault 992 → **989** ENERGY, 3 burned (tx `0x95c6…8a6d`).

Liquidity pool on testnet (2026-10-29, current design: ENERGY stays): the deploy minted 100,000 ENERGY once to the
deployer (temporary MINTER_ROLE, revoked in the same broadcast) and staked it. A fresh wallet bought 10 USDG → 10,000
ENERGY **minted** to it, the pool stake stayed **100,000**, the pool got **0.2 USDG** (2%) and the deployer **9.8 USDG** in
the same transaction (`0x1a83…cc36`); `claim()` paid the 0.2 USDG (`0x67d5…8c35`). The LP fee was then set to **10%**
(`setLpFee(1000)`, `0xad8d…13c2`). Dashboard page: `/dashboard/liquidity-pool`.

## NFT: Attacker × Defender (`StardustArt.sol`)

- ERC-721, **public mint only** at a flat **$0.20** per NFT, paid in ETH at the Chainlink ETH/USD price (mainnet feed
  `0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9`; testnet has no Chainlink feeds, so `TestEthUsdFeed.sol` stands in).
  The ETH goes to the treasury (dev wallet) in the same transaction; extra is refunded; the contract never holds ETH.
- **100,000 max, ever.** Release: 50 every week + 100 every 30 days from `startTime`, cumulative (unminted ones carry
  over). `released()`, `available()`, `nextReleaseAt()` drive the countdown. Up to 10 per mint.
- **Event airdrop**: closed by default; the owner `openAirdrop(n)` (reserved inside the 100,000), then lists the
  winners' wallets with `addAirdropWinners(addrs)`; each winner claims on the mint page with `claimAirdrop()` (free, gas
  only, works even while the public mint is paused). `airdrop(addrs)` sends directly instead; `revokeAirdrop(winner)`
  takes back an unclaimed one; `closeAirdrop()` returns the unassigned part. The dev wallet sees an admin box on the page.
- **Traits**: each token stores its L2 mint block (ArbSys); metadata derives rarity / faction / traits from the hash of
  the next block (unknown when minting). **Rarity supply is exact**: a 100,000-card deck (47,500 Common … 2,000 Mythic)
  drawn without replacement in mint order (`workspace/src/lib/stardust/art.ts` `drawTier`), so each tier ends at exactly
  its supply; the server caches the drawn tiers (`ART_RARITY_CACHE`, rebuilt from chain data if lost). The artwork
  always matches rarity + faction (one artwork per tier per faction). `tokenURI` = `https://stardust.xyz/api/art/{id}`, `contractURI` =
  `.../collection` (OpenSea format; OpenSea lists Robinhood Chain mainnet as `robinhood`). On-chain name / ticker:
  **Stardust Genesis / SGEN** on mainnet (testnet deploys: "Stardust Genesis (testnet)" / tSGEN).
- Tests: unit + fuzz (payment always ≥ $0.20, refund exact, schedule) + invariants (supply, schedule, every wei to the
  treasury). `StardustArt` 100% lines.
- Testnet: **StardustArt** "Stardust Genesis (testnet)" / tSGEN [`0x431Bf5d2235BFD3E267B66b71b2fAcB9F4d0673d`](https://explorer.testnet.chain.robinhood.com/address/0x431Bf5d2235BFD3E267B66b71b2fAcB9F4d0673d),
  test feed `0xF865…C4bD` ($2,311). E2E 2026-10-29: 10 minted in one tx → dev wallet +exactly the price, contract 0 ETH;
  airdrop opened with 5, the dev wallet listed as a winner (1 to claim). The first test deployment (`0x7592…8E8b`, no
  claim) is retired.
