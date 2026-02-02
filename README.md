# APEX Protocol

**Sui-Native x402-Style Payment Infrastructure for AI Agents**

APEX (Agent Payment EXecution Protocol) provides x402-equivalent payment functionality on Sui, enabling AI agents to pay for API access with atomic guarantees impossible on other chains.

## What is x402?

[x402](https://x402.org/) is a payment protocol for AI agents, based on HTTP 402 "Payment Required". It enables:
- Pay-per-call API billing
- Machine-to-machine payments
- Automated payment verification

**APEX brings this to Sui** with significant improvements via Programmable Transaction Blocks (PTBs).

## Why Sui / APEX?

| Feature | x402 (Solana/Base) | APEX (Sui) |
|---------|-------------------|------------|
| **Atomicity** | Multi-transaction | Single PTB |
| **Pay-and-Use** | Separate txs | Atomic in one PTB |
| **Access Control** | Account signatures | Capability objects |
| **Streaming** | External service | Native on-chain |
| **Composability** | Limited | Full PTB composability |

### The Killer Feature: Atomic Pay-and-Trade

On Sui, you can pay for an API AND use it in a **single atomic transaction**:

```
┌─────────────────────────────────────────────────────────────┐
│                    Single PTB                                │
│  1. Split payment from user's coin                          │
│  2. Purchase API access → Get AccessCapability              │
│  3. Execute trade via DeepBook                              │
│  4. Transfer results to user                                │
│                                                             │
│  ALL ATOMIC: If step 3 fails, step 2 is reverted!          │
└─────────────────────────────────────────────────────────────┘
```

This is **impossible on other chains** which require multiple transactions.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     APEX Protocol                            │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  apex_payments.move (Core - x402 equivalent)                 │
│  ├── Service registration & pricing                         │
│  ├── Access capability purchase                              │
│  ├── Streaming payments                                      │
│  ├── Agent wallets with spending limits                     │
│  └── Shield transfers (hash-locked)                         │
│                                                              │
│  apex_trading.move (Trading patterns)                        │
│  ├── Trading intents (escrow until filled)                  │
│  ├── Gated trading (require payment first)                  │
│  └── Example PTB patterns                                    │
│                                                              │
└─────────────────────────────────────────────────────────────┘
                          │
                          │ Agents call directly via PTBs
                          ▼
              ┌───────────────────────────┐
              │   DeepBook V3 (external)  │
              │   Any other Sui protocol  │
              └───────────────────────────┘
```

**Note**: APEX does NOT wrap DeepBook. Agents call DeepBook directly in their PTBs. The `apex_trading` module just provides helpful patterns and intent-based trading.

## Modules

### apex_payments.move

The core x402-equivalent payment infrastructure:

| Function | Description |
|----------|-------------|
| `register_service` | Register an API endpoint with pricing |
| `purchase_access` | Pay for access, receive `AccessCapability` |
| `use_access` | Consume units from a capability |
| `verify_access` | Check if capability is valid (read-only) |
| `open_stream` | Start streaming micropayments |
| `record_stream_consumption` | Provider records usage |
| `create_agent_wallet` | Create managed wallet with limits |
| `agent_purchase_access` | Agent pays from its wallet |
| `initiate_shield_transfer` | Hash-locked private transfer |

### apex_trading.move

Trading patterns that compose with APEX payments:

| Function | Description |
|----------|-------------|
| `create_swap_intent` | Declare desired trade, escrow input |
| `fill_intent` | Executor fills intent, receives escrowed funds |
| `cancel_intent` | Creator cancels and gets refund |
| `verify_trade_payment` | Require APEX payment before trading |
| `create_trading_service` | Create gated trading service |

## Quick Start

### Build

```bash
git clone https://github.com/anthropic/apex-protocol.git
cd apex-protocol
sui move build
```

### Deploy to Testnet

```bash
sui client switch --env testnet
sui client faucet
sui client publish --gas-budget 500000000
```

### Example: Purchase API Access

```typescript
import { Transaction } from '@mysten/sui/transactions';

const tx = new Transaction();

// Purchase access capability
const accessCap = tx.moveCall({
  target: `${APEX_PKG}::apex_payments::purchase_access`,
  arguments: [
    tx.object(protocolConfig),
    tx.object(serviceProvider),
    tx.object(paymentCoin),
    tx.pure.u64(units),
    tx.pure.u64(durationMs),
    tx.pure.u64(rateLimit),
    tx.object('0x6'), // Clock
  ],
});

// AccessCapability is returned and can be used in the SAME PTB
tx.transferObjects([accessCap], tx.pure.address(recipient));
```

### Example: Atomic Pay-and-Trade

```typescript
const tx = new Transaction();

// 1. Split payment
const [paymentCoin] = tx.splitCoins(tx.object(userCoin), [
  tx.pure.u64(100_000_000n) // 0.1 SUI
]);

// 2. Purchase API access
const accessCap = tx.moveCall({
  target: `${APEX_PKG}::apex_payments::purchase_access`,
  arguments: [config, service, paymentCoin, units, duration, rateLimit, clock],
});

// 3. Execute trade on DeepBook (DIRECT call, not wrapped)
const [baseOut, quoteOut, deepOut] = tx.moveCall({
  target: `${DEEPBOOK_PKG}::pool::swap_exact_base_for_quote`,
  typeArguments: [BASE_TYPE, QUOTE_TYPE],
  arguments: [pool, baseCoin, deepCoin, minQuote, clock],
});

// 4. Transfer everything
tx.transferObjects([accessCap, quoteOut], recipient);

// ALL ATOMIC - if trade fails, payment is never made!
```

### Example: Trading Intent

```typescript
// Agent creates intent
const tx = new Transaction();
tx.moveCall({
  target: `${APEX_PKG}::apex_trading::create_swap_intent`,
  typeArguments: ['0x2::sui::SUI'],
  arguments: [
    tx.object(inputCoin),      // Escrowed until filled
    tx.pure.u64(minOutput),    // Minimum output required
    tx.pure.address(recipient),
    tx.pure.u64(durationMs),
    tx.object('0x6'),
  ],
});

// Executor fills intent
const fillTx = new Transaction();
const [escrowedInput, receipt] = fillTx.moveCall({
  target: `${APEX_PKG}::apex_trading::fill_intent`,
  typeArguments: [INPUT_TYPE, OUTPUT_TYPE],
  arguments: [
    fillTx.object(intent),
    fillTx.object(outputCoin), // Executor provides output
    fillTx.object('0x6'),
  ],
});
```

## Key Concepts

### AccessCapability

When you pay for API access, you receive an `AccessCapability` object:

```move
public struct AccessCapability has key, store {
    service_id: ID,       // Which service
    remaining_units: u64, // API calls remaining
    expires_at: u64,      // Expiration timestamp
    rate_limit: u64,      // Max units per epoch
}
```

This capability can be:
- Passed to other functions in the same PTB (atomic pay-and-use)
- Stored for later use
- Transferred to other addresses

### Streaming Payments

For continuous API usage (LLM inference, compute, etc.):

```
┌─────────────────────────────────────────────────────────────┐
│  User opens stream with escrow                              │
│           │                                                 │
│           ▼                                                 │
│  Provider records consumption → receives payment            │
│           │                                                 │
│           ▼                                                 │
│  Stream closes → unused escrow refunded                     │
└─────────────────────────────────────────────────────────────┘
```

### Agent Wallets

AI agents can have managed wallets with spending controls:

- **Spend limit**: Max per transaction
- **Daily limit**: Max per day
- **Pause**: Emergency stop
- **Owner control**: Human owner can withdraw/adjust

### Shield Transfers

Hash-locked transfers for privacy:

1. Sender creates transfer with `secret_hash`
2. Recipient claims with `secret` (proves knowledge)
3. Or: Designated recipient claims directly
4. Expired transfers refund to sender

## Project Structure

```
apex-protocol/
├── Move.toml
├── sources/
│   ├── apex_payments.move    # Core x402 payment infrastructure
│   └── apex_trading.move     # Trading patterns & intents
└── README.md
```

## DeepBook Integration

APEX does **not wrap** DeepBook. Instead:

1. `apex_trading.move` imports DeepBook types for reference
2. Agents call DeepBook directly in their PTBs
3. APEX provides payment verification that can gate trading

This is intentional - wrapping adds overhead without value. Agents should call protocols directly.

### DeepBook Package Addresses

| Network | Address |
|---------|---------|
| **Mainnet** | `0x2d93777cc8b67c064b495e8606f2f8f5fd578450347bbe7b36e0bc03963c1c40` |
| **Testnet** | `0x22be4cade64bf2d02412c7e8d0e8beea2f78828b948118d46735315409371a3c` |

## Security

- Overflow-protected arithmetic
- Authorization checks on all sensitive operations
- Bounded inputs (name lengths, etc.)
- Rate limiting support
- Emergency pause capability
- Hash-locked transfers for privacy

## License

MIT

## Links

- [x402 Protocol](https://x402.org/)
- [Sui Documentation](https://docs.sui.io/)
- [DeepBook V3](https://github.com/MystenLabs/deepbookv3)
