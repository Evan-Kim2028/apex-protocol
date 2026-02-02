/// APEX Trading - Pay-Then-Trade Patterns with DeepBook
///
/// This module demonstrates how to compose APEX payments with DeepBook trading.
/// It does NOT wrap DeepBook - instead it shows patterns for:
///
/// 1. Requiring payment before allowing trades (gated trading)
/// 2. Trading intents that escrow funds until executed
/// 3. Atomic pay-and-trade verification
///
/// IMPORTANT: This module calls DeepBook DIRECTLY. Agents can also call
/// DeepBook directly without using this module. This is just a convenience
/// layer showing common patterns.
module apex_protocol::apex_trading;

use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::balance::{Self, Balance};
use sui::event;
use sui::sui::SUI;

use apex_protocol::apex_payments::{
    Self,
    ServiceProvider,
    AccessCapability,
};

// Note: DeepBook types would be imported when deployed to mainnet
// For local sandbox testing, we just define the patterns without DeepBook imports

// ==================== Error Codes ====================
const EInvalidCapability: u64 = 0;
const EInsufficientOutput: u64 = 1;
const EDeadlineExpired: u64 = 2;
const EIntentAlreadyFilled: u64 = 3;
const EIntentCancelled: u64 = 4;
const EUnauthorized: u64 = 5;
const EInvalidAmount: u64 = 6;

// ==================== Constants ====================
const MIN_INTENT_DURATION_MS: u64 = 60_000; // 1 minute minimum
const MAX_INTENT_DURATION_MS: u64 = 86_400_000; // 24 hours maximum

// ==================== Trading Intent ====================

/// SwapIntent - Declares desired trade outcome, escrows input
///
/// An agent creates an intent saying "I want to swap X for at least Y"
/// Executors compete to fill the intent via DeepBook or other sources.
public struct SwapIntent<phantom InputCoin> has key {
    id: UID,
    /// Creator of the intent
    creator: address,
    /// Escrowed input coins
    escrowed: Balance<InputCoin>,
    /// Minimum output amount required
    min_output: u64,
    /// Recipient of the output
    recipient: address,
    /// Deadline timestamp (ms)
    deadline: u64,
    /// Whether intent has been filled
    filled: bool,
    /// Whether intent has been cancelled
    cancelled: bool,
}

/// IntentReceipt - Proof that an intent was filled
public struct IntentReceipt has key, store {
    id: UID,
    /// Original intent ID
    intent_id: ID,
    /// Executor who filled it
    executor: address,
    /// Input amount
    input_amount: u64,
    /// Output amount delivered
    output_amount: u64,
    /// Timestamp
    timestamp: u64,
}

// ==================== Gated Trading Service ====================

/// TradingService - A service that requires APEX payment before trading
///
/// Example: A trading bot API that charges per trade recommendation
public struct TradingService has key {
    id: UID,
    /// Owner/operator
    operator: address,
    /// Associated APEX service for payments
    apex_service_id: ID,
    /// Accumulated fees from trading
    trading_fees: Balance<SUI>,
    /// Fee per trade (in addition to APEX access fee)
    fee_per_trade: u64,
    /// Total trades facilitated
    total_trades: u64,
    /// Active status
    active: bool,
}

// ==================== Events ====================

public struct IntentCreated has copy, drop {
    intent_id: ID,
    creator: address,
    input_amount: u64,
    min_output: u64,
    deadline: u64,
}

public struct IntentFilled has copy, drop {
    intent_id: ID,
    executor: address,
    input_amount: u64,
    output_amount: u64,
}

public struct IntentCancelled has copy, drop {
    intent_id: ID,
    creator: address,
    refunded_amount: u64,
}

public struct GatedTradeExecuted has copy, drop {
    service_id: ID,
    trader: address,
    capability_id: ID,
    units_consumed: u64,
}

public struct TradingServiceCreated has copy, drop {
    service_id: ID,
    operator: address,
    apex_service_id: ID,
    fee_per_trade: u64,
}

// ==================== Trading Intent Functions ====================

/// Create a swap intent - escrows input, waits for executor
public fun create_swap_intent<InputCoin>(
    input_coin: Coin<InputCoin>,
    min_output: u64,
    recipient: address,
    duration_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext
): ID {
    assert!(min_output > 0, EInvalidAmount);
    assert!(duration_ms >= MIN_INTENT_DURATION_MS, EInvalidAmount);
    assert!(duration_ms <= MAX_INTENT_DURATION_MS, EInvalidAmount);

    let input_amount = coin::value(&input_coin);
    let deadline = clock::timestamp_ms(clock) + duration_ms;

    let intent = SwapIntent<InputCoin> {
        id: object::new(ctx),
        creator: ctx.sender(),
        escrowed: coin::into_balance(input_coin),
        min_output,
        recipient,
        deadline,
        filled: false,
        cancelled: false,
    };

    let intent_id = object::id(&intent);

    event::emit(IntentCreated {
        intent_id,
        creator: ctx.sender(),
        input_amount,
        min_output,
        deadline,
    });

    transfer::share_object(intent);
    intent_id
}

