/// APEX: Agent Payment EXecution Protocol (v2 - Security Hardened)
/// A Sui-native payment infrastructure for AI agents
///
/// SECURITY FIXES APPLIED:
/// - [C-01] Added authorization to close_stream
/// - [H-01] Added AdminCap pattern
/// - [H-02] Added overflow protection
/// - [H-04] Added service.active check
/// - [M-01] Fixed daily limit calculation
/// - [M-03] Added bounds on approved_services
/// - [M-04] Added registration fee
/// - [L-01] Removed unused imports
/// - [L-02] Added missing events
module dexter_payment::apex {
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::balance::{Self, Balance};
    use sui::event;
    use sui::clock::{Self, Clock};

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
    const EDuplicateService: u64 = 10;
    const EMaxServicesReached: u64 = 11;
    const EProtocolPaused: u64 = 12;

    // ==================== Constants ====================
    const MAX_NAME_LENGTH: u64 = 256;
    const MAX_CATEGORIES_LENGTH: u64 = 64;
    const MAX_APPROVED_SERVICES: u64 = 100;
    const REGISTRATION_FEE: u64 = 100_000_000; // 0.1 SUI
    const MS_PER_DAY: u64 = 86_400_000;
    const U64_MAX: u64 = 18_446_744_073_709_551_615;

    // ==================== Admin Capability ====================

    /// One-time witness for initialization
    public struct APEX has drop {}

    /// Admin capability for protocol management
    public struct AdminCap has key, store {
        id: UID,
    }

    /// Protocol configuration (shared)
    public struct ProtocolConfig has key {
        id: UID,
        /// Protocol paused flag
        paused: bool,
        /// Registration fee for new services
        registration_fee: u64,
        /// Treasury for protocol fees
        treasury: Balance<SUI>,
        /// Protocol version
        version: u64,
    }

    // ==================== Core Structs ====================

    /// ServiceProvider - registers services that AI agents can pay for
    public struct ServiceProvider has key {
        id: UID,
        /// Provider's receiving address
        provider: address,
        /// Human-readable name
        name: vector<u8>,
        /// Service categories
        categories: vector<u8>,
        /// Base price per unit
        base_price: u64,
        /// Total units served
        total_served: u64,
        /// Revenue accumulated
        revenue: Balance<SUI>,
        /// Whether provider is active
        active: bool,
        /// Version for upgrades
        version: u64,
    }

    /// AccessCapability - holdable access token
    public struct AccessCapability has key, store {
        id: UID,
        /// Which service this grants access to
        service_id: ID,
        /// Remaining units
        remaining_units: u64,
        /// Expiry timestamp (0 = no expiry)
        expires_at: u64,
        /// Rate limit: max units per epoch
        rate_limit: u64,
        /// Units used this epoch
        epoch_usage: u64,
        /// Last epoch number
        last_epoch: u64,
    }

    /// PaymentStream - open channel for continuous micropayments
    public struct PaymentStream has key {
        id: UID,
        /// Consumer (AI agent or user)
        consumer: address,
        /// Provider's service ID
        provider_id: ID,
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
        /// Auto-close after inactivity (ms)
        timeout_ms: u64,
        /// Last activity timestamp
        last_activity: u64,
    }

    /// StreamTicket - proof of consumption
    public struct StreamTicket has key, store {
        id: UID,
        stream_id: ID,
        units_consumed: u64,
        timestamp: u64,
        attestation: vector<u8>,
    }

    /// AgentCore - AI agent's on-chain identity and wallet
    public struct AgentCore has key {
        id: UID,
        /// Human owner
        owner: address,
        /// Agent's balance
        balance: Balance<SUI>,
        /// Spending policies (encoded)
        policies: vector<u8>,
        /// Approved service providers (bounded)
        approved_services: vector<ID>,
        /// Daily spending limit
        daily_limit: u64,
        /// Spent today
        daily_spent: u64,
        /// Day timestamp (ms at start of day)
        current_day_start: u64,
        /// Nonce for ordering
        nonce: u64,
        /// Emergency stop flag
        paused: bool,
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
        base_price: u64,
    }

    public struct ServiceDeactivated has copy, drop {
        service_id: ID,
        provider: address,
    }

    public struct ServiceReactivated has copy, drop {
        service_id: ID,
        provider: address,
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

    public struct CapabilityBurned has copy, drop {
        capability_id: ID,
        remaining_units: u64,
    }

    public struct StreamOpened has copy, drop {
        stream_id: ID,
        consumer: address,
        provider_id: ID,
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
        closed_by: address,
    }

    public struct AgentCreated has copy, drop {
        agent_id: ID,
        owner: address,
        daily_limit: u64,
    }

    public struct AgentPaused has copy, drop {
        agent_id: ID,
        paused: bool,
    }

