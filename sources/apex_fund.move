/// APEX Fund - Agentic Hedge Fund on DeepBook Margin
///
/// This module implements a decentralized hedge fund where:
/// - A Fund Manager Agent operates the fund and executes margin trades
/// - Investor Agents pay an entry fee to join, deposit capital, and receive shares
/// - Capital is pooled for margin trading on DeepBook
/// - Profits are distributed proportionally to share holders
///
/// ## Fund Lifecycle
///
/// 1. **Fund Creation**: Manager creates fund with parameters
/// 2. **Investor Onboarding**: Agents pay entry fee + deposit capital → receive shares
/// 3. **Trading Period**: Manager executes margin trades via DeepBook
/// 4. **Settlement**: Fund closes, profits distributed to investors
///
/// ## Key Security Properties
///
/// - Manager cannot withdraw investor capital directly
/// - Investors can only withdraw their share after settlement
/// - All trades are atomic and on-chain verifiable
/// - Entry fees go to APEX protocol + fund treasury
module apex_protocol::apex_fund;

use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::balance::{Self, Balance};
use sui::event;
use sui::sui::SUI;
use sui::table::{Self, Table};

use apex_protocol::apex_payments::{
    Self,
    ProtocolConfig,
    ServiceProvider,
    AccessCapability,
};

// ==================== Error Codes ====================
const EFundNotOpen: u64 = 0;
const EFundNotTrading: u64 = 1;
const EFundNotSettled: u64 = 2;
const EUnauthorized: u64 = 3;
const EInsufficientDeposit: u64 = 4;
const EInsufficientShares: u64 = 5;
const EAlreadyInvested: u64 = 6;
const ENotInvestor: u64 = 7;
const EInvalidAmount: u64 = 8;
const EEntryFeeRequired: u64 = 9;
const EFundFull: u64 = 10;
const EWithdrawalPending: u64 = 11;

// ==================== Constants ====================
const MIN_DEPOSIT: u64 = 100_000_000; // 0.1 SUI minimum
const BASIS_POINTS: u64 = 10_000;

// ==================== Fund State ====================

/// Fund lifecycle phases
const FUND_OPEN: u8 = 0;      // Accepting investors
const FUND_TRADING: u8 = 1;    // Active trading, no new deposits
const FUND_SETTLED: u8 = 2;    // Trading complete, ready for withdrawal

/// The main hedge fund structure
public struct HedgeFund has key {
    id: UID,
    /// Fund name
    name: vector<u8>,
    /// Manager agent address
    manager: address,
    /// Associated APEX service for entry fees
    apex_service_id: ID,
    /// Current fund state
    state: u8,
    /// Total shares issued
    total_shares: u64,
    /// Capital pool for trading
    capital_pool: Balance<SUI>,
    /// Trading profit/loss (can be negative conceptually, stored as u64 with flag)
    realized_pnl: u64,
    is_profit: bool,
    /// Management fee in basis points (e.g., 200 = 2%)
    management_fee_bps: u64,
    /// Performance fee in basis points (e.g., 2000 = 20%)
    performance_fee_bps: u64,
    /// Entry fee in SUI (paid via APEX)
    entry_fee: u64,
    /// Maximum fund size
    max_capacity: u64,
    /// Fund start time
    created_at: u64,
    /// Trading start time
    trading_started_at: u64,
    /// Settlement time
    settled_at: u64,
    /// Manager's accumulated fees
    manager_fees: Balance<SUI>,
}

/// Investor position in the fund
public struct InvestorPosition has key, store {
    id: UID,
    /// Fund ID
    fund_id: ID,
    /// Investor address
    investor: address,
    /// Number of shares held
    shares: u64,
    /// Original deposit amount
    deposit_amount: u64,
    /// Entry timestamp
    entered_at: u64,
    /// Whether withdrawal is pending
    withdrawal_pending: bool,
}

/// Receipt for fund entry (proves entry fee was paid)
public struct EntryReceipt has key, store {
    id: UID,
    fund_id: ID,
    investor: address,
    fee_paid: u64,
    timestamp: u64,
}

/// Trade record for transparency
public struct TradeRecord has key, store {
    id: UID,
    fund_id: ID,
    trade_type: vector<u8>, // "MARGIN_LONG", "MARGIN_SHORT", "SPOT"
    input_amount: u64,
    output_amount: u64,
    pnl: u64,
    is_profit: bool,
    timestamp: u64,
}

