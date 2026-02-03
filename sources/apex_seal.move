/// APEX Seal - Encrypted Content Access Control
///
/// This module integrates Seal's decentralized secrets management with APEX payments.
/// It enables cryptographically enforced access control:
///
/// 1. Service providers encrypt content with Seal
/// 2. Buyers purchase AccessCapability via APEX
/// 3. seal_approve functions verify capability ownership
/// 4. Seal key servers provide decryption keys only to valid capability holders
///
/// This is MORE secure than standard APEX because:
/// - Content is actually encrypted, not just "honor system" gated
/// - Access control is cryptographically enforced by key servers
/// - No trust required in the service provider's API
module apex_protocol::apex_seal;

use sui::clock::{Self, Clock};
use apex_protocol::apex_payments::{
    Self,
    ServiceProvider,
    AccessCapability,
};

// ==================== Error Codes ====================
const ENoAccess: u64 = 0;
const EWrongVersion: u64 = 1;
// EAlreadyInitialized (2) reserved for future singleton pattern implementation

// ==================== Constants ====================
const VERSION: u64 = 1;

// ==================== Package Version Management ====================
// Following Seal's pattern for upgradeable access control

/// Manages the version of the package for seal_approve evaluation
public struct PackageVersion has key {
    id: UID,
    version: u64,
}

/// Capability to upgrade PackageVersion
public struct PackageVersionCap has key {
    id: UID,
}

fun init(ctx: &mut TxContext) {
    transfer::share_object(PackageVersion {
        id: object::new(ctx),
        version: VERSION,
    });
    transfer::transfer(PackageVersionCap { id: object::new(ctx) }, ctx.sender());
}

/// Initialize Seal module for sandbox testing (call once per deployment)
public fun initialize_seal(ctx: &mut TxContext) {
    transfer::share_object(PackageVersion {
        id: object::new(ctx),
        version: VERSION,
    });
    transfer::transfer(PackageVersionCap { id: object::new(ctx) }, ctx.sender());
}

// ==================== Seal Access Control ====================

/// Check if an AccessCapability grants access to a specific encrypted content ID
///
/// Key format: [service_id][content_nonce]
/// - service_id: The ID of the ServiceProvider
/// - content_nonce: Random bytes identifying specific content
///
/// This allows a single service to have multiple encrypted content items,
/// all accessible with the same AccessCapability.
fun check_access_policy(
    content_id: vector<u8>,
    pkg_version: &PackageVersion,
    capability: &AccessCapability,
    service: &ServiceProvider,
    clock: &Clock,
): bool {
    // Check package version for upgrade safety
    assert!(pkg_version.version == VERSION, EWrongVersion);

    // Verify capability matches the service
    if (apex_payments::capability_service_id(capability) != object::id(service)) {
        return false
    };

    // Check capability hasn't expired
    let expires_at = apex_payments::capability_expires_at(capability);
    if (expires_at > 0 && clock::timestamp_ms(clock) > expires_at) {
        return false
    };

    // Check capability has remaining units
    if (apex_payments::capability_remaining(capability) == 0) {
        return false
    };

    // Check content_id has the service ID as prefix (namespace validation)
    let namespace = object::id(service).to_bytes();
    let mut i = 0;
    if (namespace.length() > content_id.length()) {
        return false
    };
    while (i < namespace.length()) {
        if (namespace[i] != content_id[i]) {
            return false
        };
        i = i + 1;
    };

    true
}

/// Seal approval function - called by Seal key servers
///
/// When a user requests decryption keys for encrypted content, Seal key servers
/// call this function via dry_run_transaction_block. If it succeeds (doesn't abort),
/// the key servers provide the decryption key.
///
/// This enforces: "Only AccessCapability holders can decrypt service content"
entry fun seal_approve(
    content_id: vector<u8>,
    pkg_version: &PackageVersion,
    capability: &AccessCapability,
    service: &ServiceProvider,
    clock: &Clock,
) {
    assert!(
        check_access_policy(content_id, pkg_version, capability, service, clock),
        ENoAccess
    );
}

/// Seal approval that also verifies minimum remaining units
///
/// Use this when content requires a certain "weight" of access
entry fun seal_approve_with_units(
    content_id: vector<u8>,
    pkg_version: &PackageVersion,
    capability: &AccessCapability,
    service: &ServiceProvider,
    min_units: u64,
    clock: &Clock,
) {
    assert!(
        check_access_policy(content_id, pkg_version, capability, service, clock),
        ENoAccess
    );
    assert!(apex_payments::capability_remaining(capability) >= min_units, ENoAccess);
}

// ==================== Content Namespace Helpers ====================

/// Generate a content ID for a specific piece of content under a service
///
/// In practice, this would be called off-chain when encrypting content:
/// content_id = service_id.to_bytes() + random_nonce
///
/// This view function helps verify the format
public fun create_content_id(service: &ServiceProvider, nonce: vector<u8>): vector<u8> {
    let mut content_id = object::id(service).to_bytes();
    let mut i = 0;
    while (i < nonce.length()) {
        content_id.push_back(nonce[i]);
        i = i + 1;
    };
    content_id
}

/// Verify a content ID belongs to a service's namespace
public fun verify_content_namespace(content_id: &vector<u8>, service: &ServiceProvider): bool {
    let namespace = object::id(service).to_bytes();
    let mut i = 0;
    if (namespace.length() > content_id.length()) {
        return false
    };
    while (i < namespace.length()) {
        if (namespace[i] != content_id[i]) {
            return false
        };
        i = i + 1;
    };
    true
}

// ==================== Test Helpers ====================

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx)
}

#[test_only]
public fun create_for_testing(ctx: &mut TxContext): (PackageVersion, PackageVersionCap) {
    let pkg_version = PackageVersion {
        id: object::new(ctx),
        version: VERSION,
    };
    (pkg_version, PackageVersionCap { id: object::new(ctx) })
}

#[test_only]
public fun destroy_for_testing(pkg_version: PackageVersion, pkg_version_cap: PackageVersionCap) {
    let PackageVersion { id, .. } = pkg_version;
    object::delete(id);
    let PackageVersionCap { id, .. } = pkg_version_cap;
    object::delete(id);
}
