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

- Echo: `dry`, `swapType`, `originAsset`, `destinationAsset`, `amount`, `recipient`, `refundTo` and the three type fields must equal what Pip sent.
- Shape: `amountIn`, `minAmountIn`, `amountOut`, `minAmountOut` are positive integers; minimums are not above amounts.
- Decimals inside the quote: `toBase(amountInFormatted, originDecimals)` must equal `amountIn`, and the same for out. A provider using wrong decimals fails here.
- Exactness: exact output needs `amountOut = minAmountOut = typed`. Exact input needs `amountIn = typed`.
- Deposit: a NEAR account (64 hex or `.near`), no memo, and a deadline at least 25 minutes away (the intent lives 10 minutes and expires 15 minutes before the deadline).

## Rule 4: two price sources per asset

- Sources, in order: CoinGecko (by the token row's `coingeckoId`), Relay token price v2, the 1Click token list price.
- An asset's price is verified when at least two sources answer and all are within 2% of the first (`XCHAIN_MAX_PRICE_SPREAD_BPS`, default 200).
- Relay has no NEAR chain. NEAR-side stablecoins and ETH are priced on Relay through their Ethereum twin; NEAR and wNEAR have only CoinGecko and the 1Click list.
- Fewer than two agreeing sources: `verified: false`, no intent.

## Rule 5: fee and rate limits

- Value in = max input at the verified origin price. Value out = output at the verified destination price.
- Fee (USD) = value in minus value out. Fee (bps) = fee / value in, rounded up. Fee in origin tokens = max input minus the output's worth in origin units.
- Refuse when the fee is above 3% (`XCHAIN_MAX_FEE_BPS`, 300) or above $1 (`XCHAIN_MAX_FEE_USD_MICRO`, 1000000).
- Refuse when 1Click's own `amountInUsd` or `amountOutUsd` is more than 2% from Pip's value (`XCHAIN_MAX_RATE_DIFF_BPS`, 200).
- With exact output, the max input includes the slippage buffer (`XCHAIN_SLIPPAGE_BPS`, default 100). 1Click refunds the unused part to the user's NEAR account, so the shown fee is the most it can cost.

## Rule 6: fresh quotes only

- The phone intent is built (`/unsigned`) only within 60 seconds of the quote. After that the app asks for a new quote.
- Caps (per payment and per day, per origin token) apply to the max input, in the same SQLite transaction as plain sends.

## Worked example (a live dry quote, 2026-11-14)

"Send 5 USDC on BNB Chain to 0xd8da…9da3, from my USDC on NEAR", exact output.

1. Decimals: USDC on NEAR = 6 (list) = 6 (`ft_metadata`). USDC on BNB = 18 (list) = 18 (`decimals()` = `0x…12`).
2. Typed: `5` at 18 decimals = `5000000000000000000`.
3. Quote: `amountOut = minAmountOut = 5000000000000000000` ("5.0" at 18 decimals matches). `amountIn = 5061486` ("5.061486" at 6 decimals matches). `minAmountIn = 5010971`.
4. Prices: USDC $0.999645 (CoinGecko), $0.999694 / $0.999753 (Relay), $0.999685 (1Click). All within 2%.
5. Value in = 5061486 × 0.999645 / 10^6 = $5.059689. Value out = $4.998225.
6. Fee = $0.061464 = 122 bps (below 300 bps and $1). Fee in tokens = 0.061486 USDC. 1Click's USD figures ($5.059892, $4.998425) are within 2% of Pip's.
7. Rate = 5000000000000000000 × 10^6 / 5061486 / 10^18 = 0.987852184121422048 USDC per USDC, floored.
8. Card: you pay at most 5.061486 USDC (NEAR); they get exactly 5 USDC on BNB Chain; fee 0.061486 USDC ($0.06); ETA 23 s; refunds to your NEAR account.

The raw live output is in `server/test/fixtures/xchain-live-dry-check.txt`.

## Golden tests

`server/test/xchain.test.ts` covers USDC 6, USDT 6, NEAR 24 (1 yocto), wNEAR 24, ETH 18, SOL 9, BTC 8; `0.000001 USDC`; too many decimals; USDC on BNB (18) against USDC on NEAR (6) in one quote; dust (1 unit in, 0 out, refused); a token list with wrong decimals (refused); a quote whose formatted amount does not fit its decimals (refused); fee, rate, echo, exactness, deadline, memo and price-spread failures.