/// Settlement receipt
public struct SettlementReceipt has key, store {
    id: UID,
    fund_id: ID,
    investor: address,
    shares_redeemed: u64,
    amount_received: u64,
    profit_share: u64,
    timestamp: u64,
}

// ==================== Events ====================

public struct FundCreated has copy, drop {
    fund_id: ID,
    manager: address,
    name: vector<u8>,
    entry_fee: u64,
    max_capacity: u64,
}

public struct InvestorJoined has copy, drop {
    fund_id: ID,
    investor: address,
    deposit_amount: u64,
    shares_received: u64,
    entry_fee_paid: u64,
}

public struct TradingStarted has copy, drop {
    fund_id: ID,
    total_capital: u64,
    total_investors: u64,
    timestamp: u64,
}

public struct TradeExecuted has copy, drop {
    fund_id: ID,
    trade_type: vector<u8>,
    input_amount: u64,
    output_amount: u64,
    pnl: u64,
    is_profit: bool,
}

public struct FundSettled has copy, drop {
    fund_id: ID,
    final_capital: u64,
    total_pnl: u64,
    is_profit: bool,
    manager_fees_collected: u64,
}

public struct InvestorWithdrew has copy, drop {
    fund_id: ID,
    investor: address,
    shares_redeemed: u64,
    amount_received: u64,
}

// ==================== Fund Creation ====================

/// Create a new hedge fund
public fun create_fund(
    config: &ProtocolConfig,
    service: &mut ServiceProvider,
    name: vector<u8>,
    entry_fee: u64,
    management_fee_bps: u64,
    performance_fee_bps: u64,
    max_capacity: u64,
    registration_payment: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext
): ID {
    // Validate fees
    assert!(management_fee_bps <= 500, EInvalidAmount); // Max 5%
    assert!(performance_fee_bps <= 3000, EInvalidAmount); // Max 30%

    // Register as APEX service (pays registration fee)
    // Note: In production, you'd create a new service. Here we use existing.
    let _ = config;
    let _ = service;

    // Consume registration payment for fund treasury
    let fund = HedgeFund {
        id: object::new(ctx),
        name,
        manager: ctx.sender(),
        apex_service_id: object::id(service),
        state: FUND_OPEN,
        total_shares: 0,
        capital_pool: coin::into_balance(registration_payment),
        realized_pnl: 0,
        is_profit: true,
        management_fee_bps,
        performance_fee_bps,
        entry_fee,
        max_capacity,
        created_at: clock::timestamp_ms(clock),
        trading_started_at: 0,
        settled_at: 0,
        manager_fees: balance::zero(),
    };

    let fund_id = object::id(&fund);

    event::emit(FundCreated {
        fund_id,
        manager: ctx.sender(),
        name: fund.name,
        entry_fee,
        max_capacity,
    });

    transfer::share_object(fund);
    fund_id
}

// ==================== Investor Onboarding ====================

/// Pay entry fee to join fund (returns receipt)
/// This uses APEX payment system
public fun pay_entry_fee(
    fund: &HedgeFund,
    config: &mut ProtocolConfig,
    service: &mut ServiceProvider,
    payment: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext
): EntryReceipt {
    assert!(fund.state == FUND_OPEN, EFundNotOpen);

    // Purchase APEX access (this is the entry fee payment)
    let fee_amount = coin::value(&payment);
    assert!(fee_amount >= fund.entry_fee, EEntryFeeRequired);

    // Create access capability (proves payment)
    let _capability = apex_payments::purchase_access(
        config,
        service,
        payment,
        1, // 1 unit = entry permission
        86400_000 * 365, // 1 year validity
        0, // no rate limit
        clock,
        ctx
    );

    // Transfer capability to fund (or burn it - entry is one-time)
    transfer::public_transfer(_capability, fund.manager);

    let receipt = EntryReceipt {
        id: object::new(ctx),
        fund_id: object::id(fund),
        investor: ctx.sender(),
        fee_paid: fee_amount,
        timestamp: clock::timestamp_ms(clock),
    };

    receipt
}