/// Fill an intent by providing the output
///
/// The executor calls this after swapping on DeepBook (or elsewhere).
/// They provide the output coin, and receive the escrowed input.
public fun fill_intent<InputCoin, OutputCoin>(
    intent: &mut SwapIntent<InputCoin>,
    output_coin: Coin<OutputCoin>,
    clock: &Clock,
    ctx: &mut TxContext
): (Coin<InputCoin>, IntentReceipt) {
    assert!(!intent.filled, EIntentAlreadyFilled);
    assert!(!intent.cancelled, EIntentCancelled);
    assert!(clock::timestamp_ms(clock) <= intent.deadline, EDeadlineExpired);

    let output_amount = coin::value(&output_coin);
    assert!(output_amount >= intent.min_output, EInsufficientOutput);

    // Mark as filled
    intent.filled = true;

    // Transfer output to recipient
    transfer::public_transfer(output_coin, intent.recipient);

    // Extract escrowed input for executor
    let input_amount = balance::value(&intent.escrowed);
    let input_coin = coin::from_balance(
        balance::split(&mut intent.escrowed, input_amount),
        ctx
    );

    // Create receipt
    let receipt = IntentReceipt {
        id: object::new(ctx),
        intent_id: object::id(intent),
        executor: ctx.sender(),
        input_amount,
        output_amount,
        timestamp: clock::timestamp_ms(clock),
    };

    event::emit(IntentFilled {
        intent_id: object::id(intent),
        executor: ctx.sender(),
        input_amount,
        output_amount,
    });

    (input_coin, receipt)
}

/// Cancel an expired or unwanted intent (creator only)
public fun cancel_intent<InputCoin>(
    intent: SwapIntent<InputCoin>,
    _clock: &Clock,
    ctx: &mut TxContext
): Coin<InputCoin> {
    let SwapIntent {
        id,
        creator,
        escrowed,
        min_output: _,
        recipient: _,
        deadline,
        filled,
        cancelled: _,
    } = intent;

    assert!(ctx.sender() == creator, EUnauthorized);
    assert!(!filled, EIntentAlreadyFilled);

    // Can only cancel after deadline OR by creator at any time
    // (creator can always cancel their own intent)
    let _ = deadline; // Deadline check is optional for creator

    let refunded_amount = balance::value(&escrowed);
    let refund = coin::from_balance(escrowed, ctx);

    event::emit(IntentCancelled {
        intent_id: object::uid_to_inner(&id),
        creator,
        refunded_amount,
    });

    object::delete(id);
    refund
}

/// Anyone can clean up expired, unfilled intents
public fun cleanup_expired_intent<InputCoin>(
    intent: SwapIntent<InputCoin>,
    clock: &Clock,
    ctx: &mut TxContext
) {
    let SwapIntent {
        id,
        creator,
        escrowed,
        min_output: _,
        recipient: _,
        deadline,
        filled,
        cancelled: _,
    } = intent;

    assert!(!filled, EIntentAlreadyFilled);
    assert!(clock::timestamp_ms(clock) > deadline, EDeadlineExpired);

    let refunded_amount = balance::value(&escrowed);
    let refund = coin::from_balance(escrowed, ctx);
    transfer::public_transfer(refund, creator);

    event::emit(IntentCancelled {
        intent_id: object::uid_to_inner(&id),
        creator,
        refunded_amount,
    });

    object::delete(id);
}

// ==================== Gated Trading Functions ====================

/// Create a trading service that requires APEX payment
public fun create_trading_service(
    apex_service_id: ID,
    fee_per_trade: u64,
    ctx: &mut TxContext
): TradingService {
    let service = TradingService {
        id: object::new(ctx),
        operator: ctx.sender(),
        apex_service_id,
        trading_fees: balance::zero(),
        fee_per_trade,
        total_trades: 0,
        active: true,
    };

    event::emit(TradingServiceCreated {
        service_id: object::id(&service),
        operator: ctx.sender(),
        apex_service_id,
        fee_per_trade,
    });

    service
}

/// Create and share a trading service in one call
public fun create_and_share_trading_service(
    apex_service_id: ID,
    fee_per_trade: u64,
    ctx: &mut TxContext
) {
    let service = create_trading_service(apex_service_id, fee_per_trade, ctx);
    transfer::share_object(service);
}

/// Verify payment before allowing trade
///
/// This function checks that the caller has a valid AccessCapability
/// for the associated APEX service. Call this before executing trades.
///
/// Returns true and consumes units if valid, aborts otherwise.
public fun verify_trade_payment(
    trading_service: &mut TradingService,
    apex_service: &ServiceProvider,
    capability: &mut AccessCapability,
    units: u64,
    clock: &Clock,
    ctx: &TxContext
): bool {
    assert!(trading_service.active, EUnauthorized);
    assert!(apex_payments::capability_service_id(capability) == trading_service.apex_service_id, EInvalidCapability);

    // Use the access capability (consumes units)
    let success = apex_payments::use_access(capability, apex_service, units, clock, ctx);
    assert!(success, EInvalidCapability);

    trading_service.total_trades = trading_service.total_trades + 1;

    event::emit(GatedTradeExecuted {
        service_id: object::id(trading_service),
        trader: ctx.sender(),
        capability_id: object::id(capability),
        units_consumed: units,
    });

    true
}

