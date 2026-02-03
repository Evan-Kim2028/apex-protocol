/// APEX Payments - Sui-Native x402-Style Payment Infrastructure
///
/// This is the core payment module providing x402-equivalent functionality:
/// - Pay-per-call API billing (HTTP 402 Payment Required equivalent)
/// - Service provider registration with pricing
/// - Access capabilities (pay → get capability object)
/// - Streaming payments (per-second micropayments)
/// - Agent wallets with spending limits
/// - Shield transfers (hash-locked private transfers)
///
/// Key difference from x402: Uses Sui's PTBs for atomic pay-and-use patterns
/// that are impossible on other chains.
module apex_protocol::apex_payments;

use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::balance::{Self, Balance};
use sui::event;
use sui::hash;
use sui::bcs;
use sui::sui::SUI;

// ==================== Error Codes ====================
const EInsufficientBalance: u64 = 0;
const EInvalidCapability: u64 = 1;
const EExpired: u64 = 2;
const EExceededLimit: u64 = 3;
const ERateLimited: u64 = 4;
const EInvalidStream: u64 = 5;
const EUnauthorized: u64 = 6;
const EServiceInactive: u64 = 7;
const EOverflow: u64 = 8;
const EInvalidInput: u64 = 9;
const EProtocolPaused: u64 = 10;
const EInvalidSecret: u64 = 11;
/// Secret is required but recipient tried to claim without it
const ESecretRequired: u64 = 12;
/// Wallet funding is restricted to owner only
const EFundingRestricted: u64 = 13;

// ==================== Constants ====================
const MAX_NAME_LENGTH: u64 = 256;
const MAX_DESCRIPTION_LENGTH: u64 = 1024;
const REGISTRATION_FEE: u64 = 100_000_000; // 0.1 SUI
const MS_PER_DAY: u64 = 86_400_000;
const MIN_SECRET_HASH_LENGTH: u64 = 32;

// ==================== Admin & Config ====================

/// One-time witness for module initialization
public struct APEX_PAYMENTS has drop {}

/// Admin capability for protocol management
public struct AdminCap has key, store {
    id: UID,
}

/// Protocol configuration (shared object)
public struct ProtocolConfig has key {
    id: UID,
    /// Protocol paused flag
    paused: bool,
    /// Registration fee for new services
    registration_fee: u64,
    /// Protocol fee in basis points (100 = 1%)
    fee_bps: u64,
    /// Treasury for protocol fees
    treasury: Balance<SUI>,
    /// Protocol version
    version: u64,
}

// ==================== Service Provider ====================

/// ServiceProvider - API endpoint that agents can pay to access
/// This is the x402 equivalent of a paywalled endpoint
public struct ServiceProvider has key {
    id: UID,
    /// Provider's receiving address
    provider: address,
    /// Human-readable name
    name: vector<u8>,
    /// Service description
    description: vector<u8>,
    /// Price per unit (in MIST, 1 SUI = 10^9 MIST)
    price_per_unit: u64,
    /// Total units served
    total_served: u64,
    /// Revenue accumulated
    revenue: Balance<SUI>,
    /// Whether provider is active
    active: bool,
}

// ==================== Access Capability ====================

/// AccessCapability - Proof of payment that grants access to a service
/// This is what you get when you pay for API access (x402 receipt equivalent)
///
/// Key feature: This is a Sui object that can be passed to other functions
/// in the SAME PTB, enabling atomic pay-and-use patterns.
public struct AccessCapability has key, store {
    id: UID,
    /// Which service this grants access to
    service_id: ID,
    /// Number of API calls / units remaining
    remaining_units: u64,
    /// Expiry timestamp (0 = no expiry)
    expires_at: u64,
    /// Rate limit: max units per epoch (0 = no limit)
    rate_limit: u64,
    /// Units used this epoch
    epoch_usage: u64,
    /// Last epoch number
    last_epoch: u64,
}

// ==================== Streaming Payments ====================

/// PaymentStream - Open channel for continuous micropayments
/// Useful for pay-per-second API usage (LLM inference, compute, etc.)
public struct PaymentStream has key {
    id: UID,
    /// Consumer (AI agent or user)
    consumer: address,
    /// Provider's service ID
    service_id: ID,
    /// Provider's address (for authorization)
    provider_address: address,
    /// Escrowed funds
    escrow: Balance<SUI>,
    /// Price per unit
    unit_price: u64,
    /// Total units consumed
    total_consumed: u64,
    /// Max units allowed
    max_units: u64,
    /// Stream start time
    started_at: u64,
    /// Last activity timestamp
    last_activity: u64,
}

/// StreamTicket - Receipt for stream consumption
public struct StreamTicket has key, store {
    id: UID,
    stream_id: ID,
    units_consumed: u64,
    timestamp: u64,
}

// ==================== Agent Wallet ====================

/// AgentWallet - Managed wallet for AI agents with spending controls
public struct AgentWallet has key {
    id: UID,
    /// Human owner who controls the agent
    owner: address,
    /// Agent identifier
    agent_id: vector<u8>,
    /// Balance for payments
    balance: Balance<SUI>,
    /// Spending limit per transaction
    spend_limit: u64,
    /// Daily spending limit
    daily_limit: u64,
    /// Spent today
    daily_spent: u64,
    /// Day timestamp (ms at start of day)
    current_day_start: u64,
    /// Transaction nonce
    nonce: u64,
    /// Emergency pause flag
    paused: bool,
    /// If true, only owner can fund this wallet (prevents dust attacks)
    /// If false, anyone can deposit (default for convenience)
    restrict_funding: bool,
}

// ==================== Shield Transfer ====================

/// ShieldSession - Hash-locked private transfer
/// Funds are locked until recipient provides the secret (or expires)
public struct ShieldSession has key {
    id: UID,
    /// Sender address
    sender: address,
    /// Final recipient
    recipient: address,
    /// Amount locked
    amount: u64,
    /// Expiry timestamp
    expires_at: u64,
    /// Escrowed funds
    funds: Balance<SUI>,
    /// Hash of secret required to claim (keccak256)
    secret_hash: vector<u8>,
    /// If true, recipient MUST provide secret to claim (atomic swap mode)
    /// If false, recipient can claim directly (escrow mode)
    require_secret: bool,
}

