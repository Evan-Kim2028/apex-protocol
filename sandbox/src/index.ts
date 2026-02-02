#!/usr/bin/env node
/**
 * APEX Protocol - Interactive PTB Sandbox
 *
 * An interactive CLI for building and testing PTBs against APEX Protocol
 * with real DeepBook V3 integration.
 */

import chalk from 'chalk';
import inquirer from 'inquirer';
import { ApexClient } from './client.js';
import { createPTB } from './ptb-builder.js';
import { Network, NETWORKS, setApexPackage } from './config.js';

const BANNER = `
${chalk.cyan('╔═══════════════════════════════════════════════════════════════╗')}
${chalk.cyan('║')}  ${chalk.bold.white('APEX Protocol')} - ${chalk.yellow('PTB Sandbox')}                               ${chalk.cyan('║')}
${chalk.cyan('║')}  ${chalk.gray('Sui-Native Payment & Trading Infrastructure for AI Agents')}   ${chalk.cyan('║')}
${chalk.cyan('╚═══════════════════════════════════════════════════════════════╝')}
`;

interface SandboxState {
  client: ApexClient | null;
  apexPackage: string;
  network: Network;
}

const state: SandboxState = {
  client: null,
  apexPackage: '0x0',
  network: 'testnet',
};

async function main() {
  console.log(BANNER);

  // Initial setup
  await setupNetwork();

  // Main loop
  while (true) {
    const { action } = await inquirer.prompt([
      {
        type: 'list',
        name: 'action',
        message: 'What would you like to do?',
        choices: [
          { name: '🔄 Swap (DeepBook Spot)', value: 'swap' },
          { name: '📈 Margin Trading (DeepBook Margin)', value: 'margin' },
          { name: '📋 Create Trading Intent', value: 'intent' },
          { name: '💰 Atomic Pay-and-Trade', value: 'atomic' },
          { name: '🔍 Inspect Transaction', value: 'inspect' },
          { name: '💵 Check Balance', value: 'balance' },
          { name: '⚙️  Configure', value: 'config' },
          { name: '❌ Exit', value: 'exit' },
        ],
      },
    ]);

    switch (action) {
      case 'swap':
        await swapDemo();
        break;
      case 'margin':
        await marginDemo();
        break;
      case 'intent':
        await intentDemo();
        break;
      case 'atomic':
        await atomicPayTradeDemo();
        break;
      case 'inspect':
        await inspectTransaction();
        break;
      case 'balance':
        await checkBalance();
        break;
      case 'config':
        await configure();
        break;
      case 'exit':
        console.log(chalk.yellow('\nGoodbye! 👋\n'));
        process.exit(0);
    }
  }
}

async function setupNetwork() {
  const { network } = await inquirer.prompt([
    {
      type: 'list',
      name: 'network',
      message: 'Select network:',
      choices: [
        { name: 'Testnet (recommended for testing)', value: 'testnet' },
        { name: 'Mainnet', value: 'mainnet' },
        { name: 'Localnet', value: 'localnet' },
      ],
    },
  ]);

  state.network = network;
  state.client = new ApexClient({ network });

  console.log(chalk.green(`\n✓ Connected to ${network}`));
  console.log(chalk.gray(`  Address: ${state.client.address}`));
  console.log(chalk.gray(`  DeepBook: ${NETWORKS[network].deepbook.package.slice(0, 20)}...`));

  const { apexPackage } = await inquirer.prompt([
    {
      type: 'input',
      name: 'apexPackage',
      message: 'APEX Package ID (or press Enter to use placeholder):',
      default: '0x0',
    },
  ]);

  state.apexPackage = apexPackage;
  setApexPackage(apexPackage);
  state.client.apexPackage = apexPackage;

  console.log('');
}

