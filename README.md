# FlashLoanVault

A simple, gas-efficient ERC20 token vault with native flash loan support and a fair-share accounting model. Inspired by ERC-4626-style vaults but optimized for custom fee logic and dust handling.

---

## 🔍 Overview

This vault allows users to:
- Deposit ERC20 tokens and receive shares
- Withdraw tokens by redeeming shares
- Offer flash loans with dynamically scaled fees based on utilization

### ⚙️ Features

- ✅ **Fair-share accounting** with per-user share balances
- 🔄 **Flash loan support** (ERC-3156-like interface)
- 🧮 **Dynamic fee model** (base + slope depending on utilization)
- 🧼 **Dust protection** using `MINIMUM_SHARES` logic
- 🔐 Reentrancy protection via `ReentrancyGuard`

---

## 🧪 Test Coverage

All tests pass ✅. Key test cases include:

- `testFirstDepositorDustRefund`: ensures dust is refunded only once
- `testInitialDustLifecycle`: checks dust shares are created on first deposit and burned after last withdrawal
- `testRoundingDriftAfterRepeatedCycles`: (optional/modified) verifies rounding drift doesn't accumulate
- `testFlashLoanExecution`: flash loan success with proper fee and callback
- ...and more covering deposits, withdrawals, share accounting, and edge cases

---

## 🧠 Design Notes

### 🔸 Dust Protection (`MINIMUM_SHARES`)
- On the first deposit, `MINIMUM_SHARES` are minted to address(0)
- This prevents `share price = 0` and division-by-zero issues
- The first depositor gets a one-time refund of the dust on their first withdrawal
- Dust is **burned** when the vault is emptied

### 🔸 Flash Loan Fee Formula
```solidity
fee = baseFee + (feeSlope * utilization)