// ==================== Events ====================

public struct ProtocolInitialized has copy, drop {
    config_id: ID,
    admin: address,
}

public struct ServiceRegistered has copy, drop {
    service_id: ID,
    provider: address,
    name: vector<u8>,
    price_per_unit: u64,
}

public struct ServiceUpdated has copy, drop {
    service_id: ID,
    active: bool,
    price_per_unit: u64,
}

public struct AccessPurchased has copy, drop {
    capability_id: ID,
    service_id: ID,
    buyer: address,
    units: u64,
    cost: u64,
}

public struct AccessUsed has copy, drop {
    capability_id: ID,
    service_id: ID,
    units_used: u64,
    remaining: u64,
}

public struct StreamOpened has copy, drop {
    stream_id: ID,
    consumer: address,
    service_id: ID,
    escrow_amount: u64,
}

public struct StreamConsumed has copy, drop {
    stream_id: ID,
    units: u64,
    cost: u64,
}

public struct StreamClosed has copy, drop {
    stream_id: ID,
    total_consumed: u64,
    refunded: u64,
}

public struct AgentWalletCreated has copy, drop {
    wallet_id: ID,
    owner: address,
    daily_limit: u64,
}

public struct ShieldTransferInitiated has copy, drop {
    session_id: ID,
    sender: address,
    amount: u64,
    expires_at: u64,
}

public struct ShieldTransferCompleted has copy, drop {
    session_id: ID,
    recipient: address,
    amount: u64,
}

public struct ShieldTransferCancelled has copy, drop {
    session_id: ID,
    sender: address,
    amount: u64,
}

public struct AgentWalletFunded has copy, drop {
    wallet_id: ID,
    amount: u64,
}

public struct AgentWalletPaused has copy, drop {
    wallet_id: ID,
    paused: bool,
}

public struct AgentLimitsUpdated has copy, drop {
    wallet_id: ID,
    spend_limit: u64,
    daily_limit: u64,
}

public struct AuthorizationPaused has copy, drop {
    auth_id: ID,
    paused: bool,
}

public struct AuthorizationLimitsUpdated has copy, drop {
    auth_id: ID,
    spend_limit_per_tx: u64,
    daily_limit: u64,
}

// ==================== Init ====================

fun init(_witness: APEX_PAYMENTS, ctx: &mut TxContext) {
    let admin_cap = AdminCap {
        id: object::new(ctx),
    };

    let config = ProtocolConfig {
        id: object::new(ctx),
        paused: false,
        registration_fee: REGISTRATION_FEE,
        fee_bps: 50, // 0.5% protocol fee
        treasury: balance::zero(),
        version: 1,
    };

    event::emit(ProtocolInitialized {
        config_id: object::id(&config),
        admin: ctx.sender(),
    });

    transfer::share_object(config);
    transfer::transfer(admin_cap, ctx.sender());
}

// ==================== Admin Functions ====================

/// Pause/unpause protocol (admin only)
public fun set_protocol_paused(
    _admin: &AdminCap,
    config: &mut ProtocolConfig,
    paused: bool,
) {
    config.paused = paused;
}

/// Update protocol fee (admin only)
public fun set_protocol_fee(
    _admin: &AdminCap,
    config: &mut ProtocolConfig,
    new_fee_bps: u64,
) {
    assert!(new_fee_bps <= 1000, EInvalidInput); // Max 10%
    config.fee_bps = new_fee_bps;
}

/// Withdraw treasury (admin only)
public fun withdraw_treasury(
    _admin: &AdminCap,
    config: &mut ProtocolConfig,
    amount: u64,
    recipient: address,
    ctx: &mut TxContext
) {
    assert!(balance::value(&config.treasury) >= amount, EInsufficientBalance);
    let withdrawn = coin::from_balance(
        balance::split(&mut config.treasury, amount),
        ctx
    );
    transfer::public_transfer(withdrawn, recipient);
}

// ==================== Service Provider Functions ====================

/// Register a new service (x402-style API endpoint)
#[allow(lint(self_transfer))]
public fun register_service(
    config: &mut ProtocolConfig,
    name: vector<u8>,
    description: vector<u8>,
    price_per_unit: u64,
    registration_payment: Coin<SUI>,
    ctx: &mut TxContext
) {
    assert!(!config.paused, EProtocolPaused);
    assert!(vector::length(&name) > 0 && vector::length(&name) <= MAX_NAME_LENGTH, EInvalidInput);
    assert!(vector::length(&description) <= MAX_DESCRIPTION_LENGTH, EInvalidInput);
    assert!(price_per_unit > 0, EInvalidInput);

    // Collect registration fee
    let payment_amount = coin::value(&registration_payment);
    assert!(payment_amount >= config.registration_fee, EInsufficientBalance);

    let mut payment_balance = coin::into_balance(registration_payment);
    if (payment_amount > config.registration_fee) {
        let refund = coin::from_balance(
            balance::split(&mut payment_balance, payment_amount - config.registration_fee),
            ctx
        );
        transfer::public_transfer(refund, ctx.sender());
    };
    balance::join(&mut config.treasury, payment_balance);

    let service = ServiceProvider {
        id: object::new(ctx),
        provider: ctx.sender(),
        name,
        description,
        price_per_unit,
        total_served: 0,
        revenue: balance::zero(),
        active: true,
    };

    event::emit(ServiceRegistered {
        service_id: object::id(&service),
        provider: ctx.sender(),
        name: service.name,
        price_per_unit,
    });

    transfer::share_object(service);
}

/// Deactivate service (provider only)
public fun deactivate_service(
    service: &mut ServiceProvider,
    ctx: &TxContext
) {
    assert!(ctx.sender() == service.provider, EUnauthorized);
    service.active = false;

    event::emit(ServiceUpdated {
        service_id: object::id(service),
        active: false,
        price_per_unit: service.price_per_unit,
    });
}

