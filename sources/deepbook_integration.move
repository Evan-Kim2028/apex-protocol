/// APEX DeepBook V3 Integration
/// Real DEX integration for intent execution using Sui's native orderbook
///
/// DeepBook V3 Package: 0x2d93777cc8b67c064b495e8606f2f8f5fd578450347bbe7b36e0bc03963c1c40
///
/// This module provides:
/// - Direct swap execution via DeepBook pools
/// - Intent-to-DEX execution bridge
/// - Balance manager wrapper for trading
module dexter_payment::deepbook_v3;

use deepbook::balance_manager::{Self, BalanceManager, TradeProof, TradeCap};
use deepbook::pool::{Self, Pool};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;
use token::deep::DEEP;

// ==================== Error Codes ====================
const EInsufficientOutput: u64 = 0;
const EDeadlineExceeded: u64 = 1;
const EUnauthorized: u64 = 2;
const EInsufficientDeepForFees: u64 = 3;

// ==================== Structs ====================

/// Wrapper around BalanceManager for APEX agents
/// Enables agents to trade on DeepBook with delegated permissions
public struct AgentTrader has key {
    id: UID,
    /// Owner of this trader
    owner: address,
    /// DeepBook BalanceManager
    balance_manager: BalanceManager,
    /// Trade capability
    trade_cap: TradeCap,
}

/// Receipt proving a swap was executed
public struct SwapReceipt has key, store {
    id: UID,
    /// Pool used
    pool_id: ID,
    /// Direction (true = base->quote, false = quote->base)
    base_to_quote: bool,
    /// Input amount
    amount_in: u64,
    /// Output amount
    amount_out: u64,
    /// DEEP fees paid
    deep_fees_paid: u64,
    /// Trader
    trader: address,
    /// Timestamp
    timestamp: u64,
}

// ==================== Events ====================

public struct SwapExecuted has copy, drop {
    pool_id: ID,
    trader: address,
    base_to_quote: bool,
    amount_in: u64,
    amount_out: u64,
    deep_fees: u64,
    timestamp: u64,
}

public struct AgentTraderCreated has copy, drop {
    trader_id: ID,
    owner: address,
    balance_manager_id: ID,
}

// ==================== Agent Trader Functions ====================

/// Create a new AgentTrader with a fresh BalanceManager
public fun create_agent_trader(ctx: &mut TxContext): AgentTrader {
    let mut balance_manager = balance_manager::new(ctx);
    let trade_cap = balance_manager.mint_trade_cap(ctx);

    let trader = AgentTrader {
        id: object::new(ctx),
        owner: ctx.sender(),
        balance_manager,
        trade_cap,
    };

    event::emit(AgentTraderCreated {
        trader_id: object::id(&trader),
        owner: ctx.sender(),
        balance_manager_id: object::id(&trader.balance_manager),
    });

    trader
}

/// Deposit base asset into agent trader's balance manager
public fun deposit_base<BaseAsset>(
    trader: &mut AgentTrader,
    coin: Coin<BaseAsset>,
    ctx: &mut TxContext
) {
    assert!(ctx.sender() == trader.owner, EUnauthorized);
    trader.balance_manager.deposit(coin, ctx);
}

/// Deposit quote asset
public fun deposit_quote<QuoteAsset>(
    trader: &mut AgentTrader,
    coin: Coin<QuoteAsset>,
    ctx: &mut TxContext
) {
    assert!(ctx.sender() == trader.owner, EUnauthorized);
    trader.balance_manager.deposit(coin, ctx);
}

/// Deposit DEEP for fees
public fun deposit_deep(
    trader: &mut AgentTrader,
    coin: Coin<DEEP>,
    ctx: &mut TxContext
) {
    assert!(ctx.sender() == trader.owner, EUnauthorized);
    trader.balance_manager.deposit(coin, ctx);
}

/// Withdraw base asset
public fun withdraw_base<BaseAsset>(
    trader: &mut AgentTrader,
    amount: u64,
    ctx: &mut TxContext
): Coin<BaseAsset> {
    assert!(ctx.sender() == trader.owner, EUnauthorized);
    trader.balance_manager.withdraw(amount, ctx)
}

/// Withdraw quote asset
public fun withdraw_quote<QuoteAsset>(
    trader: &mut AgentTrader,
    amount: u64,
    ctx: &mut TxContext
): Coin<QuoteAsset> {
    assert!(ctx.sender() == trader.owner, EUnauthorized);
    trader.balance_manager.withdraw(amount, ctx)
}

// ==================== Direct Swap Functions ====================

/// Execute a swap: base asset -> quote asset
/// Uses DeepBook's swap_exact_base_for_quote
/// Returns (remaining_base, quote_out, remaining_deep)
public fun swap_base_for_quote<BaseAsset, QuoteAsset>(
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_in: Coin<BaseAsset>,
    deep_for_fees: Coin<DEEP>,
    min_quote_out: u64,
    clock: &Clock,
    ctx: &mut TxContext
): (Coin<BaseAsset>, Coin<QuoteAsset>, Coin<DEEP>, SwapReceipt) {
    let base_amount = base_in.value();
    let deep_before = deep_for_fees.value();

    let (base_remaining, quote_out, deep_remaining) = pool.swap_exact_base_for_quote(
        base_in,
        deep_for_fees,
        min_quote_out,
        clock,
        ctx
    );

    let quote_amount = quote_out.value();
    let deep_fees = deep_before - deep_remaining.value();

    // Verify minimum output met
    assert!(quote_amount >= min_quote_out, EInsufficientOutput);

    let receipt = SwapReceipt {
        id: object::new(ctx),
        pool_id: object::id(pool),
        base_to_quote: true,
        amount_in: base_amount - base_remaining.value(),
        amount_out: quote_amount,
        deep_fees_paid: deep_fees,
        trader: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    };

    event::emit(SwapExecuted {
        pool_id: object::id(pool),
        trader: ctx.sender(),
        base_to_quote: true,
        amount_in: base_amount - base_remaining.value(),
        amount_out: quote_amount,
        deep_fees: deep_fees,
        timestamp: clock.timestamp_ms(),
    });

    (base_remaining, quote_out, deep_remaining, receipt)
}

