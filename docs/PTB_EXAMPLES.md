# APEX Protocol - PTB Examples

This document contains detailed Programmable Transaction Block (PTB) examples showing input/output formats for all APEX operations.

> **Note:** All behaviors are verified by local Move VM tests (`sui move test`). Replace object IDs with real values after deployment.

## Table of Contents

1. [Purchase API Access](#example-1-purchase-api-access)
2. [Use Access (Consume Units)](#example-2-use-access-consume-units)
3. [Atomic Pay-and-Trade](#example-3-atomic-pay-and-trade-single-ptb)
4. [Create Trading Intent](#example-4-create-trading-intent)
5. [Executor Fills Intent](#example-5-executor-fills-intent)
6. [Open Payment Stream](#example-6-open-payment-stream)
7. [Provider Records Consumption](#example-7-provider-records-consumption)
8. [Agent Wallet with Limits](#example-8-agent-wallet-with-limits)
9. [Shield Transfer (Hash-Locked)](#example-9-shield-transfer-hash-locked)

---

## Example 1: Purchase API Access

**Input:**
```
PTB Commands:
  [0] MoveCall apex_payments::purchase_access
      Args: config, service, coin<1 SUI>, units=100, duration=3600000, rate_limit=10, clock

Objects consumed:
  - Coin<SUI>: 0xabc... (1 SUI)

Objects created:
  - AccessCapability { service_id, remaining_units: 100, expires_at: now+1hr }
```

**Output:**
```
Status: Success
Gas used: ~0.003 SUI

Created objects:
  - 0xdef... AccessCapability
    ├── service_id: 0x123...
    ├── remaining_units: 100
    ├── expires_at: 1706900000000
    └── rate_limit: 10

Events:
  - AccessPurchased { capability_id: 0xdef..., service_id: 0x123..., buyer: 0xuser..., units: 100, cost: 1000000000 }
```

---

## Example 2: Use Access (Consume Units)

**Input:**
```
PTB Commands:
  [0] MoveCall apex_payments::use_access
      Args: capability, service, units=1, clock

Objects mutated:
  - AccessCapability: 0xdef...
```

**Output:**
```
Status: Success
Gas used: ~0.001 SUI

Mutated objects:
  - 0xdef... AccessCapability
    └── remaining_units: 100 → 99

Events:
  - AccessUsed { capability_id: 0xdef..., service_id: 0x123..., units_used: 1, remaining: 99 }
```

---

## Example 3: Atomic Pay-and-Trade (Single PTB)

This demonstrates passing objects between commands in one PTB.

**Input:**
```
PTB Commands:
  [0] SplitCoins gas, [100000000]  // 0.1 SUI for payment
      → Result[0] = payment_coin

  [1] MoveCall apex_payments::purchase_access
      Args: config, service, Result[0], units=1, duration=0, rate_limit=0, clock
      → Result[1] = access_capability

  [2] MoveCall deepbook::pool::swap_exact_base_for_quote<SUI, USDC>
      Args: pool, trade_coin, deep_coin, min_output=1000000, clock
      → Result[2] = (base_out, quote_out, deep_out)

  [3] TransferObjects [Result[1], Result[2].quote_out] → user_address

Objects consumed:
  - Gas coin (partially)
  - Trade coin<SUI>: 0x111... (5 SUI)
  - DEEP coin: 0x222... (for fees)
```

**Output:**
```
Status: Success
Gas used: ~0.008 SUI

Created objects:
  - 0xaaa... AccessCapability (transferred to user)
  - 0xbbb... Coin<USDC> value=10500000 (transferred to user)

Mutated objects:
  - DeepBook pool state
  - Service provider revenue balance

Events:
  - AccessPurchased { ... }
  - deepbook::SwapExecuted { base_in: 5000000000, quote_out: 10500000 }
```

**Key Point:** If the DeepBook swap fails (e.g., slippage too high), the entire PTB reverts - including the payment. User loses nothing.

---

## Example 4: Create Trading Intent

**Input:**
```
PTB Commands:
  [0] MoveCall apex_trading::create_swap_intent<SUI>
      Args: input_coin<1 SUI>, min_output=2000000, recipient, duration=3600000, clock
      → Creates shared SwapIntent object

Objects consumed:
  - Coin<SUI>: 0x333... (1 SUI) - ESCROWED in intent
```

**Output:**
```
Status: Success
Gas used: ~0.002 SUI

Created objects:
  - 0xccc... SwapIntent<SUI> (shared)
    ├── creator: 0xagent...
    ├── escrowed: 1000000000 (1 SUI)
    ├── min_output: 2000000 (2 USDC)
    ├── recipient: 0xagent...
    ├── deadline: now + 1hr
    └── filled: false

Events:
  - IntentCreated { intent_id: 0xccc..., creator: 0xagent..., input_amount: 1000000000, min_output: 2000000 }
```

---

## Example 5: Executor Fills Intent

**Input:**
```
PTB Commands:
  [0] MoveCall deepbook::pool::swap_exact_base_for_quote<SUI, USDC>
      Args: pool, executor_sui_coin, deep_coin, min_output=2000000, clock
      → Result[0] = (_, usdc_out, _)

  [1] MoveCall apex_trading::fill_intent<SUI, USDC>
      Args: intent, Result[0].usdc_out, clock
      → Result[1] = (escrowed_sui, receipt)

  [2] TransferObjects [Result[1].escrowed_sui, Result[1].receipt] → executor_address

Executor provides:
  - Coin<SUI> to swap on DeepBook
  - Coin<DEEP> for fees
```

**Output:**
```
Status: Success
Gas used: ~0.006 SUI

Mutated objects:
  - 0xccc... SwapIntent<SUI>
    └── filled: false → true

Created objects:
  - 0xddd... Coin<SUI> value=1000000000 (escrowed, sent to executor)
  - 0xeee... IntentReceipt (sent to executor)

Transfers:
  - USDC (2050000) → 0xagent... (intent recipient)

Events:
  - IntentFilled { intent_id: 0xccc..., executor: 0xexec..., output_amount: 2050000 }
```

**Executor profit:** Got 1 SUI, spent ~0.95 SUI worth to get 2.05 USDC. Kept the spread.

---

## Example 6: Open Payment Stream

**Input:**
```
PTB Commands:
  [0] MoveCall apex_payments::open_stream
      Args: config, service, escrow_coin<10 SUI>, max_units=10000, clock
      → Creates shared PaymentStream
```

**Output:**
```
Status: Success

Created objects:
  - 0xfff... PaymentStream (shared)
    ├── consumer: 0xuser...
    ├── service_id: 0x123...
    ├── escrow: 10000000000 (10 SUI)
    ├── unit_price: 1000000 (0.001 SUI per unit)
    ├── total_consumed: 0
    └── max_units: 10000

Events:
  - StreamOpened { stream_id: 0xfff..., escrow_amount: 10000000000 }
```

---

## Example 7: Provider Records Consumption

**Input:**
```
PTB Commands:
  [0] MoveCall apex_payments::record_stream_consumption
      Args: stream, service, units=150, clock

Caller: Service provider only
```

**Output:**
```
Status: Success

Mutated objects:
  - 0xfff... PaymentStream
    ├── escrow: 10000000000 → 9850000000
    └── total_consumed: 0 → 150

  - 0x123... ServiceProvider
    └── revenue: +150000000 (0.15 SUI)

Created objects:
  - StreamTicket (sent to consumer)

Events:
  - StreamConsumed { stream_id: 0xfff..., units: 150, cost: 150000000 }
```

---

## Example 8: Agent Wallet with Limits

**Input:**
```
PTB Commands:
  [0] MoveCall apex_payments::create_agent_wallet
      Args: config, agent_id="bot-001", spend_limit=100000000, daily_limit=1000000000, funding<5 SUI>, clock
```

**Output:**
```
Status: Success

Created objects:
  - 0xaaa... AgentWallet (owned by creator)
    ├── owner: 0xhuman...
    ├── agent_id: "bot-001"
    ├── balance: 5000000000
    ├── spend_limit: 100000000 (0.1 SUI per tx)
    ├── daily_limit: 1000000000 (1 SUI per day)
    ├── daily_spent: 0
    └── paused: false
```

**Agent purchase (enforces limits):**
```
PTB Commands:
  [0] MoveCall apex_payments::agent_purchase_access
      Args: wallet, config, service, units=5, duration=3600000, rate_limit=0, clock

Checks:
  ✓ cost (0.05 SUI) <= spend_limit (0.1 SUI)
  ✓ daily_spent + cost (0.05 SUI) <= daily_limit (1 SUI)
  ✓ wallet not paused
```

---

## Example 9: Shield Transfer (Hash-Locked)

**Sender initiates:**
```
PTB Commands:
  [0] MoveCall apex_payments::initiate_shield_transfer
      Args: config, recipient, coin<100 SUI>, duration=86400000, secret_hash, clock

secret_hash = keccak256("my-secret-phrase")
```

**Output:**
```
Created objects:
  - 0xbbb... ShieldSession (shared)
    ├── sender: 0xsender...
    ├── recipient: 0xrecipient...
    ├── amount: 100000000000
    ├── expires_at: now + 24hr
    ├── funds: 100 SUI (escrowed)
    └── secret_hash: 0x7f83b1...
```

**Recipient claims (with secret):**
```
PTB Commands:
  [0] MoveCall apex_payments::complete_shield_transfer
      Args: session, secret="my-secret-phrase", clock

Verification:
  keccak256("my-secret-phrase") == stored secret_hash ✓
```

**Output:**
```
Status: Success

Deleted objects:
  - 0xbbb... ShieldSession

Transfers:
  - 100 SUI → 0xrecipient...
```