/// Collect trading fee (in addition to APEX access fee)
public fun collect_trading_fee(
    trading_service: &mut TradingService,
    fee_payment: Coin<SUI>,
) {
    assert!(coin::value(&fee_payment) >= trading_service.fee_per_trade, EInvalidAmount);
    balance::join(&mut trading_service.trading_fees, coin::into_balance(fee_payment));
}

/// Withdraw trading fees (operator only)
public fun withdraw_trading_fees(
    trading_service: &mut TradingService,
    ctx: &mut TxContext
): Coin<SUI> {
    assert!(ctx.sender() == trading_service.operator, EUnauthorized);

    let amount = balance::value(&trading_service.trading_fees);
    coin::from_balance(
        balance::split(&mut trading_service.trading_fees, amount),
        ctx
    )
}

/// Deactivate trading service
public fun deactivate_trading_service(
    trading_service: &mut TradingService,
    ctx: &TxContext
) {
    assert!(ctx.sender() == trading_service.operator, EUnauthorized);
    trading_service.active = false;
}

// ==================== View Functions ====================

public fun intent_min_output<InputCoin>(intent: &SwapIntent<InputCoin>): u64 {
    intent.min_output
}

public fun intent_deadline<InputCoin>(intent: &SwapIntent<InputCoin>): u64 {
    intent.deadline
}

public fun intent_escrowed_amount<InputCoin>(intent: &SwapIntent<InputCoin>): u64 {
    balance::value(&intent.escrowed)
}

public fun intent_is_filled<InputCoin>(intent: &SwapIntent<InputCoin>): bool {
    intent.filled
}

public fun intent_recipient<InputCoin>(intent: &SwapIntent<InputCoin>): address {
    intent.recipient
}

public fun trading_service_fee(service: &TradingService): u64 {
    service.fee_per_trade
}

public fun trading_service_total_trades(service: &TradingService): u64 {
    service.total_trades
}

public fun trading_service_is_active(service: &TradingService): bool {
    service.active
}

// ==================== Example PTB Patterns (Comments) ====================

// The following comments show how to construct PTBs that combine
// APEX payments with DeepBook trading. These are executed client-side.

/*
PATTERN 1: Atomic Pay-and-Trade

In a single PTB:
1. Purchase APEX access
2. Execute DeepBook swap
3. All atomic - if swap fails, payment is reverted

```typescript
const tx = new Transaction();

// 1. Purchase access capability
const accessCap = tx.moveCall({
    target: `${APEX_PKG}::apex_payments::purchase_access`,
    arguments: [config, service, payment, units, duration, rateLimit, clock],
});

// 2. Execute swap on DeepBook directly
const [baseOut, quoteOut, deepOut] = tx.moveCall({
    target: `${DEEPBOOK_PKG}::pool::swap_exact_base_for_quote`,
    typeArguments: [BASE_TYPE, QUOTE_TYPE],
    arguments: [pool, baseCoin, deepCoin, minQuote, clock],
});

// 3. Transfer outputs
tx.transferObjects([accessCap, quoteOut], recipient);
```

PATTERN 2: Gated Trading (Verify then Trade)

```typescript
const tx = new Transaction();

// 1. Verify payment (uses capability units)
tx.moveCall({
    target: `${APEX_PKG}::apex_trading::verify_trade_payment`,
    arguments: [tradingService, apexService, capability, units, clock],
});

// 2. Execute swap (only succeeds if verification passed)
const [baseOut, quoteOut, deepOut] = tx.moveCall({
    target: `${DEEPBOOK_PKG}::pool::swap_exact_base_for_quote`,
    // ...
});
```

PATTERN 3: Intent-Based Trading

Agent creates intent:
```typescript
const tx = new Transaction();
tx.moveCall({
    target: `${APEX_PKG}::apex_trading::create_swap_intent`,
    typeArguments: [INPUT_TYPE],
    arguments: [inputCoin, minOutput, recipient, duration, clock],
});
```

Executor fills intent (after swapping elsewhere):
```typescript
const tx = new Transaction();

// 1. Swap on DeepBook to get output
const [_, outputCoin, _] = tx.moveCall({
    target: `${DEEPBOOK_PKG}::pool::swap_exact_base_for_quote`,
    // ...
});

// 2. Fill intent with output, receive escrowed input
const [escrowedInput, receipt] = tx.moveCall({
    target: `${APEX_PKG}::apex_trading::fill_intent`,
    typeArguments: [INPUT_TYPE, OUTPUT_TYPE],
    arguments: [intent, outputCoin, clock],
});
```
*/