/// Reactivate service (provider only)
public fun reactivate_service(
    service: &mut ServiceProvider,
    ctx: &TxContext
) {
    assert!(ctx.sender() == service.provider, EUnauthorized);
    service.active = true;

    event::emit(ServiceUpdated {
        service_id: object::id(service),
        active: true,
        price_per_unit: service.price_per_unit,
    });
}

/// Update service price (provider only)
public fun update_service_price(
    service: &mut ServiceProvider,
    new_price: u64,
    ctx: &TxContext
) {
    assert!(ctx.sender() == service.provider, EUnauthorized);
    assert!(new_price > 0, EInvalidInput);
    service.price_per_unit = new_price;

    event::emit(ServiceUpdated {
        service_id: object::id(service),
        active: service.active,
        price_per_unit: new_price,
    });
}

/// Withdraw service revenue (provider only)
public fun withdraw_revenue(
    service: &mut ServiceProvider,
    ctx: &mut TxContext
) {
    assert!(ctx.sender() == service.provider, EUnauthorized);

    let amount = balance::value(&service.revenue);
    if (amount > 0) {
        let revenue = coin::from_balance(
            balance::split(&mut service.revenue, amount),
            ctx
        );
        transfer::public_transfer(revenue, service.provider);
    };
}

// ==================== Access Capability Functions ====================

/// Purchase access capability - THE CORE x402 PAYMENT FUNCTION
///
/// This is the equivalent of paying for an API and receiving a receipt.
/// On Sui, the receipt is an AccessCapability object that can be used
/// in the SAME PTB to access the service - enabling atomic pay-and-use.
#[allow(lint(self_transfer))]
public fun purchase_access(
    config: &mut ProtocolConfig,
    service: &mut ServiceProvider,
    payment: Coin<SUI>,
    units: u64,
    duration_ms: u64,
    rate_limit: u64,
    clock: &Clock,
    ctx: &mut TxContext
): AccessCapability {
    assert!(!config.paused, EProtocolPaused);
    assert!(service.active, EServiceInactive);
    assert!(units > 0, EInvalidInput);

    // Calculate cost with overflow protection
    let cost = safe_mul(service.price_per_unit, units);

    let payment_amount = coin::value(&payment);
    assert!(payment_amount >= cost, EInsufficientBalance);

    // Split payment: protocol fee + provider revenue
    let mut payment_balance = coin::into_balance(payment);

    let fee_amount = (cost * config.fee_bps) / 10000;
    if (fee_amount > 0) {
        let fee_balance = balance::split(&mut payment_balance, fee_amount);
        balance::join(&mut config.treasury, fee_balance);
    };

    // Refund excess
    if (payment_amount > cost) {
        let refund = coin::from_balance(
            balance::split(&mut payment_balance, payment_amount - cost),
            ctx
        );
        transfer::public_transfer(refund, ctx.sender());
    };

    balance::join(&mut service.revenue, payment_balance);
    service.total_served = service.total_served + units;

    let expires_at = if (duration_ms > 0) {
        clock::timestamp_ms(clock) + duration_ms
    } else {
        0
    };

    let capability = AccessCapability {
        id: object::new(ctx),
        service_id: object::id(service),
        remaining_units: units,
        expires_at,
        rate_limit,
        epoch_usage: 0,
        last_epoch: ctx.epoch(),
    };

    event::emit(AccessPurchased {
        capability_id: object::id(&capability),
        service_id: object::id(service),
        buyer: ctx.sender(),
        units,
        cost,
    });

    capability
}

/// Use access capability - consume units from a capability
/// Returns true if access granted, aborts otherwise
public fun use_access(
    cap: &mut AccessCapability,
    service: &ServiceProvider,
    units: u64,
    clock: &Clock,
    ctx: &TxContext
): bool {
    assert!(cap.service_id == object::id(service), EInvalidCapability);
    assert!(service.active, EServiceInactive);

    // Check expiry
    if (cap.expires_at > 0) {
        assert!(clock::timestamp_ms(clock) <= cap.expires_at, EExpired);
    };

    assert!(cap.remaining_units >= units, EInsufficientBalance);

    // Check rate limit
    let current_epoch = ctx.epoch();
    if (current_epoch != cap.last_epoch) {
        cap.epoch_usage = 0;
        cap.last_epoch = current_epoch;
    };

    if (cap.rate_limit > 0) {
        assert!(cap.epoch_usage + units <= cap.rate_limit, ERateLimited);
    };

    cap.remaining_units = cap.remaining_units - units;
    cap.epoch_usage = cap.epoch_usage + units;

    event::emit(AccessUsed {
        capability_id: object::id(cap),
        service_id: cap.service_id,
        units_used: units,
        remaining: cap.remaining_units,
    });

    true
}

/// Verify a capability is valid for a service (read-only check)
public fun verify_access(
    cap: &AccessCapability,
    service: &ServiceProvider,
    units: u64,
    clock: &Clock,
): bool {
    if (cap.service_id != object::id(service)) return false;
    if (!service.active) return false;
    if (cap.expires_at > 0 && clock::timestamp_ms(clock) > cap.expires_at) return false;
    if (cap.remaining_units < units) return false;
    true
}

/// Burn unused capability
public fun burn_capability(cap: AccessCapability) {
    let AccessCapability {
        id,
        service_id: _,
        remaining_units: _,
        expires_at: _,
        rate_limit: _,
        epoch_usage: _,
        last_epoch: _,
    } = cap;
    object::delete(id);
}

// ==================== Streaming Payment Functions ====================

