# APEX Protocol Architecture

## Overview

APEX (Agent Payment EXecution) Protocol is a Sui-native payment infrastructure designed for AI agents. It provides x402-equivalent functionality with superior atomicity guarantees through Sui's Programmable Transaction Blocks (PTBs).

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          APEX Protocol Architecture                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌───────────────┐     ┌───────────────┐     ┌───────────────┐            │
│  │   AI Agent    │     │   Service     │     │   Protocol    │            │
│  │   (Consumer)  │     │   Provider    │     │   Admin       │            │
│  └───────┬───────┘     └───────┬───────┘     └───────┬───────┘            │
│          │                     │                     │                     │
│          │ purchase_access()   │ register_service()  │ initialize()        │
│          │                     │                     │                     │
│          ▼                     ▼                     ▼                     │
│  ┌───────────────────────────────────────────────────────────────────┐    │
│  │                         Move VM (Sui Blockchain)                   │    │
│  │                                                                    │    │
│  │   ┌──────────────────────────────────────────────────────────┐    │    │
│  │   │                   apex_payments.move                      │    │    │
│  │   │  ┌────────────┐  ┌────────────┐  ┌────────────────────┐  │    │    │
│  │   │  │ Protocol   │  │ Service    │  │ Access             │  │    │    │
│  │   │  │ Config     │  │ Provider   │  │ Capability         │  │    │    │
│  │   │  │ (shared)   │  │ (shared)   │  │ (owned/store)      │  │    │    │
│  │   │  └────────────┘  └────────────┘  └────────────────────┘  │    │    │
│  │   │                                                           │    │    │
│  │   │  ┌────────────┐  ┌────────────┐  ┌────────────────────┐  │    │    │
│  │   │  │ Payment    │  │ Agent      │  │ Shield             │  │    │    │
│  │   │  │ Stream     │  │ Wallet     │  │ Session            │  │    │    │
│  │   │  │ (shared)   │  │ (owned)    │  │ (shared)           │  │    │    │
│  │   │  └────────────┘  └────────────┘  └────────────────────┘  │    │    │
│  │   └──────────────────────────────────────────────────────────┘    │    │
│  │                                                                    │    │
│  │   ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐    │    │
│  │   │apex_trading  │  │ apex_seal   │  │ apex_sponsor        │    │    │
│  │   │.move         │  │ .move       │  │ .move               │    │    │
│  │   │              │  │             │  │                     │    │    │
│  │   │DEX patterns  │  │Encrypted    │  │Gas sponsorship      │    │    │
│  │   │& intents     │  │access ctrl  │  │infrastructure       │    │    │
│  │   └──────────────┘  └──────────────┘  └──────────────────────┘    │    │
│  └───────────────────────────────────────────────────────────────────┘    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Module Overview

### 1. apex_payments.move (Core)

The heart of APEX - handles all payment flows.

**Key Structs:**

| Struct | Type | Description |
|--------|------|-------------|
| `ProtocolConfig` | shared | Global protocol settings, treasury, fees |
| `AdminCap` | owned | Admin authority for protocol management |
| `ServiceProvider` | shared | API endpoint that accepts payments |
| `AccessCapability` | owned+store | Proof of payment, grants API access |
| `PaymentStream` | shared | Open channel for streaming micropayments |
| `AgentWallet` | owned | Managed wallet with spending limits |
| `ShieldSession` | shared | Hash-locked private transfer |

**Core Functions:**

```
initialize_protocol() → creates ProtocolConfig + AdminCap
register_service()    → creates ServiceProvider
purchase_access()     → returns AccessCapability (THE KEY FUNCTION)
use_access()          → consumes capability units
open_stream()         → returns stream ID for micropayments
```

### 2. apex_trading.move

Patterns for composing payments with DEX trades.

```
┌─────────────────────────────────────────────────────────────────┐
│                    Trading Intent Flow                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. Agent creates intent:                                       │
│     ┌─────────────────────────────────────────────────────┐    │
│     │ create_swap_intent(input_coin, min_output, ...)     │    │
│     │     → SwapIntent { escrowed: Balance<INPUT> }       │    │
│     └─────────────────────────────────────────────────────┘    │
│                             │                                   │
│                             ▼                                   │
│  2. Executor fills intent (after swapping on DeepBook):        │
│     ┌─────────────────────────────────────────────────────┐    │
│     │ fill_intent(intent, output_coin, ...)               │    │
│     │     → (Coin<INPUT>, IntentReceipt)                  │    │
│     └─────────────────────────────────────────────────────┘    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 3. apex_seal.move

Integration with Seal's decentralized secrets management.

```
Content Access Control:
───────────────────────

Provider encrypts with Seal    Key servers verify    Agent decrypts
        ↓                      AccessCapability          ↓
   ┌─────────┐                      ↓              ┌─────────────┐
   │Encrypted│ ──seal_approve()──▶ ✓ ──────────▶  │ Decrypted   │
   │ Content │                                     │ Content     │
   └─────────┘                                     └─────────────┘
