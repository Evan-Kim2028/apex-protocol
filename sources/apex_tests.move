/// APEX Protocol Tests - Local Move VM Execution
///
/// These tests run via `sui move test` and execute in the local Move VM.
/// They verify all protocol functionality works correctly before testnet deployment.
#[test_only]
module dexter_payment::apex_tests;

use sui::test_scenario::{Self as ts, Scenario};
use sui::test_utils;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::sui::SUI;

use dexter_payment::apex_payments::{
    Self,
    AdminCap,
    ProtocolConfig,
    ServiceProvider,
    AccessCapability,
    PaymentStream,
    AgentWallet,
    ShieldSession,
};

use dexter_payment::apex_trading::{
    Self,
    SwapIntent,
    TradingService,
    IntentReceipt,
};

// ==================== Test Addresses ====================
const ADMIN: address = @0xAD;
const PROVIDER: address = @0x1;
const AGENT: address = @0x2;
const EXECUTOR: address = @0x3;
const RECIPIENT: address = @0x4;

// ==================== Test Constants ====================
const MIST_PER_SUI: u64 = 1_000_000_000;
const REGISTRATION_FEE: u64 = 100_000_000; // 0.1 SUI

// ==================== Helper Functions ====================

/// Initialize protocol - creates AdminCap and ProtocolConfig
fun setup_protocol(scenario: &mut Scenario) {
    ts::next_tx(scenario, ADMIN);
    {
        apex_payments::init_for_testing(ts::ctx(scenario));
    };
}

/// Create a test clock at a specific timestamp
fun create_clock(scenario: &mut Scenario, timestamp_ms: u64): Clock {
    ts::next_tx(scenario, ADMIN);
    clock::create_for_testing(ts::ctx(scenario))
}

/// Mint SUI for testing
fun mint_sui(amount: u64, ctx: &mut tx_context::TxContext): Coin<SUI> {
    coin::mint_for_testing<SUI>(amount, ctx)
}

// ==================== Protocol Initialization Tests ====================

#[test]
fun test_protocol_initialization() {
    let mut scenario = ts::begin(ADMIN);

    // Initialize protocol
    setup_protocol(&mut scenario);

    // Verify admin cap was created and transferred to admin
    ts::next_tx(&mut scenario, ADMIN);
    {
        assert!(ts::has_most_recent_for_sender<AdminCap>(&scenario), 0);
    };

    // Verify config was shared
    ts::next_tx(&mut scenario, ADMIN);
    {
        let config = ts::take_shared<ProtocolConfig>(&scenario);
        assert!(!apex_payments::protocol_is_paused(&config), 1);
        ts::return_shared(config);
    };

    ts::end(scenario);
}

// ==================== Service Registration Tests ====================

#[test]
fun test_register_service() {
    let mut scenario = ts::begin(ADMIN);
    setup_protocol(&mut scenario);

    // Provider registers a service
    ts::next_tx(&mut scenario, PROVIDER);
    {
        let mut config = ts::take_shared<ProtocolConfig>(&scenario);
        let registration_payment = mint_sui(REGISTRATION_FEE, ts::ctx(&mut scenario));

        apex_payments::register_service(
            &mut config,
            b"Test API Service",
            b"A test API endpoint for AI agents",
            10_000_000, // 0.01 SUI per unit
            registration_payment,
            ts::ctx(&mut scenario)
        );

        ts::return_shared(config);
    };

    // Verify service was created
    ts::next_tx(&mut scenario, PROVIDER);
    {
        let service = ts::take_shared<ServiceProvider>(&scenario);
        assert!(apex_payments::service_is_active(&service), 0);
        assert!(apex_payments::service_price(&service) == 10_000_000, 1);
        ts::return_shared(service);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = apex_payments::EInsufficientBalance)]
fun test_register_service_insufficient_fee() {
    let mut scenario = ts::begin(ADMIN);
    setup_protocol(&mut scenario);

    // Try to register with insufficient fee
    ts::next_tx(&mut scenario, PROVIDER);
    {
        let mut config = ts::take_shared<ProtocolConfig>(&scenario);
        let registration_payment = mint_sui(50_000_000, ts::ctx(&mut scenario)); // Only 0.05 SUI

        apex_payments::register_service(
            &mut config,
            b"Test Service",
            b"Description",
            10_000_000,
            registration_payment,
            ts::ctx(&mut scenario)
        );

        ts::return_shared(config);
    };

    ts::end(scenario);
}

