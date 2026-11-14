# Cross-chain numbers: how Pip checks every amount

Code: `server/src/pay/xchain/` (`units.ts`, `check.ts`, `decimals.ts`, `assets.ts`). Tests: `server/test/xchain.test.ts`.

Pip pays any supported token on any supported chain from the user's NEAR account through NEAR Intents 1Click.
The phone signs one NEAR transaction that sends the exact max input to 1Click's deposit account.
The checks below run on every quote. A hard mismatch refuses the quote (HTTP 422).
A number with no second source comes back `verified: false` with a `not_verified` list, and the server makes no signable payment.

## Rule 1: amounts are integers in base units

- Every amount is a `bigint` in the token's smallest unit. No `parseFloat`, no `Number` on an amount.
- Text becomes base units with string math (`toBase`). Too many fraction digits is refused, never rounded: `0.0000001 USDC` (7 digits, USDC has 6) is refused.
- Base units become text with the same decimals (`fromBase`).
- USD prices are read from their decimal text into an integer in 1e-12 USD (`parsePrice`). USD values are integers in micro-dollars (`usdValue`, rounded down).
- Shown rates are floored, so a rate never overstates what the recipient gets.

## Rule 2: decimals belong to (chain, contract), never to a symbol

| Token | Chain | Decimals |
| --- | --- | --- |
| USDC | NEAR, Ethereum, Base, Arbitrum, Solana | 6 |
| USDC, USDT | BNB Chain | 18 |
| USDT | NEAR, Ethereum, Tron, Solana | 6 |
| NEAR, wNEAR | NEAR | 24 |
| ETH | Ethereum, Base, Arbitrum | 18 |
| SOL | Solana | 9 |
| BTC | Bitcoin | 8 |

- The origin and the destination each take decimals from the 1Click token list row for that exact asset id (`findToken` refuses a missing or ambiguous row).
- Each is then read from its own chain: `ft_metadata` on NEAR, `decimals()` by `eth_call` on EVM and Tron, the mint account on Solana, the chain's fixed decimals for a native coin.
- A mismatch or an unreadable value refuses the quote: `destination USDC decimals differ: token list 18, chain 6`.
- The typed amount uses the side it names: the destination for exact output, the origin for exact input.

## Rule 3: the quote must answer our request

- Echo: `dry`, `swapType`, `originAsset`, `destinationAsset`, `amount`, `recipient`, `refundTo`, `slippageTolerance`, `depositMode`, `deadline` and the three type fields must equal what Pip sent. Slippage above `XCHAIN_SLIPPAGE_BPS` is refused.
- Shape: `amountIn`, `minAmountIn`, `amountOut`, `minAmountOut` are positive integers; minimums are not above amounts.
- Decimals inside the quote: `toBase(amountInFormatted, originDecimals)` must equal `amountIn`, and the same for out. A provider using wrong decimals fails here.
- Exactness: exact output needs `amountOut = minAmountOut = typed`. Exact input needs `amountIn = typed`.
- Worst case: `minAmountOut >= amountOut × (10000 − slippage) / 10000` (BigInt, floored), for both modes.
- Deposit: a NEAR account (64 hex or `.near`), no memo, and a deadline at least 17 minutes away (the intent can be signed for 2 minutes and expires at least 15 minutes before the deadline).

## Rule 4: two price sources per asset

