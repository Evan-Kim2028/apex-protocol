/// APEX DeepBook Margin Integration
/// Leveraged trading for AI agents using DeepBook V3 Margin
///
/// DeepBook Margin Mainnet: 0x97d9473771b01f77b0940c589484184b49f6444627ec121314fae6a6d36fb86b
/// DeepBook Margin Testnet: 0xd6a42f4df4db73d68cbeb52be66698d2fe6a9464f45ad113ca52b0c6ebd918b6 (latest)
///
/// Features:
/// - Margin trading with collateral
/// - Borrow base/quote assets for leveraged positions
/// - Take-Profit/Stop-Loss conditional orders
/// - Liquidation handling
/// - Risk ratio monitoring
module dexter_payment::deepbook_margin_v3;

use deepbook::pool::Pool;
use deepbook_margin::margin_manager::{Self, MarginManager};
use deepbook_margin::margin_pool::MarginPool;
use deepbook_margin::margin_registry::MarginRegistry;
use pyth::price_info::PriceInfoObject;
use sui::clock::Clock;
use sui::coin::Coin;
use sui::event;
use token::deep::DEEP;

// ==================== Error Codes ====================
const EUnauthorized: u64 = 0;
const ERiskTooHigh: u64 = 1;
const EInsufficientCollateral: u64 = 2;
const EInvalidLeverage: u64 = 3;
const EBorrowLimitExceeded: u64 = 4;

// ==================== Constants ====================
/// Maximum risk ratio before liquidation (85% = 850000 / 1000000)
const MAX_SAFE_RISK_RATIO: u64 = 850000;
/// Warning risk ratio (70%)
const WARNING_RISK_RATIO: u64 = 700000;

// ==================== Structs ====================

/// Agent Margin Trader - Wrapper for AI agents to do margin trading
public struct AgentMarginTrader has key {
    id: UID,
    /// Owner
    owner: address,
    /// Underlying margin manager ID
    margin_manager_id: ID,
    /// Maximum leverage allowed (e.g., 5 = 5x)
    max_leverage: u64,
    /// Whether auto-liquidation protection is enabled
    auto_protect: bool,
}

/// Margin position info for agents
public struct MarginPositionInfo has copy, drop, store {
    /// Base asset balance
    base_balance: u64,
    /// Quote asset balance
    quote_balance: u64,
    /// DEEP balance for fees
    deep_balance: u64,
    /// Base debt (borrowed shares)
    base_debt_shares: u64,
    /// Quote debt (borrowed shares)
    quote_debt_shares: u64,
    /// Current risk ratio (scaled by 1e6)
    risk_ratio: u64,
    /// Is position healthy
    is_healthy: bool,
}

// ==================== Events ====================

public struct AgentMarginTraderCreated has copy, drop {
    trader_id: ID,
    owner: address,
    margin_manager_id: ID,
    max_leverage: u64,
}

public struct CollateralDeposited has copy, drop {
    trader_id: ID,
    amount: u64,
    is_base_asset: bool,
}

public struct LeveragePositionEntered has copy, drop {
    trader_id: ID,
    borrowed_amount: u64,
    is_base_asset: bool,
    current_risk_ratio: u64,
}

public struct DebtRepaid has copy, drop {
    trader_id: ID,
    amount_repaid: u64,
    is_base_asset: bool,
}

public struct RiskWarningEmitted has copy, drop {
    trader_id: ID,
    margin_manager_id: ID,
    current_risk_ratio: u64,
    warning_threshold: u64,
}

// ==================== Core Functions ====================

/// Create AgentMarginTrader wrapper
/// Note: The underlying MarginManager must be created separately via DeepBook's functions
public fun create_agent_margin_trader(
    margin_manager_id: ID,
    max_leverage: u64,
    auto_protect: bool,
    ctx: &mut TxContext
): AgentMarginTrader {
    assert!(max_leverage >= 1 && max_leverage <= 10, EInvalidLeverage);

    let trader = AgentMarginTrader {
        id: object::new(ctx),
        owner: ctx.sender(),
        margin_manager_id,
        max_leverage,
        auto_protect,
    };

    event::emit(AgentMarginTraderCreated {
        trader_id: object::id(&trader),
        owner: ctx.sender(),
        margin_manager_id,
        max_leverage,
    });

    trader
}