// ==================== Access Capability Tests ====================

#[test]
fun test_purchase_access() {
    let mut scenario = ts::begin(ADMIN);
    setup_protocol(&mut scenario);

    // Register service
    ts::next_tx(&mut scenario, PROVIDER);
    {
        let mut config = ts::take_shared<ProtocolConfig>(&scenario);
        let registration_payment = mint_sui(REGISTRATION_FEE, ts::ctx(&mut scenario));

        apex_payments::register_service(
            &mut config,
            b"API Service",
            b"Test service",
            10_000_000, // 0.01 SUI per unit
            registration_payment,
            ts::ctx(&mut scenario)
        );

        ts::return_shared(config);
    };

    // Agent purchases access
    ts::next_tx(&mut scenario, AGENT);
    {
        let mut config = ts::take_shared<ProtocolConfig>(&scenario);
        let mut service = ts::take_shared<ServiceProvider>(&scenario);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 1000);

        let payment = mint_sui(1 * MIST_PER_SUI, ts::ctx(&mut scenario)); // 1 SUI for 100 units

        let capability = apex_payments::purchase_access(
            &mut config,
            &mut service,
            payment,
            100, // units
            3600_000, // 1 hour duration
            10, // rate limit
            &clock,
            ts::ctx(&mut scenario)
        );

        // Verify capability
        assert!(apex_payments::capability_remaining(&capability) == 100, 0);
        assert!(apex_payments::capability_expires_at(&capability) == 1000 + 3600_000, 1);

        // Transfer capability to agent
        transfer::public_transfer(capability, AGENT);

        clock::destroy_for_testing(clock);
        ts::return_shared(service);
        ts::return_shared(config);
    };

    ts::end(scenario);
}

#[test]
fun test_use_access() {
    let mut scenario = ts::begin(ADMIN);
    setup_protocol(&mut scenario);

    // Setup: register service and purchase access
    ts::next_tx(&mut scenario, PROVIDER);
    {
        let mut config = ts::take_shared<ProtocolConfig>(&scenario);
        apex_payments::register_service(
            &mut config,
            b"API",
            b"Test",
            10_000_000,
            mint_sui(REGISTRATION_FEE, ts::ctx(&mut scenario)),
            ts::ctx(&mut scenario)
        );
        ts::return_shared(config);
    };

    ts::next_tx(&mut scenario, AGENT);
    {
        let mut config = ts::take_shared<ProtocolConfig>(&scenario);
        let mut service = ts::take_shared<ServiceProvider>(&scenario);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 1000);

        let capability = apex_payments::purchase_access(
            &mut config,
            &mut service,
            mint_sui(1 * MIST_PER_SUI, ts::ctx(&mut scenario)),
            100,
            3600_000,
            0, // no rate limit
            &clock,
            ts::ctx(&mut scenario)
        );

        transfer::public_transfer(capability, AGENT);

        clock::destroy_for_testing(clock);
        ts::return_shared(service);
        ts::return_shared(config);
    };

    // Use access
    ts::next_tx(&mut scenario, AGENT);
    {
        let service = ts::take_shared<ServiceProvider>(&scenario);
        let mut capability = ts::take_from_sender<AccessCapability>(&scenario);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 2000);

        // Use 5 units
        let success = apex_payments::use_access(
            &mut capability,
            &service,
            5,
            &clock,
            ts::ctx(&mut scenario)
        );

        assert!(success, 0);
        assert!(apex_payments::capability_remaining(&capability) == 95, 1);

        clock::destroy_for_testing(clock);
        ts::return_to_sender(&scenario, capability);
        ts::return_shared(service);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = apex_payments::EExpired)]
