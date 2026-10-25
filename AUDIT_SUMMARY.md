# Valantis STEX Audit Summary

## Hypotheses tested (7)
1. **update() double-counting**: Intended. One payment settles two different debts.
2. **update() else branch**: Correct as written.
3. **Queue inflation**: Not possible. Withdrawals are pro-rata.
4. **Slashing / negative rebase**: Documented assumption. Out of scope.
5. **First-depositor share inflation**: Blocked by MINIMUM_LIQUIDITY.
6. **Donation to drop swap fee tier**: Lowers fee to minimum step, never 0.
7. **Instant-withdrawal fee**: Lower fee tier (Informational).

## Invariants that held
- Withdrawal queue stays backed (P ≤ reserve0 + U).
- Native balance covers claims.
- Swaps can't beat the conversion quote.
- No stale pricing.
- Fair withdrawals (no external loss).
- Fees never reach zero for token0 in.

## Conclusion
No Critical or High findings in scope. The core accounting is solid.

## PoC Files
- test/UpdateDoubleCount.t.sol
- test/Amount0Deduction.t.sol
- test/NegativeRebase.t.sol
- test/InflationAttack.t.sol
- test/FeeBypass.t.sol
- test/InstantWithdrawalFee.t.sol
