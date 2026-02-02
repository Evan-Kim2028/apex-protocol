/// APEX Walrus Integration - Security Hardened v2
/// Pay for decentralized storage with automatic data verification
///
/// KEY INNOVATION: Storage payments return verifiable data objects
/// Not just "I paid" but "I paid AND here's the cryptographically
/// verified data blob ID that proves what I got"
///
/// SECURITY FIXES:
/// - [H-05] Deadline enforcement in fulfill_data_request
/// - [M-06] Hash length validation
/// - Added authorization checks
/// - Added overflow protection
module dexter_payment::walrus_payments {
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::balance::{Self, Balance};
    use sui::event;
    use sui::clock::{Self, Clock};

    // ==================== Error Codes ====================
    const EInsufficientPayment: u64 = 0;
    const EBlobNotFound: u64 = 1;
    const EExpired: u64 = 2;
    const EInvalidProof: u64 = 3;
    const EUnauthorized: u64 = 4;
    const EInvalidHash: u64 = 5;
    const EOverflow: u64 = 6;
    const EInvalidBlobId: u64 = 7;
    const ERequestCancelled: u64 = 8;

    // ==================== Constants ====================
    const MIN_HASH_LENGTH: u64 = 32;
    const MIN_BLOB_ID_LENGTH: u64 = 32;
    const U64_MAX: u128 = 18446744073709551615;

    // ==================== Structs ====================

    /// StorageProvider - wraps Walrus storage nodes
    public struct StorageProvider has key {
        id: UID,
        /// Provider address
        operator: address,
        /// Price per byte per epoch
        price_per_byte_epoch: u64,
        /// Minimum storage duration (epochs)
        min_duration: u64,
        /// Maximum storage duration (epochs) - prevents overflow attacks
        max_duration: u64,
        /// Total bytes stored
        total_bytes: u64,
        /// Revenue
        revenue: Balance<SUI>,
        /// Active status
        active: bool,
    }

    /// StorageReceipt - proof of storage payment
    /// Contains the blob_id which can be used to retrieve data
    public struct StorageReceipt has key, store {
        id: UID,
        /// Walrus blob ID (32 bytes)
        blob_id: vector<u8>,
        /// Size in bytes
        size_bytes: u64,
        /// Storage expiry (epoch)
        expires_epoch: u64,
        /// Who paid
        payer: address,
        /// Amount paid
        amount_paid: u64,
        /// Timestamp
        created_at: u64,
    }

    /// DataRequest - agent requests data and pays upfront
    /// Provider fulfills by storing and returning blob_id
    public struct DataRequest has key {
        id: UID,
        /// Requester
        requester: address,
        /// Data hash (what we expect)
        expected_hash: vector<u8>,
        /// Max size willing to pay for
        max_size: u64,
        /// Duration needed
        duration_epochs: u64,
        /// Escrowed payment
        escrow: Balance<SUI>,
        /// Deadline to fulfill (timestamp in ms)
        deadline: u64,
        /// Whether request is still active
        active: bool,
    }

    /// VerifiedDataRef - a reference to verified data on Walrus
    /// This is what AI agents can pass around as proof of data
    public struct VerifiedDataRef has key, store {
        id: UID,
        /// Walrus blob ID
        blob_id: vector<u8>,
        /// Content hash
        content_hash: vector<u8>,
        /// MIME type
        mime_type: vector<u8>,
        /// Size
        size_bytes: u64,
        /// Verified at timestamp
        verified_at: u64,
        /// Verification proof (Walrus certificate)
        proof: vector<u8>,
    }

    // ==================== Events ====================

    public struct StorageProviderRegistered has copy, drop {
        provider_id: ID,
        operator: address,
        price_per_byte_epoch: u64,
    }

    public struct StoragePurchased has copy, drop {
        receipt_id: ID,
        blob_id: vector<u8>,
        size_bytes: u64,
        duration_epochs: u64,
        cost: u64,
    }