fun test_use_expired_access() {
    let mut scenario = ts::begin(ADMIN);
    setup_protocol(&mut scenario);

    // Setup: register service
    ts::next_tx(&mut scenario, PROVIDER);
    {
        let mut config = ts::take_shared<ProtocolConfig>(&scenario);
        apex_payments::register_service(
            &mut config,
            b"API",
            b"Test",
            10_000_000,
            mint_sui(REGISTRATION_FEE, ts::ctx(&mut scenario)),
            ts::ctx(&mut scenario)
        );
        ts::return_shared(config);
    };

    // Purchase access with 1 hour duration
    ts::next_tx(&mut scenario, AGENT);
    {
        let mut config = ts::take_shared<ProtocolConfig>(&scenario);
        let mut service = ts::take_shared<ServiceProvider>(&scenario);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 1000);

        let capability = apex_payments::purchase_access(
            &mut config,
            &mut service,
            mint_sui(1 * MIST_PER_SUI, ts::ctx(&mut scenario)),
            100,
            3600_000, // 1 hour
            0,
            &clock,
            ts::ctx(&mut scenario)
        );

        transfer::public_transfer(capability, AGENT);

        clock::destroy_for_testing(clock);
        ts::return_shared(service);
        ts::return_shared(config);
    };

    // Try to use after expiration
    ts::next_tx(&mut scenario, AGENT);
    {
        let service = ts::take_shared<ServiceProvider>(&scenario);
        let mut capability = ts::take_from_sender<AccessCapability>(&scenario);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 1000 + 3600_001); // Just past expiry

        // This should fail - capability expired
        apex_payments::use_access(
            &mut capability,
            &service,
            1,
            &clock,
            ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
        ts::return_to_sender(&scenario, capability);
        ts::return_shared(service);
    };

    ts::end(scenario);
}

// ==================== Streaming Payment Tests ====================

#[test]
fun test_open_and_consume_stream() {
    let mut scenario = ts::begin(ADMIN);
    setup_protocol(&mut scenario);

    // Register service
    ts::next_tx(&mut scenario, PROVIDER);
    {
        let mut config = ts::take_shared<ProtocolConfig>(&scenario);
        apex_payments::register_service(
            &mut config,
            b"Streaming API",
            b"Pay per second service",
            1_000_000, // 0.001 SUI per unit
            mint_sui(REGISTRATION_FEE, ts::ctx(&mut scenario)),
            ts::ctx(&mut scenario)
        );
        ts::return_shared(config);
    };

    // Open stream
    ts::next_tx(&mut scenario, AGENT);
    {
        let config = ts::take_shared<ProtocolConfig>(&scenario);
        let service = ts::take_shared<ServiceProvider>(&scenario);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 1000);

        let escrow = mint_sui(10 * MIST_PER_SUI, ts::ctx(&mut scenario)); // 10 SUI

        let stream_id = apex_payments::open_stream(
            &config,
            &service,
            escrow,
            10000, // max 10000 units
            &clock,
            ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(service);
        ts::return_shared(config);
    };

    // Provider records consumption
    ts::next_tx(&mut scenario, PROVIDER);
    {
        let mut stream = ts::take_shared<PaymentStream>(&scenario);
        let mut service = ts::take_shared<ServiceProvider>(&scenario);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 5000);

        apex_payments::record_stream_consumption(
            &mut stream,
            &mut service,
            100, // 100 units consumed
            &clock,
            ts::ctx(&mut scenario)
        );

        assert!(apex_payments::stream_consumed(&stream) == 100, 0);

        clock::destroy_for_testing(clock);
        ts::return_shared(service);
        ts::return_shared(stream);
    };

    ts::end(scenario);
}

// ==================== Agent Wallet Tests ====================

#[test]
fun test_create_agent_wallet() {
    let mut scenario = ts::begin(ADMIN);
    setup_protocol(&mut scenario);

    // Create agent wallet
    ts::next_tx(&mut scenario, AGENT);
    {
        let config = ts::take_shared<ProtocolConfig>(&scenario);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 1000);

        let funding = mint_sui(5 * MIST_PER_SUI, ts::ctx(&mut scenario));

        apex_payments::create_agent_wallet(
            &config,
            b"bot-001",
            100_000_000, // 0.1 SUI spend limit
            1_000_000_000, // 1 SUI daily limit
            funding,
            &clock,
            ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(config);
    };

    // Verify wallet
    ts::next_tx(&mut scenario, AGENT);
    {
        let wallet = ts::take_from_sender<AgentWallet>(&scenario);
        assert!(apex_payments::agent_wallet_balance(&wallet) == 5 * MIST_PER_SUI, 0);
        ts::return_to_sender(&scenario, wallet);
    };

    ts::end(scenario);
}

