/// APEX Workflows - Composable PTB Patterns for AI Agents
///
/// This module demonstrates advanced PTB (Programmable Transaction Block) patterns
/// that combine multiple APEX features for real-world AI agent workflows.
///
/// ## Key Patterns
///
/// 1. **Verified Consumption + Seal Decryption** (Nautilus + Seal)
///    - TEE-verified metering ensures honest usage reporting
///    - Seal-encrypted content is only decryptable after verified payment
///
/// 2. **Authorized Agent Workflows**
///    - Human delegates spending authority to AI agent
///    - Agent executes multi-step workflows atomically
///
/// 3. **Service Discovery + Access**
///    - Query registry, purchase access, use service - all atomic
///
/// 4. **Streaming + Checkpoint Verification**
///    - Open stream, verified consumption checkpoints, close with proof
module apex_protocol::apex_workflows;

use sui::clock::{Self, Clock};
use sui::coin::Coin;
use sui::sui::SUI;
use sui::event;

use apex_protocol::apex_payments::{
    Self,
    ProtocolConfig,
    ServiceProvider,
    AccessCapability,
    PaymentStream,
    AgentAuthorization,
    TrustedMeter,
    ServiceRegistry,
};

// ==================== Error Codes ====================
const EWorkflowFailed: u64 = 0;
const EVerificationFailed: u64 = 1;
const EInsufficientAccess: u64 = 2;
const EServiceNotFound: u64 = 3;
const EMeterNotTrusted: u64 = 4;

// ==================== Workflow Result Types ====================

/// Result of a verified content access workflow
public struct VerifiedAccessResult has key, store {
    id: UID,
    /// Service that was accessed
    service_id: ID,
    /// Content ID that was verified for access
    content_id: vector<u8>,
    /// Units consumed
    units_consumed: u64,
    /// Meter that verified consumption
    meter_id: ID,
    /// Timestamp of verification
    verified_at: u64,
    /// Cryptographic proof (signature from meter)
    verification_proof: vector<u8>,
}

/// Receipt for a complete agent workflow execution
public struct WorkflowReceipt has key, store {
    id: UID,
    /// Authorization used
    auth_id: ID,
    /// Services accessed in order
    services_accessed: vector<ID>,
    /// Total cost
    total_cost: u64,
    /// Workflow start time
    started_at: u64,
    /// Workflow end time
    completed_at: u64,
}

/// Checkpoint in a streaming session with verification
public struct StreamCheckpoint has key, store {
    id: UID,
    /// Stream being checkpointed
    stream_id: ID,
    /// Units at checkpoint
    units_at_checkpoint: u64,
    /// Meter that verified
    meter_id: ID,
    /// Checkpoint timestamp
    timestamp: u64,
    /// Verification signature
    signature: vector<u8>,
}

// ==================== Events ====================

public struct VerifiedAccessCompleted has copy, drop {
    service_id: ID,
    content_id: vector<u8>,
    units: u64,
    meter_id: ID,
    timestamp: u64,
}

public struct AgentWorkflowExecuted has copy, drop {
    auth_id: ID,
    services_count: u64,
    total_cost: u64,
    duration_ms: u64,
}

public struct StreamCheckpointCreated has copy, drop {
    stream_id: ID,
    checkpoint_number: u64,
    units_consumed: u64,
    meter_id: ID,
}

// ==================== Workflow 1: Verified Consumption + Access ====================
//
// This workflow combines Nautilus TEE verification with access control:
// 1. Agent requests access to encrypted content
// 2. TEE meter verifies actual consumption
// 3. Payment is released based on verified usage
// 4. seal_approve can verify the access capability
//
// PTB Structure:
// [0] MoveCall: open_verified_access_session
// [1] MoveCall: seal_approve (dry run by Seal key servers)
// [2] ... agent does work with decrypted content ...
// [3] MoveCall: close_verified_access_session (with TEE signature)

/// Open a verified access session
/// Returns an AccessCapability that can be used with seal_approve
public fun open_verified_access_session(
    config: &mut ProtocolConfig,
    service: &mut ServiceProvider,
    meter: &TrustedMeter,
    payment: Coin<SUI>,
    units: u64,
    duration_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext
): AccessCapability {
    // Verify meter is trusted and active
    assert!(apex_payments::meter_is_active(meter), EMeterNotTrusted);

    // Purchase access capability
    let capability = apex_payments::purchase_access(
        config,
        service,
        payment,
        units,
        duration_ms,
        0, // no rate limit for verified sessions
        clock,
        ctx
    );

    capability
}

