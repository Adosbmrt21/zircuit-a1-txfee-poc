# Zircuit Finance — A-1 PoC: withdrawal-queue `txFee` is paid to the keeper, not refunded to the user

Fork proof-of-concept against the **live Base deployment** of the Zircuit Finance
USDC `VaultComposer` (`0xBb801ED781dF31F660cC743bEf7Bb9D04B030923`).

## The issue

When a user enqueues a cross-chain redemption with `redeemAndSend`, the composer
quotes the LayerZero send fee and stores everything paid above the quote as
`entry.txFee = msg.value - fee.nativeFee`. The official SDK adds a **+30% buffer**
on top of the quote as protection against fee fluctuation. When the keeper
(`WITHDRAWAL_MANAGER`) later processes the entry, the outbound send is paid from
`entry.fee + extraFee` only, and the full `txFee` is transferred to the keeper as
part of the processing refund. The user never receives any of the surplus back;
the amount is uncapped and is never an explicit user-chosen parameter.

Live evidence (read-only, Base): queue entry #1 of the USDC composer stored
`fee = 1,731,257,651,789,206` wei and `txFee = 519,377,295,536,761` wei —
exactly **30.0%** of the quote. Across the 75 fulfilled USDC entries decoded on
2026-11-18, ≈ 0.00108 ETH of user buffers had been paid to the keeper.

## What the test proves

`test/TxFeeDiversion.t.sol` forks Base mainnet and, against the real contracts:

1. Gives a fresh user 10 vault shares and ETH (fork storage writes).
2. Builds the redeem `SendParam` exactly like the official SDK (Ethereum
   destination, 1% slippage, bare `0x0003` options as seen in production entries).
3. Quotes the fee via `composer.quoteSend`, pays `quote + 30%` — the SDK total.
4. Asserts the stored entry: `fee == quote`, `txFee == 30% buffer`.
5. Grants a test account `WITHDRAWAL_MANAGER` (fork storage write; the role hash
   and the OpenZeppelin ERC-7201 AccessControl slot are taken from the deployed
   source) and processes the entry — a real vault redeem and a real LayerZero
   send execute on the fork.
6. Asserts the keeper's balance increased by **exactly** the `txFee`, the user's
   balance is unchanged (no surplus refund), and the entry is fulfilled.

## Run

```bash
forge test --fork-url https://base-rpc.publicnode.com -vvv
```

Verified passing on 2026-11-19 at Base block **59,165,035**:

```
[PASS] test_txFee_goes_to_keeper_not_user() (gas: 1428877)
```

## Affected code (Sourcify-verified deployed source, `VaultComposer.sol`)

- Enqueue: `entry.txFee = msg.value - fee.nativeFee;`
- Processing: `_redeemAndSend(..., _entry.fee + _extraFee)` funds the send from
  the quote only; `_processWithdrawal` returns `txFeeRefund = _entry.txFee`;
  `processWithdrawals` pays the summed refunds to `payable(msg.sender)` — the keeper.

Suggested fix: make the keeper fee an explicit, capped parameter of
`redeemAndSend`, or refund the unused surplus to the entry's `refundAddress`
when the entry is processed.
