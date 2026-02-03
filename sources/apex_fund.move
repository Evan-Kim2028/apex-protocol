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
use sui::vec_set::{Self, VecSet};

use apex_protocol::apex_payments::{
    Self,
    ProtocolConfig,
    ServiceProvider,
};

// NOTE: DeepBook imports are commented out for sandbox compatibility.
// DeepBook functions are called via runtime PTBs using mainnet-forked packages.
// This allows the sandbox to load real mainnet DeepBook bytecode dynamically
// without compile-time address conflicts.
//
// To use DeepBook at runtime in the sandbox:
// 1. Load DeepBook package from mainnet via GrpcFetcher
// 2. Execute PTBs that call deepbook::pool::swap_exact_base_for_quote
//
// use deepbook::pool::Pool;
// use token::deep::DEEP;
// use deepbook::order_info::OrderInfo;
// use deepbook_margin::margin_manager::MarginManager;
// use deepbook_margin::margin_registry::MarginRegistry;
// use deepbook_margin::pool_proxy;

// ==================== Error Codes ====================
const EFundNotOpen: u64 = 0;
const EFundNotTrading: u64 = 1;
const EFundNotSettled: u64 = 2;
const EUnauthorized: u64 = 3;
const EInsufficientDeposit: u64 = 4;
const EInsufficientShares: u64 = 5;
// EAlreadyInvested (6) and ENotInvestor (7) reserved for future investor state tracking
const EInvalidAmount: u64 = 8;
const EEntryFeeRequired: u64 = 9;
const EFundFull: u64 = 10;
// EWithdrawalPending (11) reserved for async withdrawal flow
const EExceedsTradeLimit: u64 = 12;
// EExceedsPositionLimit (13) reserved for future position tracking integration
const EExceedsDailyVolume: u64 = 14;
const EExceedsLeverage: u64 = 15;
const EDirectionNotAllowed: u64 = 16;
const EAssetNotAllowed: u64 = 17;
const EAuthorizationExpired: u64 = 18;
const EAuthorizationPaused: u64 = 19;
const EManagerAlreadyAuthorized: u64 = 20;
const EArithmeticOverflow: u64 = 21;

// ==================== Constants ====================
// Maximum value that fits in u64 - used for overflow checks
const U64_MAX: u128 = 18_446_744_073_709_551_615;
const MIN_DEPOSIT: u64 = 100_000_000; // 0.1 SUI minimum
const BASIS_POINTS: u64 = 10_000;
const MS_PER_DAY: u64 = 86_400_000;

// Direction constants (0=long, 1=short, 2=both allowed)
// Note: Only DIRECTION_BOTH is used for validation; direction values are passed from caller
const DIRECTION_BOTH: u8 = 2;

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
    /// Set of authorized manager addresses (prevents duplicate authorizations)
    authorized_managers: VecSet<address>,
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

// ==================== Manager Authorization ====================

/// Authorization for an agent to manage trades on behalf of fund owner
///
/// Enables separation of concerns:
/// - Fund Owner: Sets strategy parameters, controls lifecycle
/// - Manager Agent: Executes trades within defined constraints
///
/// All limit parameters use 0 = unlimited/unrestricted
public struct ManagerAuthorization has key, store {
    id: UID,
    /// Which fund this authorization is for
    fund_id: ID,
    /// Fund owner who created this authorization
    owner: address,
    /// Authorized manager agent address
    manager: address,

    // ===== Position Limits (basis points, 0 = unlimited) =====
    /// Max single trade as % of portfolio (e.g., 1000 = 10%)
    max_trade_bps: u64,
    /// Max position size as % of portfolio (e.g., 2500 = 25%)
    /// NOTE: Not enforced in current version - requires external position tracking.
    /// Reserved for future integration with DeepBook margin position API.
    max_position_bps: u64,
    /// Max daily volume as % of portfolio (e.g., 5000 = 50%)
    max_daily_volume_bps: u64,

    // ===== Leverage & Direction =====
    /// Max leverage multiplier (0 = unlimited, e.g., 5 = 5x max)
    max_leverage: u64,
    /// Allowed directions: 0=long only, 1=short only, 2=both
    allowed_directions: u8,

    // ===== Asset Restrictions =====
    /// Allowed asset/pool IDs (empty = all allowed)
    allowed_assets: vector<ID>,

    // ===== Tracking =====
    /// Volume traded today (in base units)
    daily_volume: u64,
    /// Day start timestamp for daily reset
    current_day_start: u64,
    /// Total trades executed under this authorization
    total_trades: u64,