/// Open a payment stream for continuous micropayments
public fun open_stream(
    config: &ProtocolConfig,
    service: &ServiceProvider,
    escrow: Coin<SUI>,
    max_units: u64,
    clock: &Clock,
    ctx: &mut TxContext
): ID {
    assert!(!config.paused, EProtocolPaused);
    assert!(service.active, EServiceInactive);
    assert!(max_units > 0, EInvalidInput);

    let stream = PaymentStream {
        id: object::new(ctx),
        consumer: ctx.sender(),
        service_id: object::id(service),
        provider_address: service.provider,
        escrow: coin::into_balance(escrow),
        unit_price: service.price_per_unit,
        total_consumed: 0,
        max_units,
        started_at: clock::timestamp_ms(clock),
        last_activity: clock::timestamp_ms(clock),
    };

    let stream_id = object::id(&stream);

    event::emit(StreamOpened {
        stream_id,
        consumer: ctx.sender(),
        service_id: object::id(service),
        escrow_amount: balance::value(&stream.escrow),
    });

    transfer::share_object(stream);
    stream_id
}

/// Provider records consumption from stream (provider-reported).
/// For TEE-verified consumption, use `record_verified_consumption` instead.
public fun record_stream_consumption(
    stream: &mut PaymentStream,
    service: &mut ServiceProvider,
    units: u64,
    clock: &Clock,
    ctx: &mut TxContext
) {
    assert!(ctx.sender() == service.provider, EUnauthorized);
    assert!(stream.service_id == object::id(service), EInvalidStream);

    let cost = safe_mul(units, stream.unit_price);
    assert!(balance::value(&stream.escrow) >= cost, EInsufficientBalance);
    assert!(stream.total_consumed + units <= stream.max_units, EExceededLimit);

    let payment = balance::split(&mut stream.escrow, cost);
    balance::join(&mut service.revenue, payment);

    stream.total_consumed = stream.total_consumed + units;
    stream.last_activity = clock::timestamp_ms(clock);

    let ticket = StreamTicket {
        id: object::new(ctx),
        stream_id: object::id(stream),
        units_consumed: units,
        timestamp: clock::timestamp_ms(clock),
    };

    event::emit(StreamConsumed {
        stream_id: object::id(stream),
        units,
        cost,
    });

    transfer::transfer(ticket, stream.consumer);
}

/// Close stream (consumer or provider can close)
public fun close_stream(
    stream: PaymentStream,
    ctx: &mut TxContext
) {
    let sender = ctx.sender();
    assert!(
        sender == stream.consumer || sender == stream.provider_address,
        EUnauthorized
    );

    let PaymentStream {
        id,
        consumer,
        service_id: _,
        provider_address: _,
        escrow,
        unit_price: _,
        total_consumed,
        max_units: _,
        started_at: _,
        last_activity: _,
    } = stream;

    let refund_amount = balance::value(&escrow);

    if (refund_amount > 0) {
        let refund = coin::from_balance(escrow, ctx);
        transfer::public_transfer(refund, consumer);
    } else {
        balance::destroy_zero(escrow);
    };

    event::emit(StreamClosed {
        stream_id: object::uid_to_inner(&id),
        total_consumed,
        refunded: refund_amount,
    });

    object::delete(id);
}

// ==================== Agent Wallet Functions ====================

/// Create an agent wallet with spending controls
public fun create_agent_wallet(
    config: &ProtocolConfig,
    agent_id: vector<u8>,
    spend_limit: u64,
    daily_limit: u64,
    restrict_funding: bool,
    initial_funding: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext
) {
    assert!(!config.paused, EProtocolPaused);

    let wallet = AgentWallet {
        id: object::new(ctx),
        owner: ctx.sender(),
        agent_id,
        balance: coin::into_balance(initial_funding),
        spend_limit,
        daily_limit,
        daily_spent: 0,
        current_day_start: get_day_start(clock::timestamp_ms(clock)),
        nonce: 0,
        paused: false,
        restrict_funding,
    };

    event::emit(AgentWalletCreated {
        wallet_id: object::id(&wallet),
        owner: ctx.sender(),
        daily_limit,
    });

    transfer::transfer(wallet, ctx.sender());
}

/// Agent purchases access using its wallet
public fun agent_purchase_access(
    wallet: &mut AgentWallet,
    config: &mut ProtocolConfig,
    service: &mut ServiceProvider,
    units: u64,
    duration_ms: u64,
    rate_limit: u64,
    clock: &Clock,
    ctx: &mut TxContext
): AccessCapability {
    assert!(!wallet.paused, EUnauthorized);
    assert!(!config.paused, EProtocolPaused);
    assert!(service.active, EServiceInactive);

    // Update daily limit tracking
    let now = clock::timestamp_ms(clock);
    let day_start = get_day_start(now);
    if (day_start != wallet.current_day_start) {
        wallet.daily_spent = 0;
        wallet.current_day_start = day_start;
    };

    let cost = safe_mul(service.price_per_unit, units);
    assert!(cost <= wallet.spend_limit, EExceededLimit);
    assert!(wallet.daily_spent + cost <= wallet.daily_limit, EExceededLimit);
    assert!(balance::value(&wallet.balance) >= cost, EInsufficientBalance);

    // Extract payment from wallet
    let payment_balance = balance::split(&mut wallet.balance, cost);

    // Protocol fee
    let fee_amount = (cost * config.fee_bps) / 10000;
    let mut payment_balance = payment_balance;
    if (fee_amount > 0) {
        let fee_balance = balance::split(&mut payment_balance, fee_amount);
        balance::join(&mut config.treasury, fee_balance);
    };

    balance::join(&mut service.revenue, payment_balance);

    wallet.daily_spent = wallet.daily_spent + cost;
    wallet.nonce = wallet.nonce + 1;
    service.total_served = service.total_served + units;

    let expires_at = if (duration_ms > 0) {
        now + duration_ms
    } else {
        0
    };

    AccessCapability {
        id: object::new(ctx),
        service_id: object::id(service),
        remaining_units: units,
        expires_at,
        rate_limit,
        epoch_usage: 0,
        last_epoch: ctx.epoch(),
    }
}