async function swapDemo() {
  console.log(chalk.cyan('\n═══ DeepBook Spot Swap Demo ═══\n'));

  const ptb = createPTB(NETWORKS[state.network], state.apexPackage);

  // Show what the PTB will look like
  console.log(chalk.yellow('Building PTB for Base→Quote swap:\n'));

  const { baseType, quoteType, poolId, amount, minOutput } = await inquirer.prompt([
    {
      type: 'input',
      name: 'baseType',
      message: 'Base asset type:',
      default: '0x2::sui::SUI',
    },
    {
      type: 'input',
      name: 'quoteType',
      message: 'Quote asset type:',
      default: NETWORKS[state.network].tokens.usdc,
    },
    {
      type: 'input',
      name: 'poolId',
      message: 'Pool object ID:',
      default: '0x...',
    },
    {
      type: 'input',
      name: 'amount',
      message: 'Amount to swap (in base units):',
      default: '1000000000', // 1 SUI
    },
    {
      type: 'input',
      name: 'minOutput',
      message: 'Minimum output (in quote units):',
      default: '1000000', // 1 USDC
    },
  ]);

  // Build the PTB
  console.log(chalk.gray('\nConstructing PTB...\n'));

  const code = `
const ptb = createPTB(config, apexPackage);

// Swap base for quote via DeepBook
const [remainingBase, quoteOut, deepOut, receipt] = ptb.swapBaseForQuote({
  baseType: "${baseType}",
  quoteType: "${quoteType}",
  pool: "${poolId}",
  baseCoin: baseCoinObjectId,
  deepCoin: deepCoinObjectId,
  minQuoteOut: ${minOutput}n,
});

// Transfer outputs to sender
ptb.transfer(quoteOut, senderAddress);
`;

  console.log(chalk.white('Generated PTB code:'));
  console.log(chalk.gray('─'.repeat(50)));
  console.log(chalk.green(code));
  console.log(chalk.gray('─'.repeat(50)));

  const { execute } = await inquirer.prompt([
    {
      type: 'list',
      name: 'execute',
      message: 'What would you like to do?',
      choices: [
        { name: 'Dry run (simulate)', value: 'dry' },
        { name: 'Inspect (dev mode)', value: 'inspect' },
        { name: 'Cancel', value: 'cancel' },
      ],
    },
  ]);

  if (execute === 'cancel') {
    return;
  }

  if (poolId === '0x...') {
    console.log(chalk.yellow('\n⚠ Cannot execute with placeholder pool ID'));
    console.log(chalk.gray('Configure actual pool IDs to run real transactions'));
    return;
  }

  // Would execute here if configured
  console.log(chalk.gray('\n(Would execute PTB here with real object IDs)\n'));
}

async function marginDemo() {
  console.log(chalk.cyan('\n═══ DeepBook Margin Trading Demo ═══\n'));

  console.log(chalk.white('Margin trading workflow:'));
  console.log(chalk.gray('1. Create margin trader account'));
  console.log(chalk.gray('2. Deposit collateral'));
  console.log(chalk.gray('3. Borrow against collateral'));
  console.log(chalk.gray('4. Monitor risk ratio'));
  console.log(chalk.gray('5. Repay and withdraw\n'));

  const { step } = await inquirer.prompt([
    {
      type: 'list',
      name: 'step',
      message: 'Which step to demonstrate?',
      choices: [
        { name: '1. Create margin trader', value: 'create' },
        { name: '2. Deposit collateral', value: 'deposit' },
        { name: '3. Borrow base asset', value: 'borrow' },
        { name: '4. Check risk ratio', value: 'risk' },
        { name: 'Back', value: 'back' },
      ],
    },
  ]);

  if (step === 'back') return;

  let code = '';

  switch (step) {
    case 'create':
      code = `
const ptb = createPTB(config, apexPackage);

// Create a margin trader account
const marginTrader = ptb.createMarginTrader();

// Transfer to sender
ptb.transfer(marginTrader, senderAddress);
`;
      break;

    case 'deposit':
      code = `
const ptb = createPTB(config, apexPackage);

// Deposit collateral into margin account
ptb.depositCollateral({
  baseType: "0x2::sui::SUI",
  quoteType: USDC_TYPE,
  depositType: "0x2::sui::SUI",  // Depositing SUI as collateral
  marginManager: marginManagerId,
  marginRegistry: marginRegistryId,
  baseOracle: pythBaseOracleId,
  quoteOracle: pythQuoteOracleId,
  collateralCoin: suiCoinId,
});
`;
      break;

    case 'borrow':
      code = `
const ptb = createPTB(config, apexPackage);

// Borrow base asset against collateral
ptb.borrowBase({
  baseType: "0x2::sui::SUI",
  quoteType: USDC_TYPE,
  marginManager: marginManagerId,
  marginRegistry: marginRegistryId,
  baseMarginPool: baseMarginPoolId,
  baseOracle: pythBaseOracleId,
  quoteOracle: pythQuoteOracleId,
  pool: deepbookPoolId,
  borrowAmount: 500_000_000n,  // 0.5 SUI
});
`;
      break;

    case 'risk':
      code = `
const ptb = createPTB(config, apexPackage);

// Get current risk ratio
const riskRatio = ptb.getRiskRatio({
  baseType: "0x2::sui::SUI",
  quoteType: USDC_TYPE,
  marginManager: marginManagerId,
  marginRegistry: marginRegistryId,
  baseMarginPool: baseMarginPoolId,
  quoteMarginPool: quoteMarginPoolId,
  baseOracle: pythBaseOracleId,
  quoteOracle: pythQuoteOracleId,
});

// Risk ratio is in basis points (100 = 1%)
// > 7000 (70%) = Warning
// > 8500 (85%) = Critical/Liquidation risk
`;
      break;
  }

  console.log(chalk.white('\nGenerated PTB code:'));
  console.log(chalk.gray('─'.repeat(50)));
  console.log(chalk.green(code));
  console.log(chalk.gray('─'.repeat(50)));
  console.log('');
}

