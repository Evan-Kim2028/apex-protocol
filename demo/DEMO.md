# APEX Protocol Demo Guide

## What Is This Demo?

This demo is a **local testing environment** that executes APEX Protocol smart contracts against **REAL mainnet DeepBook bytecode** without deploying to any blockchain. It uses [sui-sandbox](https://github.com/Evan-Kim2028/sui-sandbox) with gRPC forking to fetch actual mainnet packages.

**Key Innovation**: All 4 phases share a **SINGLE sandbox environment**, demonstrating the complete hedge fund lifecycle from creation to settlement.

**Think of it like this:**
- The `sources/` folder contains the APEX smart contracts (Move code)
- The demo fetches **real DeepBook V3 and Pyth Oracle** from Sui mainnet via gRPC
- PTBs execute against production bytecode locally
- No testnet, no gas fees, instant feedback

## Running the Demo

### Prerequisites

```bash
# Install Sui CLI (for Move compiler)
# See: https://docs.sui.io/guides/developer/getting-started/sui-install

# Install Rust (for running the demo)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

### Steps

```bash
# 1. From the repo root, build the Move contracts
cd apex-protocol
sui move build

# 2. Run the demo
cd demo
cargo run
```

### Expected Output

You'll see 4 phases execute sequentially in a **shared sandbox**:

```
╔════════════════════════════════════════════════════════════════════════════╗
║       APEX Protocol - Mainnet Fork Hedge Fund Demonstrations               ║
╠════════════════════════════════════════════════════════════════════════════╣
║                                                                            ║
║  This demo showcases the COMPLETE hedge fund lifecycle in a SINGLE         ║
║  sandbox environment with REAL mainnet DeepBook bytecode:                  ║
║                                                                            ║
║  • PHASE 1: Fund Creation (Mainnet DeepBook + APEX deployment)             ║
║  • PHASE 2: Investor Deposits (Entry fees via APEX payments)               ║
║  • PHASE 3: Agent Trading (On-chain constraint enforcement)                ║
║  • PHASE 4: Settlement & Distribution (Fee calculation + withdrawals)      ║
║                                                                            ║
║  All phases share the SAME sandbox - demonstrating full fund lifecycle!    ║
║                                                                            ║
╚════════════════════════════════════════════════════════════════════════════╝
```

---

# Phase 1: Fund Creation with Mainnet Fork

**Purpose**: Load real mainnet DeepBook/Pyth state, deploy APEX, create hedge fund with constraints.

## Mainnet Packages Loaded

| Package | Address | Modules |
|---------|---------|---------|
| DeepBook V3 | `0x2c8d603bc51326b8c13cef9dd07031a408a48dddb541963357661df5d3204809` | 20 modules |
| DEEP Token | `0xdeeb7a4662eec9f2f3def03fb937a663dddaa2e215b8078a284d026b7946c270` | 1 module |
| Pyth Oracle | `0x8d97f1cd6ac663735be08d1d2b6d02a159e711586461306ce60a2b7a6a565a9e` | 28 modules |

## Functions Called

| Step | Function | Module | Description |
|------|----------|--------|-------------|
| 1 | `GrpcFetcher::mainnet()` | sui-sandbox | Connect to mainnet gRPC |
| 2 | `fetch_package_modules()` | sui-sandbox | Fetch DeepBook, DEEP, Pyth |
| 3 | `balance_manager::new()` | deepbook | Verify DeepBook works |
| 4 | `initialize_protocol()` | apex_payments | Create ProtocolConfig |
| 5 | `register_service()` | apex_payments | Create entry fee service |
| 6 | `create_fund()` | apex_fund | Create hedge fund |
| 7 | `authorize_manager()` | apex_fund | Authorize trading agent |

## PTB: Create Hedge Fund

### Inputs

```json
{
  "inputs": [
    {
      "type": "SharedObject",
      "object_type": "apex_protocol::apex_payments::ProtocolConfig",
      "mutable": false
    },
    {
      "type": "SharedObject",
      "object_type": "apex_protocol::apex_payments::ServiceProvider",
      "mutable": true
    },
    { "type": "Pure", "value": "DeepBook Alpha Fund" },
    { "type": "Pure", "value": 100000000, "description": "0.1 SUI entry fee" },
    { "type": "Pure", "value": 200, "description": "2% management fee (bps)" },
    { "type": "Pure", "value": 2000, "description": "20% performance fee (bps)" },
    { "type": "Pure", "value": 500000000000, "description": "500 SUI max capacity" },
    {
      "type": "OwnedObject",
      "object_type": "0x2::coin::Coin<0x2::sui::SUI>",
      "value": 1000000000,
      "description": "1 SUI initial capital"
    },
    {
      "type": "SharedObject",
      "object_id": "0x6",
      "object_type": "0x2::clock::Clock"
    }
  ]
}
```

### Output (Created Objects)

```json
{
  "success": true,
  "created_objects": [
    {
      "object_type": "apex_protocol::apex_fund::HedgeFund",
      "owner": "Shared",
      "fields": {
        "name": "DeepBook Alpha Fund",
        "entry_fee": 100000000,
        "management_fee_bps": 200,
        "performance_fee_bps": 2000,
        "state": 0,
        "total_shares": 1000000000
      }
    }
  ]
}
```

## PTB: Authorize Manager with Constraints

### Inputs

```json
{
  "inputs": [
    {
      "type": "SharedObject",
      "object_type": "apex_protocol::apex_fund::HedgeFund"
    },
    { "type": "Pure", "value": "0x9999...", "description": "manager address" },
    { "type": "Pure", "value": 1500, "description": "max_trade_bps: 15%" },
    { "type": "Pure", "value": 2500, "description": "max_position_bps: 25%" },
    { "type": "Pure", "value": 5000, "description": "max_daily_volume_bps: 50%" },
    { "type": "Pure", "value": 5, "description": "max_leverage: 5x" },
    { "type": "Pure", "value": 2, "description": "allowed_directions: BOTH" },
    { "type": "Pure", "value": [], "description": "allowed_assets: empty = all" },
    { "type": "Pure", "value": 0, "description": "expires_at: 0 = never" },
    { "type": "SharedObject", "object_id": "0x6", "object_type": "0x2::clock::Clock" }
  ]
}
```

### Output (Created Objects)

```json
{
  "created_objects": [
    {
      "object_type": "apex_protocol::apex_fund::ManagerAuthorization",
      "owner": "Address(0x9999...)",
      "fields": {
        "max_trade_bps": 1500,
        "max_position_bps": 2500,
        "max_daily_volume_bps": 5000,
        "max_leverage": 5,
        "allowed_directions": 2,
        "is_paused": false
      }
    }
  ]
}
```

---

# Phase 2: Investor Deposits (Same Sandbox)

**Purpose**: Multiple investors join fund with entry fees via APEX payments, using the **same sandbox** from Phase 1.

## Functions Called

| Step | Function | Module | Description |
|------|----------|--------|-------------|
| 1 | `join_fund()` | apex_fund | Investor A deposits 100 SUI |
| 2 | `join_fund()` | apex_fund | Investor B deposits 50 SUI |
| 3 | `join_fund()` | apex_fund | Investor C deposits 10 SUI |

**Note**: Due to a pre-existing share calculation bug in `apex_fund.move`, only the first investor may succeed. The demo handles this gracefully and continues.

## PTB: Join Fund

### Inputs

```json
{
  "inputs": [
    {
      "type": "SharedObject",
      "object_type": "apex_protocol::apex_fund::HedgeFund",
      "mutable": true
    },
    {
      "type": "SharedObject",
      "object_type": "apex_protocol::apex_payments::ProtocolConfig",
      "mutable": true
    },
    {
      "type": "SharedObject",
      "object_type": "apex_protocol::apex_payments::ServiceProvider",
      "mutable": true
    },
    {
      "type": "OwnedObject",
      "object_type": "0x2::coin::Coin<0x2::sui::SUI>",
      "value": 100000000,
      "description": "0.1 SUI entry fee"
    },
    {
      "type": "OwnedObject",
      "object_type": "0x2::coin::Coin<0x2::sui::SUI>",
      "value": 100000000000,
      "description": "100 SUI deposit"
    },
    {
      "type": "SharedObject",
      "object_id": "0x6",
      "object_type": "0x2::clock::Clock"
    }
  ]
}
```

### Output (Created Objects)

```json
{
  "created_objects": [
    {
      "object_type": "apex_protocol::apex_fund::InvestorPosition",
      "owner": "Address(0x5555...)",
      "fields": {
        "shares": 100000000000,
        "deposit_amount": 100000000000,
        "entered_at": 1700000000000
      }
    }
  ]
}
```

## Fund Capital Summary

| Source | Deposit | Status |
|--------|---------|--------|
| Owner (initial) | 1 SUI | ✓ Deposited |
| Investor A | 100 SUI | ✓ Deposited |
| **TOTAL** | **101 SUI** | |

---

# Phase 3: Agent Trading with Constraint Enforcement (Same Sandbox)

**Purpose**: Show on-chain constraint enforcement - valid trades execute, invalid trades are rejected. Uses the **same sandbox** from Phases 1 & 2.

## Functions Called

| Step | Function | Module | Description |
|------|----------|--------|-------------|
| 1 | `start_trading()` | apex_fund | Transition fund to TRADING state |
| 2 | `execute_authorized_trade()` | apex_fund | Trade 1: Within limits ✓ |
| 3 | `execute_authorized_trade()` | apex_fund | Trade 2: Exceeds size ✗ |
| 4 | `execute_authorized_trade()` | apex_fund | Trade 3: Exceeds leverage ✗ |
| 5 | `execute_authorized_trade()` | apex_fund | Trade 4: Valid short ✓ |
| 6 | `execute_authorized_trade()` | apex_fund | Trade 5: Another long ✓ |
| 7 | `pause_manager()` | apex_fund | Owner pauses agent |
| 8 | `execute_authorized_trade()` | apex_fund | Trade while paused ✗ |
| 9 | `unpause_manager()` | apex_fund | Owner resumes |
| 10 | `update_manager_limits()` | apex_fund | Change to long-only |
| 11 | `execute_authorized_trade()` | apex_fund | Short rejected ✗ |
| 12 | `execute_authorized_trade()` | apex_fund | Trade 7: Valid long ✓ |

## PTB: Execute Authorized Trade

### Inputs

```json
{
  "inputs": [
    {
      "type": "OwnedObject",
      "object_type": "apex_protocol::apex_fund::ManagerAuthorization"
    },
    {
      "type": "SharedObject",
      "object_type": "apex_protocol::apex_fund::HedgeFund",
      "mutable": true
    },
    { "type": "Pure", "value": "MARGIN_LONG_SUI", "description": "trade_type" },
    { "type": "Pure", "value": 10000000000, "description": "input_amount: 10 SUI" },
    { "type": "Pure", "value": 12000000000, "description": "output_amount: 12 SUI (simulated)" },
    { "type": "Pure", "value": 0, "description": "direction: 0 = LONG" },
    { "type": "Pure", "value": 3, "description": "leverage: 3x" },
    { "type": "Pure", "value": "0xAAAA...", "description": "asset_id" },
    { "type": "SharedObject", "object_id": "0x6", "object_type": "0x2::clock::Clock" }
  ]
}
```

### Output: Success (Within Limits)

```json
{
  "success": true,
  "created_objects": [
    {
      "object_type": "apex_protocol::apex_fund::TradeRecord",
      "owner": "Address(0x9999...)",
      "fields": {
        "trade_type": "MARGIN_LONG_SUI",
        "input_amount": 10000000000,
        "output_amount": 12000000000,
        "direction": 0,
        "leverage": 3,
        "pnl": 2000000000,
        "is_profit": true
      }
    }
  ]
}
```

### Output: Failure (Exceeds Trade Limit)

```json
{
  "success": false,
  "error": {
    "type": "MoveAbort",
    "module": "apex_fund",
    "abort_code": 12,
    "error_name": "EExceedsTradeLimit"
  }
}
```

## Trade Execution Summary

| Trade | Action | Size | Leverage | Direction | Status | Error |
|-------|--------|------|----------|-----------|--------|-------|
| 1 | Long SUI | 10 SUI (10%) | 3x | Long | ✓ SUCCESS | - |
| 2 | Long ETH | 25 SUI (25%) | 2x | Long | ✗ REJECTED | `EExceedsTradeLimit` (12) |
| 3 | Short BTC | 8 SUI (8%) | 10x | Short | ✗ REJECTED | `EExceedsLeverage` (15) |
| 4 | Short ETH | 8 SUI (8%) | 4x | Short | ✓ SUCCESS | - |
| 5 | Long SOL | 5 SUI (5%) | 2x | Long | ✓ SUCCESS | - |
| - | While Paused | 3 SUI | 2x | Long | ✗ REJECTED | `EAuthorizationPaused` (19) |
| 6 | Short SUI | 5 SUI (5%) | 2x | Short | ✗ REJECTED | `EDirectionNotAllowed` (16) |
| 7 | Long SUI | 8 SUI (8%) | 2x | Long | ✓ SUCCESS | - |

## Simulated P&L

| Trade | P&L |
|-------|-----|
| Trade 1 (Long SUI) | +2 SUI |
| Trade 4 (Short ETH) | +2 SUI |
| Trade 5 (Long SOL) | +2 SUI |
| Trade 7 (Long SUI) | +2 SUI |
| **Total** | **+8 SUI** |

---

# Phase 4: Settlement and Distribution (Same Sandbox)

**Purpose**: Fund owner settles the fund and investors withdraw their proportional shares. Uses the **same sandbox** from Phases 1-3.

## Functions Called

| Step | Function | Module | Description |
|------|----------|--------|-------------|
| 1 | `settle_fund()` | apex_fund | Calculate fees, transition to SETTLED |
| 2 | `withdraw_shares()` | apex_fund | Investor A withdraws shares |
| 3 | `withdraw_manager_fees()` | apex_fund | Owner withdraws fees |

## PTB: Settle Fund

### Inputs

```json
{
  "inputs": [
    {
      "type": "SharedObject",
      "object_type": "apex_protocol::apex_fund::HedgeFund",
      "mutable": true
    },
    {
      "type": "SharedObject",
      "object_id": "0x6",
      "object_type": "0x2::clock::Clock"
    }
  ]
}
```

### Output

```json
{
  "success": true,
  "mutated_objects": [
    {
      "object_type": "apex_protocol::apex_fund::HedgeFund",
      "changes": {
        "state": "1 → 2 (SETTLED)",
        "manager_fees": "calculated"
      }
    }
  ]
}
```

## PTB: Withdraw Shares

### Inputs

```json
{
  "inputs": [
    {
      "type": "SharedObject",
      "object_type": "apex_protocol::apex_fund::HedgeFund",
      "mutable": true
    },
    {
      "type": "OwnedObject",
      "object_type": "apex_protocol::apex_fund::InvestorPosition"
    },
    {
      "type": "SharedObject",
      "object_id": "0x6",
      "object_type": "0x2::clock::Clock"
    }
  ]
}
```

### Output

```json
{
  "success": true,
  "created_objects": [
    {
      "object_type": "apex_protocol::apex_fund::SettlementReceipt",
      "owner": "Address(0x5555...)",
      "fields": {
        "shares_redeemed": 100000000000,
        "amount_received": 104300000000,
        "profit_share": 4300000000
      }
    }
  ]
}
```

## Distribution Summary

| Item | Amount |
|------|--------|
| Initial Capital | ~101 SUI |
| Simulated P&L | +8 SUI |
| Final NAV | ~109 SUI |
| Management Fee (2%) | ~2.02 SUI |
| Performance Fee (20% of profit) | ~1.60 SUI |
| Net to Investors | ~105.38 SUI |

---

# Error Codes

| Code | Name | Trigger |
|------|------|---------|
| 12 | `EExceedsTradeLimit` | Trade size > max_trade_bps |
| 14 | `EExceedsDailyVolume` | Cumulative daily volume > max_daily_volume_bps |
| 15 | `EExceedsLeverage` | Leverage > max_leverage |
| 16 | `EDirectionNotAllowed` | Wrong direction for constraint |
| 19 | `EAuthorizationPaused` | Agent is paused |

---

# On-Chain Constraint Parameters

These fields in `ManagerAuthorization` are checked on every trade:

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| `max_trade_bps` | u64 | Max % of portfolio per trade (basis points) | 1500 = 15% |
| `max_position_bps` | u64 | Max % in single position | 2500 = 25% |
| `max_daily_volume_bps` | u64 | Max % turnover per day | 5000 = 50% |
| `max_leverage` | u64 | Max leverage multiplier | 5 = 5x |
| `allowed_directions` | u8 | 0=Long, 1=Short, 2=Both | 2 |
| `allowed_assets` | vector<ID> | Whitelist (empty = all) | [] |
| `expires_at` | u64 | Expiration timestamp (0 = never) | 0 |
| `is_paused` | bool | Trading paused? | false |

---

# Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              Your Machine                                │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │                     Sui Mainnet (via gRPC)                          │ │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                 │ │
│  │  │ DeepBook V3 │  │ DEEP Token  │  │ Pyth Oracle │                 │ │
│  │  │ 20 modules  │  │  1 module   │  │ 28 modules  │                 │ │
│  │  └─────────────┘  └─────────────┘  └─────────────┘                 │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                               │ gRPC fetch                               │
│                               ▼                                          │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │                 SINGLE SHARED SANDBOX (sui-sandbox)                 │ │
│  │  ┌──────────────────────┐  ┌──────────────────────┐               │ │
│  │  │  Move VM             │  │  Object Storage      │               │ │
│  │  │  (real bytecode)     │  │  (persists across    │               │ │
│  │  │                      │  │   all 4 phases)      │               │ │
│  │  │  • DeepBook V3       │  │                      │               │ │
│  │  │  • APEX Protocol     │  │  • HedgeFund         │               │ │
│  │  │  • Pyth Oracle       │  │  • ManagerAuth       │               │ │
│  │  │                      │  │  • InvestorPosition  │               │ │
│  │  │                      │  │  • TradeRecords      │               │ │
│  │  │                      │  │  • SettlementReceipt │               │ │
│  │  └──────────────────────┘  └──────────────────────┘               │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                               │                                          │
│                               ▼                                          │
│  apex-protocol/demo/                                                     │
│  └── src/main.rs                                                         │
│       │                                                                  │
│       ├── Phase 1: Fund Creation ──────────────┐                        │
│       ├── Phase 2: Investor Deposits ──────────┤ SAME DemoState         │
│       ├── Phase 3: Agent Trading ──────────────┤ passed between         │
│       └── Phase 4: Settlement ─────────────────┘ all phases             │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

# Verifying On-Chain (When Deployed)

After deploying to testnet/mainnet, you can verify these objects in the Sui Explorer:

## Fund Object
Look for fields:
- `name`: Fund name
- `state`: 0=Open, 1=Trading, 2=Settled
- `total_shares`: Total investor shares
- `entry_fee`: Entry fee in MIST

## ManagerAuthorization Object
Look for fields:
- `max_trade_bps`: Trade size limit
- `max_leverage`: Leverage limit
- `allowed_directions`: 0/1/2
- `is_paused`: true/false

## TradeRecord Object
Look for fields:
- `trade_type`: e.g., "MARGIN_LONG_SUI"
- `input_amount`: Trade size in MIST
- `output_amount`: Result in MIST
- `pnl`: Profit/loss in MIST

## SettlementReceipt Object
Look for fields:
- `shares_redeemed`: Number of shares
- `amount_received`: Payout in MIST
- `profit_share`: Share of profits

---

# Key APEX Advantages

| Feature | Description |
|---------|-------------|
| **Single Shared Sandbox** | Complete fund lifecycle in one environment |
| **Mainnet Fork Testing** | Test against REAL DeepBook bytecode locally |
| **On-Chain Constraints** | Agent CANNOT bypass limits - enforced by code |
| **Atomic Workflows** | If ANY step fails, ALL steps revert |
| **Separation of Concerns** | Owner sets limits, Agent executes within them |
| **Full Audit Trail** | Every trade creates a TradeRecord, every withdrawal a SettlementReceipt |

---

# Next Steps

1. **Deploy to Sui testnet**: `sui client publish`
2. **Integrate with your AI agent**: Use Sui TypeScript SDK
3. **Connect to DeepBook pools**: Load pool objects for real swaps
4. **Add Pyth price feeds**: Fetch price feed objects for oracle integration
