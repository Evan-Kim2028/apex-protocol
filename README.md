# APEX Protocol

**Sui-Native Payment & Trading Infrastructure for AI Agents**

APEX (Agent Payment EXecution Protocol) is a production-ready payment and trading infrastructure designed for AI agents on Sui, featuring real DeepBook V3 DEX integration with both spot and margin trading capabilities.

## Why APEX?

APEX is a Sui-native alternative to x402/Dexter payment protocols, designed to leverage Sui's unique capabilities:

| Feature | x402/Dexter (Solana/Base) | APEX (Sui) |
|---------|---------------------------|------------|
| **Atomicity** | Multi-transaction | Single PTB (Programmable Transaction Block) |
| **Access Control** | Account-based | Capability Objects |
| **Payments** | Settlement Layer | Streaming + Intent-based |
| **DEX Integration** | Jupiter/Uniswap | DeepBook V3 Native |
| **Margin Trading** | External protocols | DeepBook Margin Native |
| **Storage** | Off-chain | Walrus Integration |
| **Agent Security** | Limited | Bounded Limits + Pause + Shield Transfers |

### Key Advantages for AI Agents

1. **Atomic Pay-and-Use**: In a single PTB, an agent can pay for a service AND execute trades - impossible on other chains
2. **Capability-Based Access**: Secure delegated permissions without exposing private keys
3. **Intent-Based Trading**: Declare desired outcomes, let executors handle routing
4. **Streaming Payments**: Per-second micropayments for API usage
5. **Margin Trading**: Leveraged positions with risk management built-in

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           APEX Protocol                                  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐ │
│  │    apex      │  │   payment    │  │   trading    │  │   walrus     │ │
│  │   (core)     │  │ (x402-style) │  │   intents    │  │  payments    │ │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘ │
│         │                 │                 │                 │          │
│         └─────────────────┴────────┬────────┴─────────────────┘          │
│                                    │                                     │
│  ┌─────────────────────────────────┴─────────────────────────────────┐  │
│  │                      DeepBook V3 Integration                       │  │
│  ├───────────────────────────────┬───────────────────────────────────┤  │
│  │        deepbook_v3            │      deepbook_margin_v3           │  │
│  │    (Spot Trading/Swaps)       │    (Leveraged Positions)          │  │
│  └───────────────────────────────┴───────────────────────────────────┘  │
│                                    │                                     │
└────────────────────────────────────┼─────────────────────────────────────┘
                                     │
                    ┌────────────────┴────────────────┐
                    │         Sui Blockchain          │
                    │   (PTBs, Objects, Capabilities) │
                    └─────────────────────────────────┘
```

## Modules

### Core Modules

| Module | File | Description |
|--------|------|-------------|
| `apex` | `agent_protocol.move` | Core agent registry, service providers, streaming payments |
| `payment` | `dexter_payment.move` | x402-style payments, shield transfers, agent wallets |
| `trading_intents` | `trading_intents.move` | Intent-based SUI pair trading with executor network |
| `trading_intents_generic` | `trading_intents_generic.move` | Generic coin support for any token pair |
| `walrus_payments` | `walrus_payments.move` | Decentralized storage payment integration |

### DeepBook Integration

| Module | File | Description |
|--------|------|-------------|
| `deepbook_v3` | `deepbook_integration.move` | Spot trading, swaps, pool queries |
| `deepbook_margin_v3` | `deepbook_margin_integration.move` | Margin trading, collateral, borrowing |

## DeepBook V3 Package Addresses

### Core DeepBook
| Network | Address |
|---------|---------|
| **Mainnet** | `0x2d93777cc8b67c064b495e8606f2f8f5fd578450347bbe7b36e0bc03963c1c40` |
| **Testnet** | `0x22be4cade64bf2d02412c7e8d0e8beea2f78828b948118d46735315409371a3c` |

### DeepBook Margin
| Network | Address |
|---------|---------|
| **Mainnet** | `0x97d9473771b01f77b0940c589484184b49f6444627ec121314fae6a6d36fb86b` |
| **Testnet** | `0xd6a42f4df4db73d68cbeb52be66698d2fe6a9464f45ad113ca52b0c6ebd918b6` |

## Quick Start

### Prerequisites

- [Sui CLI](https://docs.sui.io/build/install) installed
- Node.js 18+ (for PTB sandbox)

### Build

```bash
# Clone the repository
git clone https://github.com/YOUR_ORG/apex-protocol.git
cd apex-protocol