#[test]
fun test_agent_wallet_spending_limits() {
    let mut scenario = ts::begin(ADMIN);
    setup_protocol(&mut scenario);

    // Register service
    ts::next_tx(&mut scenario, PROVIDER);
    {
        let mut config = ts::take_shared<ProtocolConfig>(&scenario);
        apex_payments::register_service(
            &mut config,
            b"API",
            b"Test",
            10_000_000, // 0.01 SUI per unit
            mint_sui(REGISTRATION_FEE, ts::ctx(&mut scenario)),
            ts::ctx(&mut scenario)
        );
        ts::return_shared(config);
    };

    // Create agent wallet
    ts::next_tx(&mut scenario, AGENT);
    {
        let config = ts::take_shared<ProtocolConfig>(&scenario);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 1000);

        apex_payments::create_agent_wallet(
            &config,
            b"bot-001",
            100_000_000, // 0.1 SUI spend limit per tx
            1_000_000_000, // 1 SUI daily limit
            mint_sui(5 * MIST_PER_SUI, ts::ctx(&mut scenario)),
            &clock,
            ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(config);
    };

    // Agent purchases access using wallet
    ts::next_tx(&mut scenario, AGENT);
    {
        let mut config = ts::take_shared<ProtocolConfig>(&scenario);
        let mut service = ts::take_shared<ServiceProvider>(&scenario);
        let mut wallet = ts::take_from_sender<AgentWallet>(&scenario);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 2000);

        let capability = apex_payments::agent_purchase_access(
            &mut wallet,
            &mut config,
            &mut service,
            5, // 5 units = 0.05 SUI (under 0.1 limit)
            3600_000,
            0,
            &clock,
            ts::ctx(&mut scenario)
        );

        // Verify purchase worked
        assert!(apex_payments::capability_remaining(&capability) == 5, 0);

        // Check wallet balance decreased
        assert!(apex_payments::agent_wallet_balance(&wallet) == 5 * MIST_PER_SUI - 50_000_000, 1);

        transfer::public_transfer(capability, AGENT);
        clock::destroy_for_testing(clock);
        ts::return_to_sender(&scenario, wallet);
        ts::return_shared(service);
        ts::return_shared(config);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = apex_payments::EExceededLimit)]
fun test_agent_wallet_exceeds_spend_limit() {
    let mut scenario = ts::begin(ADMIN);
    setup_protocol(&mut scenario);

    // Register service
    ts::next_tx(&mut scenario, PROVIDER);
    {
        let mut config = ts::take_shared<ProtocolConfig>(&scenario);
        apex_payments::register_service(
            &mut config,
            b"API",
            b"Test",
            10_000_000,
            mint_sui(REGISTRATION_FEE, ts::ctx(&mut scenario)),
            ts::ctx(&mut scenario)
        );
        ts::return_shared(config);
    };

    // Create agent wallet with low spend limit
    ts::next_tx(&mut scenario, AGENT);
    {
        let config = ts::take_shared<ProtocolConfig>(&scenario);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 1000);

        apex_payments::create_agent_wallet(
            &config,
            b"bot-001",
            50_000_000, // Only 0.05 SUI spend limit
            1_000_000_000,
            mint_sui(5 * MIST_PER_SUI, ts::ctx(&mut scenario)),
            &clock,
            ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(config);
    };

    // Try to purchase more than spend limit
    ts::next_tx(&mut scenario, AGENT);
    {
        let mut config = ts::take_shared<ProtocolConfig>(&scenario);
        let mut service = ts::take_shared<ServiceProvider>(&scenario);
        let mut wallet = ts::take_from_sender<AgentWallet>(&scenario);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 2000);

        // Try to buy 10 units = 0.1 SUI (exceeds 0.05 limit)
        let capability = apex_payments::agent_purchase_access(
            &mut wallet,
            &mut config,
            &mut service,
            10, // 0.1 SUI - exceeds limit!
            3600_000,
            0,
            &clock,
            ts::ctx(&mut scenario)
        );

        transfer::public_transfer(capability, AGENT);
        clock::destroy_for_testing(clock);
        ts::return_to_sender(&scenario, wallet);
        ts::return_shared(service);
        ts::return_shared(config);
    };

    ts::end(scenario);
}