- Sources, in order: CoinGecko (by the token row's `coingeckoId`), Relay token price v2, the 1Click token list price.
- An asset's price is verified when at least two sources answer, all are within 2% of the first (`XCHAIN_MAX_PRICE_SPREAD_BPS`, default 200), and one of them is independent of 1Click: CoinGecko, or Relay at an address from Pip's own table. A Relay price at a contract address taken from 1Click's row is labelled `relay-via-1click-address` and does not count as independent.
- Relay has no NEAR chain. NEAR-side stablecoins and ETH are priced on Relay through their Ethereum twin; NEAR and wNEAR have only CoinGecko and the 1Click list.
- Fewer than two agreeing sources: `verified: false`, no intent.

## Rule 5: fee and rate limits

- Value in = max input at the verified origin price. Value out = the minimum output (the worst case) at the verified destination price.
- Fee (USD) = value in minus value out. Fee (bps) = fee / value in, rounded up. Fee in origin tokens = max input minus the minimum output's worth in origin units.
- Refuse when the fee is above 3% (`XCHAIN_MAX_FEE_BPS`, 300) or above $1 (`XCHAIN_MAX_FEE_USD_MICRO`, 1000000).
- Refuse when 1Click's own `amountInUsd` or `amountOutUsd` is more than 2% from Pip's value (`XCHAIN_MAX_RATE_DIFF_BPS`, 200).
- With exact output, the max input includes the slippage buffer (`XCHAIN_SLIPPAGE_BPS`, default 100). 1Click refunds the unused part to the user's NEAR account, so the shown fee is the most it can cost.

## Rule 6: fresh quotes only

- An xchain intent can be signed for 2 minutes after its quote. If the quote is over 60 seconds old at `/unsigned`, the server quotes again, runs every check again, and moves the intent onto the new numbers and deposit account; the `/unsigned` answer carries the new card (`xchain`). A failed re-check blocks the build.
- Caps (per payment and per day, per origin token) apply to the max input, in the same SQLite transaction as plain sends.

## Worked example (a live dry quote, 2026-11-14)

"Send 5 USDC on BNB Chain to 0xd8da…9da3, from my USDC on NEAR", exact output.

1. Decimals: USDC on NEAR = 6 (list) = 6 (`ft_metadata`). USDC on BNB = 18 (list) = 18 (`decimals()` = `0x…12`).
2. Typed: `5` at 18 decimals = `5000000000000000000`.
3. Quote: `amountOut = minAmountOut = 5000000000000000000` ("5.0" at 18 decimals matches). `amountIn = 5061486` ("5.061486" at 6 decimals matches). `minAmountIn = 5010971`.
4. Prices: USDC $0.999645 (CoinGecko), $0.999694 / $0.999753 (Relay), $0.999685 (1Click). All within 2%.
5. Value in = 5061486 × 0.999645 / 10^6 = $5.059689. Value out = $4.998225.
6. Fee (exact output, so minimum output = 5) = $0.061464 = 122 bps (below 300 bps and $1). Fee in tokens = 0.061486 USDC. 1Click's USD figures ($5.059892, $4.998425) are within 2% of Pip's.
7. Rate = 5000000000000000000 × 10^6 / 5061486 / 10^18 = 0.987852184121422048 USDC per USDC, floored.
8. Card: you pay at most 5.061486 USDC (NEAR); they get exactly 5 USDC on BNB Chain; fee 0.061486 USDC ($0.06); ETA 23 s; refunds to your NEAR account.

The raw live output is in `server/test/fixtures/xchain-live-dry-check.txt`.

## Pinned assets (top tokens)

Generated on 2026-11-14 into `server/src/pay/xchain/pins.ts` from read-only calls: the 1Click token list, CoinGecko `/coins/list?include_platform=true` (contract to id; native coins from a fixed chain table), and each contract's decimals read on its own chain. A row marked N is blocked: the quote answers `verified: false` and no intent is made. When 1Click's own CoinGecko id differs (bridged tokens such as USDC on BNB Chain), the pin records it as `oneclickCoingeckoId` and prices with CoinGecko's id.

Not in 1Click's list today, so not payable: native TON (only USDT on TON is listed, and it is blocked), LINK/UNI/AAVE/PEPE/SHIB/DAI outside Ethereum. Rows on chains Pip has no address check for (Aptos, Starknet, Stellar, Hypercore, Miden, Monad, X Layer, Scroll, Abstract) are left out.

| Symbol | Chain | Contract | Decimals | Decimals source | CoinGecko id | Verified |
| --- | --- | --- | --- | --- | --- | --- |
| AAVE | eth | `0x7fc66500c84a76ad7e9c93437bfc5ac33e2ddae9` | 18 | decimals() | aave | Y |
| ADA | cardano | native | 6 | native constant | cardano | Y |
| ARB | arb | `0x912ce59144191c1204e64559fe8253a0e49e6548` | 18 | decimals() | arbitrum | Y |
| AVAX | avax | native | 18 | native constant | avalanche-2 | Y |
| BCH | bch | native | 8 | native constant | bitcoin-cash | Y |
| BNB | bsc | native | 18 | native constant | binancecoin | Y |
| BTC | btc | native | 8 | native constant | bitcoin | Y |
| BTC | near | `nbtc.bridge.near` | 8 | ft_metadata | near-intents-bridged-wbtc | Y |
| DAI | eth | `0x6b175474e89094c44da98b954eedeac495271d0f` | 18 | decimals() | dai | Y |
| DOGE | doge | native | 8 | native constant | dogecoin | Y |
| ETH | arb | native | 18 | native constant | ethereum | Y |
| ETH | base | native | 18 | native constant | ethereum | Y |
| ETH | eth | native | 18 | native constant | ethereum | Y |
| ETH | near | `eth.bridge.near` | 18 | ft_metadata | - | N (no CoinGecko id for this contract) |
| ETH | op | native | 18 | native constant | ethereum | Y |
| LINK | eth | `0x514910771af9ca656af840dff83e8264ecf986ca` | 18 | decimals() | chainlink | Y |
| LTC | ltc | native | 8 | native constant | litecoin | Y |
| NEAR | bsc | `0x1fa4a73a3f0133f0025378af00236f3abdee5d63` | 18 | decimals() | binance-peg-near-protocol | Y |
| OP | op | `0x4200000000000000000000000000000000000042` | 18 | decimals() | optimism | Y |
| PEPE | eth | `0x6982508145454ce325ddbe47a25d4ec3d2311933` | 18 | decimals() | pepe | Y |
| POL | pol | native | 18 | native constant | polygon-ecosystem-token | Y |
| SHIB | eth | `0x95ad61b0a150d79219dcf64e1e6cc01f0b64c4ce` | 18 | decimals() | shiba-inu | Y |
| SOL | sol | native | 9 | native constant | solana | Y |
| SUI | sui | native | 9 | native constant | sui | Y |
| TRX | tron | native | 6 | native constant | tron | Y |
| UNI | eth | `0x1f9840a85d5af5bf1d1762f925bdaddc4201f984` | 18 | decimals() | uniswap | Y |
| USDC | arb | `0xaf88d065e77c8cc2239327c5edb3a432268e5831` | 6 | decimals() | usd-coin | Y |
| USDC | avax | `0xb97ef9ef8734c71904d8002f8b6bc66dd9c48a6e` | 6 | decimals() | usd-coin | Y |
| USDC | base | `0x833589fcd6edb6e08f4c7c32d4f71b54bda02913` | 6 | decimals() | usd-coin | Y |
| USDC | bsc | `0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d` | 18 | decimals() | binance-bridged-usdc-bnb-smart-chain | Y |
| USDC | eth | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | 6 | decimals() | usd-coin | Y |
| USDC | gnosis | `0x2a22f9c3b484c3629090feed35f17ff8f88f76f0` | 6 | decimals() | bridged-usdc-gnosis | Y |
| USDC | near | `17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1` | 6 | ft_metadata | usd-coin | Y |
| USDC | op | `0x0b2c639c533813f4aa9d7837caf62653d097ff85` | 6 | decimals() | usd-coin | Y |
| USDC | pol | `0x3c499c542cef5e3811e1192ce70d8cc03d5c3359` | 6 | decimals() | usd-coin | Y |
| USDC | sol | `EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v` | 6 | Solana mint | usd-coin | Y |
| USDC | sui | `0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC` | 6 | Sui coinMetadata | usd-coin | Y |
| USDT | avax | `0x9702230a8ea53601f5cd2dc00fdbc13d4df4a8c7` | 6 | decimals() | tether | Y |
| USDT | bsc | `0x55d398326f99059ff775485246999027b3197955` | 18 | decimals() | binance-bridged-usdt-bnb-smart-chain | Y |
| USDT | eth | `0xdac17f958d2ee523a2206206994597c13d831ec7` | 6 | decimals() | tether | Y |
| USDT | gnosis | `0x4ecaba5870353805a9f068101a40e0f32ed605c6` | 6 | decimals() | gnosis-xdai-bridged-usdt-gnosis | Y |
| USDT | near | `usdt.tether-token.near` | 6 | ft_metadata | tether | Y |
| USDT | op | `0x94b008aa00579c1307b0ef2c499ad98a8ce58e58` | 6 | decimals() | bridged-usdt | Y |
| USDT | pol | `0xc2132d05d31c914a87c6611c10748aeb04b58e8f` | 6 | decimals() | usdt0 | Y |
| USDT | sol | `Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB` | 6 | Solana mint | tether | Y |
| USDT | ton | `EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs` | 6 | none | tether | N (decimals not readable on chain) |
| USDT | tron | `TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t` | 6 | TRC-20 decimals() | tether | Y |
| WBTC | eth | `0x2260fac5e5542a773aa44fbcfedf7c193bc2c599` | 8 | decimals() | wrapped-bitcoin | Y |
| WBTC | near | `2260fac5e5542a773aa44fbcfedf7c193bc2c599.factory.bridge.near` | 8 | ft_metadata | rainbow-bridged-wbtc-near-protocol | Y |
| WNEAR | near | `wrap.near` | 24 | ft_metadata | wrapped-near | Y |
| WNEAR | sol | `3ZLekZYq2qkZiSpnSvabjit34tUkjSwD1JFuW9as9wBG` | 9 | Solana mint | - | N (no CoinGecko id for this contract) |
| XRP | xrp | native | 6 | native constant | ripple | Y |

## Address checks per destination chain

| Chain | Accepted | Check |
| --- | --- | --- |
| Ethereum, Base, Arbitrum, Optimism, Polygon, Avalanche, BNB Chain, Gnosis | `0x` + 40 hex | EIP-55 when mixed case; zero address refused |
| NEAR | `.near` names (must exist) and 64-hex implicit ids | NEAR account rules |
| Solana | base58, 32 bytes | decode length |
| Tron | `T…` base58check, version 0x41 | double SHA-256 checksum |
| Bitcoin | `1…`, `3…`, `bc1q…` (bech32), `bc1p…` (bech32m) | base58check or BIP-173/350 checksum and program length |
| Litecoin | `L…`, `M…`, `3…`, `ltc1…` | as Bitcoin |
| Dogecoin | `D…`, `9…`/`A…` | base58check, versions 0x1e/0x16 |
| Bitcoin Cash | CashAddr `bitcoincash:q…`/`p…`, prefix optional | CashAddr polymod checksum |
| XRP Ledger | classic `r…` | Ripple-alphabet base58check. Destination tags are parsed but blocked: how 1Click carries a tag is not verified |
| Cardano | Shelley `addr1…` | bech32, mainnet network id |
| Sui | `0x` + 64 hex | format |
| TON | friendly 48-char form or raw `0:<hex>` | CRC16; testnet-only flag refused (no TON asset is payable yet) |

A `3…` address fits both Bitcoin and Litecoin, so the text must name the chain. Read-only dry quotes on 2026-11-14 confirmed that 1Click accepts each format: Bitcoin bech32, XRP `r…`, Cardano `addr1…`, Bitcoin Cash with and without the prefix, Dogecoin, Litecoin and Sui. One XRP address (the genesis account) got a 1Click internal error; another worked.

## Golden tests

`server/test/xchain.test.ts` covers every decimal class in the pin table (6, 8, 9, 18, 24, including USDC/USDT 18 on BNB Chain, BTC/DOGE/LTC/BCH/WBTC 8, SOL/SUI 9, XRP/ADA/TRX 6), each address check above with good and bad cases, and also USDC 6, USDT 6, NEAR 24 (1 yocto), wNEAR 24, ETH 18, SOL 9, BTC 8; `0.000001 USDC`; too many decimals; USDC on BNB (18) against USDC on NEAR (6) in one quote; dust (1 unit in, 0 out, refused); a token list with wrong decimals (refused); a quote whose formatted amount does not fit its decimals (refused); fee, rate, echo, exactness, deadline, memo and price-spread failures.