    // ===== Control =====
    /// Emergency pause flag
    paused: bool,
    /// Expiration timestamp (0 = never expires)
    expires_at: u64,
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

public struct ManagerAuthorized has copy, drop {
    fund_id: ID,
    owner: address,
    manager: address,
    max_trade_bps: u64,
    max_leverage: u64,
    allowed_directions: u8,
}

public struct ManagerRevoked has copy, drop {
    fund_id: ID,
    owner: address,
    manager: address,
}

public struct AuthorizedTradeExecuted has copy, drop {
    fund_id: ID,
    manager: address,
    trade_type: vector<u8>,
    input_amount: u64,
    output_amount: u64,
    direction: u8,
    leverage: u64,
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
        authorized_managers: vec_set::empty(),
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
    // Use u128 intermediate calculation to prevent overflow with large amounts
    let shares = if (fund.total_shares == 0) {
        deposit_amount
    } else {
        // Safety: current_capital > 0 is guaranteed since fund.total_shares > 0
        // means at least one deposit has been made
        assert!(current_capital > 0, EInvalidAmount);

        // Cast to u128 to handle multiplication of large MIST values without overflow
        // e.g., 100 SUI * 100 SUI = 10^20 which exceeds u64::MAX
        let shares_u128 = ((deposit_amount as u128) * (fund.total_shares as u128)) / (current_capital as u128);

        // Verify result fits in u64 before casting
        assert!(shares_u128 <= U64_MAX, EArithmeticOverflow);
        (shares_u128 as u64)
    };

    // Ensure shares > 0 to prevent dust deposits that dilute existing investors
    assert!(shares > 0, EInvalidAmount);

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

/// Execute a margin trade (sandbox only - replace with DeepBook in production)
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

