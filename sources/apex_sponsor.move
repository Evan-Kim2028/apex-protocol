/// APEX Sponsor - Gas Sponsorship Support
///
/// This module provides patterns for sponsored transactions, enabling gasless
/// UX similar to x402 where the facilitator pays gas.
///
/// Sui's sponsored transaction model:
/// 1. User builds transaction (PTB)
/// 2. Sponsor signs GasData (provides gas coin, budget)
/// 3. User signs transaction
/// 4. Either party submits to network
///
/// This module provides on-chain components to complement off-chain sponsorship:
/// - SponsorRegistry: Track approved sponsors and their budgets
/// - SponsorIntent: Declare intent to sponsor specific transaction types
/// - Usage tracking for sponsor accounting
///
/// Off-chain components needed (not in this module):
/// - Sponsor server that signs GasData
/// - API for users to request sponsorship
module apex_protocol::apex_sponsor;

use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;
use sui::sui::SUI;
use sui::table::{Self, Table};

// ==================== Error Codes ====================
const ESponsorNotRegistered: u64 = 0;
// ESponsorInactive (1) reserved for future use
// EInsufficientBudget (2) reserved for future use
const EUnauthorized: u64 = 3;
// EServiceNotWhitelisted (4) reserved for future use
// EUserRateLimited (5) reserved for future use

// ==================== Constants ====================
const MS_PER_HOUR: u64 = 3_600_000;
const DEFAULT_RATE_LIMIT: u64 = 100; // 100 sponsored txs per hour per user

// ==================== Sponsor Registry ====================

/// Registry of approved sponsors for a protocol
public struct SponsorRegistry has key {
    id: UID,
    /// Mapping of sponsor address to their config
    sponsors: Table<address, SponsorConfig>,
    /// Protocol admin
    admin: address,
}

/// Configuration for a sponsor
public struct SponsorConfig has store {
    /// Whether sponsor is active
    active: bool,
    /// Budget remaining (in MIST)
    budget_remaining: u64,
    /// Services this sponsor will pay for (empty = all)
    whitelisted_services: vector<ID>,
    /// Total sponsored so far
    total_sponsored: u64,
    /// Rate limit per user per hour
    user_rate_limit: u64,
}

/// User's sponsorship usage tracking
public struct UserSponsorUsage has key {
    id: UID,
    /// User address
    user: address,
    /// Sponsor address
    sponsor: address,
    /// Transactions sponsored this hour
    hourly_count: u64,
    /// Hour timestamp
    current_hour: u64,
}

// ==================== Events ====================

public struct SponsorRegistered has copy, drop {
    registry_id: ID,
    sponsor: address,
    initial_budget: u64,
}

public struct SponsorshipUsed has copy, drop {
    sponsor: address,
    user: address,
    service_id: ID,
    gas_cost: u64,
}

public struct SponsorBudgetUpdated has copy, drop {
    sponsor: address,
    new_budget: u64,
}

// ==================== Registry Management ====================

/// Create a new sponsor registry
public fun create_registry(ctx: &mut TxContext): SponsorRegistry {
    SponsorRegistry {
        id: object::new(ctx),
        sponsors: table::new(ctx),
        admin: ctx.sender(),
    }
}

/// Register a sponsor with initial budget
#[allow(lint(self_transfer))]
public fun register_sponsor(
    registry: &mut SponsorRegistry,
    budget: Coin<SUI>,
    whitelisted_services: vector<ID>,
    ctx: &mut TxContext
) {
    let sponsor = ctx.sender();
    let budget_amount = coin::value(&budget);

    // Return the budget to sponsor - actual gas payment happens off-chain
    // This registration just tracks the sponsor's commitment
    transfer::public_transfer(budget, sponsor);

    registry.sponsors.add(sponsor, SponsorConfig {
        active: true,
        budget_remaining: budget_amount,
        whitelisted_services,
        total_sponsored: 0,
        user_rate_limit: DEFAULT_RATE_LIMIT,
    });

    event::emit(SponsorRegistered {
        registry_id: object::id(registry),
        sponsor,
        initial_budget: budget_amount,
    });
}