# Build Move contracts
sui move build

# Run tests
sui move test
```

### Local PTB Sandbox

```bash
# Install dependencies
cd sandbox
npm install

# Run the interactive PTB sandbox
npm run sandbox

# Run example agent scenarios
npm run examples
```

## Usage Examples

### 1. Atomic Pay-and-Trade (Single PTB)

This demonstrates Sui's unique capability - paying for a service AND trading in one atomic transaction:

```typescript
import { TransactionBlock } from '@mysten/sui.js/transactions';

const txb = new TransactionBlock();

// Step 1: Split payment from user's coin
const [paymentCoin] = txb.splitCoins(txb.object(userSuiCoin), [100_000_000n]); // 0.1 SUI

// Step 2: Pay for API service
const accessCap = txb.moveCall({
  target: `${APEX_PACKAGE}::apex::purchase_access`,
  arguments: [txb.object(serviceProvider), paymentCoin],
});

// Step 3: Execute trade with remaining balance
const [remainingBase, quoteOut, deepOut, receipt] = txb.moveCall({
  target: `${APEX_PACKAGE}::deepbook_v3::swap_base_for_quote`,
  typeArguments: [SUI_TYPE, USDC_TYPE],
  arguments: [
    txb.object(pool),
    txb.object(userSuiCoin), // remaining after split
    txb.object(deepCoin),
    txb.pure(minQuoteOut),
    txb.object(CLOCK),
  ],
});

// All happens atomically - if trade fails, payment is refunded!
```

### 2. Intent-Based Trading

Agents declare trading intents; executors compete to fill them:

```typescript
// Agent creates intent
const txb = new TransactionBlock();

txb.moveCall({
  target: `${APEX_PACKAGE}::trading_intents::create_swap_intent`,
  typeArguments: [SUI_TYPE],
  arguments: [
    txb.object(intentRegistry),
    txb.object(inputCoin),          // Escrowed
    txb.pure(minOutputAmount),
    txb.pure(recipientAddress),
    txb.pure(deadlineMs),
    txb.object(CLOCK),
  ],
});

// Executor fills intent via DeepBook
const fillTxb = new TransactionBlock();

fillTxb.moveCall({
  target: `${APEX_PACKAGE}::deepbook_v3::execute_intent_swap`,
  typeArguments: [SUI_TYPE, USDC_TYPE],
  arguments: [
    fillTxb.object(pool),
    fillTxb.object(intentInputCoin),
    fillTxb.object(deepForFees),
    fillTxb.pure(minOutput),
    fillTxb.pure(intentRecipient),
    fillTxb.object(CLOCK),
  ],
});
```

### 3. Margin Trading

Open leveraged positions with collateral management:

```typescript
const txb = new TransactionBlock();

// Deposit collateral
txb.moveCall({
  target: `${APEX_PACKAGE}::deepbook_margin_v3::deposit_collateral`,
  typeArguments: [BASE_TYPE, QUOTE_TYPE, COLLATERAL_TYPE],
  arguments: [
    txb.object(marginManager),
    txb.object(marginRegistry),
    txb.object(baseOracle),
    txb.object(quoteOracle),
    txb.object(collateralCoin),
    txb.object(CLOCK),
  ],
});

// Borrow against collateral
txb.moveCall({
  target: `${APEX_PACKAGE}::deepbook_margin_v3::borrow_base`,
  typeArguments: [BASE_TYPE, QUOTE_TYPE],
  arguments: [
    txb.object(marginManager),
    txb.object(marginRegistry),
    txb.object(baseMarginPool),
    txb.object(baseOracle),
    txb.object(quoteOracle),
    txb.object(pool),
    txb.pure(borrowAmount),
    txb.object(CLOCK),
  ],
});