    public struct ProtocolPaused has copy, drop {
        paused: bool,
        by: address,
    }

    // ==================== Init ====================

    fun init(witness: APEX, ctx: &mut TxContext) {
        let _ = witness;

        let admin_cap = AdminCap {
            id: object::new(ctx),
        };

        let config = ProtocolConfig {
            id: object::new(ctx),
            paused: false,
            registration_fee: REGISTRATION_FEE,
            treasury: balance::zero(),
            version: 1,
        };

        event::emit(ProtocolInitialized {
            config_id: object::id(&config),
            admin: tx_context::sender(ctx),
        });

        transfer::share_object(config);
        transfer::transfer(admin_cap, tx_context::sender(ctx));
    }

    // ==================== Admin Functions ====================

    /// Pause/unpause protocol (admin only)
    public entry fun set_protocol_paused(
        _admin: &AdminCap,
        config: &mut ProtocolConfig,
        paused: bool,
        ctx: &TxContext
    ) {
        config.paused = paused;
        event::emit(ProtocolPaused {
            paused,
            by: tx_context::sender(ctx),
        });
    }

    /// Update registration fee (admin only)
    public entry fun set_registration_fee(
        _admin: &AdminCap,
        config: &mut ProtocolConfig,
        new_fee: u64,
    ) {
        config.registration_fee = new_fee;
    }

