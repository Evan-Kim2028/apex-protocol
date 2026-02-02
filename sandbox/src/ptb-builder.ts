/**
 * PTB Builder - Fluent API for constructing APEX Protocol transactions
 *
 * Provides typed helpers for building PTBs that interact with:
 * - APEX core (payments, streaming, agents)
 * - DeepBook V3 (spot trading)
 * - DeepBook Margin (leveraged trading)
 */

import { Transaction, TransactionResult } from '@mysten/sui/transactions';
import { CLOCK_OBJECT, NetworkConfig } from './config.js';

export class ApexPTBBuilder {
  readonly tx: Transaction;
  readonly config: NetworkConfig;
  readonly apexPackage: string;

  constructor(config: NetworkConfig, apexPackage: string) {
    this.tx = new Transaction();
    this.config = config;
    this.apexPackage = apexPackage;
  }

  // ============================================
  // DEEPBOOK V3 SPOT TRADING
  // ============================================

  /**
   * Create an agent trader wrapper for DeepBook
   */
  createAgentTrader(): TransactionResult {
    return this.tx.moveCall({
      target: `${this.apexPackage}::deepbook_v3::create_agent_trader`,
    });
  }

  /**
   * Swap base asset for quote asset via DeepBook
   */
  swapBaseForQuote(params: {
    baseType: string;
    quoteType: string;
    pool: string;
    baseCoin: TransactionResult | string;
    deepCoin: TransactionResult | string;
    minQuoteOut: bigint;
  }): TransactionResult {
    return this.tx.moveCall({
      target: `${this.apexPackage}::deepbook_v3::swap_base_for_quote`,
      typeArguments: [params.baseType, params.quoteType],
      arguments: [
        typeof params.pool === 'string' ? this.tx.object(params.pool) : params.pool,
        typeof params.baseCoin === 'string' ? this.tx.object(params.baseCoin) : params.baseCoin,
        typeof params.deepCoin === 'string' ? this.tx.object(params.deepCoin) : params.deepCoin,
        this.tx.pure.u64(params.minQuoteOut),
        this.tx.object(CLOCK_OBJECT),
      ],
    });
  }

  /**
   * Swap quote asset for base asset via DeepBook
   */
  swapQuoteForBase(params: {
    baseType: string;
    quoteType: string;
    pool: string;
    quoteCoin: TransactionResult | string;
    deepCoin: TransactionResult | string;
    minBaseOut: bigint;
  }): TransactionResult {
    return this.tx.moveCall({
      target: `${this.apexPackage}::deepbook_v3::swap_quote_for_base`,
      typeArguments: [params.baseType, params.quoteType],
      arguments: [
        typeof params.pool === 'string' ? this.tx.object(params.pool) : params.pool,
        typeof params.quoteCoin === 'string' ? this.tx.object(params.quoteCoin) : params.quoteCoin,
        typeof params.deepCoin === 'string' ? this.tx.object(params.deepCoin) : params.deepCoin,
        this.tx.pure.u64(params.minBaseOut),
        this.tx.object(CLOCK_OBJECT),
      ],
    });
  }

  /**
   * Execute a swap for an intent recipient
   */
  executeIntentSwap(params: {
    baseType: string;
    quoteType: string;
    pool: string;
    inputCoin: TransactionResult | string;
    deepCoin: TransactionResult | string;
    minOutput: bigint;
    recipient: string;
  }): TransactionResult {
    return this.tx.moveCall({
      target: `${this.apexPackage}::deepbook_v3::execute_intent_swap`,
      typeArguments: [params.baseType, params.quoteType],
      arguments: [
        this.tx.object(params.pool),
        typeof params.inputCoin === 'string' ? this.tx.object(params.inputCoin) : params.inputCoin,
        typeof params.deepCoin === 'string' ? this.tx.object(params.deepCoin) : params.deepCoin,
        this.tx.pure.u64(params.minOutput),
        this.tx.pure.address(params.recipient),
        this.tx.object(CLOCK_OBJECT),
      ],
    });
  }