```

### 4. apex_sponsor.move

Gas sponsorship infrastructure for gasless UX.

## PTB (Programmable Transaction Block) Patterns

### The Atomic Pay-and-Use Pattern

This is APEX's killer feature - atomic transactions impossible on other chains:

```
┌──────────────────────────────────────────────────────────────────┐
│                    Single Atomic PTB                             │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Inputs:                                                         │
│  ├─ [0] ProtocolConfig (shared, mutable)                        │
│  ├─ [1] ServiceProvider (shared, mutable)                       │
│  ├─ [2] Coin<SUI> (owned) - payment                             │
│  ├─ [3] units: u64 (pure)                                       │
│  ├─ [4] duration_ms: u64 (pure)                                 │
│  ├─ [5] rate_limit: u64 (pure)                                  │
│  ├─ [6] Clock (shared, immutable)                               │
│  └─ [7] units_to_use: u64 (pure)                                │
│                                                                  │
│  Commands:                                                       │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │ [0] MoveCall: purchase_access(0,1,2,3,4,5,6)               │ │
│  │     → Result[0] = AccessCapability                          │ │
│  ├────────────────────────────────────────────────────────────┤ │
│  │ [1] MoveCall: use_access(Result[0], 1, 7, 6)               │ │
│  │     → Result[1] = bool (true)                               │ │
│  ├────────────────────────────────────────────────────────────┤ │
│  │ [2] MoveCall: deepbook::swap(...)                          │ │
│  │     → Result[2] = Coin<QUOTE>                               │ │
│  ├────────────────────────────────────────────────────────────┤ │
│  │ [3] TransferObjects([Result[0], Result[2]], sender)        │ │
│  └────────────────────────────────────────────────────────────┘ │
│                                                                  │
│  ATOMICITY: If ANY command fails, ENTIRE transaction reverts!   │
│             Agent's payment is protected - no risk of paying    │
│             but not receiving the service.                       │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

## PTB Input/Output Examples

### Example 1: Initialize Protocol

**PTB Input:**
```rust
inputs: []  // No inputs needed
commands: [
    MoveCall {
        package: 0xAA...,
        module: "apex_payments",
        function: "initialize_protocol",
        type_args: [],
        args: []
    }
]
```

**Expected Output:**
```
Effects:
├─ Gas used: ~1000 MIST
├─ Objects created: 2
│   ├─ ProtocolConfig (shared)
│   │   └─ ID: 0xf971...42a8
│   └─ AdminCap (owned by sender)
│       └─ ID: 0xb7ac...79a4
└─ Events:
    └─ ProtocolInitialized { config_id, admin }
```

### Example 2: Register Service

**PTB Input:**
```rust
inputs: [
    Object(Shared { id: config_id, mutable: true, ... }),
    Pure(bcs::to_bytes(b"AI Agent API")),           // name
    Pure(bcs::to_bytes(b"Pay-per-call inference")), // description
    Pure(bcs::to_bytes(&10_000_000u64)),            // price: 0.01 SUI
    Object(Owned { id: payment_coin, ... })         // 1 SUI registration
]
commands: [
    MoveCall {
        package: apex_pkg,
        module: "apex_payments",
        function: "register_service",
        args: [Input(0), Input(1), Input(2), Input(3), Input(4)]
    }
]
```

**Expected Output:**
```
Effects:
├─ Gas used: ~2500 MIST
├─ Objects created: 1
│   └─ ServiceProvider (shared)
│       ├─ ID: 0x03ad...23b8
│       ├─ provider: <sender address>
│       ├─ name: "AI Agent API"
│       ├─ price_per_unit: 10_000_000 (0.01 SUI)
│       └─ active: true
├─ Objects mutated: 1
│   └─ ProtocolConfig (treasury updated)
└─ Events:
    └─ ServiceRegistered { service_id, provider, name, price }
```

### Example 3: Purchase Access

**PTB Input:**
```rust
inputs: [
    Object(Shared { id: config_id, mutable: true }),
    Object(Shared { id: service_id, mutable: true }),
    Object(Owned { id: payment_coin }),  // Coin<SUI>
    Pure(bcs::to_bytes(&100u64)),        // units
    Pure(bcs::to_bytes(&3_600_000u64)),  // duration: 1 hour
    Pure(bcs::to_bytes(&10u64)),         // rate_limit: 10/epoch
    Object(Shared { id: clock_id, mutable: false })
]
commands: [
    MoveCall {
        function: "purchase_access",
        args: [Input(0)..Input(6)]
    },
    TransferObjects { objects: [Result(0)], address: sender }
]
```