/// Execute a swap: quote asset -> base asset
/// Uses DeepBook's swap_exact_quote_for_base
public fun swap_quote_for_base<BaseAsset, QuoteAsset>(
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    quote_in: Coin<QuoteAsset>,
    deep_for_fees: Coin<DEEP>,
    min_base_out: u64,
    clock: &Clock,
    ctx: &mut TxContext
): (Coin<BaseAsset>, Coin<QuoteAsset>, Coin<DEEP>, SwapReceipt) {
    let quote_amount = quote_in.value();
    let deep_before = deep_for_fees.value();

    let (base_out, quote_remaining, deep_remaining) = pool.swap_exact_quote_for_base(
        quote_in,
        deep_for_fees,
        min_base_out,
        clock,
        ctx
    );

    let base_amount = base_out.value();
    let deep_fees = deep_before - deep_remaining.value();

    // Verify minimum output met
    assert!(base_amount >= min_base_out, EInsufficientOutput);

    let receipt = SwapReceipt {
        id: object::new(ctx),
        pool_id: object::id(pool),
        base_to_quote: false,
        amount_in: quote_amount - quote_remaining.value(),
        amount_out: base_amount,
        deep_fees_paid: deep_fees,
        trader: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    };

    event::emit(SwapExecuted {
        pool_id: object::id(pool),
        trader: ctx.sender(),
        base_to_quote: false,
        amount_in: quote_amount - quote_remaining.value(),
        amount_out: base_amount,
        deep_fees: deep_fees,
        timestamp: clock.timestamp_ms(),
    });

    (base_out, quote_remaining, deep_remaining, receipt)
}

// ==================== Pool Query Functions ====================

/// Get mid price from pool (useful for price discovery)
public fun get_mid_price<BaseAsset, QuoteAsset>(
    pool: &Pool<BaseAsset, QuoteAsset>,
    clock: &Clock
): u64 {
    pool.mid_price(clock)
}

/// Get expected output amount (dry run)
/// Returns (base_out, quote_out, deep_required)
public fun get_quantity_out<BaseAsset, QuoteAsset>(
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_quantity: u64,
    quote_quantity: u64,
    clock: &Clock
): (u64, u64, u64) {
    pool.get_quantity_out(base_quantity, quote_quantity, clock)
}

/// Get pool parameters
/// Returns (tick_size, lot_size, min_size)
public fun get_pool_params<BaseAsset, QuoteAsset>(
    pool: &Pool<BaseAsset, QuoteAsset>
): (u64, u64, u64) {
    pool.pool_book_params()
}

/// Get pool trade parameters
/// Returns (taker_fee, maker_fee, stake_required)
public fun get_trade_params<BaseAsset, QuoteAsset>(
    pool: &Pool<BaseAsset, QuoteAsset>
): (u64, u64, u64) {
    pool.pool_trade_params()
}

// ==================== Intent Execution Bridge ====================

/// Execute an APEX swap intent using DeepBook
/// This bridges our intent system to real DEX liquidity
///
/// Flow:
/// 1. Executor takes intent's escrowed input
/// 2. Swaps on DeepBook pool
/// 3. Sends output to intent requester
/// 4. Gets receipt as proof
public fun execute_intent_swap<BaseAsset, QuoteAsset>(
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    input_coin: Coin<BaseAsset>,
    deep_for_fees: Coin<DEEP>,
    min_output: u64,
    recipient: address,
    clock: &Clock,
    ctx: &mut TxContext
): SwapReceipt {
    let (remaining_base, quote_out, remaining_deep, receipt) = swap_base_for_quote(
        pool,
        input_coin,
        deep_for_fees,
        min_output,
        clock,
        ctx
    );

    // Send output to the intent requester (recipient)
    transfer::public_transfer(quote_out, recipient);

    // Return any remaining input/DEEP to executor
    if (remaining_base.value() > 0) {
        transfer::public_transfer(remaining_base, ctx.sender());
    } else {
        remaining_base.destroy_zero();
    };

    if (remaining_deep.value() > 0) {
        transfer::public_transfer(remaining_deep, ctx.sender());
    } else {
        remaining_deep.destroy_zero();
    };

    receipt
}

// ==================== View Functions ====================

public fun receipt_pool_id(receipt: &SwapReceipt): ID {
    receipt.pool_id
}

public fun receipt_amount_in(receipt: &SwapReceipt): u64 {
    receipt.amount_in
}

public fun receipt_amount_out(receipt: &SwapReceipt): u64 {
    receipt.amount_out
}

public fun receipt_fees_paid(receipt: &SwapReceipt): u64 {
    receipt.deep_fees_paid
}

public fun trader_owner(trader: &AgentTrader): address {
    trader.owner
}
