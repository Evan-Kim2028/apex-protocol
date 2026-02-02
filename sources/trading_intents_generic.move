/// APEX Trading Intents - Generic Coin Support (v3)
/// Intent-based trading for AI agents supporting ANY coin type
///
/// This module uses type parameters to enable trading between any pair of coins,
/// not just SUI. This enables:
/// - USDC/SUI swaps
/// - DEEP/SUI swaps
/// - USDC/USDT swaps
/// - Any token pair supported by DEXes
module dexter_payment::trading_intents_generic {
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::balance::{Self, Balance};
    use sui::event;
    use sui::clock::{Self, Clock};

    // ==================== Error Codes ====================
    const EInvalidIntent: u64 = 0;
    const ESlippageExceeded: u64 = 1;
    const EDeadlineExceeded: u64 = 2;
    const EInsufficientInput: u64 = 3;
    const EUnauthorized: u64 = 4;
    const EInsufficientStake: u64 = 5;
    const EExecutorInactive: u64 = 6;
    const EInvalidOutput: u64 = 7;
    const EIntentNotCancellable: u64 = 8;
    const EOverflow: u64 = 9;

    // ==================== Constants ====================
    const MIN_EXECUTOR_STAKE: u64 = 1_000_000_000; // 1 SUI minimum
    const SLASH_PERCENTAGE: u64 = 10; // 10% slash on bad execution
    const REPUTATION_DECAY_RATE: u64 = 1;

    // ==================== Structs ====================

    /// GenericSwapIntent<INPUT, OUTPUT> - swap any coin type for another
    /// Uses phantom types to specify the exact token pair
    public struct GenericSwapIntent<phantom INPUT, phantom OUTPUT> has key {
        id: UID,
        /// Requester
        requester: address,
        /// Input amount (stored in balance)
        input_escrow: Balance<INPUT>,
        /// Minimum output expected
        min_output: u64,
        /// Maximum slippage (basis points)
        max_slippage_bps: u64,
        /// Deadline timestamp
        deadline: u64,
        /// Created at timestamp
        created_at: u64,
    }

    /// GenericDCAIntent<INPUT, OUTPUT> - DCA with any token pair
    public struct GenericDCAIntent<phantom INPUT, phantom OUTPUT> has key {
        id: UID,
        /// Requester
        requester: address,
        /// Number of intervals
        num_intervals: u64,
        /// Interval duration (ms)
        interval_ms: u64,
        /// Executed count
        executed_count: u64,
        /// Last execution time
        last_executed: u64,
        /// Remaining funds
        remaining: Balance<INPUT>,
        /// Min output per interval
        min_output_per_interval: u64,
        /// Cancel grace period
        cancel_grace_period_ms: u64,
        /// Created at
        created_at: u64,
    }

    /// GenericExecutionReceipt<INPUT, OUTPUT> - proof of generic swap
    public struct GenericExecutionReceipt<phantom INPUT, phantom OUTPUT> has key, store {
        id: UID,
        /// Original intent ID
        intent_id: ID,
        /// Input amount used
        input_used: u64,
        /// Output received
        output_received: u64,
        /// Effective price (scaled by 1e9)
        effective_price: u64,
        /// Executor who filled it
        executor: address,
        /// Timestamp
        executed_at: u64,
    }

    // ==================== Events ====================

    public struct GenericSwapCreated has copy, drop {
        intent_id: ID,
        requester: address,
        input_amount: u64,
        min_output: u64,
        deadline: u64,
        input_type_name: vector<u8>,
        output_type_name: vector<u8>,
    }

    public struct GenericSwapExecuted has copy, drop {
        intent_id: ID,
        executor: address,
        input_used: u64,
        output_received: u64,
        effective_price: u64,
    }

    public struct GenericSwapCancelled has copy, drop {
        intent_id: ID,
        requester: address,
        refunded: u64,
    }

    public struct GenericDCACreated has copy, drop {
        intent_id: ID,
        requester: address,
        total_amount: u64,
        num_intervals: u64,
    }

    public struct GenericDCAIntervalExecuted has copy, drop {
        intent_id: ID,
        interval_number: u64,
        amount_invested: u64,
        amount_received: u64,
    }

    public struct GenericDCACancelled has copy, drop {
        intent_id: ID,
        requester: address,
        refunded: u64,
    }

