/// Dexter Payment Infrastructure for AI Agent Economy on Sui - Security Hardened v2
///
/// This module implements the core x402-style payment infrastructure:
/// 1. Pay-per-call API billing via on-chain payment verification
/// 2. Facilitator system for payment processing
/// 3. Private transfer mechanism (Dexter Shield concept) - FIXED
/// 4. AI Agent wallet management
///
/// SECURITY FIXES:
/// - [C-02] Shield transfer requires recipient or secret to complete
/// - [M-05] Removed unused provider_amount variable
/// - [L-04] Removed unused table import
/// - Added admin controls for protocol pause
/// - Added overflow protection
module dexter_payment::payment {
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::balance::{Self, Balance};
    use sui::event;
    use sui::clock::{Self, Clock};
    use sui::hash;

    // ==================== Error Codes ====================
    const EInsufficientPayment: u64 = 0;
    const EInvalidEndpoint: u64 = 1;
    const EUnauthorized: u64 = 2;
    const EExpiredPayment: u64 = 3;
    const EAlreadyProcessed: u64 = 4;
    const EInvalidAmount: u64 = 5;
    const EProtocolPaused: u64 = 6;
    const EInvalidSecret: u64 = 7;
    const EOverflow: u64 = 8;
    const EEndpointInactive: u64 = 9;

    // ==================== Constants ====================
    const U64_MAX: u128 = 18446744073709551615;
    const MAX_FEE_BPS: u64 = 1000; // 10% max fee

    // ==================== Core Structs ====================

    /// Admin capability for protocol management
    public struct AdminCap has key, store {
        id: UID,
    }

    /// Global facilitator registry - manages payment processing
    public struct FacilitatorRegistry has key {
        id: UID,
        /// Total processed volume
        total_volume: u64,
        /// Fee in basis points (100 = 1%)
        fee_bps: u64,
        /// Accumulated fees
        fees: Balance<SUI>,
        /// Admin capability ID
        admin: address,
        /// Protocol pause status
        paused: bool,
    }

    /// API Endpoint paywall configuration
    public struct Endpoint has key, store {
        id: UID,
        /// Owner/provider address
        provider: address,
        /// Price per call in MIST (1 SUI = 10^9 MIST)
        price_per_call: u64,
        /// Endpoint identifier (hash of URL/path)
        endpoint_hash: vector<u8>,
        /// Whether endpoint is active
        active: bool,
        /// Total calls processed
        total_calls: u64,
        /// Accumulated revenue
        revenue: Balance<SUI>,
    }

    /// Payment receipt - proof of payment for API access
    public struct PaymentReceipt has key, store {
        id: UID,
        /// Endpoint this payment is for
        endpoint_id: ID,
        /// Amount paid
        amount: u64,
        /// Timestamp
        timestamp: u64,
        /// Payer address
        payer: address,
        /// Nonce for replay protection
        nonce: u64,
    }

    /// AI Agent Wallet - managed wallet for AI agents
    public struct AgentWallet has key {
        id: UID,
        /// Owner who controls the agent
        owner: address,
        /// Agent identifier
        agent_id: vector<u8>,
        /// Spending limit per transaction
        spend_limit: u64,
        /// Balance for payments
        balance: Balance<SUI>,
        /// Nonce for sequential transactions
        nonce: u64,
    }

    /// Shield Transfer Session - for private transfers
    /// [C-02] FIXED: Now requires secret hash for completion
    public struct ShieldSession has key {
        id: UID,
        /// Sender address
        sender: address,
        /// Final recipient
        recipient: address,
        /// Amount to transfer
        amount: u64,
        /// Expiry timestamp
        expires_at: u64,
        /// Session funds
        funds: Balance<SUI>,
        /// Hash of secret for claim (SHA3-256)
        secret_hash: vector<u8>,
    }

    // ==================== Events ====================

    public struct PaymentProcessed has copy, drop {
        endpoint_id: ID,
        payer: address,
        amount: u64,
        timestamp: u64,
    }

    public struct EndpointCreated has copy, drop {
        endpoint_id: ID,
        provider: address,
        price_per_call: u64,
    }

    public struct EndpointDeactivated has copy, drop {
        endpoint_id: ID,
        provider: address,
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

    public struct ProtocolPaused has copy, drop {
        admin: address,
    }