/// Fund agent wallet (respects restrict_funding setting)
public fun fund_agent_wallet(
    wallet: &mut AgentWallet,
    funding: Coin<SUI>,
    ctx: &TxContext
) {
    if (wallet.restrict_funding) {
        assert!(ctx.sender() == wallet.owner, EFundingRestricted);
    };

    let amount = coin::value(&funding);
    balance::join(&mut wallet.balance, coin::into_balance(funding));

    event::emit(AgentWalletFunded {
        wallet_id: object::id(wallet),
        amount,
    });
}

/// Owner can toggle funding restriction
public fun set_funding_restriction(
    wallet: &mut AgentWallet,
    restrict_funding: bool,
    ctx: &TxContext
) {
    assert!(ctx.sender() == wallet.owner, EUnauthorized);
    wallet.restrict_funding = restrict_funding;
}

/// Withdraw from agent wallet (owner only)
public fun withdraw_from_agent_wallet(
    wallet: &mut AgentWallet,
    amount: u64,
    ctx: &mut TxContext
) {
    assert!(ctx.sender() == wallet.owner, EUnauthorized);
    assert!(balance::value(&wallet.balance) >= amount, EInsufficientBalance);

    let withdrawn = coin::from_balance(
        balance::split(&mut wallet.balance, amount),
        ctx
    );
    transfer::public_transfer(withdrawn, wallet.owner);
}

/// Pause/unpause agent wallet (owner only)
public fun set_agent_paused(
    wallet: &mut AgentWallet,
    paused: bool,
    ctx: &TxContext
) {
    assert!(ctx.sender() == wallet.owner, EUnauthorized);
    wallet.paused = paused;

    event::emit(AgentWalletPaused {
        wallet_id: object::id(wallet),
        paused,
    });
}

/// Update agent spending limits (owner only)
public fun update_agent_limits(
    wallet: &mut AgentWallet,
    spend_limit: u64,
    daily_limit: u64,
    ctx: &TxContext
) {
    assert!(ctx.sender() == wallet.owner, EUnauthorized);
    wallet.spend_limit = spend_limit;
    wallet.daily_limit = daily_limit;

    event::emit(AgentLimitsUpdated {
        wallet_id: object::id(wallet),
        spend_limit,
        daily_limit,
    });
}

// ==================== Shield Transfer Functions ====================

/// Initiate a hash-locked transfer (require_secret: true for atomic swaps, false for escrow)
public fun initiate_shield_transfer(
    config: &ProtocolConfig,
    recipient: address,
    payment: Coin<SUI>,
    duration_ms: u64,
    secret_hash: vector<u8>,
    require_secret: bool,
    clock: &Clock,
    ctx: &mut TxContext
) {
    assert!(!config.paused, EProtocolPaused);
    assert!(vector::length(&secret_hash) >= MIN_SECRET_HASH_LENGTH, EInvalidSecret);

    let amount = coin::value(&payment);
    let expires_at = clock::timestamp_ms(clock) + duration_ms;

    let session = ShieldSession {
        id: object::new(ctx),
        sender: ctx.sender(),
        recipient,
        amount,
        expires_at,
        funds: coin::into_balance(payment),
        secret_hash,
        require_secret,
    };

    event::emit(ShieldTransferInitiated {
        session_id: object::id(&session),
        sender: ctx.sender(),
        amount,
        expires_at,
    });

    transfer::share_object(session);
}

/// Complete shield transfer with secret preimage
public fun complete_shield_transfer(
    session: ShieldSession,
    secret: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext
) {
    let ShieldSession {
        id,
        sender: _,
        recipient,
        amount,
        expires_at,
        funds,
        secret_hash,
        require_secret: _,
    } = session;

    assert!(clock::timestamp_ms(clock) <= expires_at, EExpired);

    // Verify secret hash
    let provided_hash = hash::keccak256(&secret);
    assert!(provided_hash == secret_hash, EInvalidSecret);

    let payment = coin::from_balance(funds, ctx);
    transfer::public_transfer(payment, recipient);

    event::emit(ShieldTransferCompleted {
        session_id: object::uid_to_inner(&id),
        recipient,
        amount,
    });

    object::delete(id);
}

/// Complete shield transfer as recipient (only if require_secret=false)
public fun complete_shield_transfer_recipient(
    session: ShieldSession,
    clock: &Clock,
    ctx: &mut TxContext
) {
    let ShieldSession {
        id,
        sender: _,
        recipient,
        amount,
        expires_at,
        funds,
        secret_hash: _,
        require_secret,
    } = session;

    assert!(ctx.sender() == recipient, EUnauthorized);
    assert!(clock::timestamp_ms(clock) <= expires_at, EExpired);
    assert!(!require_secret, ESecretRequired);

    let payment = coin::from_balance(funds, ctx);
    transfer::public_transfer(payment, recipient);

    event::emit(ShieldTransferCompleted {
        session_id: object::uid_to_inner(&id),
        recipient,
        amount,
    });

    object::delete(id);
}

/// Cancel expired shield transfer (refund to sender)
public fun cancel_shield_transfer(
    session: ShieldSession,
    clock: &Clock,
    ctx: &mut TxContext
) {
    let ShieldSession {
        id,
        sender,
        recipient: _,
        amount,
        expires_at,
        funds,
        secret_hash: _,
        require_secret: _,
    } = session;

    assert!(clock::timestamp_ms(clock) > expires_at, EExpired);

    let refund = coin::from_balance(funds, ctx);
    transfer::public_transfer(refund, sender);

    event::emit(ShieldTransferCancelled {
        session_id: object::uid_to_inner(&id),
        sender,
        amount,
    });

    object::delete(id);
}

// ==================== Helper Functions ====================

/// Safe multiplication with overflow check
fun safe_mul(a: u64, b: u64): u64 {
    if (a == 0 || b == 0) {
        return 0
    };
    let result = a * b;
    assert!(result / a == b, EOverflow);
    result
}

/// Get start of day (ms) from timestamp
fun get_day_start(timestamp_ms: u64): u64 {
    (timestamp_ms / MS_PER_DAY) * MS_PER_DAY
}

// ==================== View Functions ====================

public fun capability_remaining(cap: &AccessCapability): u64 {
    cap.remaining_units
}

