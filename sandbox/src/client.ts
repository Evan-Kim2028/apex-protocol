/**
 * Sui Client Wrapper for APEX Protocol
 *
 * Provides a typed interface for interacting with Sui blockchain
 */

import { SuiClient, SuiTransactionBlockResponse } from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Network, NETWORKS, NetworkConfig } from './config.js';

export interface ApexClientConfig {
  network: Network;
  keypair?: Ed25519Keypair;
  apexPackage?: string;
}

export class ApexClient {
  readonly network: Network;
  readonly config: NetworkConfig;
  readonly suiClient: SuiClient;
  readonly keypair: Ed25519Keypair;
  apexPackage: string;

  constructor(config: ApexClientConfig) {
    this.network = config.network;
    this.config = NETWORKS[config.network];
    this.suiClient = new SuiClient({ url: this.config.rpcUrl });
    this.keypair = config.keypair ?? Ed25519Keypair.generate();
    this.apexPackage = config.apexPackage ?? '0x0';
  }

  get address(): string {
    return this.keypair.getPublicKey().toSuiAddress();
  }

  /**
   * Execute a transaction (dry run or actual)
   */
  async execute(
    tx: Transaction,
    options: { dryRun?: boolean } = {}
  ): Promise<SuiTransactionBlockResponse | DryRunResult> {
    if (options.dryRun) {
      return this.dryRun(tx);
    }

    const result = await this.suiClient.signAndExecuteTransaction({
      transaction: tx,
      signer: this.keypair,
      options: {
        showEffects: true,
        showEvents: true,
        showObjectChanges: true,
        showBalanceChanges: true,
      },
    });

    return result;
  }

  /**
   * Dry run a transaction to simulate effects without executing
   */
  async dryRun(tx: Transaction): Promise<DryRunResult> {
    tx.setSender(this.address);
    const bytes = await tx.build({ client: this.suiClient });

    const result = await this.suiClient.dryRunTransactionBlock({
      transactionBlock: bytes,
    });

    return {
      success: result.effects.status.status === 'success',
      gasUsed: result.effects.gasUsed,
      events: result.events,
      objectChanges: result.objectChanges,
      balanceChanges: result.balanceChanges,
      error: result.effects.status.status === 'failure'
        ? result.effects.status.error
        : undefined,
    };
  }

  /**
   * Inspect a transaction locally (no gas, no signatures)
   */
  async inspect(tx: Transaction): Promise<InspectResult> {
    tx.setSender(this.address);
    const bytes = await tx.build({ client: this.suiClient });

    const result = await this.suiClient.devInspectTransactionBlock({
      transactionBlock: bytes,
      sender: this.address,
    });

    return {
      success: result.effects.status.status === 'success',
      results: result.results ?? [],
      events: result.events,
      error: result.effects.status.status === 'failure'
        ? result.effects.status.error
        : undefined,
    };
  }

  /**
   * Get SUI balance for an address
   */
  async getBalance(address?: string): Promise<bigint> {
    const balance = await this.suiClient.getBalance({
      owner: address ?? this.address,
      coinType: '0x2::sui::SUI',
    });
    return BigInt(balance.totalBalance);
  }

  /**
   * Get coins for a specific type
   */
  async getCoins(coinType: string, address?: string) {
    const coins = await this.suiClient.getCoins({
      owner: address ?? this.address,
      coinType,
    });
    return coins.data;
  }

  /**
   * Get an object by ID
   */
  async getObject(objectId: string) {
    return this.suiClient.getObject({
      id: objectId,
      options: {
        showContent: true,
        showType: true,
        showOwner: true,
      },
    });
  }

  /**
   * Request testnet faucet (testnet only)
   */
  async requestFaucet(): Promise<void> {
    if (this.network !== 'testnet') {
      throw new Error('Faucet only available on testnet');
    }

    const response = await fetch('https://faucet.testnet.sui.io/gas', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        FixedAmountRequest: { recipient: this.address },
      }),
    });

    if (!response.ok) {
      throw new Error(`Faucet request failed: ${response.statusText}`);
    }
  }
}

export interface DryRunResult {
  success: boolean;
  gasUsed: {
    computationCost: string;
    storageCost: string;
    storageRebate: string;
  };
  events: any[];
  objectChanges: any[];
  balanceChanges: any[];
  error?: string;
}

export interface InspectResult {
  success: boolean;
  results: any[];
  events: any[];
  error?: string;
}
