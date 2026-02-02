/**
 * Example: DeepBook V3 Spot Swap
 *
 * Demonstrates how an AI agent can execute spot swaps via DeepBook
 * using the APEX Protocol's typed PTB builder.
 */

import { ApexClient } from '../client.js';
import { createPTB } from '../ptb-builder.js';
import { NETWORKS } from '../config.js';
import chalk from 'chalk';

// Configuration - set these to actual values for real execution
const CONFIG = {
  network: 'testnet' as const,
  apexPackage: '0x0', // Set after deployment

  // Object IDs - replace with actual testnet objects
  pool: '0x...', // DeepBook SUI/USDC pool
  suiCoin: '0x...', // User's SUI coin
  deepCoin: '0x...', // DEEP token for fees
};

async function main() {
  console.log(chalk.cyan('\n═══ DeepBook V3 Spot Swap Example ═══\n'));

  // Initialize client
  const client = new ApexClient({
    network: CONFIG.network,
    apexPackage: CONFIG.apexPackage,
  });

  console.log(chalk.gray(`Agent Address: ${client.address}`));
  console.log(chalk.gray(`Network: ${CONFIG.network}\n`));

  // Create PTB builder
  const ptb = createPTB(NETWORKS[CONFIG.network], CONFIG.apexPackage);

  // === Build the swap transaction ===

  console.log(chalk.yellow('Building swap transaction...\n'));

  // Scenario: Swap 1 SUI for USDC with 2% slippage tolerance
  const swapAmountSui = 1_000_000_000n; // 1 SUI (9 decimals)
  const minUsdcOut = 2_000_000n; // Expect ~$2 USDC (6 decimals), adjust for slippage

  // If we had actual coin objects, we would:
  // 1. Split the exact amount to swap
  // const [coinToSwap] = ptb.splitCoins(CONFIG.suiCoin, [swapAmountSui]);

  // 2. Execute the swap
  // const [remainingBase, quoteOut, deepOut, receipt] = ptb.swapBaseForQuote({
  //   baseType: '0x2::sui::SUI',
  //   quoteType: NETWORKS[CONFIG.network].tokens.usdc,
  //   pool: CONFIG.pool,
  //   baseCoin: coinToSwap,
  //   deepCoin: CONFIG.deepCoin,
  //   minQuoteOut: minUsdcOut,
  // });

  // 3. Transfer outputs to sender
  // ptb.transfer(quoteOut, client.address);

  // Show what the transaction would look like
  const pseudoCode = `
// Transaction Structure:
{
  "inputs": [
    { "type": "object", "id": "${CONFIG.pool}" },        // DeepBook Pool
    { "type": "object", "id": "${CONFIG.suiCoin}" },     // User's SUI
    { "type": "object", "id": "${CONFIG.deepCoin}" },    // DEEP for fees
    { "type": "pure", "value": "${minUsdcOut}" },        // Min output
    { "type": "object", "id": "0x6" }                    // Clock
  ],
  "commands": [
    {
      "SplitCoins": {
        "coin": { "Input": 1 },
        "amounts": [${swapAmountSui}]
      }
    },
    {
      "MoveCall": {
        "package": "${CONFIG.apexPackage}",
        "module": "deepbook_v3",
        "function": "swap_base_for_quote",
        "type_arguments": [
          "0x2::sui::SUI",
          "${NETWORKS[CONFIG.network].tokens.usdc}"
        ],
        "arguments": [
          { "Input": 0 },      // pool
          { "Result": 0 },     // split coin
          { "Input": 2 },      // DEEP
          { "Input": 3 },      // min output
          { "Input": 4 }       // clock
        ]
      }
    },
    {
      "TransferObjects": {
        "objects": [{ "NestedResult": [1, 1] }],  // quoteOut
        "address": "${client.address}"
      }
    }
  ]
}
`;

  console.log(chalk.white('Transaction structure:'));
  console.log(chalk.green(pseudoCode));

  // === Agent Decision Logic ===

  console.log(chalk.cyan('\n═══ Agent Decision Flow ═══\n'));

  console.log(chalk.white('1. Price Discovery:'));
  console.log(chalk.gray('   - Query DeepBook mid_price for SUI/USDC'));
  console.log(chalk.gray('   - Calculate expected output'));
  console.log(chalk.gray('   - Apply slippage tolerance (2%)'));

  console.log(chalk.white('\n2. Pre-flight Checks:'));
  console.log(chalk.gray('   - Verify sufficient SUI balance'));
  console.log(chalk.gray('   - Verify DEEP token for fees'));
  console.log(chalk.gray('   - Check pool liquidity'));

  console.log(chalk.white('\n3. Execute or Abort:'));
  console.log(chalk.gray('   - If price acceptable: Execute swap'));
  console.log(chalk.gray('   - If slippage too high: Create intent instead'));
  console.log(chalk.gray('   - If no liquidity: Wait or try alternative pool'));

  // === Dry Run (if configured) ===

  if (CONFIG.pool !== '0x...' && CONFIG.suiCoin !== '0x...') {
    console.log(chalk.yellow('\n═══ Dry Run ═══\n'));

    try {
      const tx = ptb.build();
      const result = await client.dryRun(tx);

      if (result.success) {
        console.log(chalk.green('✓ Transaction would succeed'));
        console.log(chalk.gray(`  Gas: ${result.gasUsed.computationCost} MIST`));
      } else {
        console.log(chalk.red('✗ Transaction would fail'));
        console.log(chalk.gray(`  Error: ${result.error}`));
      }
    } catch (error: any) {
      console.log(chalk.red(`Error: ${error.message}`));
    }
  } else {
    console.log(chalk.yellow('\n⚠ Configure actual object IDs to run dry-run\n'));
  }
}

main().catch(console.error);