async function intentDemo() {
  console.log(chalk.cyan('\n═══ Trading Intent Demo ═══\n'));

  console.log(chalk.white('Intent-based trading workflow:'));
  console.log(chalk.gray('1. Agent creates swap intent (funds escrowed)'));
  console.log(chalk.gray('2. Executors monitor for profitable intents'));
  console.log(chalk.gray('3. Executor fills intent via DeepBook'));
  console.log(chalk.gray('4. Agent receives output, executor gets receipt\n'));

  const code = `
// === AGENT: Create Intent ===
const agentPtb = createPTB(config, apexPackage);

const intent = agentPtb.createSwapIntent({
  coinType: "0x2::sui::SUI",
  registry: intentRegistryId,
  inputCoin: suiCoinId,           // Escrowed until filled
  minOutput: 2_000_000n,          // Minimum USDC to receive
  recipient: agentAddress,
  deadlineMs: Date.now() + 3600000n,  // 1 hour
});

// === EXECUTOR: Fill Intent via DeepBook ===
const executorPtb = createPTB(config, apexPackage);

const receipt = executorPtb.executeIntentSwap({
  baseType: "0x2::sui::SUI",
  quoteType: USDC_TYPE,
  pool: deepbookPoolId,
  inputCoin: intentInputCoin,     // From the intent
  deepCoin: deepForFeesId,
  minOutput: 2_000_000n,
  recipient: agentAddress,        // Output goes to agent
});
`;

  console.log(chalk.white('Generated PTB code:'));
  console.log(chalk.gray('─'.repeat(50)));
  console.log(chalk.green(code));
  console.log(chalk.gray('─'.repeat(50)));
  console.log('');
}

async function atomicPayTradeDemo() {
  console.log(chalk.cyan('\n═══ Atomic Pay-and-Trade Demo ═══\n'));

  console.log(chalk.white('This demonstrates Sui\'s unique PTB capability:'));
  console.log(chalk.yellow('In a SINGLE atomic transaction:'));
  console.log(chalk.gray('  1. Split payment from user coin'));
  console.log(chalk.gray('  2. Pay for API service'));
  console.log(chalk.gray('  3. Execute trade via DeepBook'));
  console.log(chalk.gray('  4. Return results to user'));
  console.log(chalk.red('\n⚡ Impossible on other chains - they require multiple txs!\n'));

  const code = `
const ptb = createPTB(config, apexPackage);

// Step 1: Split payment from user's SUI
const [paymentCoin] = ptb.splitCoins(userSuiCoin, [100_000_000n]); // 0.1 SUI

// Step 2: Pay for API service (get access capability)
const accessCap = ptb.purchaseAccess({
  serviceProvider: serviceProviderId,
  paymentCoin: paymentCoin,
});

// Step 3: Execute trade with remaining balance (same PTB!)
const [remainingBase, quoteOut, deepOut, receipt] = ptb.swapBaseForQuote({
  baseType: "0x2::sui::SUI",
  quoteType: USDC_TYPE,
  pool: deepbookPoolId,
  baseCoin: userSuiCoin,      // Remaining after split
  deepCoin: deepCoinId,
  minQuoteOut: 1_000_000n,
});

// Step 4: Transfer outputs
ptb.transfer(quoteOut, userAddress);
ptb.transfer(accessCap, userAddress);

// ALL OF THIS IS ATOMIC!
// If the trade fails, the payment is never made.
// If the payment fails, the trade never executes.
`;

  console.log(chalk.white('Generated PTB code:'));
  console.log(chalk.gray('─'.repeat(50)));
  console.log(chalk.green(code));
  console.log(chalk.gray('─'.repeat(50)));

  console.log(chalk.cyan('\n💡 Why this matters for AI Agents:'));
  console.log(chalk.gray('  • No partial execution risk'));
  console.log(chalk.gray('  • No stuck funds between operations'));
  console.log(chalk.gray('  • Composable with any Sui protocol'));
  console.log(chalk.gray('  • Gas efficient (single transaction)'));
  console.log('');
}

