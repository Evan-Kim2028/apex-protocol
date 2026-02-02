/**
 * Example: Intent-Based Trading
 *
 * Demonstrates the intent-based trading pattern where:
 * 1. Agents declare their desired trade outcome
 * 2. Executors compete to fill intents via DeepBook
 * 3. Best execution is achieved through competition
 */

import { ApexClient } from '../client.js';
import { createPTB } from '../ptb-builder.js';
import { NETWORKS } from '../config.js';
import chalk from 'chalk';

const CONFIG = {
  network: 'testnet' as const,
  apexPackage: '0x0',

  // Intent registry
  intentRegistry: '0x...',

  // DeepBook pool
  pool: '0x...',

  // Coins
  suiCoin: '0x...',
  deepCoin: '0x...',
};

async function main() {
  console.log(chalk.cyan('\n═══ Intent-Based Trading Demo ═══\n'));

  const client = new ApexClient({
    network: CONFIG.network,
    apexPackage: CONFIG.apexPackage,
  });

  // === How Intent Trading Works ===

  console.log(chalk.yellow('How Intent-Based Trading Works:\n'));

  console.log(chalk.gray(`
┌─────────────────────────────────────────────────────────────────────┐
│                      INTENT LIFECYCLE                                │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌──────────┐                                                       │
│  │  AGENT   │  "I want to swap 1 SUI for at least 2 USDC"           │
│  └────┬─────┘                                                       │
│       │                                                              │
│       ▼  create_swap_intent()                                        │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                    INTENT (On-Chain)                        │    │
│  │  • Input: 1 SUI (ESCROWED)                                 │    │
│  │  • Min Output: 2 USDC                                       │    │
│  │  • Recipient: Agent's address                               │    │
│  │  • Deadline: 1 hour from now                                │    │
│  └─────────────────────────────────────────────────────────────┘    │
│       │                                                              │
│       │  Executors monitor for profitable intents                   │
│       ▼                                                              │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐                     │
│  │ Executor 1 │  │ Executor 2 │  │ Executor 3 │                     │
│  │ (checks    │  │ (checks    │  │ (checks    │                     │
│  │  DeepBook) │  │  other DEX)│  │  arbitrage)│                     │
│  └─────┬──────┘  └────────────┘  └────────────┘                     │
│        │                                                             │
│        │  "I can fill this for 2.05 USDC via DeepBook"              │
│        ▼                                                             │
│  execute_intent_swap()                                               │
│        │                                                             │
│        ▼                                                             │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                    RESULT                                    │    │
│  │  • Agent receives: 2.05 USDC ✓                              │    │
│  │  • Intent marked: FILLED                                     │    │
│  │  • Executor gets: SwapReceipt (for rewards/tracking)        │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
`));

  // === Part 1: Agent Creates Intent ===

  console.log(chalk.yellow('\n═══ Part 1: Agent Creates Intent ═══\n'));

  const intentCode = `
// Agent creates a swap intent
const agentPtb = createPTB(config, apexPackage);

// Intent parameters
const inputAmount = 1_000_000_000n;  // 1 SUI
const minOutput = 2_000_000n;         // Minimum 2 USDC
const deadline = BigInt(Date.now() + 3600000);  // 1 hour

// Create the intent - this escrows the SUI
const intent = agentPtb.createSwapIntent({
  coinType: "0x2::sui::SUI",
  registry: "${CONFIG.intentRegistry}",
  inputCoin: suiCoinId,
  minOutput: minOutput,
  recipient: agentAddress,
  deadlineMs: deadline,
});

// Execute - SUI is now locked in the intent
const result = await client.execute(agentPtb.build());
const intentId = result.objectChanges.find(c => c.type === 'created')?.objectId;

console.log(\`Intent created: \${intentId}\`);
console.log("Waiting for executor to fill...");
`;

  console.log(chalk.green(intentCode));

  // === Part 2: Executor Fills Intent ===

  console.log(chalk.yellow('\n═══ Part 2: Executor Fills Intent ═══\n'));

  const executorCode = `
// Executor monitors for intents and fills via DeepBook
const executorPtb = createPTB(config, apexPackage);

// The executor has fetched the intent and verified:
// 1. Intent is still valid (not expired, not filled)
// 2. DeepBook has enough liquidity
// 3. The fill is profitable (spread covers gas + profit)

const receipt = executorPtb.executeIntentSwap({
  baseType: "0x2::sui::SUI",
  quoteType: USDC_TYPE,
  pool: "${CONFIG.pool}",
  inputCoin: intentInputCoin,     // The escrowed SUI from intent
  deepCoin: executorDeepCoin,     // Executor provides DEEP for fees
  minOutput: 2_000_000n,          // Must meet intent's minimum
  recipient: intentRecipient,     // USDC goes to original agent
});

// Execute the fill
const fillResult = await executorClient.execute(executorPtb.build());

// Agent receives USDC, executor gets receipt for tracking
console.log("Intent filled successfully!");
`;

  console.log(chalk.green(executorCode));

  // === Benefits ===

  console.log(chalk.cyan('\n═══ Why Intent-Based Trading? ═══\n'));

  const benefits = [
    {
      icon: '🎯',
      title: 'Outcome-Based',
      desc: 'Agent specifies WHAT they want, not HOW to get it',
    },
    {
      icon: '💰',
      title: 'Best Execution',
      desc: 'Executors compete to provide best price',
    },
    {
      icon: '🔒',
      title: 'Funds Protected',
      desc: 'SUI escrowed until valid fill or expiry',
    },
    {
      icon: '⏰',
      title: 'Time-Bounded',
      desc: 'Intents expire - no indefinite locks',
    },
    {
      icon: '🤖',
      title: 'Agent-Friendly',
      desc: 'Fire and forget - no monitoring required',
    },
    {
      icon: '⚡',
      title: 'MEV Resistant',
      desc: 'Minimum output guarantees protect agents',
    },
  ];

  for (const b of benefits) {
    console.log(chalk.white(`${b.icon} ${b.title}`));
    console.log(chalk.gray(`   ${b.desc}`));
  }

  // === Executor Strategy ===

  console.log(chalk.cyan('\n═══ Executor Strategy ═══\n'));

  console.log(chalk.white('Executor Profit Calculation:\n'));
  console.log(chalk.gray(`
  Intent: Swap 1 SUI for ≥2.00 USDC

  DeepBook Query:
    • Current SUI/USDC mid price: $2.10
    • 1 SUI → 2.05 USDC (after fees)

  Executor Costs:
    • Gas: ~0.001 SUI
    • DEEP fees: ~0.01 DEEP

  Profit Margin:
    • Output: 2.05 USDC
    • Min required: 2.00 USDC
    • Surplus: 0.05 USDC → Executor profit

  Decision: FILL ✓
`));

  // === Advanced: Multi-Intent Fill ===

  console.log(chalk.yellow('\n═══ Advanced: Batch Intent Filling ═══\n'));

  const batchCode = `
// Executors can fill multiple intents in a single PTB
const batchPtb = createPTB(config, apexPackage);

// Fill 3 intents atomically
for (const intent of [intent1, intent2, intent3]) {
  batchPtb.executeIntentSwap({
    baseType: intent.baseType,
    quoteType: intent.quoteType,
    pool: deepbookPool,
    inputCoin: intent.escrowedCoin,
    deepCoin: executorDeepCoin,
    minOutput: intent.minOutput,
    recipient: intent.recipient,
  });
}

// All 3 fills succeed or all fail - no partial state
const result = await executorClient.execute(batchPtb.build());
`;

  console.log(chalk.green(batchCode));

  // === Intent vs Direct Trade ===

  console.log(chalk.cyan('\n═══ When to Use Intents vs Direct Trade ═══\n'));

  console.log(chalk.white('Use Intents When:'));
  console.log(chalk.gray('  • You don\'t need immediate execution'));
  console.log(chalk.gray('  • You want best-effort price discovery'));
  console.log(chalk.gray('  • You\'re an agent that can\'t monitor continuously'));
  console.log(chalk.gray('  • You want MEV protection'));

  console.log(chalk.white('\nUse Direct Trade When:'));
  console.log(chalk.gray('  • You need immediate execution'));
  console.log(chalk.gray('  • You\'re already monitoring prices'));
  console.log(chalk.gray('  • You\'re building atomic PTBs with other operations'));
  console.log(chalk.gray('  • Gas efficiency is critical'));

  console.log('');
}

main().catch(console.error);