public fun capability_expires_at(cap: &AccessCapability): u64 {
    cap.expires_at
}

public fun capability_service_id(cap: &AccessCapability): ID {
    cap.service_id
}

public fun stream_remaining_escrow(stream: &PaymentStream): u64 {
    balance::value(&stream.escrow)
}

public fun stream_consumed(stream: &PaymentStream): u64 {
    stream.total_consumed
}

public fun agent_wallet_balance(wallet: &AgentWallet): u64 {
    balance::value(&wallet.balance)
}

public fun agent_wallet_daily_remaining(wallet: &AgentWallet): u64 {
    if (wallet.daily_spent >= wallet.daily_limit) {
        0
    } else {
        wallet.daily_limit - wallet.daily_spent
    }
}

public fun service_price(service: &ServiceProvider): u64 {
    service.price_per_unit
}

public fun service_is_active(service: &ServiceProvider): bool {
    service.active
}

public fun service_total_served(service: &ServiceProvider): u64 {
    service.total_served
}

public fun protocol_is_paused(config: &ProtocolConfig): bool {
    config.paused
}

// ==================== Delegated Agent Authorization ====================

/// Authorization from human owner to agent address
/// Allows agents to spend on behalf of owner with restrictions
public struct AgentAuthorization has key, store {
    id: UID,
    /// Human owner who created this authorization
    owner: address,
    /// Authorized agent address
    agent: address,
    /// Allowed services (empty = all services allowed)
    allowed_services: vector<ID>,
    /// Max spend per transaction (0 = unlimited)
    spend_limit_per_tx: u64,
    /// Max daily spend (0 = unlimited)
    daily_limit: u64,
    /// Amount spent today
    daily_spent: u64,
    /// Day tracking (epoch-based)
    last_reset_epoch: u64,
    /// Expiry timestamp (0 = never)
    expires_at: u64,
    /// Emergency pause
    paused: bool,
}

public struct AuthorizationCreated has copy, drop {
    auth_id: ID,
    owner: address,
    agent: address,
    daily_limit: u64,
}

public struct AuthorizationRevoked has copy, drop {
    auth_id: ID,
    owner: address,
}

/// Create authorization for an agent to spend on owner's behalf
public fun create_authorization(
    agent: address,
    allowed_services: vector<ID>,
    spend_limit_per_tx: u64,
    daily_limit: u64,
    duration_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext
): AgentAuthorization {
    let expires_at = if (duration_ms == 0) {
        0
    } else {
        clock::timestamp_ms(clock) + duration_ms
    };

    let auth = AgentAuthorization {
        id: object::new(ctx),
        owner: ctx.sender(),
        agent,
        allowed_services,
        spend_limit_per_tx,
        daily_limit,
        daily_spent: 0,
        last_reset_epoch: ctx.epoch(),
        expires_at,
        paused: false,
    };

    event::emit(AuthorizationCreated {
        auth_id: object::id(&auth),
        owner: ctx.sender(),
        agent,
        daily_limit,
    });

    auth
}

/// Agent purchases access using authorization
#[allow(lint(self_transfer))]
public fun authorized_purchase(
    auth: &mut AgentAuthorization,
    config: &mut ProtocolConfig,
    service: &mut ServiceProvider,
    payment: Coin<SUI>,
    units: u64,
    duration_ms: u64,
    rate_limit: u64,
    clock: &Clock,
    ctx: &mut TxContext
): AccessCapability {
    // Verify caller is authorized agent
    assert!(ctx.sender() == auth.agent, EUnauthorized);

    // Verify not paused
    assert!(!auth.paused, EUnauthorized);

    // Verify not expired
    if (auth.expires_at > 0) {
        assert!(clock::timestamp_ms(clock) < auth.expires_at, EExpired);
    };

    // Verify service is allowed (empty = all allowed)
    if (!vector::is_empty(&auth.allowed_services)) {
        assert!(vector::contains(&auth.allowed_services, &object::id(service)), EUnauthorized);
    };

    // Reset daily limit if new epoch
    let current_epoch = ctx.epoch();
    if (current_epoch > auth.last_reset_epoch) {
        auth.daily_spent = 0;
        auth.last_reset_epoch = current_epoch;
    };

    let cost = coin::value(&payment);

    // Verify spend limits
    if (auth.spend_limit_per_tx > 0) {
        assert!(cost <= auth.spend_limit_per_tx, EExceededLimit);
    };
    if (auth.daily_limit > 0) {
        assert!(auth.daily_spent + cost <= auth.daily_limit, EExceededLimit);
    };

    auth.daily_spent = auth.daily_spent + cost;

    // Delegate to standard purchase
    purchase_access(config, service, payment, units, duration_ms, rate_limit, clock, ctx)
}

/// Owner pauses authorization
public fun pause_authorization(auth: &mut AgentAuthorization, ctx: &TxContext) {
    assert!(ctx.sender() == auth.owner, EUnauthorized);
    auth.paused = true;

    event::emit(AuthorizationPaused {
        auth_id: object::id(auth),
        paused: true,
    });
}

/// Owner unpauses authorization
public fun unpause_authorization(auth: &mut AgentAuthorization, ctx: &TxContext) {
    assert!(ctx.sender() == auth.owner, EUnauthorized);
    auth.paused = false;

    event::emit(AuthorizationPaused {
        auth_id: object::id(auth),
        paused: false,
    });
}

/// Owner revokes (destroys) authorization
public fun revoke_authorization(auth: AgentAuthorization, ctx: &TxContext) {
    assert!(ctx.sender() == auth.owner, EUnauthorized);

    event::emit(AuthorizationRevoked {
        auth_id: object::id(&auth),
        owner: auth.owner,
    });

    let AgentAuthorization {
        id,
        owner: _,
        agent: _,
        allowed_services: _,
        spend_limit_per_tx: _,
        daily_limit: _,
        daily_spent: _,
        last_reset_epoch: _,
        expires_at: _,
        paused: _,
    } = auth;
    object::delete(id);
}

