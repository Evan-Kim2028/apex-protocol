# APEX Protocol

**Sui-Native x402-Style Payment Infrastructure for AI Agents**

APEX (Agent Payment EXecution Protocol) provides x402-equivalent payment functionality on Sui, leveraging Sui's unique object model and Programmable Transaction Blocks (PTBs).

## What is x402?

[x402](https://x402.org/) is Coinbase's payment protocol for AI agents, based on HTTP 402 "Payment Required". It enables:
- Pay-per-call API billing
- Machine-to-machine payments
- Automated payment verification via signed authorizations (EIP-3009/Permit2)

**APEX brings similar functionality to Sui** with a different architectural approach.

## How x402 Works vs APEX

### x402 Flow (Base/Solana)
```
Client                    Server                   Facilitator           Blockchain
   │                         │                          │                     │
   │─── GET /resource ──────>│                          │                     │
   │<── 402 + PaymentReq ────│                          │                     │
   │                         │                          │                     │
   │ [Client signs auth]     │                          │                     │
   │                         │                          │                     │
   │─── GET + signature ────>│                          │                     │
   │                         │─── verify ──────────────>│                     │
   │                         │<── valid ────────────────│                     │
   │                         │                          │                     │
   │<── 200 + resource ──────│ (optimistic)             │                     │
   │                         │                          │                     │
   │                         │─── settle ──────────────>│                     │
   │                         │                          │──── transfer ──────>│
   │                         │<── receipt ─────────────>│                     │
```

### APEX Flow (Sui)
```
Client                              Sui Blockchain
   │                                      │
   │  [Build PTB locally]                 │
   │  ┌─────────────────────────────┐     │
   │  │ 1. purchase_access()        │     │
   │  │ 2. use_access() or trade    │     │
   │  │ 3. transfer outputs         │     │
   │  └─────────────────────────────┘     │
   │                                      │
   │────── Submit single PTB ────────────>│
   │                                      │
   │<───── Result (all or nothing) ───────│
```

## Honest Comparison

| Aspect | x402 (Base/Solana) | APEX (Sui) |
|--------|-------------------|------------|
| **Atomicity** | ✅ Both chains support atomic multi-operation transactions | ✅ PTBs are atomic |
| **Payment Model** | Off-chain signature → on-chain settlement | On-chain payment in PTB |
| **Facilitator** | Required (submits tx, pays gas) | Not required (user submits) |
| **Gas Abstraction** | ✅ Facilitator pays gas | ❌ User pays gas |
| **Optimistic Serving** | ✅ Can serve before settlement | ❌ Must wait for tx |
| **Object Passing** | N/A (account model) | ✅ Pass objects between calls |
| **Client Complexity** | Sign authorization | Build PTB |

### Clarification on Atomicity

**Solana** supports [atomic multi-instruction transactions](https://solana.com/docs/core/transactions) - if any instruction fails, all fail.

**Ethereum/Base** supports atomic batching via [Multicall3](https://docs.base.org/base-account/improve-ux/batch-transactions) and smart contract patterns.

**The difference is NOT atomicity** - all three chains can do atomic operations.

### What Sui PTBs Actually Offer

1. **Client-side composition**: Build complex multi-contract interactions without deploying new contracts ([up to 1,024 operations](https://docs.sui.io/concepts/transactions/prog-txn-blocks))
2. **Object passing**: Results from one call can be inputs to another in the same PTB
3. **No facilitator needed**: User builds and submits their own transaction
4. **Capability objects**: Access rights as transferable objects, not account permissions

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     APEX Protocol                            │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  apex_payments.move (Core)                                   │
│  ├── Service registration & pricing                         │
│  ├── Access capability purchase                              │
│  ├── Streaming payments                                      │
│  ├── Agent wallets with spending limits                     │
│  └── Shield transfers (hash-locked)                         │
│                                                              │
│  apex_trading.move (Trading patterns)                        │
│  ├── Trading intents (escrow until filled)                  │
│  ├── Gated trading (verify payment first)                   │
│  └── Composable with DeepBook                                │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## PTB Examples (Verified via Local Move VM)

These examples show expected PTB structure and outputs. **All behaviors are verified by the local Move VM tests** (`sui move test`). Replace object IDs with real values after deployment.

### Example 1: Purchase API Access

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

### Example 2: Use Access (Consume Units)

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

### Example 3: Atomic Pay-and-Trade (Single PTB)

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

### Example 4: Create Trading Intent

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

### Example 5: Executor Fills Intent

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

### Example 6: Open Payment Stream

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

### Example 7: Provider Records Consumption

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

### Example 8: Agent Wallet with Limits

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

### Example 9: Shield Transfer (Hash-Locked)

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

---

## Key Concepts

### AccessCapability

An object representing paid API access:

```move
public struct AccessCapability has key, store {
    id: UID,
    service_id: ID,       // Which service
    remaining_units: u64, // API calls remaining
    expires_at: u64,      // Expiration (0 = never)
    rate_limit: u64,      // Max per epoch (0 = unlimited)
    epoch_usage: u64,     // Used this epoch
    last_epoch: u64,
}
```

**Key property:** Can be passed between PTB commands, enabling atomic pay-then-use patterns.

### Why Capability Objects Matter

On account-based chains, "access" is typically checked by:
- API key validation
- Signature verification
- On-chain permission mapping

On Sui, access is an **object you hold**:
- Transfer it to grant access to others
- Pass it to functions that require it
- Compose it in PTBs with other operations
- Burn it when done

## Project Structure

```
apex-protocol/
├── Move.toml
├── sources/
│   ├── apex_payments.move    # Core payment infrastructure
│   ├── apex_trading.move     # Trading patterns & intents
│   └── apex_tests.move       # Local Move VM tests
└── README.md
```

## Local Move VM Testing

All protocol functionality is verified through **local Move VM execution** via `sui move test`. These tests run the actual Move bytecode in a simulated environment before testnet deployment.

### Running Tests

```bash
# Run all tests
sui move test

# Run with verbose output
sui move test --verbose

# Run specific test
sui move test test_purchase_access
```

### Test Coverage (19 tests)

| Test | What It Verifies |
|------|------------------|
| `test_protocol_initialization` | AdminCap and ProtocolConfig created correctly |
| `test_register_service` | Service registration with fee payment |
| `test_register_service_insufficient_fee` | Rejects registration without proper fee |
| `test_purchase_access` | AccessCapability purchase and validation |
| `test_use_access` | Consuming units from capability |
| `test_use_expired_access` | Rejects expired capabilities |
| `test_open_and_consume_stream` | Streaming payment flow |
| `test_create_agent_wallet` | Agent wallet creation with limits |
| `test_agent_wallet_spending_limits` | Wallet purchases respect limits |
| `test_agent_wallet_exceeds_spend_limit` | Rejects over-limit purchases |
| `test_shield_transfer_complete` | Hash-locked transfer with secret |
| `test_shield_transfer_wrong_secret` | Rejects incorrect secrets |
| `test_create_and_fill_intent` | Trading intent creation and execution |
| `test_fill_intent_insufficient_output` | Rejects underpaid fills |
| `test_cancel_intent` | Intent cancellation with refund |
| `test_gated_trading_service` | Payment verification before trading |
| `test_atomic_purchase_and_use` | Multi-operation atomic sequences |
| `test_protocol_pause` | Admin pause functionality |
| `test_register_while_paused` | Operations blocked when paused |

### Example Test Output

```
$ sui move test
Running Move unit tests
[ PASS    ] dexter_payment::apex_tests::test_protocol_initialization
[ PASS    ] dexter_payment::apex_tests::test_register_service
[ PASS    ] dexter_payment::apex_tests::test_purchase_access
[ PASS    ] dexter_payment::apex_tests::test_use_access
[ PASS    ] dexter_payment::apex_tests::test_atomic_purchase_and_use
[ PASS    ] dexter_payment::apex_tests::test_create_and_fill_intent
[ PASS    ] dexter_payment::apex_tests::test_shield_transfer_complete
... (19 tests total)
Test result: OK. Total tests: 19; passed: 19; failed: 0
```

### What the Tests Demonstrate

The tests mirror PTB patterns by executing multiple operations in sequence within a single test transaction:

```move
// Example: test_atomic_purchase_and_use
// Simulates a PTB with purchase + use in same transaction

// Command 1: Purchase access
let mut capability = apex_payments::purchase_access(
    &mut config,
    &mut service,
    payment,
    100,      // units
    3600_000, // 1 hour duration
    0,        // no rate limit
    &clock,
    ctx
);

// Command 2: Use access (same tx, object passed between commands)
let success = apex_payments::use_access(
    &mut capability,
    &service,
    5,
    &clock,
    ctx
);

// Both operations atomic - if use_access failed, purchase would revert
```

## Build & Deploy

```bash
# Build
sui move build

# Test (local Move VM)
sui move test

# Deploy to testnet
sui client switch --env testnet
sui client faucet
sui client publish --gas-budget 500000000
```

## Security Features

- Overflow-protected arithmetic
- Authorization checks on all sensitive operations
- Bounded inputs (name lengths, etc.)
- Rate limiting support
- Emergency pause (protocol and agent level)
- Hash-locked transfers with expiry

## References

- [x402 Protocol](https://x402.org/) - Coinbase's HTTP 402 payment standard
- [x402 GitHub](https://github.com/coinbase/x402) - Reference implementation
- [Sui PTB Documentation](https://docs.sui.io/concepts/transactions/prog-txn-blocks)
- [DeepBook V3](https://github.com/MystenLabs/deepbookv3)
- [Solana Transaction Atomicity](https://solana.com/docs/core/transactions)
- [Base Batch Transactions](https://docs.base.org/base-account/improve-ux/batch-transactions)

## License

MIT
