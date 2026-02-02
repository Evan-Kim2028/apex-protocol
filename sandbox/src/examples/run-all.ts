#!/usr/bin/env node
/**
 * Run All APEX Protocol Examples
 *
 * Executes all example scripts to demonstrate the full capabilities
 * of the APEX Protocol for AI agents.
 */

import chalk from 'chalk';
import { spawn } from 'child_process';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const EXAMPLES = [
  {
    name: 'Atomic Pay-and-Trade',
    file: 'atomic-pay-trade.ts',
    description: 'Sui\'s killer feature for AI agents',
  },
  {
    name: 'DeepBook Spot Swap',
    file: 'spot-swap.ts',
    description: 'Direct swaps via DeepBook V3',
  },
  {
    name: 'Margin Trading',
    file: 'margin-trading.ts',
    description: 'Leveraged positions with risk management',
  },
  {
    name: 'Intent-Based Trading',
    file: 'intent-trading.ts',
    description: 'Declarative trading with executor network',
  },
];

async function runExample(example: typeof EXAMPLES[0]): Promise<void> {
  return new Promise((resolve, reject) => {
    console.log(chalk.cyan(`\n${'═'.repeat(70)}`));
    console.log(chalk.cyan(`Running: ${example.name}`));
    console.log(chalk.gray(example.description));
    console.log(chalk.cyan('═'.repeat(70)));

    const child = spawn('npx', ['tsx', join(__dirname, example.file)], {
      stdio: 'inherit',
      shell: true,
    });

    child.on('close', (code) => {
      if (code === 0) {
        resolve();
      } else {
        reject(new Error(`Example ${example.name} failed with code ${code}`));
      }
    });

    child.on('error', reject);
  });
}

async function main() {
  console.log(chalk.bgCyan.black('\n APEX Protocol - Example Suite \n'));
  console.log(chalk.white('Running all examples to demonstrate AI agent capabilities...\n'));

  for (const example of EXAMPLES) {
    try {
      await runExample(example);
    } catch (error: any) {
      console.log(chalk.red(`\nError in ${example.name}: ${error.message}`));
    }
  }

  console.log(chalk.cyan(`\n${'═'.repeat(70)}`));
  console.log(chalk.green('✓ All examples completed'));
  console.log(chalk.cyan('═'.repeat(70)));

  console.log(chalk.white('\nNext Steps:'));
  console.log(chalk.gray('1. Deploy APEX to testnet: sui client publish'));
  console.log(chalk.gray('2. Configure actual object IDs in examples'));
  console.log(chalk.gray('3. Run with real transactions'));
  console.log(chalk.gray('4. Build your AI agent using these patterns\n'));
}

main().catch(console.error);
