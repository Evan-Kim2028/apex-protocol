/**
 * Example: DeepBook Margin Trading
 *
 * Demonstrates how an AI agent can use leveraged positions via DeepBook Margin
 * with proper risk management through the APEX Protocol.
 */

import { ApexClient } from '../client.js';
import { createPTB } from '../ptb-builder.js';
import { NETWORKS } from '../config.js';
import chalk from 'chalk';

// Configuration
const CONFIG = {
  network: 'testnet' as const,
  apexPackage: '0x0',

  // Margin infrastructure (set after deployment/discovery)
  marginManager: '0x...',
  marginRegistry: '0x...',
  baseMarginPool: '0x...',
  quoteMarginPool: '0x...',

  // Pyth oracles
  baseOracle: '0x...', // SUI price feed
  quoteOracle: '0x...', // USDC price feed

  // DeepBook pool
  pool: '0x...',

  // User's coins
  collateralCoin: '0x...',
};

// Risk management constants (matching contract)
const MAX_SAFE_RISK_RATIO = 8500n; // 85% - liquidation danger
const WARNING_RISK_RATIO = 7000n; // 70% - should reduce position
const HEALTHY_RISK_RATIO = 5000n; // 50% - comfortable

async function main() {
  console.log(chalk.cyan('\n═══ DeepBook Margin Trading Example ═══\n'));

  const client = new ApexClient({
    network: CONFIG.network,
    apexPackage: CONFIG.apexPackage,
  });

  console.log(chalk.gray(`Agent Address: ${client.address}\n`));

  // === Step 1: Create Margin Trader Account ===

  console.log(chalk.yellow('Step 1: Create Margin Trader Account\n'));

  const createPtb = createPTB(NETWORKS[CONFIG.network], CONFIG.apexPackage);

  console.log(chalk.white('PTB Code:'));
  console.log(chalk.green(`
const ptb = createPTB(config, apexPackage);
const marginTrader = ptb.createMarginTrader();
ptb.transfer(marginTrader, agentAddress);
`));

  // === Step 2: Deposit Collateral ===

  console.log(chalk.yellow('Step 2: Deposit Collateral\n'));

  console.log(chalk.white('PTB Code:'));
  console.log(chalk.green(`
const ptb = createPTB(config, apexPackage);

// Deposit 10 SUI as collateral
ptb.depositCollateral({
  baseType: "0x2::sui::SUI",
  quoteType: USDC_TYPE,
  depositType: "0x2::sui::SUI",
  marginManager: "${CONFIG.marginManager}",
  marginRegistry: "${CONFIG.marginRegistry}",
  baseOracle: "${CONFIG.baseOracle}",
  quoteOracle: "${CONFIG.quoteOracle}",
  collateralCoin: suiCoinId,  // 10 SUI
});
`));

  // === Step 3: Borrow and Trade ===

  console.log(chalk.yellow('Step 3: Borrow Against Collateral\n'));

  console.log(chalk.white('PTB Code:'));
  console.log(chalk.green(`
const ptb = createPTB(config, apexPackage);

// Borrow 5 SUI against 10 SUI collateral (50% utilization)
ptb.borrowBase({
  baseType: "0x2::sui::SUI",
  quoteType: USDC_TYPE,
  marginManager: "${CONFIG.marginManager}",
  marginRegistry: "${CONFIG.marginRegistry}",
  baseMarginPool: "${CONFIG.baseMarginPool}",
  baseOracle: "${CONFIG.baseOracle}",
  quoteOracle: "${CONFIG.quoteOracle}",
  pool: "${CONFIG.pool}",
  borrowAmount: 5_000_000_000n,  // 5 SUI
});
`));

  // === Step 4: Monitor Risk ===

  console.log(chalk.yellow('Step 4: Monitor Position Risk\n'));

  console.log(chalk.white('Risk Ratio Interpretation:'));
  console.log(chalk.green(`  < 50% (5000 bps)  → ${chalk.green('HEALTHY')} - Safe to hold or increase`));
  console.log(chalk.yellow(`  50-70% (5000-7000) → ${chalk.yellow('CAUTION')} - Monitor closely`));
  console.log(chalk.red(`  70-85% (7000-8500) → ${chalk.red('WARNING')} - Reduce position`));
  console.log(chalk.bgRed(`  > 85% (8500+)      → ${chalk.bgRed('CRITICAL')} - Liquidation imminent`));

  console.log(chalk.white('\nPTB Code:'));
  console.log(chalk.green(`
const ptb = createPTB(config, apexPackage);

const riskRatio = ptb.getRiskRatio({
  baseType: "0x2::sui::SUI",
  quoteType: USDC_TYPE,
  marginManager: "${CONFIG.marginManager}",
  marginRegistry: "${CONFIG.marginRegistry}",
  baseMarginPool: "${CONFIG.baseMarginPool}",
  quoteMarginPool: "${CONFIG.quoteMarginPool}",
  baseOracle: "${CONFIG.baseOracle}",
  quoteOracle: "${CONFIG.quoteOracle}",
});

// Agent decision logic based on risk ratio
const result = await client.inspect(ptb.build());
const ratio = BigInt(result.results[0].returnValues[0]);

if (ratio > ${MAX_SAFE_RISK_RATIO}n) {
  console.log("CRITICAL: Immediate action required!");
  // Execute repayment or add collateral
} else if (ratio > ${WARNING_RISK_RATIO}n) {
  console.log("WARNING: Consider reducing position");
} else if (ratio > ${HEALTHY_RISK_RATIO}n) {
  console.log("CAUTION: Monitor position");
} else {
  console.log("HEALTHY: Position is safe");
}
`));

  // === Agent Strategy Example ===

  console.log(chalk.cyan('\n═══ Agent Margin Strategy ═══\n'));

  console.log(chalk.white('Automated Margin Management:'));
  console.log(chalk.gray(`
┌─────────────────────────────────────────────────────────────────┐
│                    Agent Margin Loop                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. MONITOR                                                      │
│     └─→ Check risk ratio every N blocks                         │
│                                                                  │
│  2. EVALUATE                                                     │
│     ├─→ If ratio > 85%: Emergency repay                         │
│     ├─→ If ratio > 70%: Gradual deleverage                      │
│     ├─→ If ratio < 40%: Consider increasing position            │
│     └─→ Otherwise: Hold                                          │
│                                                                  │
│  3. EXECUTE (Atomic PTB)                                         │
│     ├─→ Repay debt from available balance                       │
│     ├─→ Or: Swap collateral to repay                            │
│     └─→ Or: Add more collateral                                  │
│                                                                  │
│  4. REPORT                                                       │
│     └─→ Emit events for monitoring dashboard                    │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
`));

  // === Complex PTB: Emergency Deleverage ===

  console.log(chalk.yellow('Emergency Deleverage PTB:\n'));

  console.log(chalk.green(`
// When risk ratio is critical, execute emergency deleverage
// All operations are atomic - if any fail, nothing happens

const ptb = createPTB(config, apexPackage);

// 1. Check current risk
const riskRatio = ptb.getRiskRatio({...params});

// 2. Repay half the borrowed base
const repayAmount = borrowedAmount / 2n;
ptb.tx.moveCall({
  target: \`\${apexPackage}::deepbook_margin_v3::repay_base_debt\`,
  typeArguments: [BASE_TYPE, QUOTE_TYPE],
  arguments: [
    ptb.tx.object(marginManager),
    ptb.tx.object(marginRegistry),
    ptb.tx.object(baseMarginPool),
    ptb.tx.pure.option('u64', repayAmount),
    ptb.tx.object(repaymentCoin),
    ptb.tx.object(CLOCK),
  ],
});

// 3. Re-check risk after repayment
const newRiskRatio = ptb.getRiskRatio({...params});

// All atomic - guaranteed consistent state
`));

  console.log(chalk.cyan('\n═══ Summary ═══\n'));
  console.log(chalk.white('Key benefits for AI agents:'));
  console.log(chalk.gray('  • Atomic operations prevent partial state'));
  console.log(chalk.gray('  • Built-in risk monitoring'));
  console.log(chalk.gray('  • Pyth oracle integration for accurate pricing'));
  console.log(chalk.gray('  • Composable with spot trading and payments'));
  console.log('');
}

main().catch(console.error);