/// Owner updates authorization limits
public fun update_authorization_limits(
    auth: &mut AgentAuthorization,
    spend_limit_per_tx: u64,
    daily_limit: u64,
    ctx: &TxContext
) {
    assert!(ctx.sender() == auth.owner, EUnauthorized);
    auth.spend_limit_per_tx = spend_limit_per_tx;
    auth.daily_limit = daily_limit;

    event::emit(AuthorizationLimitsUpdated {
        auth_id: object::id(auth),
        spend_limit_per_tx,
        daily_limit,
    });
}

/// Owner adds allowed service
public fun add_allowed_service(
    auth: &mut AgentAuthorization,
    service_id: ID,
    ctx: &TxContext
) {
    assert!(ctx.sender() == auth.owner, EUnauthorized);
    if (!vector::contains(&auth.allowed_services, &service_id)) {
        vector::push_back(&mut auth.allowed_services, service_id);
    };
}

/// Owner removes allowed service
public fun remove_allowed_service(
    auth: &mut AgentAuthorization,
    service_id: ID,
    ctx: &TxContext
) {
    assert!(ctx.sender() == auth.owner, EUnauthorized);
    let (found, idx) = vector::index_of(&auth.allowed_services, &service_id);
    if (found) {
        vector::remove(&mut auth.allowed_services, idx);
    };
}

// ==================== Nautilus Verified Metering ====================

/// Registered Nautilus enclave for verified consumption metering
public struct TrustedMeter has key, store {
    id: UID,
    /// 32-byte Ed25519 public key of the enclave
    enclave_pubkey: vector<u8>,
    /// PCR values (enclave code measurement)
    pcr_values: vector<u8>,
    /// Who registered this meter
    registered_by: address,
    /// Description
    description: vector<u8>,
    /// Active status
    active: bool,
}

public struct MeterRegistered has copy, drop {
    meter_id: ID,
    enclave_pubkey: vector<u8>,
    registered_by: address,
}

public struct VerifiedConsumption has copy, drop {
    stream_id: ID,
    meter_id: ID,
    units: u64,
    cost: u64,
}

/// Admin registers a trusted metering enclave
public fun register_meter(
    _admin: &AdminCap,
    enclave_pubkey: vector<u8>,
    pcr_values: vector<u8>,
    description: vector<u8>,
    ctx: &mut TxContext
): TrustedMeter {
    // Validate pubkey length (Ed25519 = 32 bytes)
    assert!(vector::length(&enclave_pubkey) == 32, EInvalidInput);

    let meter = TrustedMeter {
        id: object::new(ctx),
        enclave_pubkey,
        pcr_values,
        registered_by: ctx.sender(),
        description,
        active: true,
    };

    event::emit(MeterRegistered {
        meter_id: object::id(&meter),
        enclave_pubkey: meter.enclave_pubkey,
        registered_by: ctx.sender(),
    });

    meter
}

/// Admin deactivates a meter
public fun deactivate_meter(
    _admin: &AdminCap,
    meter: &mut TrustedMeter,
) {
    meter.active = false;
}

/// Consume stream units with TEE-verified usage report (Ed25519 signed).
public fun record_verified_consumption(
    stream: &mut PaymentStream,
    service: &mut ServiceProvider,
    meter: &TrustedMeter,
    units: u64,
    timestamp: u64,
    signature: vector<u8>,
    clock: &Clock,
    _ctx: &mut TxContext
) {
    use sui::ed25519;

    // Verify meter is active
    assert!(meter.active, EUnauthorized);

    // Verify stream matches service
    assert!(stream.service_id == object::id(service), EInvalidStream);

    // Build the message that was signed: stream_id || units || timestamp
    let mut message = object::id(stream).to_bytes();
    vector::append(&mut message, bcs::to_bytes(&units));
    vector::append(&mut message, bcs::to_bytes(&timestamp));

    // Verify Ed25519 signature from enclave
    let is_valid = ed25519::ed25519_verify(
        &signature,
        &meter.enclave_pubkey,
        &message
    );
    assert!(is_valid, EUnauthorized);

    // Verify timestamp is recent (within 5 minutes)
    let now = clock::timestamp_ms(clock);
    assert!(now >= timestamp && now - timestamp < 300_000, EExpired);

    // Calculate cost and verify sufficient escrow
    let cost = safe_mul(units, stream.unit_price);
    assert!(balance::value(&stream.escrow) >= cost, EInsufficientBalance);
    assert!(stream.total_consumed + units <= stream.max_units, EExceededLimit);

    // Pull payment from escrow to provider
    let payment = balance::split(&mut stream.escrow, cost);
    balance::join(&mut service.revenue, payment);

    stream.total_consumed = stream.total_consumed + units;
    stream.last_activity = now;

    event::emit(VerifiedConsumption {
        stream_id: object::id(stream),
        meter_id: object::id(meter),
        units,
        cost,
    });
}

// View functions for new types
public fun authorization_owner(auth: &AgentAuthorization): address {
    auth.owner
}

public fun authorization_agent(auth: &AgentAuthorization): address {
    auth.agent
}

public fun authorization_daily_remaining(auth: &AgentAuthorization): u64 {
    if (auth.daily_limit == 0) {
        // Unlimited
        18446744073709551615 // u64::MAX
    } else if (auth.daily_spent >= auth.daily_limit) {
        0
    } else {
        auth.daily_limit - auth.daily_spent
    }
}

public fun authorization_is_paused(auth: &AgentAuthorization): bool {
    auth.paused
}

public fun meter_pubkey(meter: &TrustedMeter): vector<u8> {
    meter.enclave_pubkey
}

public fun meter_is_active(meter: &TrustedMeter): bool {
    meter.active
}

// ==================== Service Discovery Registry ====================

/// Metadata for service discovery
public struct ServiceMetadata has store, copy, drop {
    /// Service name
    name: vector<u8>,
    /// Description
    description: vector<u8>,
    /// Category (e.g., "oracle", "ai", "defi", "storage")
    category: vector<u8>,
    /// Walrus blob ID for Seal-encrypted endpoint details
    endpoint_blob_id: vector<u8>,
    /// Current unit price (cached from ServiceProvider)
    unit_price: u64,
    /// Total usage count (cached)
    total_served: u64,
    /// Registration timestamp
    registered_at: u64,
}