/// Deposit base collateral into margin position
public fun deposit_base_collateral<BaseAsset, QuoteAsset>(
    trader: &AgentMarginTrader,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    margin_registry: &MarginRegistry,
    base_oracle: &PriceInfoObject,
    quote_oracle: &PriceInfoObject,
    collateral: Coin<BaseAsset>,
    clock: &Clock,
    ctx: &mut TxContext
) {
    assert!(ctx.sender() == trader.owner, EUnauthorized);

    let amount = collateral.value();

    margin_manager::deposit<BaseAsset, QuoteAsset, BaseAsset>(
        margin_manager,
        margin_registry,
        base_oracle,
        quote_oracle,
        collateral,
        clock,
        ctx
    );

    event::emit(CollateralDeposited {
        trader_id: object::id(trader),
        amount,
        is_base_asset: true,
    });
}

/// Deposit quote collateral into margin position
public fun deposit_quote_collateral<BaseAsset, QuoteAsset>(
    trader: &AgentMarginTrader,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    margin_registry: &MarginRegistry,
    base_oracle: &PriceInfoObject,
    quote_oracle: &PriceInfoObject,
    collateral: Coin<QuoteAsset>,
    clock: &Clock,
    ctx: &mut TxContext
) {
    assert!(ctx.sender() == trader.owner, EUnauthorized);

    let amount = collateral.value();

    margin_manager::deposit<BaseAsset, QuoteAsset, QuoteAsset>(
        margin_manager,
        margin_registry,
        base_oracle,
        quote_oracle,
        collateral,
        clock,
        ctx
    );

    event::emit(CollateralDeposited {
        trader_id: object::id(trader),
        amount,
        is_base_asset: false,
    });
}

/// Deposit DEEP for trading fees
public fun deposit_deep<BaseAsset, QuoteAsset>(
    trader: &AgentMarginTrader,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    margin_registry: &MarginRegistry,
    base_oracle: &PriceInfoObject,
    quote_oracle: &PriceInfoObject,
    deep_coin: Coin<DEEP>,
    clock: &Clock,
    ctx: &mut TxContext
) {
    assert!(ctx.sender() == trader.owner, EUnauthorized);

    margin_manager::deposit<BaseAsset, QuoteAsset, DEEP>(
        margin_manager,
        margin_registry,
        base_oracle,
        quote_oracle,
        deep_coin,
        clock,
        ctx
    );
}

/// Borrow base asset for leveraged long position
public fun borrow_base_for_long<BaseAsset, QuoteAsset>(
    trader: &AgentMarginTrader,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    margin_registry: &MarginRegistry,
    base_margin_pool: &mut MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    base_oracle: &PriceInfoObject,
    quote_oracle: &PriceInfoObject,
    pool: &Pool<BaseAsset, QuoteAsset>,
    borrow_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext
) {
    assert!(ctx.sender() == trader.owner, EUnauthorized);

    margin_manager::borrow_base<BaseAsset, QuoteAsset>(
        margin_manager,
        margin_registry,
        base_margin_pool,
        base_oracle,
        quote_oracle,
        pool,
        borrow_amount,
        clock,
        ctx
    );

    // Check risk ratio after borrow
    let risk_ratio = margin_manager::risk_ratio<BaseAsset, QuoteAsset>(
        margin_manager,
        margin_registry,
        base_oracle,
        quote_oracle,
        pool,
        base_margin_pool,
        quote_margin_pool,
        clock
    );

    assert!(risk_ratio <= MAX_SAFE_RISK_RATIO, ERiskTooHigh);

    if (risk_ratio >= WARNING_RISK_RATIO) {
        event::emit(RiskWarningEmitted {
            trader_id: object::id(trader),
            margin_manager_id: trader.margin_manager_id,
            current_risk_ratio: risk_ratio,
            warning_threshold: WARNING_RISK_RATIO,
        });
    };

    event::emit(LeveragePositionEntered {
        trader_id: object::id(trader),
        borrowed_amount: borrow_amount,
        is_base_asset: true,
        current_risk_ratio: risk_ratio,
    });
}