async function inspectTransaction() {
  console.log(chalk.cyan('\n═══ Inspect Transaction ═══\n'));

  if (!state.client) {
    console.log(chalk.red('No client connected'));
    return;
  }

  const { txDigest } = await inquirer.prompt([
    {
      type: 'input',
      name: 'txDigest',
      message: 'Transaction digest to inspect:',
    },
  ]);

  if (!txDigest) {
    console.log(chalk.yellow('No digest provided'));
    return;
  }

  try {
    const tx = await state.client.suiClient.getTransactionBlock({
      digest: txDigest,
      options: {
        showEffects: true,
        showEvents: true,
        showInput: true,
        showObjectChanges: true,
      },
    });

    console.log(chalk.green('\nTransaction found:'));
    console.log(chalk.gray(JSON.stringify(tx, null, 2)));
  } catch (error: any) {
    console.log(chalk.red(`\nError: ${error.message}`));
  }

  console.log('');
}

async function checkBalance() {
  if (!state.client) {
    console.log(chalk.red('No client connected'));
    return;
  }

  try {
    const balance = await state.client.getBalance();
    const suiBalance = Number(balance) / 1_000_000_000;

    console.log(chalk.green(`\nBalance: ${suiBalance.toFixed(4)} SUI`));
    console.log(chalk.gray(`Address: ${state.client.address}\n`));
  } catch (error: any) {
    console.log(chalk.red(`\nError: ${error.message}\n`));
  }
}

async function configure() {
  const { option } = await inquirer.prompt([
    {
      type: 'list',
      name: 'option',
      message: 'Configure:',
      choices: [
        { name: 'Change network', value: 'network' },
        { name: 'Set APEX package ID', value: 'package' },
        { name: 'Request testnet faucet', value: 'faucet' },
        { name: 'Show current config', value: 'show' },
        { name: 'Back', value: 'back' },
      ],
    },
  ]);

  switch (option) {
    case 'network':
      await setupNetwork();
      break;

    case 'package':
      const { pkg } = await inquirer.prompt([
        {
          type: 'input',
          name: 'pkg',
          message: 'APEX Package ID:',
          default: state.apexPackage,
        },
      ]);
      state.apexPackage = pkg;
      setApexPackage(pkg);
      if (state.client) {
        state.client.apexPackage = pkg;
      }
      console.log(chalk.green(`\n✓ Package set to ${pkg}\n`));
      break;

    case 'faucet':
      if (state.network !== 'testnet') {
        console.log(chalk.yellow('\nFaucet only available on testnet\n'));
        return;
      }
      if (!state.client) {
        console.log(chalk.red('No client connected'));
        return;
      }
      try {
        console.log(chalk.gray('\nRequesting faucet...'));
        await state.client.requestFaucet();
        console.log(chalk.green('✓ Faucet request sent!\n'));
      } catch (error: any) {
        console.log(chalk.red(`Error: ${error.message}\n`));
      }
      break;

    case 'show':
      console.log(chalk.white('\nCurrent Configuration:'));
      console.log(chalk.gray(`  Network: ${state.network}`));
      console.log(chalk.gray(`  RPC: ${NETWORKS[state.network].rpcUrl}`));
      console.log(chalk.gray(`  Address: ${state.client?.address ?? 'Not connected'}`));
      console.log(chalk.gray(`  APEX Package: ${state.apexPackage}`));
      console.log(chalk.gray(`  DeepBook: ${NETWORKS[state.network].deepbook.package}`));
      console.log(chalk.gray(`  DeepBook Margin: ${NETWORKS[state.network].deepbook.marginPackage}`));
      console.log('');
      break;
  }
}

// Run the sandbox
main().catch(console.error);