// ==================== Shield Transfer Tests ====================

#[test]
fun test_shield_transfer_complete() {
    let mut scenario = ts::begin(ADMIN);
    setup_protocol(&mut scenario);

    // Sender initiates shield transfer
    ts::next_tx(&mut scenario, AGENT);
    {
        let config = ts::take_shared<ProtocolConfig>(&scenario);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 1000);

        let payment = mint_sui(100 * MIST_PER_SUI, ts::ctx(&mut scenario));

        // Hash of "secret-passphrase"
        let secret_hash = sui::hash::keccak256(&b"secret-passphrase");

        apex_payments::initiate_shield_transfer(
            &config,
            RECIPIENT,
            payment,
            86400_000, // 24 hours
            secret_hash,
            &clock,
            ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(config);
    };

    // Recipient claims with correct secret
    ts::next_tx(&mut scenario, RECIPIENT);
    {
        let session = ts::take_shared<ShieldSession>(&scenario);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 5000);

        apex_payments::complete_shield_transfer(
            session,
            b"secret-passphrase",
            &clock,
            ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
    };

    // Verify recipient received funds
    ts::next_tx(&mut scenario, RECIPIENT);
    {
        let coin = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&coin) == 100 * MIST_PER_SUI, 0);
        ts::return_to_sender(&scenario, coin);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = apex_payments::EInvalidSecret)]
fun test_shield_transfer_wrong_secret() {
    let mut scenario = ts::begin(ADMIN);
    setup_protocol(&mut scenario);

    // Sender initiates
    ts::next_tx(&mut scenario, AGENT);
    {
        let config = ts::take_shared<ProtocolConfig>(&scenario);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 1000);

        let payment = mint_sui(100 * MIST_PER_SUI, ts::ctx(&mut scenario));
        let secret_hash = sui::hash::keccak256(&b"correct-secret");

        apex_payments::initiate_shield_transfer(
            &config,
            RECIPIENT,
            payment,
            86400_000,
            secret_hash,
            &clock,
            ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(config);
    };

    // Try to claim with wrong secret
    ts::next_tx(&mut scenario, RECIPIENT);
    {
        let session = ts::take_shared<ShieldSession>(&scenario);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 5000);

        apex_payments::complete_shield_transfer(
            session,
            b"wrong-secret", // Wrong!
            &clock,
            ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}

// ==================== Trading Intent Tests ====================

#[test]
fun test_create_and_fill_intent() {
    let mut scenario = ts::begin(ADMIN);

    // Agent creates swap intent
    ts::next_tx(&mut scenario, AGENT);
    {
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 1000);

        let input_coin = mint_sui(1 * MIST_PER_SUI, ts::ctx(&mut scenario));

        apex_trading::create_swap_intent<SUI>(
            input_coin,
            2_000_000, // min 2 USDC output (simulated)
            AGENT,
            3600_000, // 1 hour
            &clock,
            ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
    };

    // Verify intent was created
    ts::next_tx(&mut scenario, EXECUTOR);
    {
        let intent = ts::take_shared<SwapIntent<SUI>>(&scenario);
        assert!(apex_trading::intent_escrowed_amount(&intent) == 1 * MIST_PER_SUI, 0);
        assert!(apex_trading::intent_min_output(&intent) == 2_000_000, 1);
        assert!(!apex_trading::intent_is_filled(&intent), 2);
        ts::return_shared(intent);
    };

    // Executor fills intent
    ts::next_tx(&mut scenario, EXECUTOR);
    {
        let mut intent = ts::take_shared<SwapIntent<SUI>>(&scenario);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 2000);

        // Executor provides output (simulating DeepBook swap result)
        let output_coin = mint_sui(3_000_000, ts::ctx(&mut scenario)); // More than min output

        let (escrowed_input, receipt) = apex_trading::fill_intent<SUI, SUI>(
            &mut intent,
            output_coin,
            &clock,
            ts::ctx(&mut scenario)
        );

        // Verify executor received escrowed input
        assert!(coin::value(&escrowed_input) == 1 * MIST_PER_SUI, 0);

        // Verify intent marked as filled
        assert!(apex_trading::intent_is_filled(&intent), 1);

        transfer::public_transfer(escrowed_input, EXECUTOR);
        transfer::public_transfer(receipt, EXECUTOR);
        clock::destroy_for_testing(clock);
        ts::return_shared(intent);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = apex_trading::EInsufficientOutput)]