// Check position health
const riskRatio = txb.moveCall({
  target: `${APEX_PACKAGE}::deepbook_margin_v3::get_risk_ratio`,
  typeArguments: [BASE_TYPE, QUOTE_TYPE],
  arguments: [
    txb.object(marginManager),
    txb.object(marginRegistry),
    txb.object(baseMarginPool),
    txb.object(quoteMarginPool),
    txb.object(baseOracle),
    txb.object(quoteOracle),
    txb.object(CLOCK),
  ],
});
```

### 4. Streaming Payments

Per-second micropayments for API usage:

```typescript
// Start a payment stream
const txb = new TransactionBlock();

txb.moveCall({
  target: `${APEX_PACKAGE}::apex::start_stream`,
  arguments: [
    txb.object(agent),
    txb.object(serviceProvider),
    txb.object(escrowCoin),      // Total budget
    txb.pure(ratePerSecond),
    txb.object(CLOCK),
  ],
});

// Later: claim accrued payment
const claimTxb = new TransactionBlock();

claimTxb.moveCall({
  target: `${APEX_PACKAGE}::apex::claim_stream`,
  arguments: [
    claimTxb.object(stream),
    claimTxb.object(CLOCK),
  ],
});
```

## Security

### Audit Status

All modules have undergone security review with **19 issues identified and fixed**:

| Severity | Count | Status |
|----------|-------|--------|
| Critical | 3 | ✅ Fixed |
| High | 5 | ✅ Fixed |
| Medium | 7 | ✅ Fixed |
| Low | 4 | ✅ Fixed |

See `SECURITY_AUDIT_REPORT.md` for detailed findings.

### Security Features

- **Bounded Agent Limits**: Spending caps and rate limits per agent
- **Shield Transfers**: Hash-locked transfers requiring secret to claim
- **Pausable Operations**: Emergency pause for service providers
- **Deadline Enforcement**: All intents have mandatory expiration
- **Risk Ratio Monitoring**: Automatic health checks for margin positions

## Project Structure

```
apex-protocol/
├── Move.toml                          # Package configuration
├── sources/
│   ├── agent_protocol.move            # Core APEX (apex module)
│   ├── dexter_payment.move            # Payment infrastructure
│   ├── trading_intents.move           # SUI trading intents
│   ├── trading_intents_generic.move   # Generic coin trading
│   ├── walrus_payments.move           # Storage payments
│   ├── deepbook_integration.move      # DeepBook V3 spot
│   └── deepbook_margin_integration.move # DeepBook margin
├── sandbox/                           # Local PTB testing
│   ├── package.json
│   ├── src/
│   │   ├── index.ts                   # Interactive sandbox
│   │   ├── client.ts                  # Sui client wrapper
│   │   ├── ptb-builder.ts             # PTB construction helpers
│   │   └── examples/                  # Agent scenario examples
│   └── tsconfig.json
├── scripts/
│   └── test_deepbook_integration.sh   # Shell-based testing
├── SECURITY_AUDIT_REPORT.md
└── README.md
```

## Dependencies

```toml
[dependencies]
# DeepBook V3 core - includes Sui framework
deepbook = { git = "https://github.com/MystenLabs/deepbookv3.git", subdir = "packages/deepbook", rev = "main" }

# DeepBook V3 margin for leveraged trading
deepbook_margin = { git = "https://github.com/MystenLabs/deepbookv3.git", subdir = "packages/deepbook_margin", rev = "main" }
```

## Deployment

### Testnet

```bash
# Switch to testnet
sui client switch --env testnet

# Get testnet SUI
sui client faucet

# Deploy
sui client publish --gas-budget 500000000
```

### Mainnet

```bash
# Switch to mainnet
sui client switch --env mainnet

# Deploy (ensure sufficient gas)
sui client publish --gas-budget 1000000000
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run tests: `sui move test`
5. Submit a pull request

## License

MIT

## Links

- [Sui Documentation](https://docs.sui.io/)
- [DeepBook V3 Documentation](https://docs.sui.io/standards/deepbook)
- [DeepBook V3 GitHub](https://github.com/MystenLabs/deepbookv3)
- [x402 Protocol](https://x402.org/) (for comparison)