/// Update sponsor budget (sponsor only)
public fun update_budget(
    registry: &mut SponsorRegistry,
    additional_budget: u64,
    ctx: &TxContext
) {
    let sponsor = ctx.sender();
    assert!(registry.sponsors.contains(sponsor), ESponsorNotRegistered);

    let config = registry.sponsors.borrow_mut(sponsor);
    config.budget_remaining = config.budget_remaining + additional_budget;

    event::emit(SponsorBudgetUpdated {
        sponsor,
        new_budget: config.budget_remaining,
    });
}

/// Deactivate sponsor (sponsor or admin only)
public fun deactivate_sponsor(
    registry: &mut SponsorRegistry,
    sponsor: address,
    ctx: &TxContext
) {
    let sender = ctx.sender();
    assert!(sender == sponsor || sender == registry.admin, EUnauthorized);
    assert!(registry.sponsors.contains(sponsor), ESponsorNotRegistered);

    let config = registry.sponsors.borrow_mut(sponsor);
    config.active = false;
}

// ==================== Sponsorship Verification ====================

/// Check if a sponsor would approve a transaction
/// This is called off-chain by the sponsor server before signing
public fun verify_sponsorship(
    registry: &SponsorRegistry,
    sponsor: address,
    _user: address,
    service_id: ID,
    estimated_gas: u64,
    usage: &UserSponsorUsage,
    clock: &Clock,
): bool {
    if (!registry.sponsors.contains(sponsor)) {
        return false
    };

    let config = registry.sponsors.borrow(sponsor);

    // Check sponsor is active
    if (!config.active) {
        return false
    };

    // Check budget
    if (config.budget_remaining < estimated_gas) {
        return false
    };

    // Check service whitelist (empty = all services)
    if (!config.whitelisted_services.is_empty()) {
        let mut found = false;
        let mut i = 0;
        while (i < config.whitelisted_services.length()) {
            if (config.whitelisted_services[i] == service_id) {
                found = true;
                break
            };
            i = i + 1;
        };
        if (!found) {
            return false
        }
    };

    // Check user rate limit
    let current_hour = clock::timestamp_ms(clock) / MS_PER_HOUR;
    if (usage.sponsor == sponsor) {
        if (usage.current_hour == current_hour && usage.hourly_count >= config.user_rate_limit) {
            return false
        };
    };

    true
}

/// Record sponsorship usage (called after transaction completes)
public fun record_sponsorship(
    registry: &mut SponsorRegistry,
    usage: &mut UserSponsorUsage,
    sponsor: address,
    service_id: ID,
    gas_used: u64,
    clock: &Clock,
) {
    assert!(registry.sponsors.contains(sponsor), ESponsorNotRegistered);

    let config = registry.sponsors.borrow_mut(sponsor);
    config.budget_remaining = config.budget_remaining - gas_used;
    config.total_sponsored = config.total_sponsored + gas_used;

    // Update user usage
    let current_hour = clock::timestamp_ms(clock) / MS_PER_HOUR;
    if (usage.current_hour != current_hour) {
        usage.current_hour = current_hour;
        usage.hourly_count = 0;
    };
    usage.hourly_count = usage.hourly_count + 1;

    event::emit(SponsorshipUsed {
        sponsor,
        user: usage.user,
        service_id,
        gas_cost: gas_used,
    });
}

// ==================== User Usage Tracking ====================

/// Create usage tracker for a user
public fun create_user_usage(
    sponsor: address,
    clock: &Clock,
    ctx: &mut TxContext
): UserSponsorUsage {
    UserSponsorUsage {
        id: object::new(ctx),
        user: ctx.sender(),
        sponsor,
        hourly_count: 0,
        current_hour: clock::timestamp_ms(clock) / MS_PER_HOUR,
    }
}

// ==================== View Functions ====================

public fun sponsor_budget(registry: &SponsorRegistry, sponsor: address): u64 {
    if (!registry.sponsors.contains(sponsor)) {
        return 0
    };
    registry.sponsors.borrow(sponsor).budget_remaining
}

public fun sponsor_is_active(registry: &SponsorRegistry, sponsor: address): bool {
    if (!registry.sponsors.contains(sponsor)) {
        return false
    };
    registry.sponsors.borrow(sponsor).active
}

public fun sponsor_total_sponsored(registry: &SponsorRegistry, sponsor: address): u64 {
    if (!registry.sponsors.contains(sponsor)) {
        return 0
    };
    registry.sponsors.borrow(sponsor).total_sponsored
}

public fun user_hourly_usage(usage: &UserSponsorUsage): u64 {
    usage.hourly_count
}