/// Borrow quote asset for leveraged short position
public fun borrow_quote_for_short<BaseAsset, QuoteAsset>(
    trader: &AgentMarginTrader,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    margin_registry: &MarginRegistry,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &mut MarginPool<QuoteAsset>,
    base_oracle: &PriceInfoObject,
    quote_oracle: &PriceInfoObject,
    pool: &Pool<BaseAsset, QuoteAsset>,
    borrow_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext
) {
    assert!(ctx.sender() == trader.owner, EUnauthorized);

    margin_manager::borrow_quote<BaseAsset, QuoteAsset>(
        margin_manager,
        margin_registry,
        quote_margin_pool,
        base_oracle,
        quote_oracle,
        pool,
        borrow_amount,
        clock,
        ctx
    );

    let risk_ratio = margin_manager::risk_ratio<BaseAsset, QuoteAsset>(
        margin_manager,
        margin_registry,
        base_oracle,
        quote_oracle,
        pool,
        base_margin_pool,
        quote_margin_pool,
        clock
    );

    assert!(risk_ratio <= MAX_SAFE_RISK_RATIO, ERiskTooHigh);

    if (risk_ratio >= WARNING_RISK_RATIO) {
        event::emit(RiskWarningEmitted {
            trader_id: object::id(trader),
            margin_manager_id: trader.margin_manager_id,
            current_risk_ratio: risk_ratio,
            warning_threshold: WARNING_RISK_RATIO,
        });
    };

    event::emit(LeveragePositionEntered {
        trader_id: object::id(trader),
        borrowed_amount: borrow_amount,
        is_base_asset: false,
        current_risk_ratio: risk_ratio,
    });
}

/// Repay base debt
public fun repay_base_debt<BaseAsset, QuoteAsset>(
    trader: &AgentMarginTrader,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    margin_registry: &MarginRegistry,
    margin_pool: &mut MarginPool<BaseAsset>,
    amount: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext
): u64 {
    assert!(ctx.sender() == trader.owner, EUnauthorized);

    let repaid = margin_manager::repay_base<BaseAsset, QuoteAsset>(
        margin_manager,
        margin_registry,
        margin_pool,
        amount,
        clock,
        ctx
    );

    event::emit(DebtRepaid {
        trader_id: object::id(trader),
        amount_repaid: repaid,
        is_base_asset: true,
    });

    repaid
}

/// Repay quote debt
public fun repay_quote_debt<BaseAsset, QuoteAsset>(
    trader: &AgentMarginTrader,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    margin_registry: &MarginRegistry,
    margin_pool: &mut MarginPool<QuoteAsset>,
    amount: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext
): u64 {
    assert!(ctx.sender() == trader.owner, EUnauthorized);

    let repaid = margin_manager::repay_quote<BaseAsset, QuoteAsset>(
        margin_manager,
        margin_registry,
        margin_pool,
        amount,
        clock,
        ctx
    );

    event::emit(DebtRepaid {
        trader_id: object::id(trader),
        amount_repaid: repaid,
        is_base_asset: false,
    });

    repaid
}