    /// Withdraw treasury (admin only)
    public entry fun withdraw_treasury(
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

    /// Register as a service provider (with fee)
    public entry fun register_service(
        config: &mut ProtocolConfig,
        name: vector<u8>,
        categories: vector<u8>,
        base_price: u64,
        registration_payment: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        assert!(!config.paused, EProtocolPaused);

        // Validate inputs
        assert!(vector::length(&name) > 0 && vector::length(&name) <= MAX_NAME_LENGTH, EInvalidInput);
        assert!(vector::length(&categories) <= MAX_CATEGORIES_LENGTH, EInvalidInput);
        assert!(base_price > 0, EInvalidInput);

        // Collect registration fee
        let payment_amount = coin::value(&registration_payment);
        assert!(payment_amount >= config.registration_fee, EInsufficientBalance);

        let mut payment_balance = coin::into_balance(registration_payment);
        if (payment_amount > config.registration_fee) {
            let refund = coin::from_balance(
                balance::split(&mut payment_balance, payment_amount - config.registration_fee),
                ctx
            );
            transfer::public_transfer(refund, tx_context::sender(ctx));
        };
        balance::join(&mut config.treasury, payment_balance);

        let service = ServiceProvider {
            id: object::new(ctx),
            provider: tx_context::sender(ctx),
            name,
            categories,
            base_price,
            total_served: 0,
            revenue: balance::zero(),
            active: true,
            version: 1,
        };

        event::emit(ServiceRegistered {
            service_id: object::id(&service),
            provider: tx_context::sender(ctx),
            name: service.name,
            base_price,
        });

        transfer::share_object(service);
    }

    /// Deactivate service (provider only)
    public entry fun deactivate_service(
        service: &mut ServiceProvider,
        ctx: &TxContext
    ) {
        assert!(tx_context::sender(ctx) == service.provider, EUnauthorized);
        service.active = false;

        event::emit(ServiceDeactivated {
            service_id: object::id(service),
            provider: service.provider,
        });
    }

    /// Reactivate service (provider only)
    public entry fun reactivate_service(
        service: &mut ServiceProvider,
        ctx: &TxContext
    ) {
        assert!(tx_context::sender(ctx) == service.provider, EUnauthorized);
        service.active = true;

        event::emit(ServiceReactivated {
            service_id: object::id(service),
            provider: service.provider,
        });
    }

    /// Update service price (provider only)
    public entry fun update_service_price(
        service: &mut ServiceProvider,
        new_price: u64,
        ctx: &TxContext
    ) {
        assert!(tx_context::sender(ctx) == service.provider, EUnauthorized);
        assert!(new_price > 0, EInvalidInput);
        service.base_price = new_price;
    }

    /// Withdraw service revenue (provider only)
    public entry fun withdraw_service_revenue(
        service: &mut ServiceProvider,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == service.provider, EUnauthorized);

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

    /// Purchase access capability with overflow protection
    public fun purchase_access(
        config: &ProtocolConfig,
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

        // Overflow-safe cost calculation
        let cost = safe_mul(service.base_price, units);

        let payment_amount = coin::value(&payment);
        assert!(payment_amount >= cost, EInsufficientBalance);

        let mut payment_balance = coin::into_balance(payment);
        if (payment_amount > cost) {
            let refund = coin::from_balance(
                balance::split(&mut payment_balance, payment_amount - cost),
                ctx
            );
            transfer::public_transfer(refund, tx_context::sender(ctx));
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
            last_epoch: tx_context::epoch(ctx),
        };

        event::emit(AccessPurchased {
            capability_id: object::id(&capability),
            service_id: object::id(service),
            buyer: tx_context::sender(ctx),
            units,
            cost,
        });

        capability
    }

    /// Use access capability
    public fun use_access(
        cap: &mut AccessCapability,
        service: &ServiceProvider,
        units: u64,
        clock: &Clock,
        ctx: &TxContext
    ): bool {
        assert!(cap.service_id == object::id(service), EInvalidCapability);
        assert!(service.active, EServiceInactive);

        if (cap.expires_at > 0) {
            assert!(clock::timestamp_ms(clock) <= cap.expires_at, EExpired);
        };

        assert!(cap.remaining_units >= units, EInsufficientBalance);

        let current_epoch = tx_context::epoch(ctx);
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

    /// Burn unused capability
    public entry fun burn_capability(cap: AccessCapability) {
        let AccessCapability {
            id,
            service_id: _,
            remaining_units,
            expires_at: _,
            rate_limit: _,
            epoch_usage: _,
            last_epoch: _,
        } = cap;

        event::emit(CapabilityBurned {
            capability_id: object::uid_to_inner(&id),
            remaining_units,
        });

        object::delete(id);
    }

    // ==================== Streaming Payment Functions ====================

    /// Open a payment stream
    public entry fun open_stream(
        config: &ProtocolConfig,
        service: &ServiceProvider,
        escrow: Coin<SUI>,
        max_units: u64,
        timeout_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(!config.paused, EProtocolPaused);
        assert!(service.active, EServiceInactive);
        assert!(max_units > 0, EInvalidInput);

        let stream = PaymentStream {
            id: object::new(ctx),
            consumer: tx_context::sender(ctx),
            provider_id: object::id(service),
            provider_address: service.provider,
            escrow: coin::into_balance(escrow),
            unit_price: service.base_price,
            total_consumed: 0,
            max_units,
            started_at: clock::timestamp_ms(clock),
            timeout_ms,
            last_activity: clock::timestamp_ms(clock),
        };

        event::emit(StreamOpened {
            stream_id: object::id(&stream),
            consumer: tx_context::sender(ctx),
            provider_id: object::id(service),
            escrow_amount: balance::value(&stream.escrow),
        });

        transfer::share_object(stream);
    }

    /// Provider records consumption
    public entry fun record_consumption(
        stream: &mut PaymentStream,
        service: &mut ServiceProvider,
        units: u64,
        attestation: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == service.provider, EUnauthorized);
        assert!(stream.provider_id == object::id(service), EInvalidStream);

        let cost = safe_mul(units, stream.unit_price);
        assert!(balance::value(&stream.escrow) >= cost, EInsufficientBalance);
        assert!(stream.total_consumed + units <= stream.max_units, EExceededLimit);

        if (stream.timeout_ms > 0) {
            assert!(
                clock::timestamp_ms(clock) <= stream.last_activity + stream.timeout_ms,
                EExpired
            );
        };

        let payment = balance::split(&mut stream.escrow, cost);
        balance::join(&mut service.revenue, payment);

        stream.total_consumed = stream.total_consumed + units;
        stream.last_activity = clock::timestamp_ms(clock);

        let ticket = StreamTicket {
            id: object::new(ctx),
            stream_id: object::id(stream),
            units_consumed: units,
            timestamp: clock::timestamp_ms(clock),
            attestation,
        };

        event::emit(StreamConsumed {
            stream_id: object::id(stream),
            units,
            cost,
        });

        transfer::transfer(ticket, stream.consumer);
    }

    /// Close stream (FIXED: only consumer or provider can close)
    public entry fun close_stream(
        stream: PaymentStream,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);

        // SECURITY FIX [C-01]: Authorization check
        assert!(
            sender == stream.consumer || sender == stream.provider_address,
            EUnauthorized
        );

        let PaymentStream {
            id,
            consumer,
            provider_id: _,
            provider_address: _,
            escrow,
            unit_price: _,
            total_consumed,
            max_units: _,
            started_at: _,
            timeout_ms: _,
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
            closed_by: sender,
        });

        object::delete(id);
    }

    // ==================== Agent Functions ====================

    /// Create an AI agent with spending policies
    public entry fun create_agent(
        config: &ProtocolConfig,
        initial_funding: Coin<SUI>,
        policies: vector<u8>,
        daily_limit: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(!config.paused, EProtocolPaused);

        let agent = AgentCore {
            id: object::new(ctx),
            owner: tx_context::sender(ctx),
            balance: coin::into_balance(initial_funding),
            policies,
            approved_services: vector::empty(),
            daily_limit,
            daily_spent: 0,
            current_day_start: get_day_start(clock::timestamp_ms(clock)),
            nonce: 0,
            paused: false,
        };

        event::emit(AgentCreated {
            agent_id: object::id(&agent),
            owner: tx_context::sender(ctx),
            daily_limit,
        });

        transfer::transfer(agent, tx_context::sender(ctx));
    }