    public struct ProtocolUnpaused has copy, drop {
        admin: address,
    }

    public struct FeeUpdated has copy, drop {
        old_fee_bps: u64,
        new_fee_bps: u64,
    }

    // ==================== Helper Functions ====================

    /// Safe multiplication with overflow check
    fun safe_mul(a: u64, b: u64): u64 {
        let result = (a as u128) * (b as u128);
        assert!(result <= U64_MAX, EOverflow);
        (result as u64)
    }

    // ==================== Facilitator Functions ====================

    /// Initialize the facilitator registry (called once)
    fun init(ctx: &mut TxContext) {
        let admin_cap = AdminCap {
            id: object::new(ctx),
        };

        let registry = FacilitatorRegistry {
            id: object::new(ctx),
            total_volume: 0,
            fee_bps: 50, // 0.5% fee
            fees: balance::zero(),
            admin: tx_context::sender(ctx),
            paused: false,
        };

        transfer::share_object(registry);
        transfer::transfer(admin_cap, tx_context::sender(ctx));
    }

    /// Pause protocol (admin only)
    public entry fun pause_protocol(
        _admin_cap: &AdminCap,
        registry: &mut FacilitatorRegistry,
        ctx: &mut TxContext
    ) {
        registry.paused = true;
        event::emit(ProtocolPaused {
            admin: tx_context::sender(ctx),
        });
    }

    /// Unpause protocol (admin only)
    public entry fun unpause_protocol(
        _admin_cap: &AdminCap,
        registry: &mut FacilitatorRegistry,
        ctx: &mut TxContext
    ) {
        registry.paused = false;
        event::emit(ProtocolUnpaused {
            admin: tx_context::sender(ctx),
        });
    }

    /// Update protocol fee (admin only)
    public entry fun update_fee(
        _admin_cap: &AdminCap,
        registry: &mut FacilitatorRegistry,
        new_fee_bps: u64,
    ) {
        assert!(new_fee_bps <= MAX_FEE_BPS, EInvalidAmount);
        let old_fee = registry.fee_bps;
        registry.fee_bps = new_fee_bps;
        event::emit(FeeUpdated {
            old_fee_bps: old_fee,
            new_fee_bps,
        });
    }

    /// Withdraw accumulated fees (admin only)
    public entry fun withdraw_fees(
        _admin_cap: &AdminCap,
        registry: &mut FacilitatorRegistry,
        ctx: &mut TxContext
    ) {
        let amount = balance::value(&registry.fees);
        if (amount > 0) {
            let fees = coin::from_balance(
                balance::split(&mut registry.fees, amount),
                ctx
            );
            transfer::public_transfer(fees, registry.admin);
        }
    }

    /// Create a new API endpoint with paywall
    public entry fun create_endpoint(
        registry: &FacilitatorRegistry,
        endpoint_hash: vector<u8>,
        price_per_call: u64,
        ctx: &mut TxContext
    ) {
        assert!(!registry.paused, EProtocolPaused);

        let endpoint = Endpoint {
            id: object::new(ctx),
            provider: tx_context::sender(ctx),
            price_per_call,
            endpoint_hash,
            active: true,
            total_calls: 0,
            revenue: balance::zero(),
        };

        event::emit(EndpointCreated {
            endpoint_id: object::id(&endpoint),
            provider: tx_context::sender(ctx),
            price_per_call,
        });

        transfer::share_object(endpoint);
    }

    /// Deactivate endpoint (provider only)
    public entry fun deactivate_endpoint(
        endpoint: &mut Endpoint,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == endpoint.provider, EUnauthorized);
        endpoint.active = false;

        event::emit(EndpointDeactivated {
            endpoint_id: object::id(endpoint),
            provider: endpoint.provider,
        });
    }