    // Update fund P&L tracking with overflow protection
    if (is_profit) {
        if (fund.is_profit) {
            // Check for overflow before addition
            let max_addable = (U64_MAX - (fund.realized_pnl as u128)) as u64;
            assert!(pnl <= max_addable, EArithmeticOverflow);
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
            // Check for overflow before addition
            let max_addable = (U64_MAX - (fund.realized_pnl as u128)) as u64;
            assert!(pnl <= max_addable, EArithmeticOverflow);
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

// ==================== DeepBook V3 Integration ====================

// NOTE: Margin trading functions are commented out due to upstream Pyth test issues.
// When deepbook_margin package tests are fixed, uncomment the imports and these functions:
//
// /// Place a limit order on DeepBook using a MarginManager
// public fun place_deepbook_limit_order<BaseAsset, QuoteAsset>(
//     fund: &mut HedgeFund,
//     registry: &MarginRegistry,
//     margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
//     pool: &mut Pool<BaseAsset, QuoteAsset>,
//     client_order_id: u64,
//     order_type: u8,
//     self_matching_option: u8,
//     price: u64,
//     quantity: u64,
//     is_bid: bool,
//     pay_with_deep: bool,
//     expire_timestamp: u64,
//     clock: &Clock,
//     ctx: &TxContext
// ): OrderInfo { ... }
//
// /// Place a market order on DeepBook using a MarginManager
// public fun place_deepbook_market_order<BaseAsset, QuoteAsset>(
//     fund: &mut HedgeFund,
//     registry: &MarginRegistry,
//     margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
//     pool: &mut Pool<BaseAsset, QuoteAsset>,
//     client_order_id: u64,
//     self_matching_option: u8,
//     quantity: u64,
//     is_bid: bool,
//     pay_with_deep: bool,
//     clock: &Clock,
//     ctx: &TxContext
// ): OrderInfo { ... }

// NOTE: DeepBook swap functions are commented out for sandbox compatibility.
// At runtime, call DeepBook directly via PTBs with mainnet-forked packages:
//
// PTB pattern for DeepBook swap:
// 1. Load DeepBook package from mainnet via GrpcFetcher
// 2. Execute: deepbook::pool::swap_exact_base_for_quote<BaseAsset, QuoteAsset>(
//       pool, base_in, deep_in, min_quote_out, clock, ctx)
//
// /// Swap exact base for quote directly on DeepBook pool (no margin)
// public fun swap_base_for_quote<BaseAsset, QuoteAsset>(
//     fund: &mut HedgeFund,
//     pool: &mut Pool<BaseAsset, QuoteAsset>,
//     base_in: Coin<BaseAsset>,
//     deep_in: Coin<DEEP>,
//     min_quote_out: u64,
//     clock: &Clock,
//     ctx: &mut TxContext
// ): (Coin<BaseAsset>, Coin<QuoteAsset>, Coin<DEEP>) { ... }
//
// /// Swap exact quote for base directly on DeepBook pool (no margin)
// public fun swap_quote_for_base<BaseAsset, QuoteAsset>(
//     fund: &mut HedgeFund,
//     pool: &mut Pool<BaseAsset, QuoteAsset>,
//     quote_in: Coin<QuoteAsset>,
//     deep_in: Coin<DEEP>,
//     min_base_out: u64,
//     clock: &Clock,
//     ctx: &mut TxContext
// ): (Coin<BaseAsset>, Coin<QuoteAsset>, Coin<DEEP>) { ... }

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

    // Update P&L with overflow protection
    if (fund.is_profit) {
        // Check for overflow before addition: a + b overflows if b > MAX - a
        let max_addable = (U64_MAX - (fund.realized_pnl as u128)) as u64;
        assert!(profit_amount <= max_addable, EArithmeticOverflow);
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

// ==================== Manager Authorization ====================

/// Authorize a manager to trade with constraints (0 = unlimited for any limit)
public fun authorize_manager(
    fund: &mut HedgeFund,
    manager: address,
    max_trade_bps: u64,
    max_position_bps: u64,
    max_daily_volume_bps: u64,
    max_leverage: u64,
    allowed_directions: u8,
    allowed_assets: vector<ID>,
    expires_at: u64,
    clock: &Clock,
    ctx: &mut TxContext
): ManagerAuthorization {
    assert!(ctx.sender() == fund.manager, EUnauthorized);
    assert!(!vec_set::contains(&fund.authorized_managers, &manager), EManagerAlreadyAuthorized);
    vec_set::insert(&mut fund.authorized_managers, manager);

    // Validate direction parameter
    assert!(allowed_directions <= DIRECTION_BOTH, EInvalidAmount);

    let auth = ManagerAuthorization {
        id: object::new(ctx),
        fund_id: object::id(fund),
        owner: ctx.sender(),
        manager,
        max_trade_bps,
        max_position_bps,
        max_daily_volume_bps,
        max_leverage,
        allowed_directions,
        allowed_assets,
        daily_volume: 0,
        current_day_start: get_day_start(clock::timestamp_ms(clock)),
        total_trades: 0,
        paused: false,
        expires_at,
    };

    event::emit(ManagerAuthorized {
        fund_id: object::id(fund),
        owner: ctx.sender(),
        manager,
        max_trade_bps,
        max_leverage,
        allowed_directions,
    });

    auth
}

/// Execute trade with constraint enforcement (sandbox - replace with DeepBook in production)
public fun execute_authorized_trade(
    auth: &mut ManagerAuthorization,
    fund: &mut HedgeFund,
    trade_type: vector<u8>,
    input_amount: u64,
    simulated_output: u64,
    direction: u8,       // 0 = long, 1 = short
    leverage: u64,       // 1 = no leverage, 2 = 2x, etc.
    asset_id: ID,        // Which asset/pool being traded
    clock: &Clock,
    ctx: &mut TxContext
): TradeRecord {
    // === Basic Authorization Checks ===
    assert!(ctx.sender() == auth.manager, EUnauthorized);
    assert!(auth.fund_id == object::id(fund), EUnauthorized);
    assert!(!auth.paused, EAuthorizationPaused);

    // Check expiration
    if (auth.expires_at > 0) {
        assert!(clock::timestamp_ms(clock) < auth.expires_at, EAuthorizationExpired);
    };

    // Fund must be in trading state
    assert!(fund.state == FUND_TRADING, EFundNotTrading);

    // === Reset Daily Volume if New Day ===
    let now = clock::timestamp_ms(clock);
    let day_start = get_day_start(now);
    if (day_start != auth.current_day_start) {
        auth.daily_volume = 0;
        auth.current_day_start = day_start;
    };

    // === Enforce Constraints ===
    let pool_size = balance::value(&fund.capital_pool);

    // Max trade size (as % of portfolio)
    if (auth.max_trade_bps > 0) {
        let max_trade = (pool_size * auth.max_trade_bps) / BASIS_POINTS;
        assert!(input_amount <= max_trade, EExceedsTradeLimit);
    };

    // Max daily volume (as % of portfolio)
    if (auth.max_daily_volume_bps > 0) {
        let max_daily = (pool_size * auth.max_daily_volume_bps) / BASIS_POINTS;
        assert!(auth.daily_volume + input_amount <= max_daily, EExceedsDailyVolume);
    };

    // Max leverage
    if (auth.max_leverage > 0) {
        assert!(leverage <= auth.max_leverage, EExceedsLeverage);
    };

    // Direction constraint
    if (auth.allowed_directions != DIRECTION_BOTH) {
        assert!(direction == auth.allowed_directions, EDirectionNotAllowed);
    };

    // Asset whitelist (empty = all allowed)
    if (!vector::is_empty(&auth.allowed_assets)) {
        assert!(vector::contains(&auth.allowed_assets, &asset_id), EAssetNotAllowed);
    };

    // === Update Tracking (with overflow protection) ===
    let max_addable_volume = (U64_MAX - (auth.daily_volume as u128)) as u64;
    assert!(input_amount <= max_addable_volume, EArithmeticOverflow);
    auth.daily_volume = auth.daily_volume + input_amount;

    let max_addable_trades = (U64_MAX - (auth.total_trades as u128)) as u64;
    assert!(1 <= max_addable_trades, EArithmeticOverflow);
    auth.total_trades = auth.total_trades + 1;

    // === Execute Trade (same logic as execute_margin_trade) ===
    assert!(pool_size >= input_amount, EInsufficientDeposit);

    // Calculate P&L
    let (pnl, is_profit) = if (simulated_output >= input_amount) {
        (simulated_output - input_amount, true)
    } else {
        (input_amount - simulated_output, false)
    };

    // Update fund P&L tracking with overflow protection
    if (is_profit) {
        if (fund.is_profit) {
            // Check for overflow before addition
            let max_addable = (U64_MAX - (fund.realized_pnl as u128)) as u64;
            assert!(pnl <= max_addable, EArithmeticOverflow);
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
            // Check for overflow before addition
            let max_addable = (U64_MAX - (fund.realized_pnl as u128)) as u64;
            assert!(pnl <= max_addable, EArithmeticOverflow);
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

    let record = TradeRecord {
        id: object::new(ctx),
        fund_id: object::id(fund),
        trade_type,
        input_amount,
        output_amount: simulated_output,
        pnl,
        is_profit,
        timestamp: now,
    };

    event::emit(AuthorizedTradeExecuted {
        fund_id: object::id(fund),
        manager: auth.manager,
        trade_type: record.trade_type,
        input_amount,
        output_amount: simulated_output,
        direction,
        leverage,
    });

    record
}

// NOTE: execute_authorized_deepbook_trade is commented out due to upstream Pyth test issues.
// When deepbook_margin package tests are fixed, uncomment the imports and this function.
// The function provides authorized DeepBook margin trading with constraint enforcement.

/// Owner pauses manager authorization (emergency stop)
public fun pause_manager(
    auth: &mut ManagerAuthorization,
    ctx: &TxContext
) {
    assert!(ctx.sender() == auth.owner, EUnauthorized);
    auth.paused = true;
}

/// Owner unpauses manager authorization
public fun unpause_manager(
    auth: &mut ManagerAuthorization,
    ctx: &TxContext
) {
    assert!(ctx.sender() == auth.owner, EUnauthorized);
    auth.paused = false;
}

/// Owner updates manager constraints
public fun update_manager_limits(
    auth: &mut ManagerAuthorization,
    max_trade_bps: u64,
    max_position_bps: u64,
    max_daily_volume_bps: u64,
    max_leverage: u64,
    allowed_directions: u8,
    ctx: &TxContext
) {
    assert!(ctx.sender() == auth.owner, EUnauthorized);
    assert!(allowed_directions <= DIRECTION_BOTH, EInvalidAmount);

    auth.max_trade_bps = max_trade_bps;
    auth.max_position_bps = max_position_bps;
    auth.max_daily_volume_bps = max_daily_volume_bps;
    auth.max_leverage = max_leverage;
    auth.allowed_directions = allowed_directions;
}

/// Owner adds an asset to the allowed list
public fun add_allowed_asset(
    auth: &mut ManagerAuthorization,
    asset_id: ID,
    ctx: &TxContext
) {
    assert!(ctx.sender() == auth.owner, EUnauthorized);
    if (!vector::contains(&auth.allowed_assets, &asset_id)) {
        vector::push_back(&mut auth.allowed_assets, asset_id);
    };
}

/// Owner removes an asset from the allowed list
public fun remove_allowed_asset(
    auth: &mut ManagerAuthorization,
    asset_id: ID,
    ctx: &TxContext
) {
    assert!(ctx.sender() == auth.owner, EUnauthorized);
    let (found, idx) = vector::index_of(&auth.allowed_assets, &asset_id);
    if (found) {
        vector::remove(&mut auth.allowed_assets, idx);
    };
}

/// Owner revokes manager authorization
public fun revoke_manager(
    fund: &mut HedgeFund,
    auth: ManagerAuthorization,
    ctx: &TxContext
) {
    assert!(ctx.sender() == auth.owner, EUnauthorized);
    assert!(auth.fund_id == object::id(fund), EUnauthorized);

    // Remove from authorized set so they can be re-authorized later
    vec_set::remove(&mut fund.authorized_managers, &auth.manager);

    event::emit(ManagerRevoked {
        fund_id: auth.fund_id,
        owner: auth.owner,
        manager: auth.manager,
    });

    let ManagerAuthorization {
        id,
        fund_id: _,
        owner: _,
        manager: _,
        max_trade_bps: _,
        max_position_bps: _,
        max_daily_volume_bps: _,
        max_leverage: _,
        allowed_directions: _,
        allowed_assets: _,
        daily_volume: _,
        current_day_start: _,
        total_trades: _,
        paused: _,
        expires_at: _,
    } = auth;
    object::delete(id);
}

// ==================== Manager Authorization View Functions ====================

public fun auth_manager(auth: &ManagerAuthorization): address {
    auth.manager
}

public fun auth_owner(auth: &ManagerAuthorization): address {
    auth.owner
}

public fun auth_fund_id(auth: &ManagerAuthorization): ID {
    auth.fund_id
}

public fun auth_max_trade_bps(auth: &ManagerAuthorization): u64 {
    auth.max_trade_bps
}

public fun auth_max_leverage(auth: &ManagerAuthorization): u64 {
    auth.max_leverage
}

public fun auth_daily_volume(auth: &ManagerAuthorization): u64 {
    auth.daily_volume
}

public fun auth_total_trades(auth: &ManagerAuthorization): u64 {
    auth.total_trades
}

public fun auth_is_paused(auth: &ManagerAuthorization): bool {
    auth.paused
}

public fun auth_allowed_directions(auth: &ManagerAuthorization): u8 {
    auth.allowed_directions
}

/// Helper: Get start of day (ms) from timestamp
fun get_day_start(timestamp_ms: u64): u64 {
    (timestamp_ms / MS_PER_DAY) * MS_PER_DAY
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
    // Use u128 intermediate calculation to prevent overflow with large capital amounts
    let total_capital = balance::value(&fund.capital_pool);

    // Management fee: (total_capital * fee_bps) / 10000
    // Safe because fee_bps is typically small (e.g., 200 = 2%)
    // and result is always <= total_capital (since fee_bps <= 10000)
    let mgmt_fee_u128 = ((total_capital as u128) * (fund.management_fee_bps as u128)) / (BASIS_POINTS as u128);
    assert!(mgmt_fee_u128 <= U64_MAX, EArithmeticOverflow);
    let management_fee = (mgmt_fee_u128 as u64);

    // Calculate performance fee (only on profits)
    // Use u128 intermediate calculation to prevent overflow
    let performance_fee = if (fund.is_profit && fund.realized_pnl > 0) {
        let perf_fee_u128 = ((fund.realized_pnl as u128) * (fund.performance_fee_bps as u128)) / (BASIS_POINTS as u128);
        assert!(perf_fee_u128 <= U64_MAX, EArithmeticOverflow);
        (perf_fee_u128 as u64)
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
    // Use u128 intermediate calculation to handle large MIST values
    let withdrawal_amount = if (shares == fund.total_shares) {
        // Last investor gets remaining balance (handles rounding)
        total_capital
    } else {
        // Cast to u128 to prevent overflow with large amounts
        let amount_u128 = ((total_capital as u128) * (shares as u128)) / (fund.total_shares as u128);

        // Verify result fits in u64 before casting
        assert!(amount_u128 <= U64_MAX, EArithmeticOverflow);
        (amount_u128 as u64)
    };

    // Ensure withdrawal amount doesn't exceed available capital (sanity check)
    assert!(withdrawal_amount <= total_capital, EArithmeticOverflow);

    // Calculate profit share for receipt
    let profit_share = if (withdrawal_amount > deposit_amount) {
        withdrawal_amount - deposit_amount
    } else {
        0
    };

    // Update fund shares (underflow protected by prior assertion that shares <= total_shares implicitly)
    assert!(fund.total_shares >= shares, EArithmeticOverflow);
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
        authorized_managers: vec_set::empty(),
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
        authorized_managers: _,
    } = fund;

    balance::destroy_for_testing(capital_pool);
    balance::destroy_for_testing(manager_fees);
    object::delete(id);
}