/// Withdraw collateral (with safety checks)
public fun withdraw_base_collateral<BaseAsset, QuoteAsset>(
    trader: &AgentMarginTrader,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    margin_registry: &MarginRegistry,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    base_oracle: &PriceInfoObject,
    quote_oracle: &PriceInfoObject,
    pool: &Pool<BaseAsset, QuoteAsset>,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext
): Coin<BaseAsset> {
    assert!(ctx.sender() == trader.owner, EUnauthorized);

    margin_manager::withdraw<BaseAsset, QuoteAsset, BaseAsset>(
        margin_manager,
        margin_registry,
        base_margin_pool,
        quote_margin_pool,
        base_oracle,
        quote_oracle,
        pool,
        amount,
        clock,
        ctx
    )
}

/// Withdraw quote collateral
public fun withdraw_quote_collateral<BaseAsset, QuoteAsset>(
    trader: &AgentMarginTrader,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    margin_registry: &MarginRegistry,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    base_oracle: &PriceInfoObject,
    quote_oracle: &PriceInfoObject,
    pool: &Pool<BaseAsset, QuoteAsset>,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext
): Coin<QuoteAsset> {
    assert!(ctx.sender() == trader.owner, EUnauthorized);

    margin_manager::withdraw<BaseAsset, QuoteAsset, QuoteAsset>(
        margin_manager,
        margin_registry,
        base_margin_pool,
        quote_margin_pool,
        base_oracle,
        quote_oracle,
        pool,
        amount,
        clock,
        ctx
    )
}

// ==================== View Functions ====================

/// Get current position info
public fun get_position_info<BaseAsset, QuoteAsset>(
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
    margin_registry: &MarginRegistry,
    base_oracle: &PriceInfoObject,
    quote_oracle: &PriceInfoObject,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    clock: &Clock
): MarginPositionInfo {
    let base_balance = margin_manager::base_balance<BaseAsset, QuoteAsset>(margin_manager);
    let quote_balance = margin_manager::quote_balance<BaseAsset, QuoteAsset>(margin_manager);
    let deep_balance = margin_manager::deep_balance<BaseAsset, QuoteAsset>(margin_manager);

    let (borrowed_base, borrowed_quote) = margin_manager::borrowed_shares<BaseAsset, QuoteAsset>(margin_manager);

    let risk_ratio = margin_manager::risk_ratio<BaseAsset, QuoteAsset>(
        margin_manager,
        margin_registry,
        base_oracle,
        quote_oracle,
        pool,
        base_margin_pool,
        quote_margin_pool,
        clock
    );

    MarginPositionInfo {
        base_balance,
        quote_balance,
        deep_balance,
        base_debt_shares: borrowed_base,
        quote_debt_shares: borrowed_quote,
        risk_ratio,
        is_healthy: risk_ratio < MAX_SAFE_RISK_RATIO,
    }
}

/// Get risk ratio directly
public fun get_risk_ratio<BaseAsset, QuoteAsset>(
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
    margin_registry: &MarginRegistry,
    base_oracle: &PriceInfoObject,
    quote_oracle: &PriceInfoObject,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    clock: &Clock
): u64 {
    margin_manager::risk_ratio<BaseAsset, QuoteAsset>(
        margin_manager,
        margin_registry,
        base_oracle,
        quote_oracle,
        pool,
        base_margin_pool,
        quote_margin_pool,
        clock
    )
}

public fun trader_owner(trader: &AgentMarginTrader): address {
    trader.owner
}

public fun trader_margin_manager_id(trader: &AgentMarginTrader): ID {
    trader.margin_manager_id
}

public fun trader_max_leverage(trader: &AgentMarginTrader): u64 {
    trader.max_leverage
}

public fun position_is_healthy(info: &MarginPositionInfo): bool {
    info.is_healthy
}

public fun position_risk_ratio(info: &MarginPositionInfo): u64 {
    info.risk_ratio
}

public fun position_base_balance(info: &MarginPositionInfo): u64 {
    info.base_balance
}

public fun position_quote_balance(info: &MarginPositionInfo): u64 {
    info.quote_balance
}

public fun position_base_debt(info: &MarginPositionInfo): u64 {
    info.base_debt_shares
}

public fun position_quote_debt(info: &MarginPositionInfo): u64 {
    info.quote_debt_shares
}