  // ============================================
  // DEEPBOOK MARGIN TRADING
  // ============================================

  /**
   * Create a margin trader account
   */
  createMarginTrader(): TransactionResult {
    return this.tx.moveCall({
      target: `${this.apexPackage}::deepbook_margin_v3::create_agent_margin_trader`,
    });
  }

  /**
   * Deposit collateral into margin account
   */
  depositCollateral(params: {
    baseType: string;
    quoteType: string;
    depositType: string;
    marginManager: string;
    marginRegistry: string;
    baseOracle: string;
    quoteOracle: string;
    collateralCoin: TransactionResult | string;
  }): void {
    this.tx.moveCall({
      target: `${this.apexPackage}::deepbook_margin_v3::deposit_collateral`,
      typeArguments: [params.baseType, params.quoteType, params.depositType],
      arguments: [
        this.tx.object(params.marginManager),
        this.tx.object(params.marginRegistry),
        this.tx.object(params.baseOracle),
        this.tx.object(params.quoteOracle),
        typeof params.collateralCoin === 'string'
          ? this.tx.object(params.collateralCoin)
          : params.collateralCoin,
        this.tx.object(CLOCK_OBJECT),
      ],
    });
  }

  /**
   * Borrow base asset against collateral
   */
  borrowBase(params: {
    baseType: string;
    quoteType: string;
    marginManager: string;
    marginRegistry: string;
    baseMarginPool: string;
    baseOracle: string;
    quoteOracle: string;
    pool: string;
    borrowAmount: bigint;
  }): void {
    this.tx.moveCall({
      target: `${this.apexPackage}::deepbook_margin_v3::borrow_base`,
      typeArguments: [params.baseType, params.quoteType],
      arguments: [
        this.tx.object(params.marginManager),
        this.tx.object(params.marginRegistry),
        this.tx.object(params.baseMarginPool),
        this.tx.object(params.baseOracle),
        this.tx.object(params.quoteOracle),
        this.tx.object(params.pool),
        this.tx.pure.u64(params.borrowAmount),
        this.tx.object(CLOCK_OBJECT),
      ],
    });
  }

  /**
   * Borrow quote asset against collateral
   */
  borrowQuote(params: {
    baseType: string;
    quoteType: string;
    marginManager: string;
    marginRegistry: string;
    quoteMarginPool: string;
    baseOracle: string;
    quoteOracle: string;
    pool: string;
    borrowAmount: bigint;
  }): void {
    this.tx.moveCall({
      target: `${this.apexPackage}::deepbook_margin_v3::borrow_quote`,
      typeArguments: [params.baseType, params.quoteType],
      arguments: [
        this.tx.object(params.marginManager),
        this.tx.object(params.marginRegistry),
        this.tx.object(params.quoteMarginPool),
        this.tx.object(params.baseOracle),
        this.tx.object(params.quoteOracle),
        this.tx.object(params.pool),
        this.tx.pure.u64(params.borrowAmount),
        this.tx.object(CLOCK_OBJECT),
      ],
    });
  }

  /**
   * Get current risk ratio for a margin position
   */
  getRiskRatio(params: {
    baseType: string;
    quoteType: string;
    marginManager: string;
    marginRegistry: string;
    baseMarginPool: string;
    quoteMarginPool: string;
    baseOracle: string;
    quoteOracle: string;
  }): TransactionResult {
    return this.tx.moveCall({
      target: `${this.apexPackage}::deepbook_margin_v3::get_risk_ratio`,
      typeArguments: [params.baseType, params.quoteType],
      arguments: [
        this.tx.object(params.marginManager),
        this.tx.object(params.marginRegistry),
        this.tx.object(params.baseMarginPool),
        this.tx.object(params.quoteMarginPool),
        this.tx.object(params.baseOracle),
        this.tx.object(params.quoteOracle),
        this.tx.object(CLOCK_OBJECT),
      ],
    });
  }