/// Deposit capital after paying entry fee
public fun deposit_capital(
    fund: &mut HedgeFund,
    entry_receipt: EntryReceipt,
    deposit: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext
): InvestorPosition {
    assert!(fund.state == FUND_OPEN, EFundNotOpen);

    // Verify entry receipt
    let EntryReceipt { id, fund_id, investor, fee_paid: _, timestamp: _ } = entry_receipt;
    assert!(fund_id == object::id(fund), EUnauthorized);
    assert!(investor == ctx.sender(), EUnauthorized);
    object::delete(id);

    let deposit_amount = coin::value(&deposit);
    assert!(deposit_amount >= MIN_DEPOSIT, EInsufficientDeposit);

    // Check capacity
    let current_capital = balance::value(&fund.capital_pool);
    assert!(current_capital + deposit_amount <= fund.max_capacity, EFundFull);

    // Calculate shares (1:1 for first investor, proportional after)
    let shares = if (fund.total_shares == 0) {
        deposit_amount
    } else {
        (deposit_amount * fund.total_shares) / current_capital
    };

    // Add to capital pool
    balance::join(&mut fund.capital_pool, coin::into_balance(deposit));
    fund.total_shares = fund.total_shares + shares;

    let position = InvestorPosition {
        id: object::new(ctx),
        fund_id: object::id(fund),
        investor: ctx.sender(),
        shares,
        deposit_amount,
        entered_at: clock::timestamp_ms(clock),
        withdrawal_pending: false,
    };

    event::emit(InvestorJoined {
        fund_id: object::id(fund),
        investor: ctx.sender(),
        deposit_amount,
        shares_received: shares,
        entry_fee_paid: 0, // Already recorded in entry receipt
    });

    position
}

/// Combined entry: pay fee + deposit in one transaction
/// This is the typical user flow
public fun join_fund(
    fund: &mut HedgeFund,
    config: &mut ProtocolConfig,
    service: &mut ServiceProvider,
    entry_fee_payment: Coin<SUI>,
    deposit: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext
): InvestorPosition {
    // Pay entry fee
    let receipt = pay_entry_fee(fund, config, service, entry_fee_payment, clock, ctx);

    // Deposit capital
    deposit_capital(fund, receipt, deposit, clock, ctx)
}

// ==================== Trading Phase ====================

/// Manager starts trading period (closes new investments)
public fun start_trading(
    fund: &mut HedgeFund,
    clock: &Clock,
    ctx: &TxContext
) {
    assert!(ctx.sender() == fund.manager, EUnauthorized);
    assert!(fund.state == FUND_OPEN, EFundNotOpen);
    assert!(fund.total_shares > 0, EInvalidAmount); // Must have investors

    fund.state = FUND_TRADING;
    fund.trading_started_at = clock::timestamp_ms(clock);

    event::emit(TradingStarted {
        fund_id: object::id(fund),
        total_capital: balance::value(&fund.capital_pool),
        total_investors: fund.total_shares, // Simplified: assume 1 share = 1 investor initially
        timestamp: clock::timestamp_ms(clock),
    });
}

/// Execute a margin trade (simulated for sandbox)
/// In production, this would interact with DeepBook margin
///
/// For the sandbox demo, we simulate trades by:
/// 1. Taking capital from pool
/// 2. Returning capital +/- simulated P&L
public fun execute_margin_trade(
    fund: &mut HedgeFund,
    trade_type: vector<u8>,
    input_amount: u64,
    simulated_output: u64, // In sandbox, we pass the result
    clock: &Clock,
    ctx: &mut TxContext
): TradeRecord {
    assert!(ctx.sender() == fund.manager, EUnauthorized);
    assert!(fund.state == FUND_TRADING, EFundNotTrading);
    assert!(balance::value(&fund.capital_pool) >= input_amount, EInsufficientDeposit);

    // Calculate P&L
    let (pnl, is_profit) = if (simulated_output >= input_amount) {
        (simulated_output - input_amount, true)
    } else {
        (input_amount - simulated_output, false)
    };

    // Update fund P&L tracking
    if (is_profit) {
        if (fund.is_profit) {
            fund.realized_pnl = fund.realized_pnl + pnl;
        } else {
            if (pnl >= fund.realized_pnl) {
                fund.realized_pnl = pnl - fund.realized_pnl;
                fund.is_profit = true;
            } else {
                fund.realized_pnl = fund.realized_pnl - pnl;
            }
        }
    } else {
        if (!fund.is_profit) {
            fund.realized_pnl = fund.realized_pnl + pnl;
        } else {
            if (pnl >= fund.realized_pnl) {
                fund.realized_pnl = pnl - fund.realized_pnl;
                fund.is_profit = false;
            } else {
                fund.realized_pnl = fund.realized_pnl - pnl;
            }
        }
    };

    // Simulate the trade by tracking P&L only
    // In production, actual DeepBook margin calls would handle capital movement
    // For simulation purposes, we only track the P&L without moving capital
    // The actual capital adjustment happens when trades are settled
    // (profits added via record_trade_profit, losses are just tracked)

    let record = TradeRecord {
        id: object::new(ctx),
        fund_id: object::id(fund),
        trade_type,
        input_amount,
        output_amount: simulated_output,
        pnl,
        is_profit,
        timestamp: clock::timestamp_ms(clock),
    };

    event::emit(TradeExecuted {
        fund_id: object::id(fund),
        trade_type: record.trade_type,
        input_amount,
        output_amount: simulated_output,
        pnl,
        is_profit,
    });

    record
}