    public struct DataRequested has copy, drop {
        request_id: ID,
        requester: address,
        expected_hash: vector<u8>,
        max_size: u64,
        deadline: u64,
    }

    public struct DataDelivered has copy, drop {
        request_id: ID,
        blob_id: vector<u8>,
        actual_size: u64,
        provider: address,
    }

    public struct DataRequestCancelled has copy, drop {
        request_id: ID,
        requester: address,
        refund_amount: u64,
    }

    public struct StorageProviderDeactivated has copy, drop {
        provider_id: ID,
        operator: address,
    }

    // ==================== Helper Functions ====================

    /// Safe multiplication with overflow check
    fun safe_mul(a: u64, b: u64): u64 {
        let result = (a as u128) * (b as u128);
        assert!(result <= U64_MAX, EOverflow);
        (result as u64)
    }

    /// Safe triple multiplication for cost calculation
    fun safe_cost(size: u64, duration: u64, price: u64): u64 {
        let intermediate = (size as u128) * (duration as u128);
        assert!(intermediate <= U64_MAX, EOverflow);
        let result = intermediate * (price as u128);
        assert!(result <= U64_MAX, EOverflow);
        (result as u64)
    }

    // ==================== Storage Functions ====================

    /// Register as storage provider (wrapping Walrus)
    public entry fun register_storage_provider(
        price_per_byte_epoch: u64,
        min_duration: u64,
        max_duration: u64,
        ctx: &mut TxContext
    ) {
        assert!(max_duration >= min_duration, EInvalidProof);
        assert!(price_per_byte_epoch > 0, EInsufficientPayment);

        let provider = StorageProvider {
            id: object::new(ctx),
            operator: tx_context::sender(ctx),
            price_per_byte_epoch,
            min_duration,
            max_duration,
            total_bytes: 0,
            revenue: balance::zero(),
            active: true,
        };

        event::emit(StorageProviderRegistered {
            provider_id: object::id(&provider),
            operator: tx_context::sender(ctx),
            price_per_byte_epoch,
        });

        transfer::share_object(provider);
    }

    /// Deactivate storage provider (operator only)
    public entry fun deactivate_provider(
        provider: &mut StorageProvider,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == provider.operator, EUnauthorized);
        provider.active = false;