/// Close verified access session with TEE-signed consumption report
/// This is called after the agent finishes using the service
public fun close_verified_access_session(
    capability: &mut AccessCapability,
    service: &ServiceProvider,
    meter: &TrustedMeter,
    units_consumed: u64,
    content_id: vector<u8>,
    timestamp: u64,
    signature: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext
): VerifiedAccessResult {
    use sui::ed25519;
    use sui::bcs;

    // Verify meter is active
    assert!(apex_payments::meter_is_active(meter), EMeterNotTrusted);

    // Build verification message
    let mut message = apex_payments::capability_service_id(capability).to_bytes();
    vector::append(&mut message, bcs::to_bytes(&units_consumed));
    vector::append(&mut message, bcs::to_bytes(&timestamp));
    vector::append(&mut message, content_id);

    // Verify signature from TEE
    let is_valid = ed25519::ed25519_verify(
        &signature,
        &apex_payments::meter_pubkey(meter),
        &message
    );
    assert!(is_valid, EVerificationFailed);

    // Verify timestamp is recent
    let now = clock::timestamp_ms(clock);
    assert!(now >= timestamp && now - timestamp < 300_000, EVerificationFailed);

    // Consume the verified units from capability
    let success = apex_payments::use_access(
        capability,
        service,
        units_consumed,
        clock,
        ctx
    );
    assert!(success, EWorkflowFailed);

    let result = VerifiedAccessResult {
        id: object::new(ctx),
        service_id: object::id(service),
        content_id,
        units_consumed,
        meter_id: object::id(meter),
        verified_at: now,
        verification_proof: signature,
    };

    event::emit(VerifiedAccessCompleted {
        service_id: object::id(service),
        content_id: result.content_id,
        units: units_consumed,
        meter_id: object::id(meter),
        timestamp: now,
    });

    result
}

// ==================== Workflow 2: Authorized Multi-Service Access ====================
//
// Human owner pre-authorizes agent to access multiple services.
// Agent executes atomic multi-step workflows.
//
// PTB Structure:
// [0] MoveCall: begin_authorized_workflow
// [1] MoveCall: authorized_purchase (service A)
// [2] MoveCall: use_access (service A)
// [3] MoveCall: authorized_purchase (service B)
// [4] MoveCall: use_access (service B)
// [5] MoveCall: complete_authorized_workflow
// [6] TransferObjects [receipt] -> agent

/// Begin an authorized workflow - validates authorization is valid
public fun begin_authorized_workflow(
    auth: &AgentAuthorization,
    clock: &Clock,
    _ctx: &TxContext
): (u64, u64) {
    // Verify authorization is valid and not paused
    assert!(!apex_payments::authorization_is_paused(auth), EWorkflowFailed);

    // Return start time and daily remaining for tracking
    (clock::timestamp_ms(clock), apex_payments::authorization_daily_remaining(auth))
}

/// Complete an authorized workflow - creates receipt
public fun complete_authorized_workflow(
    auth: &AgentAuthorization,
    services_accessed: vector<ID>,
    start_cost_remaining: u64,
    started_at: u64,
    clock: &Clock,
    ctx: &mut TxContext
): WorkflowReceipt {
    let now = clock::timestamp_ms(clock);
    let end_cost_remaining = apex_payments::authorization_daily_remaining(auth);
    let total_cost = if (start_cost_remaining > end_cost_remaining) {
        start_cost_remaining - end_cost_remaining
    } else {
        0
    };

    let receipt = WorkflowReceipt {
        id: object::new(ctx),
        auth_id: object::id(auth),
        services_accessed,
        total_cost,
        started_at,
        completed_at: now,
    };

    event::emit(AgentWorkflowExecuted {
        auth_id: object::id(auth),
        services_count: vector::length(&receipt.services_accessed),
        total_cost,
        duration_ms: now - started_at,
    });

    receipt
}