**Expected Output:**
```
Effects:
├─ Gas used: ~6800 MIST
├─ Objects created: 1
│   └─ AccessCapability (transferred to sender)
│       ├─ ID: 0xd9b3...c7eb
│       ├─ service_id: 0x03ad...23b8
│       ├─ remaining_units: 100
│       ├─ expires_at: 1700003600000
│       └─ rate_limit: 10
├─ Objects mutated: 2
│   ├─ ProtocolConfig (treasury fee collected)
│   └─ ServiceProvider (revenue, total_served updated)
└─ Events:
    └─ AccessPurchased { capability_id, service_id, buyer, units, cost }
```

### Example 4: Use Access

**PTB Input:**
```rust
inputs: [
    Object(MutRef { id: capability_id }),   // &mut AccessCapability
    Object(Shared { id: service_id, mutable: false }),
    Pure(bcs::to_bytes(&1u64)),             // units to consume
    Object(Shared { id: clock_id, mutable: false })
]
commands: [
    MoveCall {
        function: "use_access",
        args: [Input(0), Input(1), Input(2), Input(3)]
    }
]
```

**Expected Output:**
```
Effects:
├─ Gas used: ~5300 MIST
├─ Objects mutated: 1
│   └─ AccessCapability
│       ├─ remaining_units: 99 (was 100)
│       └─ epoch_usage: 1
└─ Events:
    └─ AccessUsed { capability_id, service_id, units_used: 1, remaining: 99 }
```

## Object State Diagram

```
                         APEX Object Lifecycle
═══════════════════════════════════════════════════════════════════

ProtocolConfig (Singleton, Shared)
┌──────────────────────────────────────────────────────────────────┐
│ Created once at deployment                                       │
│ ├─ paused: bool                                                  │
│ ├─ registration_fee: u64 (0.1 SUI)                              │
│ ├─ fee_bps: u64 (50 = 0.5%)                                     │
│ ├─ treasury: Balance<SUI>  ←── fees accumulate here             │
│ └─ version: u64                                                  │
│                                                                  │
│ Mutated by: register_service, purchase_access, withdraw_treasury │
└──────────────────────────────────────────────────────────────────┘

ServiceProvider (Per-service, Shared)
┌──────────────────────────────────────────────────────────────────┐
│ Created by provider via register_service                         │
│ ├─ provider: address                                             │
│ ├─ name: vector<u8>                                              │
│ ├─ price_per_unit: u64                                           │
│ ├─ total_served: u64  ←── increments on each purchase           │
│ ├─ revenue: Balance<SUI>  ←── provider's earnings               │
│ └─ active: bool                                                  │
│                                                                  │
│ Mutated by: purchase_access, update_service_price, withdraw_revenue│
└──────────────────────────────────────────────────────────────────┘

AccessCapability (Per-purchase, Owned + store)
┌──────────────────────────────────────────────────────────────────┐
│ Created by purchase_access, transferred to buyer                 │
│ ├─ service_id: ID                                                │
│ ├─ remaining_units: u64  ←── decrements on use_access           │
│ ├─ expires_at: u64 (0 = no expiry)                              │
│ ├─ rate_limit: u64 (0 = no limit)                               │
│ ├─ epoch_usage: u64  ←── resets each epoch                      │
│ └─ last_epoch: u64                                               │
│                                                                  │
│ Lifecycle: Created → Used (mutated) → Burned (destroyed)        │
│ Composable: Can be passed to other functions in same PTB!       │
└──────────────────────────────────────────────────────────────────┘
```

## Comparison with x402

| Feature | x402 (HTTP) | APEX (Sui) |
|---------|-------------|------------|
| Payment verification | Off-chain facilitator | On-chain Move VM |
| Atomicity | None (pay then hope) | Full (PTB atomic) |
| Refund risk | High | Zero |
| Settlement | Async | Instant |
| Composability | None | Full (PTB) |
| Streaming payments | Complex | Native |
| Rate limiting | Server-side | On-chain enforced |

## Testing with sui-sandbox

sui-sandbox enables local Move VM execution without deploying to testnet:

```bash
# Run the full demo
cargo run --example apex_protocol_demo

# What it demonstrates:
# 1. Deploy APEX contracts locally
# 2. Initialize protocol (creates shared ProtocolConfig)
# 3. Register service provider
# 4. Agent purchases AccessCapability
# 5. Agent uses access (consumes units)
```

**Key insight:** The same bytecode executes locally as on mainnet. Gas costs, object effects, and error handling all match production behavior.

## Security Considerations

1. **Protocol pause**: Admin can pause via `set_protocol_paused()`
2. **Rate limiting**: Per-epoch limits enforced on-chain
3. **Expiry**: Capabilities can have time-based expiration
4. **Spending limits**: AgentWallet has per-tx and daily limits
5. **Shield transfers**: Hash-locked for private payments

## Future Enhancements

- [ ] Integration with Seal key servers for encrypted content
- [ ] DeepBook integration for atomic swap patterns
- [ ] Multi-signature admin capabilities
- [ ] Subscription billing patterns
- [ ] Cross-chain bridge support