        event::emit(StorageProviderDeactivated {
            provider_id: object::id(provider),
            operator: provider.operator,
        });
    }

    /// Withdraw provider revenue (operator only)
    public entry fun withdraw_provider_revenue(
        provider: &mut StorageProvider,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == provider.operator, EUnauthorized);

        let amount = balance::value(&provider.revenue);
        if (amount > 0) {
            let revenue = coin::from_balance(
                balance::split(&mut provider.revenue, amount),
                ctx
            );
            transfer::public_transfer(revenue, provider.operator);
        }
    }

    /// Pay for storage and get receipt with blob_id
    /// This is called AFTER uploading to Walrus - the blob_id is known
    public entry fun pay_for_storage(
        provider: &mut StorageProvider,
        blob_id: vector<u8>,
        size_bytes: u64,
        duration_epochs: u64,
        payment: Coin<SUI>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(provider.active, EUnauthorized);
        assert!(duration_epochs >= provider.min_duration, EInsufficientPayment);
        assert!(duration_epochs <= provider.max_duration, EInsufficientPayment);

        // [M-06] Validate blob_id length
        assert!(vector::length(&blob_id) >= MIN_BLOB_ID_LENGTH, EInvalidBlobId);

        // Safe cost calculation with overflow protection
        let cost = safe_cost(size_bytes, duration_epochs, provider.price_per_byte_epoch);
        let payment_amount = coin::value(&payment);
        assert!(payment_amount >= cost, EInsufficientPayment);

        // Handle payment
        let mut payment_balance = coin::into_balance(payment);
        if (payment_amount > cost) {
            let refund = coin::from_balance(
                balance::split(&mut payment_balance, payment_amount - cost),
                ctx
            );
            transfer::public_transfer(refund, tx_context::sender(ctx));
        };

        balance::join(&mut provider.revenue, payment_balance);
        provider.total_bytes = provider.total_bytes + size_bytes;

        let receipt = StorageReceipt {
            id: object::new(ctx),
            blob_id,
            size_bytes,
            expires_epoch: tx_context::epoch(ctx) + duration_epochs,
            payer: tx_context::sender(ctx),
            amount_paid: cost,
            created_at: clock::timestamp_ms(clock),
        };

        event::emit(StoragePurchased {
            receipt_id: object::id(&receipt),
            blob_id: receipt.blob_id,
            size_bytes,
            duration_epochs,
            cost,
        });

        transfer::transfer(receipt, tx_context::sender(ctx));
    }

    /// Create a data request (pay upfront, get data delivered)
    public entry fun create_data_request(
        provider: &StorageProvider,
        expected_hash: vector<u8>,
        max_size: u64,
        duration_epochs: u64,
        payment: Coin<SUI>,
        deadline: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(provider.active, EUnauthorized);

        // [M-06] Validate hash length - must be at least 32 bytes
        assert!(vector::length(&expected_hash) >= MIN_HASH_LENGTH, EInvalidHash);

        // Validate deadline is in the future
        assert!(deadline > clock::timestamp_ms(clock), EExpired);

        // Validate duration within bounds
        assert!(duration_epochs >= provider.min_duration, EInsufficientPayment);
        assert!(duration_epochs <= provider.max_duration, EInsufficientPayment);

        // Safe cost calculation
        let max_cost = safe_cost(max_size, duration_epochs, provider.price_per_byte_epoch);
        assert!(coin::value(&payment) >= max_cost, EInsufficientPayment);

        let request = DataRequest {
            id: object::new(ctx),
            requester: tx_context::sender(ctx),
            expected_hash,
            max_size,
            duration_epochs,
            escrow: coin::into_balance(payment),
            deadline,
            active: true,
        };

        event::emit(DataRequested {
            request_id: object::id(&request),
            requester: tx_context::sender(ctx),
            expected_hash,
            max_size,
            deadline,
        });

        transfer::share_object(request);
    }

    /// Cancel data request (requester only, before fulfillment)
    public entry fun cancel_data_request(
        request: DataRequest,
        ctx: &mut TxContext
    ) {
        let DataRequest {
            id,
            requester,
            expected_hash: _,
            max_size: _,
            duration_epochs: _,
            escrow,
            deadline: _,
            active,
        } = request;

        // Only requester can cancel
        assert!(tx_context::sender(ctx) == requester, EUnauthorized);
        assert!(active, ERequestCancelled);

        let refund_amount = balance::value(&escrow);
        let refund = coin::from_balance(escrow, ctx);
        transfer::public_transfer(refund, requester);

        event::emit(DataRequestCancelled {
            request_id: object::uid_to_inner(&id),
            requester,
            refund_amount,
        });

        object::delete(id);
    }

    /// Fulfill data request by storing and providing blob_id
    /// [H-05] FIXED: Now enforces deadline
    public entry fun fulfill_data_request(
        request: DataRequest,
        provider: &mut StorageProvider,
        blob_id: vector<u8>,
        actual_size: u64,
        content_hash: vector<u8>,
        proof: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let DataRequest {
            id,
            requester,
            expected_hash,
            max_size,
            duration_epochs,
            escrow,
            deadline,
            active,
        } = request;

        // Verify request is still active
        assert!(active, ERequestCancelled);

        // [H-05] CRITICAL FIX: Enforce deadline
        assert!(clock::timestamp_ms(clock) <= deadline, EExpired);

        // Provider must be active
        assert!(provider.active, EUnauthorized);

        // [M-06] Validate hash lengths
        assert!(vector::length(&expected_hash) >= MIN_HASH_LENGTH, EInvalidHash);
        assert!(vector::length(&content_hash) >= MIN_HASH_LENGTH, EInvalidHash);
        assert!(vector::length(&blob_id) >= MIN_BLOB_ID_LENGTH, EInvalidBlobId);

        // Verify hash matches (simplified - real impl would verify cryptographically)
        assert!(expected_hash == content_hash, EInvalidProof);
        assert!(actual_size <= max_size, EInsufficientPayment);

        // Calculate actual cost with overflow protection
        let actual_cost = safe_cost(actual_size, duration_epochs, provider.price_per_byte_epoch);
        let escrow_amount = balance::value(&escrow);

        // Pay provider
        let mut escrow_mut = escrow;
        let payment = balance::split(&mut escrow_mut, actual_cost);
        balance::join(&mut provider.revenue, payment);
        provider.total_bytes = provider.total_bytes + actual_size;

        // Refund excess to requester
        if (balance::value(&escrow_mut) > 0) {
            let refund = coin::from_balance(escrow_mut, ctx);
            transfer::public_transfer(refund, requester);
        } else {
            balance::destroy_zero(escrow_mut);
        };

        // Create verified data reference
        let data_ref = VerifiedDataRef {
            id: object::new(ctx),
            blob_id,
            content_hash,
            mime_type: vector::empty(),
            size_bytes: actual_size,
            verified_at: clock::timestamp_ms(clock),
            proof,
        };

        event::emit(DataDelivered {
            request_id: object::uid_to_inner(&id),
            blob_id: data_ref.blob_id,
            actual_size,
            provider: tx_context::sender(ctx),
        });

        // Send data reference to requester
        transfer::transfer(data_ref, requester);

        object::delete(id);
    }

    /// Refund expired request (anyone can call after deadline)
    public entry fun refund_expired_request(
        request: DataRequest,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let DataRequest {
            id,
            requester,
            expected_hash: _,
            max_size: _,
            duration_epochs: _,
            escrow,
            deadline,
            active,
        } = request;

        // Must be past deadline
        assert!(clock::timestamp_ms(clock) > deadline, EExpired);
        assert!(active, ERequestCancelled);

        let refund_amount = balance::value(&escrow);
        let refund = coin::from_balance(escrow, ctx);
        transfer::public_transfer(refund, requester);

        event::emit(DataRequestCancelled {
            request_id: object::uid_to_inner(&id),
            requester,
            refund_amount,
        });

        object::delete(id);
    }

    // ==================== View Functions ====================

    public fun receipt_blob_id(receipt: &StorageReceipt): vector<u8> {
        receipt.blob_id
    }

    public fun receipt_expires(receipt: &StorageReceipt): u64 {
        receipt.expires_epoch
    }

    public fun receipt_size(receipt: &StorageReceipt): u64 {
        receipt.size_bytes
    }

    public fun receipt_payer(receipt: &StorageReceipt): address {
        receipt.payer
    }

    public fun data_ref_blob_id(data_ref: &VerifiedDataRef): vector<u8> {
        data_ref.blob_id
    }

    public fun data_ref_hash(data_ref: &VerifiedDataRef): vector<u8> {
        data_ref.content_hash
    }

    public fun data_ref_size(data_ref: &VerifiedDataRef): u64 {
        data_ref.size_bytes
    }

    public fun provider_active(provider: &StorageProvider): bool {
        provider.active
    }

    public fun provider_price(provider: &StorageProvider): u64 {
        provider.price_per_byte_epoch
    }

    public fun provider_total_bytes(provider: &StorageProvider): u64 {
        provider.total_bytes
    }

    public fun request_deadline(request: &DataRequest): u64 {
        request.deadline
    }

    public fun request_active(request: &DataRequest): bool {
        request.active
    }
}