// ==================== Workflow 3: Registry Discovery + Access ====================
//
// Agent discovers service from registry, purchases access, uses it - atomically.
//
// PTB Structure:
// [0] MoveCall: lookup_service_by_category (returns service info)
// [1] MoveCall: purchase_access (with the discovered service)
// [2] MoveCall: use_access
// [3] TransferObjects

/// Lookup a service by category from registry
/// Returns (service_id, name, price, featured) or aborts if not found
public fun lookup_service_by_category(
    registry: &ServiceRegistry,
    category: vector<u8>,
): (ID, vector<u8>, u64, bool) {
    let count = apex_payments::registry_count(registry);
    let mut i = 0;
    while (i < count) {
        let (id, name, svc_category, price, featured) = apex_payments::registry_get(registry, i);
        if (svc_category == category) {
            return (id, name, price, featured)
        };
        i = i + 1;
    };
    abort EServiceNotFound
}

/// Lookup featured services only
public fun lookup_featured_service(
    registry: &ServiceRegistry,
): (ID, vector<u8>, u64) {
    let count = apex_payments::registry_count(registry);
    let mut i = 0;
    while (i < count) {
        let (id, name, _category, price, featured) = apex_payments::registry_get(registry, i);
        if (featured) {
            return (id, name, price)
        };
        i = i + 1;
    };
    abort EServiceNotFound
}

// ==================== Workflow 4: Streaming with Verified Checkpoints ====================
//
// For long-running consumption (LLM inference, compute jobs), create
// periodic checkpoints verified by TEE to ensure honest accounting.
//
// PTB Structure (checkpoint):
// [0] MoveCall: create_stream_checkpoint
//
// This can be called periodically during a streaming session

/// Create a verified checkpoint in a streaming session
public fun create_stream_checkpoint(
    stream: &PaymentStream,
    meter: &TrustedMeter,
    units_at_checkpoint: u64,
    signature: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext
): StreamCheckpoint {
    use sui::ed25519;
    use sui::bcs;

    // Verify meter is active
    assert!(apex_payments::meter_is_active(meter), EMeterNotTrusted);

    let timestamp = clock::timestamp_ms(clock);

    // Build checkpoint message: stream_id || units || timestamp
    let mut message = object::id(stream).to_bytes();
    vector::append(&mut message, bcs::to_bytes(&units_at_checkpoint));
    vector::append(&mut message, bcs::to_bytes(&timestamp));

    // Verify TEE signature
    let is_valid = ed25519::ed25519_verify(
        &signature,
        &apex_payments::meter_pubkey(meter),
        &message
    );
    assert!(is_valid, EVerificationFailed);

    let checkpoint = StreamCheckpoint {
        id: object::new(ctx),
        stream_id: object::id(stream),
        units_at_checkpoint,
        meter_id: object::id(meter),
        timestamp,
        signature,
    };

    event::emit(StreamCheckpointCreated {
        stream_id: object::id(stream),
        checkpoint_number: 0, // Would track this in real implementation
        units_consumed: units_at_checkpoint,
        meter_id: object::id(meter),
    });

    checkpoint
}

// ==================== Workflow 5: Atomic Seal Access Verification ====================
//
// This workflow pattern is used for Seal key server dry_run verification.
// It validates that an agent has valid access before Seal releases decryption keys.
//
// The PTB is executed as dry_run_transaction_block by Seal key servers:
// [0] MoveCall: verify_seal_access_atomic
// If this succeeds (doesn't abort), Seal provides decryption keys.