/// Registry for service discovery (shared object)
public struct ServiceRegistry has key {
    id: UID,
    /// Service ID -> Metadata
    services: vector<RegistryEntry>,
    /// Admin who can curate featured list
    admin: address,
}

/// Entry in the registry
public struct RegistryEntry has store, copy, drop {
    service_id: ID,
    metadata: ServiceMetadata,
    featured: bool,
}

public struct RegistryCreated has copy, drop {
    registry_id: ID,
    admin: address,
}

public struct ServiceListed has copy, drop {
    registry_id: ID,
    service_id: ID,
    category: vector<u8>,
}

public struct ServiceDelisted has copy, drop {
    registry_id: ID,
    service_id: ID,
}

/// Initialize service registry (admin creates this)
public fun create_registry(
    _admin: &AdminCap,
    ctx: &mut TxContext
) {
    let registry = ServiceRegistry {
        id: object::new(ctx),
        services: vector::empty(),
        admin: ctx.sender(),
    };

    event::emit(RegistryCreated {
        registry_id: object::id(&registry),
        admin: ctx.sender(),
    });

    transfer::share_object(registry);
}

/// Service owner lists their service in registry
public fun list_service(
    registry: &mut ServiceRegistry,
    service: &ServiceProvider,
    category: vector<u8>,
    endpoint_blob_id: vector<u8>,
    clock: &Clock,
    ctx: &TxContext
) {
    // Only service owner can list
    assert!(ctx.sender() == service.provider, EUnauthorized);
    assert!(service.active, EServiceInactive);

    // Check not already listed
    let service_id = object::id(service);
    let mut i = 0;
    let len = vector::length(&registry.services);
    while (i < len) {
        let entry = vector::borrow(&registry.services, i);
        assert!(entry.service_id != service_id, EInvalidInput);
        i = i + 1;
    };

    let metadata = ServiceMetadata {
        name: service.name,
        description: service.description,
        category,
        endpoint_blob_id,
        unit_price: service.price_per_unit,
        total_served: service.total_served,
        registered_at: clock::timestamp_ms(clock),
    };

    let entry = RegistryEntry {
        service_id,
        metadata,
        featured: false,
    };

    vector::push_back(&mut registry.services, entry);

    event::emit(ServiceListed {
        registry_id: object::id(registry),
        service_id,
        category,
    });
}

/// Service owner updates their listing
public fun update_listing(
    registry: &mut ServiceRegistry,
    service: &ServiceProvider,
    category: vector<u8>,
    endpoint_blob_id: vector<u8>,
    ctx: &TxContext
) {
    assert!(ctx.sender() == service.provider, EUnauthorized);

    let service_id = object::id(service);
    let mut i = 0;
    let len = vector::length(&registry.services);
    while (i < len) {
        let entry = vector::borrow_mut(&mut registry.services, i);
        if (entry.service_id == service_id) {
            entry.metadata.category = category;
            entry.metadata.endpoint_blob_id = endpoint_blob_id;
            entry.metadata.unit_price = service.price_per_unit;
            entry.metadata.total_served = service.total_served;
            return
        };
        i = i + 1;
    };

    // Not found
    abort EInvalidInput
}

/// Service owner delists their service
public fun delist_service(
    registry: &mut ServiceRegistry,
    service: &ServiceProvider,
    ctx: &TxContext
) {
    assert!(ctx.sender() == service.provider, EUnauthorized);

    let service_id = object::id(service);
    let mut i = 0;
    let len = vector::length(&registry.services);
    while (i < len) {
        let entry = vector::borrow(&registry.services, i);
        if (entry.service_id == service_id) {
            vector::remove(&mut registry.services, i);

            event::emit(ServiceDelisted {
                registry_id: object::id(registry),
                service_id,
            });
            return
        };
        i = i + 1;
    };
}

/// Admin sets featured status
public fun set_featured(
    registry: &mut ServiceRegistry,
    service_id: ID,
    featured: bool,
    ctx: &TxContext
) {
    assert!(ctx.sender() == registry.admin, EUnauthorized);

    let mut i = 0;
    let len = vector::length(&registry.services);
    while (i < len) {
        let entry = vector::borrow_mut(&mut registry.services, i);
        if (entry.service_id == service_id) {
            entry.featured = featured;
            return
        };
        i = i + 1;
    };
}

/// Get number of services in registry
public fun registry_count(registry: &ServiceRegistry): u64 {
    vector::length(&registry.services)
}

/// Get service entry by index
public fun registry_get(registry: &ServiceRegistry, idx: u64): (ID, vector<u8>, vector<u8>, u64, bool) {
    let entry = vector::borrow(&registry.services, idx);
    (
        entry.service_id,
        entry.metadata.name,
        entry.metadata.category,
        entry.metadata.unit_price,
        entry.featured
    )
}

// ==================== Sandbox/Testing Initialization ====================

/// Initialize protocol for sandbox/testing.
/// Creates ProtocolConfig (shared) and AdminCap (transferred to sender).
///
/// NOTE: In production, init() runs automatically on publish.
/// This function exists for sui-sandbox local PTB execution where
/// init doesn't run automatically.
#[allow(lint(self_transfer))]
public fun initialize_protocol(ctx: &mut TxContext) {
    let admin_cap = AdminCap {
        id: object::new(ctx),
    };

    let config = ProtocolConfig {
        id: object::new(ctx),
        paused: false,
        registration_fee: REGISTRATION_FEE,
        fee_bps: 50, // 0.5% protocol fee
        treasury: balance::zero(),
        version: 1,
    };

    event::emit(ProtocolInitialized {
        config_id: object::id(&config),
        admin: ctx.sender(),
    });

    transfer::share_object(config);
    transfer::transfer(admin_cap, ctx.sender());
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(APEX_PAYMENTS {}, ctx)
}
