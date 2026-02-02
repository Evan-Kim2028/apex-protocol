# APEX Protocol

**Sui-Native Payment Infrastructure for AI Agents**

APEX (Agent Payment EXecution Protocol) is payment infrastructure for AI agents built on Sui, using Programmable Transaction Blocks (PTBs) and Sui's object model.

## What APEX Does

APEX provides on-chain primitives for agent-to-service payments:

- **AccessCapability**: Prepaid API access as a transferable object
- **Payment Streams**: Escrow-based pay-as-you-go with provider-recorded consumption
- **Agent Wallets**: Spending limits and daily caps for autonomous agents
- **Trading Intents**: Escrow-based swap requests filled by executors
- **Shield Transfers**: Hash-locked transfers for secure handoffs

## Core Design

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

**Key properties:**
- **Atomic**: All operations in a PTB succeed or fail together
- **Composable**: Objects created by one call can be inputs to the next
- **Self-custodial**: User builds and submits their own transaction
- **Capability-based**: Access rights are objects, not account permissions

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     APEX Protocol                            │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  apex_payments.move                                          │
│  ├── Service registration & pricing                         │
│  ├── AccessCapability purchase                               │
│  ├── Streaming payments (escrow + provider consumption)     │
│  ├── Agent wallets with spending limits                     │
│  └── Shield transfers (hash-locked)                         │
│                                                              │
│  apex_trading.move                                           │
│  ├── Trading intents (escrow until filled)                  │
│  ├── Gated trading (verify payment first)                   │
│  └── Composable with DeepBook                                │
│                                                              │
│  apex_fund.move  ⭐ NEW                                      │
│  ├── Agentic hedge fund management                          │
│  ├── Multi-investor capital pooling                         │
│  ├── Margin trading simulation (DeepBook integration)       │
│  ├── P&L tracking and profit distribution                   │
│  └── Management & performance fees                           │
│                                                              │
│  apex_seal.move                                              │
│  ├── Encrypted content access control (Seal integration)    │
│  └── Nautilus TEE verification for metered usage            │
│                                                              │
│  apex_workflows.move                                         │
│  ├── Service registry discovery                              │
│  ├── Delegated agent authorization                          │
│  └── Atomic multi-step workflow patterns                    │
│                                                              │
│  apex_sponsor.move                                           │
│  └── Gas sponsorship infrastructure                          │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## Quick Start

### Prerequisites