/// Atomic verification for Seal access - combines capability + meter verification
/// Used by Seal key servers to verify access before releasing keys
entry fun verify_seal_access_atomic(
    capability: &AccessCapability,
    service: &ServiceProvider,
    meter: &TrustedMeter,
    content_id: vector<u8>,
    min_units: u64,
    recent_verification_signature: vector<u8>,
    recent_verification_timestamp: u64,
    clock: &Clock,
) {
    use sui::ed25519;
    use sui::bcs;

    // 1. Verify capability is valid for service
    assert!(apex_payments::capability_service_id(capability) == object::id(service), EWorkflowFailed);

    // 2. Verify capability hasn't expired
    let expires_at = apex_payments::capability_expires_at(capability);
    let now = clock::timestamp_ms(clock);
    if (expires_at > 0) {
        assert!(now <= expires_at, EWorkflowFailed);
    };

    // 3. Verify sufficient units
    assert!(apex_payments::capability_remaining(capability) >= min_units, EInsufficientAccess);

    // 4. Verify service is active
    assert!(apex_payments::service_is_active(service), EWorkflowFailed);

    // 5. Verify meter is trusted
    assert!(apex_payments::meter_is_active(meter), EMeterNotTrusted);

    // 6. Verify recent TEE attestation (proves capability holder is actually using a trusted environment)
    // Message format: capability_id || content_id || timestamp
    let mut message = object::id(capability).to_bytes();
    vector::append(&mut message, content_id);
    vector::append(&mut message, bcs::to_bytes(&recent_verification_timestamp));

    let is_valid = ed25519::ed25519_verify(
        &recent_verification_signature,
        &apex_payments::meter_pubkey(meter),
        &message
    );
    assert!(is_valid, EVerificationFailed);

    // 7. Verify timestamp is recent (within 5 minutes)
    assert!(now >= recent_verification_timestamp, EVerificationFailed);
    assert!(now - recent_verification_timestamp < 300_000, EVerificationFailed);

    // 8. Verify content_id namespace matches service
    let namespace = object::id(service).to_bytes();
    let namespace_len = vector::length(&namespace);
    let content_len = vector::length(&content_id);
    assert!(content_len >= namespace_len, EWorkflowFailed);

    let mut i = 0;
    while (i < namespace_len) {
        assert!(*vector::borrow(&namespace, i) == *vector::borrow(&content_id, i), EWorkflowFailed);
        i = i + 1;
    };

    // All checks passed - Seal key servers can release decryption keys
}

// ==================== View Functions ====================

public fun verified_result_service_id(result: &VerifiedAccessResult): ID {
    result.service_id
}

public fun verified_result_units_consumed(result: &VerifiedAccessResult): u64 {
    result.units_consumed
}

public fun verified_result_meter_id(result: &VerifiedAccessResult): ID {
    result.meter_id
}

public fun workflow_receipt_auth_id(receipt: &WorkflowReceipt): ID {
    receipt.auth_id
}

public fun workflow_receipt_total_cost(receipt: &WorkflowReceipt): u64 {
    receipt.total_cost
}

public fun workflow_receipt_services_count(receipt: &WorkflowReceipt): u64 {
    vector::length(&receipt.services_accessed)
}

public fun checkpoint_stream_id(checkpoint: &StreamCheckpoint): ID {
    checkpoint.stream_id
}

public fun checkpoint_units(checkpoint: &StreamCheckpoint): u64 {
    checkpoint.units_at_checkpoint
}

public fun checkpoint_meter_id(checkpoint: &StreamCheckpoint): ID {
    checkpoint.meter_id
}

// ==================== Cleanup Functions ====================

public fun burn_verified_result(result: VerifiedAccessResult) {
    let VerifiedAccessResult {
        id,
        service_id: _,
        content_id: _,
        units_consumed: _,
        meter_id: _,
        verified_at: _,
        verification_proof: _,
    } = result;
    object::delete(id);
}

public fun burn_workflow_receipt(receipt: WorkflowReceipt) {
    let WorkflowReceipt {
        id,
        auth_id: _,
        services_accessed: _,
        total_cost: _,
        started_at: _,
        completed_at: _,
    } = receipt;
    object::delete(id);
}

public fun burn_checkpoint(checkpoint: StreamCheckpoint) {
    let StreamCheckpoint {
        id,
        stream_id: _,
        units_at_checkpoint: _,
        meter_id: _,
        timestamp: _,
        signature: _,
    } = checkpoint;
    object::delete(id);
}

// ==================== Test Helpers ====================

#[test_only]
public fun create_verified_result_for_testing(
    service_id: ID,
    content_id: vector<u8>,
    units_consumed: u64,
    meter_id: ID,
    ctx: &mut TxContext
): VerifiedAccessResult {
    VerifiedAccessResult {
        id: object::new(ctx),
        service_id,
        content_id,
        units_consumed,
        meter_id,
        verified_at: 0,
        verification_proof: vector::empty(),
    }
}