fun test_fill_intent_insufficient_output() {
    let mut scenario = ts::begin(ADMIN);

    // Agent creates intent
    ts::next_tx(&mut scenario, AGENT);
    {
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 1000);

        apex_trading::create_swap_intent<SUI>(
            mint_sui(1 * MIST_PER_SUI, ts::ctx(&mut scenario)),
            2_000_000, // min 2 million mist
            AGENT,
            3600_000,
            &clock,
            ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
    };

    // Try to fill with insufficient output
    ts::next_tx(&mut scenario, EXECUTOR);
    {
        let mut intent = ts::take_shared<SwapIntent<SUI>>(&scenario);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 2000);

        // Only 1 million - below 2 million minimum
        let insufficient_output = mint_sui(1_000_000, ts::ctx(&mut scenario));

        let (input, receipt) = apex_trading::fill_intent<SUI, SUI>(
            &mut intent,
            insufficient_output,
            &clock,
            ts::ctx(&mut scenario)
        );

        transfer::public_transfer(input, EXECUTOR);
        transfer::public_transfer(receipt, EXECUTOR);
        clock::destroy_for_testing(clock);
        ts::return_shared(intent);
    };

    ts::end(scenario);
}

#[test]
fun test_cancel_intent() {
    let mut scenario = ts::begin(ADMIN);

    // Agent creates intent
    ts::next_tx(&mut scenario, AGENT);
    {
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 1000);

        apex_trading::create_swap_intent<SUI>(
            mint_sui(1 * MIST_PER_SUI, ts::ctx(&mut scenario)),
            2_000_000,
            AGENT,
            3600_000,
            &clock,
            ts::ctx(&mut scenario)
        );

        clock::destroy_for_testing(clock);
    };

    // Agent cancels intent
    ts::next_tx(&mut scenario, AGENT);
    {
        let intent = ts::take_shared<SwapIntent<SUI>>(&scenario);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 2000);

        let refund = apex_trading::cancel_intent(
            intent,
            &clock,
            ts::ctx(&mut scenario)
        );

        // Verify full refund
        assert!(coin::value(&refund) == 1 * MIST_PER_SUI, 0);

        transfer::public_transfer(refund, AGENT);
        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}

// ==================== Gated Trading Tests ====================

#[test]
fun test_gated_trading_service() {
    let mut scenario = ts::begin(ADMIN);
    setup_protocol(&mut scenario);

    // Register APEX service
    ts::next_tx(&mut scenario, PROVIDER);
    {
        let mut config = ts::take_shared<ProtocolConfig>(&scenario);
        apex_payments::register_service(
            &mut config,
            b"Trading API",
            b"Premium trading signals",
            10_000_000,
            mint_sui(REGISTRATION_FEE, ts::ctx(&mut scenario)),
            ts::ctx(&mut scenario)
        );
        ts::return_shared(config);
    };

    // Get service ID and create trading service
    ts::next_tx(&mut scenario, PROVIDER);
    {
        let service = ts::take_shared<ServiceProvider>(&scenario);
        let apex_service_id = object::id(&service);

        apex_trading::create_and_share_trading_service(
            apex_service_id,
            5_000_000, // 0.005 SUI fee per trade
            ts::ctx(&mut scenario)
        );

        ts::return_shared(service);
    };

    // Agent purchases access
    ts::next_tx(&mut scenario, AGENT);
    {
        let mut config = ts::take_shared<ProtocolConfig>(&scenario);
        let mut service = ts::take_shared<ServiceProvider>(&scenario);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 1000);

        let capability = apex_payments::purchase_access(
            &mut config,
            &mut service,
            mint_sui(1 * MIST_PER_SUI, ts::ctx(&mut scenario)),
            100,
            3600_000,
            0,
            &clock,
            ts::ctx(&mut scenario)
        );

        transfer::public_transfer(capability, AGENT);

        clock::destroy_for_testing(clock);
        ts::return_shared(service);
        ts::return_shared(config);
    };

    // Agent verifies payment before trading
    ts::next_tx(&mut scenario, AGENT);
    {
        let mut trading_service = ts::take_shared<TradingService>(&scenario);
        let apex_service = ts::take_shared<ServiceProvider>(&scenario);
        let mut capability = ts::take_from_sender<AccessCapability>(&scenario);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 2000);

        let verified = apex_trading::verify_trade_payment(
            &mut trading_service,
            &apex_service,
            &mut capability,
            1, // consume 1 unit
            &clock,
            ts::ctx(&mut scenario)
        );

        assert!(verified, 0);
        assert!(apex_payments::capability_remaining(&capability) == 99, 1);
        assert!(apex_trading::trading_service_total_trades(&trading_service) == 1, 2);

        clock::destroy_for_testing(clock);
        ts::return_to_sender(&scenario, capability);
        ts::return_shared(apex_service);
        ts::return_shared(trading_service);
    };

    ts::end(scenario);
}