    /// Pay for API access - core x402 settlement function
    /// [M-05] FIXED: Removed unused provider_amount variable
    public entry fun pay_for_access(
        registry: &mut FacilitatorRegistry,
        endpoint: &mut Endpoint,
        payment: Coin<SUI>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(!registry.paused, EProtocolPaused);
        assert!(endpoint.active, EEndpointInactive);

        let payment_amount = coin::value(&payment);
        assert!(payment_amount >= endpoint.price_per_call, EInsufficientPayment);

        // Calculate facilitator fee with overflow protection
        let fee_amount = safe_mul(payment_amount, registry.fee_bps) / 10000;

        // Split payment
        let mut payment_balance = coin::into_balance(payment);
        let fee_balance = balance::split(&mut payment_balance, fee_amount);

        // Accumulate fees and revenue
        balance::join(&mut registry.fees, fee_balance);
        balance::join(&mut endpoint.revenue, payment_balance);

        // Update stats
        registry.total_volume = registry.total_volume + payment_amount;
        endpoint.total_calls = endpoint.total_calls + 1;

        // Create receipt
        let receipt = PaymentReceipt {
            id: object::new(ctx),
            endpoint_id: object::id(endpoint),
            amount: payment_amount,
            timestamp: clock::timestamp_ms(clock),
            payer: tx_context::sender(ctx),
            nonce: endpoint.total_calls,
        };

        event::emit(PaymentProcessed {
            endpoint_id: object::id(endpoint),
            payer: tx_context::sender(ctx),
            amount: payment_amount,
            timestamp: clock::timestamp_ms(clock),
        });

        transfer::transfer(receipt, tx_context::sender(ctx));
    }

    /// Withdraw accumulated revenue (provider only)
    public entry fun withdraw_revenue(
        endpoint: &mut Endpoint,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == endpoint.provider, EUnauthorized);