    /// Agent purchases access (FIXED: proper daily limit, service check)
    public fun agent_purchase_access(
        agent: &mut AgentCore,
        service: &mut ServiceProvider,
        units: u64,
        duration_ms: u64,
        rate_limit: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): AccessCapability {
        assert!(!agent.paused, EInvalidCapability);
        assert!(service.active, EServiceInactive);  // SECURITY FIX [H-04]

        // SECURITY FIX [M-01]: Proper daily limit calculation
        let now = clock::timestamp_ms(clock);
        let day_start = get_day_start(now);
        if (day_start != agent.current_day_start) {
            agent.daily_spent = 0;
            agent.current_day_start = day_start;
        };

        let cost = safe_mul(service.base_price, units);
        assert!(agent.daily_spent + cost <= agent.daily_limit, EExceededLimit);
        assert!(balance::value(&agent.balance) >= cost, EInsufficientBalance);

        let payment_balance = balance::split(&mut agent.balance, cost);
        balance::join(&mut service.revenue, payment_balance);

        agent.daily_spent = agent.daily_spent + cost;
        agent.nonce = agent.nonce + 1;
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
            last_epoch: tx_context::epoch(ctx),
        }
    }

    /// Add service to approved list (FIXED: bounded, no duplicates)
    public entry fun approve_service(
        agent: &mut AgentCore,
        service_id: ID,
        ctx: &TxContext
    ) {
        assert!(tx_context::sender(ctx) == agent.owner, EUnauthorized);

        // SECURITY FIX [M-03]: Check bounds
        assert!(
            vector::length(&agent.approved_services) < MAX_APPROVED_SERVICES,
            EMaxServicesReached
        );

        // Check for duplicates
        let len = vector::length(&agent.approved_services);
        let mut i = 0;
        while (i < len) {
            assert!(*vector::borrow(&agent.approved_services, i) != service_id, EDuplicateService);
            i = i + 1;
        };

        vector::push_back(&mut agent.approved_services, service_id);
    }

    /// Remove service from approved list
    public entry fun remove_approved_service(
        agent: &mut AgentCore,
        service_id: ID,
        ctx: &TxContext
    ) {
        assert!(tx_context::sender(ctx) == agent.owner, EUnauthorized);

        let len = vector::length(&agent.approved_services);
        let mut i = 0;
        while (i < len) {
            if (*vector::borrow(&agent.approved_services, i) == service_id) {
                vector::remove(&mut agent.approved_services, i);
                return
            };
            i = i + 1;
        };
    }

    /// Pause/unpause agent
    public entry fun set_agent_paused(
        agent: &mut AgentCore,
        paused: bool,
        ctx: &TxContext
    ) {
        assert!(tx_context::sender(ctx) == agent.owner, EUnauthorized);
        agent.paused = paused;

        event::emit(AgentPaused {
            agent_id: object::id(agent),
            paused,
        });
    }

    /// Fund agent wallet
    public entry fun fund_agent(
        agent: &mut AgentCore,
        funding: Coin<SUI>,
    ) {
        balance::join(&mut agent.balance, coin::into_balance(funding));
    }

    /// Withdraw from agent wallet (owner only)
    public entry fun withdraw_from_agent(
        agent: &mut AgentCore,
        amount: u64,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == agent.owner, EUnauthorized);
        assert!(balance::value(&agent.balance) >= amount, EInsufficientBalance);

        let withdrawn = coin::from_balance(
            balance::split(&mut agent.balance, amount),
            ctx
        );
        transfer::public_transfer(withdrawn, agent.owner);
    }

    // ==================== Helper Functions ====================

    /// Safe multiplication with overflow check
    fun safe_mul(a: u64, b: u64): u64 {
        if (a == 0 || b == 0) {
            return 0
        };
        let result = a * b;
        // Check for overflow: result / a should equal b
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

    public fun stream_remaining_escrow(stream: &PaymentStream): u64 {
        balance::value(&stream.escrow)
    }

    public fun stream_consumed(stream: &PaymentStream): u64 {
        stream.total_consumed
    }

    public fun agent_balance(agent: &AgentCore): u64 {
        balance::value(&agent.balance)
    }

    public fun agent_daily_remaining(agent: &AgentCore): u64 {
        if (agent.daily_spent >= agent.daily_limit) {
            0
        } else {
            agent.daily_limit - agent.daily_spent
        }
    }

    public fun service_revenue(service: &ServiceProvider): u64 {
        balance::value(&service.revenue)
    }

    public fun service_is_active(service: &ServiceProvider): bool {
        service.active
    }

    public fun protocol_is_paused(config: &ProtocolConfig): bool {
        config.paused
    }
}