    // ==================== Generic Swap Functions ====================

    /// Create a generic swap intent for any INPUT/OUTPUT pair
    /// Example: create_generic_swap_intent<USDC, SUI>(...) for USDC->SUI swap
    public fun create_generic_swap_intent<INPUT, OUTPUT>(
        input: Coin<INPUT>,
        min_output: u64,
        max_slippage_bps: u64,
        deadline: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let input_amount = coin::value(&input);
        assert!(input_amount > 0, EInsufficientInput);

        let intent = GenericSwapIntent<INPUT, OUTPUT> {
            id: object::new(ctx),
            requester: tx_context::sender(ctx),
            input_escrow: coin::into_balance(input),
            min_output,
            max_slippage_bps,
            deadline,
            created_at: clock::timestamp_ms(clock),
        };

        event::emit(GenericSwapCreated {
            intent_id: object::id(&intent),
            requester: tx_context::sender(ctx),
            input_amount,
            min_output,
            deadline,
            input_type_name: b"INPUT", // In production: use type_name::get<INPUT>()
            output_type_name: b"OUTPUT",
        });

        transfer::share_object(intent);
    }

    /// Execute generic swap - executor provides actual output coin
    public fun execute_generic_swap<INPUT, OUTPUT>(
        intent: GenericSwapIntent<INPUT, OUTPUT>,
        output_coin: Coin<OUTPUT>,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<INPUT> {
        let GenericSwapIntent {
            id,
            requester,
            input_escrow,
            min_output,
            max_slippage_bps: _,
            deadline,
            created_at: _,
        } = intent;

        // Verify deadline
        let now = clock::timestamp_ms(clock);
        assert!(now <= deadline, EDeadlineExceeded);

        // Verify output meets minimum
        let output_amount = coin::value(&output_coin);
        assert!(output_amount >= min_output, ESlippageExceeded);

        let input_amount = balance::value(&input_escrow);

        // Calculate effective price (scaled)
        let effective_price = if (output_amount > 0) {
            safe_mul(input_amount, 1_000_000_000) / output_amount
        } else {
            0
        };

        // Send output to requester
        transfer::public_transfer(output_coin, requester);

        // Create receipt for requester
        let receipt = GenericExecutionReceipt<INPUT, OUTPUT> {
            id: object::new(ctx),
            intent_id: object::uid_to_inner(&id),
            input_used: input_amount,
            output_received: output_amount,
            effective_price,
            executor: tx_context::sender(ctx),
            executed_at: now,
        };

        event::emit(GenericSwapExecuted {
            intent_id: object::uid_to_inner(&id),
            executor: tx_context::sender(ctx),
            input_used: input_amount,
            output_received: output_amount,
            effective_price,
        });

        transfer::transfer(receipt, requester);
        object::delete(id);

        // Return input to executor (caller)
        coin::from_balance(input_escrow, ctx)
    }

    /// Cancel generic swap intent
    public fun cancel_generic_swap<INPUT, OUTPUT>(
        intent: GenericSwapIntent<INPUT, OUTPUT>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let GenericSwapIntent {
            id,
            requester,
            input_escrow,
            min_output: _,
            max_slippage_bps: _,
            deadline,
            created_at: _,
        } = intent;

        let sender = tx_context::sender(ctx);
        let now = clock::timestamp_ms(clock);

        // Can cancel if: requester OR deadline passed
        assert!(sender == requester || now > deadline, EUnauthorized);

        let refund_amount = balance::value(&input_escrow);
        let refund = coin::from_balance(input_escrow, ctx);
        transfer::public_transfer(refund, requester);

        event::emit(GenericSwapCancelled {
            intent_id: object::uid_to_inner(&id),
            requester,
            refunded: refund_amount,
        });

        object::delete(id);
    }

    // ==================== Generic DCA Functions ====================

    /// Create DCA intent for any token pair
    public fun create_generic_dca<INPUT, OUTPUT>(
        total_funding: Coin<INPUT>,
        num_intervals: u64,
        interval_ms: u64,
        min_output_per_interval: u64,
        cancel_grace_period_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let total_amount = coin::value(&total_funding);
        assert!(total_amount > 0, EInsufficientInput);
        assert!(num_intervals > 0, EInvalidIntent);

        let intent = GenericDCAIntent<INPUT, OUTPUT> {
            id: object::new(ctx),
            requester: tx_context::sender(ctx),
            num_intervals,
            interval_ms,
            executed_count: 0,
            last_executed: clock::timestamp_ms(clock),
            remaining: coin::into_balance(total_funding),
            min_output_per_interval,
            cancel_grace_period_ms,
            created_at: clock::timestamp_ms(clock),
        };

        event::emit(GenericDCACreated {
            intent_id: object::id(&intent),
            requester: tx_context::sender(ctx),
            total_amount,
            num_intervals,
        });

        transfer::share_object(intent);
    }

    /// Execute one DCA interval
    public fun execute_generic_dca_interval<INPUT, OUTPUT>(
        intent: &mut GenericDCAIntent<INPUT, OUTPUT>,
        output_coin: Coin<OUTPUT>,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<INPUT> {
        assert!(intent.executed_count < intent.num_intervals, EInvalidIntent);

        let now = clock::timestamp_ms(clock);
        assert!(now >= intent.last_executed + intent.interval_ms, EDeadlineExceeded);

        // Verify output
        let output_amount = coin::value(&output_coin);
        assert!(output_amount >= intent.min_output_per_interval, ESlippageExceeded);

        // Calculate amount for this interval
        let remaining_intervals = intent.num_intervals - intent.executed_count;
        let amount_this_interval = balance::value(&intent.remaining) / remaining_intervals;

        // Extract input payment
        let input_payment = balance::split(&mut intent.remaining, amount_this_interval);

        // Send output to requester
        transfer::public_transfer(output_coin, intent.requester);

        intent.executed_count = intent.executed_count + 1;
        intent.last_executed = now;

        event::emit(GenericDCAIntervalExecuted {
            intent_id: object::id(intent),
            interval_number: intent.executed_count,
            amount_invested: amount_this_interval,
            amount_received: output_amount,
        });

        // Return input to executor
        coin::from_balance(input_payment, ctx)
    }

    /// Cancel DCA intent
    public fun cancel_generic_dca<INPUT, OUTPUT>(
        intent: GenericDCAIntent<INPUT, OUTPUT>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let GenericDCAIntent {
            id,
            requester,
            num_intervals: _,
            interval_ms: _,
            executed_count: _,
            last_executed: _,
            remaining,
            min_output_per_interval: _,
            cancel_grace_period_ms,
            created_at,
        } = intent;

        let sender = tx_context::sender(ctx);
        let now = clock::timestamp_ms(clock);

        assert!(
            sender == requester || now > created_at + cancel_grace_period_ms,
            EIntentNotCancellable
        );

        let refund_amount = balance::value(&remaining);

        if (refund_amount > 0) {
            let refund = coin::from_balance(remaining, ctx);
            transfer::public_transfer(refund, requester);
        } else {
            balance::destroy_zero(remaining);
        };

        event::emit(GenericDCACancelled {
            intent_id: object::uid_to_inner(&id),
            requester,
            refunded: refund_amount,
        });

        object::delete(id);
    }

    // ==================== Helper Functions ====================

    fun safe_mul(a: u64, b: u64): u64 {
        if (a == 0 || b == 0) {
            return 0
        };
        let result = a * b;
        assert!(result / a == b, EOverflow);
        result
    }

    // ==================== View Functions ====================

    public fun generic_intent_min_output<INPUT, OUTPUT>(intent: &GenericSwapIntent<INPUT, OUTPUT>): u64 {
        intent.min_output
    }

    public fun generic_intent_deadline<INPUT, OUTPUT>(intent: &GenericSwapIntent<INPUT, OUTPUT>): u64 {
        intent.deadline
    }

    public fun generic_intent_input_amount<INPUT, OUTPUT>(intent: &GenericSwapIntent<INPUT, OUTPUT>): u64 {
        balance::value(&intent.input_escrow)
    }

    public fun generic_dca_remaining<INPUT, OUTPUT>(intent: &GenericDCAIntent<INPUT, OUTPUT>): u64 {
        balance::value(&intent.remaining)
    }

    public fun generic_dca_progress<INPUT, OUTPUT>(intent: &GenericDCAIntent<INPUT, OUTPUT>): (u64, u64) {
        (intent.executed_count, intent.num_intervals)
    }
}