  // ============================================
  // APEX CORE - PAYMENTS & AGENTS
  // ============================================

  /**
   * Register a new service provider
   */
  registerServiceProvider(params: {
    name: string;
    description: string;
    basePrice: bigint;
  }): TransactionResult {
    return this.tx.moveCall({
      target: `${this.apexPackage}::apex::register_service_provider`,
      arguments: [
        this.tx.pure.string(params.name),
        this.tx.pure.string(params.description),
        this.tx.pure.u64(params.basePrice),
      ],
    });
  }

  /**
   * Purchase access to a service
   */
  purchaseAccess(params: {
    serviceProvider: string;
    paymentCoin: TransactionResult | string;
  }): TransactionResult {
    return this.tx.moveCall({
      target: `${this.apexPackage}::apex::purchase_access`,
      arguments: [
        this.tx.object(params.serviceProvider),
        typeof params.paymentCoin === 'string'
          ? this.tx.object(params.paymentCoin)
          : params.paymentCoin,
      ],
    });
  }

  /**
   * Start a streaming payment
   */
  startStream(params: {
    agent: string;
    serviceProvider: string;
    escrowCoin: TransactionResult | string;
    ratePerSecond: bigint;
  }): TransactionResult {
    return this.tx.moveCall({
      target: `${this.apexPackage}::apex::start_stream`,
      arguments: [
        this.tx.object(params.agent),
        this.tx.object(params.serviceProvider),
        typeof params.escrowCoin === 'string'
          ? this.tx.object(params.escrowCoin)
          : params.escrowCoin,
        this.tx.pure.u64(params.ratePerSecond),
        this.tx.object(CLOCK_OBJECT),
      ],
    });
  }

  // ============================================
  // TRADING INTENTS
  // ============================================

  /**
   * Create a swap intent (escrows funds)
   */
  createSwapIntent(params: {
    coinType: string;
    registry: string;
    inputCoin: TransactionResult | string;
    minOutput: bigint;
    recipient: string;
    deadlineMs: bigint;
  }): TransactionResult {
    return this.tx.moveCall({
      target: `${this.apexPackage}::trading_intents::create_swap_intent`,
      typeArguments: [params.coinType],
      arguments: [
        this.tx.object(params.registry),
        typeof params.inputCoin === 'string' ? this.tx.object(params.inputCoin) : params.inputCoin,
        this.tx.pure.u64(params.minOutput),
        this.tx.pure.address(params.recipient),
        this.tx.pure.u64(params.deadlineMs),
        this.tx.object(CLOCK_OBJECT),
      ],
    });
  }

  // ============================================
  // UTILITY METHODS
  // ============================================

  /**
   * Split coins from a source
   */
  splitCoins(coin: string, amounts: bigint[]): TransactionResult[] {
    return this.tx.splitCoins(
      this.tx.object(coin),
      amounts.map((a) => this.tx.pure.u64(a))
    );
  }

  /**
   * Merge coins into one
   */
  mergeCoins(destination: string, sources: string[]): void {
    this.tx.mergeCoins(
      this.tx.object(destination),
      sources.map((s) => this.tx.object(s))
    );
  }

  /**
   * Transfer object to recipient
   */
  transfer(object: TransactionResult | string, recipient: string): void {
    this.tx.transferObjects(
      [typeof object === 'string' ? this.tx.object(object) : object],
      this.tx.pure.address(recipient)
    );
  }

  /**
   * Get the underlying Transaction object
   */
  build(): Transaction {
    return this.tx;
  }
}

/**
 * Create a new PTB builder
 */
export function createPTB(config: NetworkConfig, apexPackage: string): ApexPTBBuilder {
  return new ApexPTBBuilder(config, apexPackage);
}