- [Sui CLI](https://docs.sui.io/guides/developer/getting-started/sui-install) (v1.63.4 or later)
- [Rust](https://rustup.rs/) (for running the demo)

### Installation

```bash
# Clone the repository
git clone https://github.com/Evan-Kim2028/apex-protocol.git
cd apex-protocol

# Build Move contracts
sui move build

# Run tests
sui move test
```

### Run the Local PTB Demo

The `demo/` directory is a **local testing environment** that executes APEX contracts in a real Move VM without deploying to any blockchain. It uses [sui-sandbox](https://github.com/Evan-Kim2028/sui-sandbox) to run the exact same bytecode that would execute on Sui mainnet - instant feedback, no gas fees.

```bash
# First, build the Move contracts
sui move build

# Then run the demo
cd demo
cargo run
```

> **New to the demo?** Read the comprehensive [Demo Guide](demo/DEMO.md) for architecture details, code walkthrough, and troubleshooting.

**5 Comprehensive Demos:**

| Demo | Description |
|------|-------------|
| **Demo 1: Basic Flow** | Deploy → Initialize → Register Service → Purchase → Use |
| **Demo 2: Delegated Authorization** | Human owner delegates spending to AI agent with limits |
| **Demo 3: Service Registry** | Agent discovers services on-chain, then accesses them atomically |
| **Demo 4: Nautilus + Seal** | TEE-verified metering + threshold-encrypted content access |
| **Demo 5: Agentic Hedge Fund** | Multi-agent fund: create → invest → trade → settle → withdraw |

All demos run in the **real Move VM** via sui-sandbox, executing the same bytecode that would run on mainnet.

### Deploy to Testnet

```bash
# Switch to testnet
sui client switch --env testnet

# Get test tokens
sui client faucet

# Deploy
sui client publish --gas-budget 500000000
```

## Project Structure

```
apex-protocol/
├── Move.toml                    # Move package config
├── sources/
│   ├── apex_payments.move       # Core payment infrastructure
│   ├── apex_trading.move        # Trading patterns & intents
│   ├── apex_fund.move           # Agentic hedge fund management
│   ├── apex_workflows.move      # Composable workflow patterns
│   ├── apex_seal.move           # Encrypted access + TEE verification
│   ├── apex_sponsor.move        # Gas sponsorship infrastructure
│   └── apex_tests.move          # Local Move VM tests
├── demo/                        # Local PTB replay demo (5 demos)
│   ├── Cargo.toml               # Imports sui-sandbox
│   ├── DEMO.md                  # Comprehensive demo guide
│   ├── ptb_traces.json          # Generated PTB traces (gitignored)
│   └── src/main.rs              # Full protocol flow demo
├── docs/
│   ├── APEX_ARCHITECTURE.md     # Detailed architecture docs
│   ├── PTB_EXAMPLES.md          # PTB input/output examples
│   ├── PTB_TRACES.md            # PTB traces documentation (local explorer)
│   └── DESIGN_DECISIONS.md      # Design rationale and tradeoffs
└── README.md
```

## PTB Examples

See [docs/PTB_EXAMPLES.md](docs/PTB_EXAMPLES.md) for detailed input/output examples of all APEX operations, including:
- Purchase and use AccessCapability
- Atomic pay-and-trade patterns
- Trading intents and executor fills
- Payment streams
- Agent wallets with limits
- Shield transfers (hash-locked)

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

### Agentic Hedge Fund (apex_fund.move)

A complete on-chain hedge fund implementation for AI agents:

```move
public struct HedgeFund has key {
    id: UID,
    name: vector<u8>,
    manager: address,          // Fund manager agent
    state: u8,                 // OPEN → TRADING → SETTLED
    total_shares: u64,         // Total shares issued
    capital_pool: Balance<SUI>,// Pooled investor capital
    realized_pnl: u64,         // Profit/loss tracking
    management_fee_bps: u64,   // 2% management fee
    performance_fee_bps: u64,  // 20% of profits
}

public struct InvestorPosition has key, store {
    id: UID,
    fund_id: ID,
    investor: address,
    shares: u64,               // Ownership stake
    deposit_amount: u64,       // Original deposit
}
```

**Fund Lifecycle:**
1. **Create**: Manager creates fund with fee structure
2. **Join**: Investors pay APEX entry fee + deposit capital → receive shares
3. **Trade**: Manager executes margin trades (DeepBook integration)
4. **Settle**: Fund closes, fees deducted, withdrawals enabled
5. **Withdraw**: Investors redeem shares for proportional capital + profits

**Security Properties:**
- Manager cannot withdraw investor capital directly
- All trades recorded on-chain (TradeRecord objects)
- Fees capped (max 5% management, 30% performance)
- Proportional profit distribution enforced by contract

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

## Security Features

- Overflow-protected arithmetic
- Authorization checks on all sensitive operations
- Bounded inputs (name lengths, etc.)
- Rate limiting support
- Emergency pause (protocol and agent level)
- Hash-locked transfers with expiry
- Safe withdrawal calculations (handles last-investor edge cases)

## Sandbox Limitations

The demo uses [sui-sandbox](https://github.com/Evan-Kim2028/sui-sandbox) for local Move VM execution. While this provides real bytecode execution, some features are simulated:

| Feature | Sandbox Status | Production Requirement |
|---------|---------------|------------------------|
| Move VM execution | ✅ Real bytecode | Same as mainnet |
| Object storage | ✅ Simulated locally | Sui validators |
| Nautilus TEE | ⚠️ Signature verification only | Deploy Nautilus enclave |
| Seal encryption | ⚠️ dry_run demonstration | Seal key server network |
| Owned object passing | ⚠️ Requires explicit type_tag | Automatic on mainnet |

**Known Issue:** Custom-typed owned objects require `type_tag` to be explicitly set when passed between PTBs. See [sui-sandbox#18](https://github.com/Evan-Kim2028/sui-sandbox/issues/18) for details and workaround.

## Documentation

- **[Demo Guide](demo/DEMO.md)** - How the local demo works, code walkthrough, troubleshooting
- **[PTB Traces](docs/PTB_TRACES.md)** - Local "blockchain explorer" showing all PTB inputs/outputs from the simulation
- [Design Decisions](docs/DESIGN_DECISIONS.md) - Rationale, tradeoffs, competitive analysis, and evolution roadmap
- [PTB Examples](docs/PTB_EXAMPLES.md) - Detailed input/output examples
- [Architecture](docs/APEX_ARCHITECTURE.md) - System diagrams

## References

- [Sui PTB Documentation](https://docs.sui.io/concepts/transactions/prog-txn-blocks)
- [DeepBook V3](https://github.com/MystenLabs/deepbookv3)
- [sui-sandbox](https://github.com/Evan-Kim2028/sui-sandbox) - Local Move VM execution

## License

MIT