// ==================== Atomic PTB Pattern Tests ====================
// These tests demonstrate multi-operation sequences that mirror PTB behavior

#[test]
fun test_atomic_purchase_and_use() {
    let mut scenario = ts::begin(ADMIN);
    setup_protocol(&mut scenario);

    // Register service
    ts::next_tx(&mut scenario, PROVIDER);
    {
        let mut config = ts::take_shared<ProtocolConfig>(&scenario);
        apex_payments::register_service(
            &mut config,
            b"API",
            b"Test",
            10_000_000,
            mint_sui(REGISTRATION_FEE, ts::ctx(&mut scenario)),
            ts::ctx(&mut scenario)
        );
        ts::return_shared(config);
    };

    // Simulate PTB: purchase access + use access in same transaction
    ts::next_tx(&mut scenario, AGENT);
    {
        let mut config = ts::take_shared<ProtocolConfig>(&scenario);
        let mut service = ts::take_shared<ServiceProvider>(&scenario);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 1000);

        // Command 1: Purchase access
        let mut capability = apex_payments::purchase_access(
            &mut config,
            &mut service,
            mint_sui(1 * MIST_PER_SUI, ts::ctx(&mut scenario)),
            100,
            3600_000,
            0,
            &clock,
            ts::ctx(&mut scenario)
        );

        // Command 2: Use access (in same tx, capability passed between commands)
        let success = apex_payments::use_access(
            &mut capability,
            &service,
            5,
            &clock,
            ts::ctx(&mut scenario)
        );

        assert!(success, 0);
        assert!(apex_payments::capability_remaining(&capability) == 95, 1);

        // Command 3: Transfer to recipient
        transfer::public_transfer(capability, AGENT);

        clock::destroy_for_testing(clock);
        ts::return_shared(service);
        ts::return_shared(config);
    };

    ts::end(scenario);
}

#[test]
fun test_protocol_pause() {
    let mut scenario = ts::begin(ADMIN);
    setup_protocol(&mut scenario);

    // Admin pauses protocol
    ts::next_tx(&mut scenario, ADMIN);
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
        let mut config = ts::take_shared<ProtocolConfig>(&scenario);

        apex_payments::set_protocol_paused(&admin_cap, &mut config, true);
        assert!(apex_payments::protocol_is_paused(&config), 0);

        ts::return_to_sender(&scenario, admin_cap);
        ts::return_shared(config);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = apex_payments::EProtocolPaused)]
fun test_register_while_paused() {
    let mut scenario = ts::begin(ADMIN);
    setup_protocol(&mut scenario);

    // Admin pauses protocol
    ts::next_tx(&mut scenario, ADMIN);
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
        let mut config = ts::take_shared<ProtocolConfig>(&scenario);

        apex_payments::set_protocol_paused(&admin_cap, &mut config, true);

        ts::return_to_sender(&scenario, admin_cap);
        ts::return_shared(config);
    };

    // Try to register while paused
    ts::next_tx(&mut scenario, PROVIDER);
    {
        let mut config = ts::take_shared<ProtocolConfig>(&scenario);

        apex_payments::register_service(
            &mut config,
            b"Test",
            b"Test",
            10_000_000,
            mint_sui(REGISTRATION_FEE, ts::ctx(&mut scenario)),
            ts::ctx(&mut scenario)
        );

        ts::return_shared(config);
    };

    ts::end(scenario);
}