        let revenue_amount = balance::value(&endpoint.revenue);
        if (revenue_amount > 0) {
            let revenue = coin::from_balance(
                balance::split(&mut endpoint.revenue, revenue_amount),
                ctx
            );
            transfer::public_transfer(revenue, endpoint.provider);
        }
    }

    // ==================== Agent Wallet Functions ====================

    /// Create an AI agent wallet
    public entry fun create_agent_wallet(
        registry: &FacilitatorRegistry,
        agent_id: vector<u8>,
        spend_limit: u64,
        initial_funding: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        assert!(!registry.paused, EProtocolPaused);

        let wallet = AgentWallet {
            id: object::new(ctx),
            owner: tx_context::sender(ctx),
            agent_id,
            spend_limit,
            balance: coin::into_balance(initial_funding),
            nonce: 0,
        };
        transfer::transfer(wallet, tx_context::sender(ctx));
    }

    /// Update agent wallet spend limit (owner only)
    public entry fun update_spend_limit(
        wallet: &mut AgentWallet,
        new_limit: u64,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == wallet.owner, EUnauthorized);
        wallet.spend_limit = new_limit;
    }

    /// Agent pays for API access (delegated payment)
    public entry fun agent_pay_for_access(
        wallet: &mut AgentWallet,
        registry: &mut FacilitatorRegistry,
        endpoint: &mut Endpoint,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(!registry.paused, EProtocolPaused);
        assert!(endpoint.active, EEndpointInactive);

        // Verify wallet has sufficient balance
        let price = endpoint.price_per_call;
        assert!(balance::value(&wallet.balance) >= price, EInsufficientPayment);
        assert!(price <= wallet.spend_limit, EInvalidAmount);

        // Extract payment from wallet
        let payment_balance = balance::split(&mut wallet.balance, price);
        let payment = coin::from_balance(payment_balance, ctx);

        // Increment nonce
        wallet.nonce = wallet.nonce + 1;

        // Calculate facilitator fee with overflow protection
        let fee_amount = safe_mul(price, registry.fee_bps) / 10000;

        let mut payment_balance = coin::into_balance(payment);
        let fee_balance = balance::split(&mut payment_balance, fee_amount);

        balance::join(&mut registry.fees, fee_balance);
        balance::join(&mut endpoint.revenue, payment_balance);

        registry.total_volume = registry.total_volume + price;
        endpoint.total_calls = endpoint.total_calls + 1;

        let receipt = PaymentReceipt {
            id: object::new(ctx),
            endpoint_id: object::id(endpoint),
            amount: price,
            timestamp: clock::timestamp_ms(clock),
            payer: tx_context::sender(ctx),
            nonce: wallet.nonce,
        };

        event::emit(PaymentProcessed {
            endpoint_id: object::id(endpoint),
            payer: tx_context::sender(ctx),
            amount: price,
            timestamp: clock::timestamp_ms(clock),
        });

        transfer::transfer(receipt, tx_context::sender(ctx));
    }

    /// Top up agent wallet
    public entry fun fund_agent_wallet(
        wallet: &mut AgentWallet,
        funding: Coin<SUI>,
    ) {
        balance::join(&mut wallet.balance, coin::into_balance(funding));
    }

    /// Withdraw from agent wallet (owner only)
    public entry fun withdraw_from_wallet(
        wallet: &mut AgentWallet,
        amount: u64,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == wallet.owner, EUnauthorized);
        assert!(balance::value(&wallet.balance) >= amount, EInsufficientPayment);

        let withdrawn = coin::from_balance(
            balance::split(&mut wallet.balance, amount),
            ctx
        );
        transfer::public_transfer(withdrawn, wallet.owner);
    }

    // ==================== Shield (Private Transfer) Functions ====================

    /// Initiate a shielded transfer - funds go to temporary address first
    /// [C-02] FIXED: Now requires secret hash for secure claiming
    public entry fun initiate_shield_transfer(
        registry: &FacilitatorRegistry,
        recipient: address,
        payment: Coin<SUI>,
        duration_ms: u64,
        secret_hash: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(!registry.paused, EProtocolPaused);
        assert!(vector::length(&secret_hash) >= 32, EInvalidSecret);

        let amount = coin::value(&payment);
        let expires_at = clock::timestamp_ms(clock) + duration_ms;

        let session = ShieldSession {
            id: object::new(ctx),
            sender: tx_context::sender(ctx),
            recipient,
            amount,
            expires_at,
            funds: coin::into_balance(payment),
            secret_hash,
        };

        event::emit(ShieldTransferInitiated {
            session_id: object::id(&session),
            sender: tx_context::sender(ctx),
            amount,
            expires_at,
        });

        // Session is shared - but requires secret to complete
        transfer::share_object(session);
    }

    /// Complete shielded transfer - requires secret proof
    /// [C-02] FIXED: Now verifies secret before completion
    public entry fun complete_shield_transfer(
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
        } = session;

        assert!(clock::timestamp_ms(clock) <= expires_at, EExpiredPayment);

        // [C-02] CRITICAL FIX: Verify secret hash
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

    /// Complete shield transfer by recipient directly (no secret needed)
    /// Only the designated recipient can call this
    public entry fun complete_shield_transfer_recipient(
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
        } = session;

        // Only recipient can complete without secret
        assert!(tx_context::sender(ctx) == recipient, EUnauthorized);
        assert!(clock::timestamp_ms(clock) <= expires_at, EExpiredPayment);

        let payment = coin::from_balance(funds, ctx);
        transfer::public_transfer(payment, recipient);

        event::emit(ShieldTransferCompleted {
            session_id: object::uid_to_inner(&id),
            recipient,
            amount,
        });

        object::delete(id);
    }

    /// Cancel expired shield session - refund to sender
    public entry fun cancel_shield_transfer(
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
        } = session;

        assert!(clock::timestamp_ms(clock) > expires_at, EExpiredPayment);

        let refund = coin::from_balance(funds, ctx);
        transfer::public_transfer(refund, sender);

        event::emit(ShieldTransferCancelled {
            session_id: object::uid_to_inner(&id),
            sender,
            amount,
        });

        object::delete(id);
    }

    // ==================== View Functions ====================

    public fun endpoint_price(endpoint: &Endpoint): u64 {
        endpoint.price_per_call
    }

    public fun endpoint_total_calls(endpoint: &Endpoint): u64 {
        endpoint.total_calls
    }

    public fun endpoint_revenue(endpoint: &Endpoint): u64 {
        balance::value(&endpoint.revenue)
    }

    public fun endpoint_active(endpoint: &Endpoint): bool {
        endpoint.active
    }

    public fun agent_wallet_balance(wallet: &AgentWallet): u64 {
        balance::value(&wallet.balance)
    }

    public fun agent_wallet_owner(wallet: &AgentWallet): address {
        wallet.owner
    }

    public fun agent_wallet_nonce(wallet: &AgentWallet): u64 {
        wallet.nonce
    }

    public fun registry_volume(registry: &FacilitatorRegistry): u64 {
        registry.total_volume
    }

    public fun registry_paused(registry: &FacilitatorRegistry): bool {
        registry.paused
    }

    public fun registry_fee_bps(registry: &FacilitatorRegistry): u64 {
        registry.fee_bps
    }
}
