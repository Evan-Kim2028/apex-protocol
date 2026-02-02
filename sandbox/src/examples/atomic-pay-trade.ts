/**
 * Example: Atomic Pay-and-Trade
 *
 * This is the flagship example demonstrating Sui's unique PTB capability:
 * Paying for a service AND executing a trade in a SINGLE atomic transaction.
 *
 * This pattern is IMPOSSIBLE on other blockchains which require multiple
 * transactions with potential failure between them.
 */

import { ApexClient } from '../client.js';
import { createPTB } from '../ptb-builder.js';
import { NETWORKS } from '../config.js';
import chalk from 'chalk';

const CONFIG = {
  network: 'testnet' as const,
  apexPackage: '0x0',

  // Service provider (API endpoint owner)
  serviceProvider: '0x...',

  // DeepBook pool
  pool: '0x...',

  // User's coins
  suiCoin: '0x...',
  deepCoin: '0x...',

  // Pricing
  apiCost: 100_000_000n, // 0.1 SUI for API access
  tradeAmount: 500_000_000n, // 0.5 SUI to trade
  minOutput: 1_000_000n, // Minimum USDC expected
};

async function main() {
  console.log(chalk.cyan('\n═══ Atomic Pay-and-Trade Demo ═══\n'));

  console.log(chalk.bgYellow.black(' THIS IS THE KILLER FEATURE OF SUI FOR AI AGENTS '));
  console.log('');

  const client = new ApexClient({
    network: CONFIG.network,
    apexPackage: CONFIG.apexPackage,
  });

  // === The Problem on Other Chains ===

  console.log(chalk.red('❌ On Ethereum/Solana/Base:\n'));
  console.log(chalk.gray(`
  Transaction 1: Pay for API access
       │
       ▼
  [WAIT FOR CONFIRMATION]  ← Risk: Network congestion, tx could fail
       │
       ▼
  Transaction 2: Execute trade
       │
       ▼
  [WAIT FOR CONFIRMATION]  ← Risk: Price moved, slippage, MEV
       │
       ▼
  Transaction 3: Use API with proof
       │
       ▼
  [PROBLEMS]:
    • Paid for API but trade failed → Lost money
    • Trade succeeded but API payment failed → Inconsistent state
    • MEV bots can frontrun between txs
    • User must sign 3 separate transactions
    • Gas paid 3 times
`));

  // === The Solution on Sui ===

  console.log(chalk.green('\n✓ On Sui with APEX Protocol:\n'));
  console.log(chalk.gray(`
  Single PTB Transaction:
  ┌─────────────────────────────────────────────────────────────┐
  │  Command 1: Split payment from user's coin                  │
  │      ↓                                                      │
  │  Command 2: Pay for API access → Get AccessCapability       │
  │      ↓                                                      │
  │  Command 3: Execute trade via DeepBook                      │
  │      ↓                                                      │
  │  Command 4: Transfer outputs to user                        │
  └─────────────────────────────────────────────────────────────┘
                           │
                           ▼
  [ATOMIC GUARANTEES]:
    • ALL succeed or ALL fail (no partial state)
    • Single signature from user
    • Single gas payment
    • No MEV between operations
    • Instant finality (~400ms)
`));

  // === Build the Atomic PTB ===

  console.log(chalk.yellow('\n═══ Building Atomic PTB ═══\n'));

  const ptb = createPTB(NETWORKS[CONFIG.network], CONFIG.apexPackage);

  const fullCode = `
import { Transaction } from '@mysten/sui/transactions';

const tx = new Transaction();

// ═══════════════════════════════════════════════════════════════
// STEP 1: Split coins for payment and trading
// ═══════════════════════════════════════════════════════════════

// Split exact payment amount for API access
const [paymentCoin] = tx.splitCoins(
  tx.object("${CONFIG.suiCoin}"),
  [tx.pure.u64(${CONFIG.apiCost}n)]
);

// Split amount for trading
const [tradeCoin] = tx.splitCoins(
  tx.object("${CONFIG.suiCoin}"),
  [tx.pure.u64(${CONFIG.tradeAmount}n)]
);

// ═══════════════════════════════════════════════════════════════
// STEP 2: Pay for API access (get capability object)
// ═══════════════════════════════════════════════════════════════

const accessCapability = tx.moveCall({
  target: "${CONFIG.apexPackage}::apex::purchase_access",
  arguments: [
    tx.object("${CONFIG.serviceProvider}"),
    paymentCoin,
  ],
});

// ═══════════════════════════════════════════════════════════════
// STEP 3: Execute trade via DeepBook
// ═══════════════════════════════════════════════════════════════

const [remainingBase, quoteOut, deepRefund, receipt] = tx.moveCall({
  target: "${CONFIG.apexPackage}::deepbook_v3::swap_base_for_quote",
  typeArguments: [
    "0x2::sui::SUI",
    "${NETWORKS[CONFIG.network].tokens.usdc}",
  ],
  arguments: [
    tx.object("${CONFIG.pool}"),
    tradeCoin,
    tx.object("${CONFIG.deepCoin}"),
    tx.pure.u64(${CONFIG.minOutput}n),
    tx.object("0x6"), // Clock
  ],
});

// ═══════════════════════════════════════════════════════════════
// STEP 4: Transfer all outputs to user
// ═══════════════════════════════════════════════════════════════

tx.transferObjects(
  [accessCapability, quoteOut, remainingBase, deepRefund],
  tx.pure.address("${client.address}")
);

// ═══════════════════════════════════════════════════════════════
// Execute the atomic transaction
// ═══════════════════════════════════════════════════════════════

const result = await client.signAndExecuteTransaction({
  transaction: tx,
  options: {
    showEffects: true,
    showEvents: true,
    showBalanceChanges: true,
  },
});

// If we get here, EVERYTHING succeeded atomically:
// ✓ API payment processed
// ✓ Access capability received
// ✓ Trade executed at expected price
// ✓ All outputs in user's wallet
`;

  console.log(chalk.white('Complete TypeScript Code:'));
  console.log(chalk.gray('─'.repeat(60)));
  console.log(chalk.green(fullCode));
  console.log(chalk.gray('─'.repeat(60)));

  // === Use Cases ===

  console.log(chalk.cyan('\n═══ AI Agent Use Cases ═══\n'));

  const useCases = [
    {
      title: 'Trading Bot with Premium Data',
      description: 'Pay for real-time market data AND execute trade based on it',
      flow: 'Pay API → Get price feed → Execute trade → All atomic',
    },
    {
      title: 'DeFi Aggregator',
      description: 'Pay aggregator fee AND get best execution across DEXs',
      flow: 'Pay fee → Query routes → Execute best route → Atomic',
    },
    {
      title: 'AI Model Inference + Action',
      description: 'Pay for AI inference AND act on the result',
      flow: 'Pay model API → Get prediction → Trade on prediction → Atomic',
    },
    {
      title: 'Automated Rebalancing',
      description: 'Pay for portfolio analysis AND rebalance positions',
      flow: 'Pay analyzer → Get recommendations → Execute swaps → Atomic',
    },
    {
      title: 'Cross-Protocol Operations',
      description: 'Pay for oracle data AND use it in DeFi protocols',
      flow: 'Pay oracle → Get price → Update position → Atomic',
    },
  ];

  for (const useCase of useCases) {
    console.log(chalk.yellow(`📌 ${useCase.title}`));
    console.log(chalk.gray(`   ${useCase.description}`));
    console.log(chalk.white(`   Flow: ${useCase.flow}`));
    console.log('');
  }

  // === Comparison Table ===

  console.log(chalk.cyan('═══ Platform Comparison ═══\n'));

  console.log(chalk.white('Feature                  | Ethereum | Solana | Sui (APEX)'));
  console.log(chalk.gray('─'.repeat(60)));
  console.log(chalk.gray('Atomic Pay+Trade         | ❌       | ❌     | ✓ Native PTB'));
  console.log(chalk.gray('Single Signature         | ❌       | ❌     | ✓ One sign'));
  console.log(chalk.gray('MEV Protection           | ❌       | ~      | ✓ Atomic'));
  console.log(chalk.gray('Partial Failure Risk     | ❌ High  | ❌ Med | ✓ None'));
  console.log(chalk.gray('Gas Efficiency           | ❌ 3x    | ~ 2x   | ✓ 1x'));
  console.log(chalk.gray('Finality                 | ~15min   | ~0.4s  | ✓ ~0.4s'));
  console.log(chalk.gray('Capability Objects       | ❌       | ❌     | ✓ Native'));
  console.log(chalk.gray('Composability            | Limited  | Good   | ✓ Excellent'));
  console.log('');

  console.log(chalk.bgGreen.black(' APEX Protocol: Built for the atomic future of AI agents '));
  console.log('');
}

main().catch(console.error);