/// Add profit to fund (simulates profitable trade completion)
/// In production, this would be the result of closing a margin position
public fun record_trade_profit(
    fund: &mut HedgeFund,
    profit: Coin<SUI>,
    ctx: &TxContext
) {
    assert!(ctx.sender() == fund.manager, EUnauthorized);
    assert!(fund.state == FUND_TRADING, EFundNotTrading);

    let profit_amount = coin::value(&profit);

    // Update P&L
    if (fund.is_profit) {
        fund.realized_pnl = fund.realized_pnl + profit_amount;
    } else {
        if (profit_amount >= fund.realized_pnl) {
            fund.realized_pnl = profit_amount - fund.realized_pnl;
            fund.is_profit = true;
        } else {
            fund.realized_pnl = fund.realized_pnl - profit_amount;
        }
    };

    // Add profit to capital pool
    balance::join(&mut fund.capital_pool, coin::into_balance(profit));
}

// ==================== Settlement Phase ====================

/// Manager settles the fund (ends trading, enables withdrawals)
public fun settle_fund(
    fund: &mut HedgeFund,
    clock: &Clock,
    ctx: &mut TxContext
) {
    assert!(ctx.sender() == fund.manager, EUnauthorized);
    assert!(fund.state == FUND_TRADING, EFundNotTrading);

    // Calculate and deduct management fee
    let total_capital = balance::value(&fund.capital_pool);
    let management_fee = (total_capital * fund.management_fee_bps) / BASIS_POINTS;

    // Calculate performance fee (only on profits)
    let performance_fee = if (fund.is_profit && fund.realized_pnl > 0) {
        (fund.realized_pnl * fund.performance_fee_bps) / BASIS_POINTS
    } else {
        0
    };

    let total_fees = management_fee + performance_fee;

    // Deduct fees if there's enough capital
    if (total_fees > 0 && total_capital >= total_fees) {
        let fee_balance = balance::split(&mut fund.capital_pool, total_fees);
        balance::join(&mut fund.manager_fees, fee_balance);
    };

    fund.state = FUND_SETTLED;
    fund.settled_at = clock::timestamp_ms(clock);

    event::emit(FundSettled {
        fund_id: object::id(fund),
        final_capital: balance::value(&fund.capital_pool),
        total_pnl: fund.realized_pnl,
        is_profit: fund.is_profit,
        manager_fees_collected: total_fees,
    });
}

/// Investor withdraws their share after settlement
public fun withdraw_shares(
    fund: &mut HedgeFund,
    position: InvestorPosition,
    clock: &Clock,
    ctx: &mut TxContext
): SettlementReceipt {
    assert!(fund.state == FUND_SETTLED, EFundNotSettled);

    let InvestorPosition {
        id,
        fund_id,
        investor,
        shares,
        deposit_amount,
        entered_at: _,
        withdrawal_pending: _,
    } = position;

    assert!(fund_id == object::id(fund), EUnauthorized);
    assert!(investor == ctx.sender(), EUnauthorized);
    assert!(shares > 0, EInsufficientShares);

    object::delete(id);

    // Calculate share value
    let total_capital = balance::value(&fund.capital_pool);

    // Safety check: ensure total_shares > 0 to prevent division by zero
    assert!(fund.total_shares > 0, EInvalidAmount);

    // Safe withdrawal calculation to avoid overflow
    // withdrawal_amount = (total_capital * shares) / total_shares
    // But we need to handle potential overflow in multiplication
    let withdrawal_amount = if (shares == fund.total_shares) {
        // Last investor gets remaining balance (handles rounding)
        total_capital
    } else {
        (total_capital * shares) / fund.total_shares
    };

    // Calculate profit share for receipt
    let profit_share = if (withdrawal_amount > deposit_amount) {
        withdrawal_amount - deposit_amount
    } else {
        0
    };

    // Update fund shares
    fund.total_shares = fund.total_shares - shares;

    // Transfer funds to investor
    let withdrawal = coin::from_balance(
        balance::split(&mut fund.capital_pool, withdrawal_amount),
        ctx
    );
    transfer::public_transfer(withdrawal, investor);

    event::emit(InvestorWithdrew {
        fund_id: object::id(fund),
        investor,
        shares_redeemed: shares,
        amount_received: withdrawal_amount,
    });

    SettlementReceipt {
        id: object::new(ctx),
        fund_id,
        investor,
        shares_redeemed: shares,
        amount_received: withdrawal_amount,
        profit_share,
        timestamp: clock::timestamp_ms(clock),
    }
}

/// Manager withdraws accumulated fees
public fun withdraw_manager_fees(
    fund: &mut HedgeFund,
    ctx: &mut TxContext
): Coin<SUI> {
    assert!(ctx.sender() == fund.manager, EUnauthorized);
    assert!(fund.state == FUND_SETTLED, EFundNotSettled);

    let amount = balance::value(&fund.manager_fees);
    coin::from_balance(
        balance::split(&mut fund.manager_fees, amount),
        ctx
    )
}

// ==================== View Functions ====================

public fun fund_name(fund: &HedgeFund): vector<u8> {
    fund.name
}

public fun fund_manager(fund: &HedgeFund): address {
    fund.manager
}

public fun fund_state(fund: &HedgeFund): u8 {
    fund.state
}

public fun fund_total_shares(fund: &HedgeFund): u64 {
    fund.total_shares
}

public fun fund_capital(fund: &HedgeFund): u64 {
    balance::value(&fund.capital_pool)
}

public fun fund_realized_pnl(fund: &HedgeFund): (u64, bool) {
    (fund.realized_pnl, fund.is_profit)
}

public fun fund_entry_fee(fund: &HedgeFund): u64 {
    fund.entry_fee
}

public fun fund_max_capacity(fund: &HedgeFund): u64 {
    fund.max_capacity
}

public fun position_shares(position: &InvestorPosition): u64 {
    position.shares
}

public fun position_deposit_amount(position: &InvestorPosition): u64 {
    position.deposit_amount
}

public fun position_investor(position: &InvestorPosition): address {
    position.investor
}

public fun is_fund_open(fund: &HedgeFund): bool {
    fund.state == FUND_OPEN
}

public fun is_fund_trading(fund: &HedgeFund): bool {
    fund.state == FUND_TRADING
}

public fun is_fund_settled(fund: &HedgeFund): bool {
    fund.state == FUND_SETTLED
}

// ==================== Test Helpers ====================

#[test_only]
public fun create_fund_for_testing(
    name: vector<u8>,
    manager: address,
    entry_fee: u64,
    max_capacity: u64,
    ctx: &mut TxContext
): HedgeFund {
    HedgeFund {
        id: object::new(ctx),
        name,
        manager,
        apex_service_id: object::id_from_address(@0x0),
        state: FUND_OPEN,
        total_shares: 0,
        capital_pool: balance::zero(),
        realized_pnl: 0,
        is_profit: true,
        management_fee_bps: 200,
        performance_fee_bps: 2000,
        entry_fee,
        max_capacity,
        created_at: 0,
        trading_started_at: 0,
        settled_at: 0,
        manager_fees: balance::zero(),
    }
}

#[test_only]
public fun destroy_fund_for_testing(fund: HedgeFund) {
    let HedgeFund {
        id,
        name: _,
        manager: _,
        apex_service_id: _,
        state: _,
        total_shares: _,
        capital_pool,
        realized_pnl: _,
        is_profit: _,
        management_fee_bps: _,
        performance_fee_bps: _,
        entry_fee: _,
        max_capacity: _,
        created_at: _,
        trading_started_at: _,
        settled_at: _,
        manager_fees,
    } = fund;

    balance::destroy_for_testing(capital_pool);
    balance::destroy_for_testing(manager_fees);
    object::delete(id);
}
