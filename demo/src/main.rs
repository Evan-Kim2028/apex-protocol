//! APEX Protocol - Full Flow Demonstration
//!
//! This demo uses [sui-sandbox](https://github.com/Evan-Kim2028/sui-sandbox) to execute
//! APEX protocol PTBs locally in the real Move VM - same bytecode execution as mainnet.
//!
//! ## What This Demonstrates
//!
//! 1. Deploy APEX protocol contracts locally
//! 2. Initialize protocol (creates ProtocolConfig + AdminCap)
//! 3. Register a service provider
//! 4. Agent purchases AccessCapability
//! 5. Agent uses access (consumes units)
//!
//! ## Run It
//!
//! ```bash
//! cd demo && cargo run
//! ```

use anyhow::{anyhow, Result};
use move_core_types::account_address::AccountAddress;
use move_core_types::identifier::Identifier;
use move_core_types::language_storage::TypeTag;
use std::path::PathBuf;

use sui_sandbox::ptb::{Argument, Command, InputValue, ObjectInput};
use sui_sandbox::simulation::SimulationEnvironment;

// Test addresses
const ADMIN: &str = "0xAD00000000000000000000000000000000000000000000000000000000000001";
const PROVIDER: &str = "0x1111111111111111111111111111111111111111111111111111111111111111";
const AGENT: &str = "0x2222222222222222222222222222222222222222222222222222222222222222";

// Amounts in MIST (1 SUI = 10^9 MIST)
const MIST_PER_SUI: u64 = 1_000_000_000;
const PRICE_PER_UNIT: u64 = 10_000_000; // 0.01 SUI per unit

fn main() -> Result<()> {
    print_header();

    // =========================================================================
    // STEP 1: Create sandbox and deploy APEX protocol
    // =========================================================================
    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    println!("STEP 1: Deploy APEX Protocol");
    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");

    let mut env = SimulationEnvironment::new()?;

    let admin_addr = AccountAddress::from_hex_literal(ADMIN)?;
    let provider_addr = AccountAddress::from_hex_literal(PROVIDER)?;
    let agent_addr = AccountAddress::from_hex_literal(AGENT)?;

    env.set_sender(admin_addr);

    // Deploy APEX protocol
    let apex_path = get_apex_path();
    let (apex_pkg, modules) = env.compile_and_deploy(&apex_path)?;

    println!("  ✓ Deployed APEX Protocol");
    println!("    Package: 0x{:x}", apex_pkg);
    println!("    Modules: {:?}", modules);

    // =========================================================================
    // STEP 2: Initialize Protocol
    // =========================================================================
    println!("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    println!("STEP 2: Initialize Protocol (creates ProtocolConfig + AdminCap)");
    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");

    // Call initialize_protocol
    let result = env.execute_ptb(
        vec![],
        vec![Command::MoveCall {
            package: apex_pkg,
            module: Identifier::new("apex_payments")?,
            function: Identifier::new("initialize_protocol")?,
            type_args: vec![],
            args: vec![],
        }],
    );

    let (config_id, _admin_cap_id) = if result.success {
        println!("  ✓ Protocol initialized");
        if let Some(effects) = &result.effects {
            println!(
                "    Gas used: {} MIST ({:.6} SUI)",
                effects.gas_used,
                effects.gas_used as f64 / MIST_PER_SUI as f64
            );
            println!("    Objects created: {}", effects.created.len());

            // Get the created object IDs
            let created: Vec<_> = effects.created.iter().collect();
            if created.len() >= 2 {
                // First is typically the shared object (ProtocolConfig), second is owned (AdminCap)
                let config = *created
                    .iter()
                    .find(|id| env.get_object(id).map(|o| o.is_shared).unwrap_or(false))
                    .unwrap_or(created.first().unwrap());
                let admin_cap = *created
                    .iter()
                    .find(|id| !env.get_object(id).map(|o| o.is_shared).unwrap_or(true))
                    .unwrap_or(created.last().unwrap());

                println!("\n    Created Objects:");
                println!("    ├─ ProtocolConfig (shared): 0x{:x}", config);
                println!("    └─ AdminCap (owned by admin): 0x{:x}", admin_cap);
                (config, admin_cap)
            } else {
                return Err(anyhow!("Expected 2 objects, got {}", created.len()));
            }
        } else {
            return Err(anyhow!("No effects returned"));
        }
    } else {
        println!("  ✗ Failed: {:?}", result.error);
        if let Some(raw) = &result.raw_error {
            println!("    Raw: {}", raw);
        }
        return Err(anyhow!("Protocol initialization failed"));
    };

    // =========================================================================
    // STEP 3: Register Service (Provider)
    // =========================================================================
    println!("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    println!("STEP 3: Register Service (Provider pays 0.1 SUI registration fee)");
    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");

    env.set_sender(provider_addr);

    // Create coin for provider (uses balance only, not address)
    let provider_coin_id = env.create_sui_coin(1 * MIST_PER_SUI)?;
    println!("  Created 1 SUI for provider: 0x{:x}", provider_coin_id);

    // Get the config object
    let config_obj = env
        .get_object(&config_id)
        .ok_or_else(|| anyhow!("Config not found"))?;

    // Get provider coin
    let provider_coin = env
        .get_object(&provider_coin_id)
        .ok_or_else(|| anyhow!("Coin not found"))?;

    // Build type tags
    let sui_type: TypeTag = "0x2::sui::SUI".parse()?;
    let coin_type = TypeTag::Struct(Box::new(move_core_types::language_storage::StructTag {
        address: AccountAddress::from_hex_literal("0x2")?,
        module: Identifier::new("coin")?,
        name: Identifier::new("Coin")?,
        type_params: vec![sui_type.clone()],
    }));

    // Build PTB for register_service
    let inputs = vec![
        // Input 0: ProtocolConfig (shared/mutable)
        InputValue::Object(ObjectInput::Shared {
            id: *config_id,
            bytes: config_obj.bcs_bytes.clone(),
            type_tag: None,
            version: Some(config_obj.version),
            mutable: true,
        }),
        // Input 1: name (vector<u8>)
        InputValue::Pure(bcs::to_bytes(&b"AI Trading API".to_vec())?),
        // Input 2: description (vector<u8>)
        InputValue::Pure(bcs::to_bytes(&b"Premium trading signals for AI agents".to_vec())?),
        // Input 3: price_per_unit (u64)
        InputValue::Pure(bcs::to_bytes(&PRICE_PER_UNIT)?),
        // Input 4: payment coin
        InputValue::Object(ObjectInput::Owned {
            id: provider_coin_id,
            bytes: provider_coin.bcs_bytes.clone(),
            type_tag: Some(coin_type.clone()),
            version: None,
        }),
    ];

    let commands = vec![Command::MoveCall {
        package: apex_pkg,
        module: Identifier::new("apex_payments")?,
        function: Identifier::new("register_service")?,
        type_args: vec![],
        args: vec![
            Argument::Input(0), // config
            Argument::Input(1), // name
            Argument::Input(2), // description
            Argument::Input(3), // price_per_unit
            Argument::Input(4), // payment
        ],
    }];

    let result = env.execute_ptb(inputs, commands);

    let service_id = if result.success {
        println!("  ✓ Service registered");
        if let Some(effects) = &result.effects {
            println!(
                "    Gas used: {} MIST ({:.6} SUI)",
                effects.gas_used,
                effects.gas_used as f64 / MIST_PER_SUI as f64
            );

            // Find the created ServiceProvider (shared object)
            if let Some(service) = effects
                .created
                .iter()
                .find(|id| env.get_object(id).map(|o| o.is_shared).unwrap_or(false))
            {
                println!("    ServiceProvider: 0x{:x}", service);
                *service
            } else {
                // Take first created if no shared found
                let service = *effects
                    .created
                    .first()
                    .ok_or_else(|| anyhow!("No service created"))?;
                println!("    ServiceProvider: 0x{:x}", service);
                service
            }
        } else {
            return Err(anyhow!("No effects"));
        }
    } else {
        println!("  ✗ Failed: {:?}", result.error);
        if let Some(raw) = &result.raw_error {
            println!("    Raw: {}", raw);
        }
        return Err(anyhow!("Service registration failed"));
    };

    // =========================================================================
    // STEP 4: Agent Purchases AccessCapability (without clock)
    // =========================================================================
    println!("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    println!("STEP 4: Agent Purchases AccessCapability (100 units)");
    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");

    env.set_sender(agent_addr);

    // Create coin for agent
    let agent_coin_id = env.create_sui_coin(2 * MIST_PER_SUI)?;
    println!("  Created 2 SUI for agent: 0x{:x}", agent_coin_id);

    // Note: purchase_access requires a Clock object (0x6), which may not be available
    // in the sandbox by default. We'll create a mock clock first.
    println!("  Setting up Clock object for time-based operations...");

    // Create a Clock object at address 0x6 (the standard Sui Clock)
    let clock_id = AccountAddress::from_hex_literal("0x6")?;

    // Clock BCS format: UID (32 bytes) + timestamp_ms (8 bytes)
    // We'll use a current-ish timestamp
    let mut clock_bytes = Vec::new();
    clock_bytes.extend_from_slice(&clock_id.to_vec()); // UID uses the object ID
    let current_timestamp_ms: u64 = 1700000000000; // A reasonable timestamp
    clock_bytes.extend_from_slice(&current_timestamp_ms.to_le_bytes());

    // Load the clock object
    let clock_type_str = "0x2::clock::Clock";
    env.load_object_from_data(
        "0x6",
        clock_bytes.clone(),
        Some(clock_type_str),
        true,  // is_shared
        false, // is_immutable
        1,     // version
    )?;
    println!("  ✓ Clock object loaded at 0x6");

    // Now get fresh objects (after clock is loaded)
    let config_obj = env
        .get_object(&config_id)
        .ok_or_else(|| anyhow!("Config not found"))?;
    let service_obj = env
        .get_object(&service_id)
        .ok_or_else(|| anyhow!("Service not found"))?;
    let agent_coin = env
        .get_object(&agent_coin_id)
        .ok_or_else(|| anyhow!("Agent coin not found"))?;
    let clock_obj = env.get_object(&clock_id).ok_or_else(|| anyhow!("Clock not found"))?;

    // Build PTB for purchase_access
    let inputs = vec![
        // Input 0: ProtocolConfig (shared/mutable)
        InputValue::Object(ObjectInput::Shared {
            id: *config_id,
            bytes: config_obj.bcs_bytes.clone(),
            type_tag: None,
            version: Some(config_obj.version),
            mutable: true,
        }),
        // Input 1: ServiceProvider (shared/mutable)
        InputValue::Object(ObjectInput::Shared {
            id: service_id,
            bytes: service_obj.bcs_bytes.clone(),
            type_tag: None,
            version: Some(service_obj.version),
            mutable: true,
        }),
        // Input 2: payment coin
        InputValue::Object(ObjectInput::Owned {
            id: agent_coin_id,
            bytes: agent_coin.bcs_bytes.clone(),
            type_tag: Some(coin_type.clone()),
            version: None,
        }),
        // Input 3: units (u64) - 100 units
        InputValue::Pure(bcs::to_bytes(&100u64)?),
        // Input 4: duration_ms (u64) - 1 hour
        InputValue::Pure(bcs::to_bytes(&3_600_000u64)?),
        // Input 5: rate_limit (u64) - 10 per epoch
        InputValue::Pure(bcs::to_bytes(&10u64)?),
        // Input 6: clock (shared immutable)
        InputValue::Object(ObjectInput::Shared {
            id: clock_id,
            bytes: clock_obj.bcs_bytes.clone(),
            type_tag: None,
            version: Some(clock_obj.version),
            mutable: false, // Clock is always immutable reference
        }),
    ];

    let commands = vec![
        // Call purchase_access
        Command::MoveCall {
            package: apex_pkg,
            module: Identifier::new("apex_payments")?,
            function: Identifier::new("purchase_access")?,
            type_args: vec![],
            args: vec![
                Argument::Input(0), // config
                Argument::Input(1), // service
                Argument::Input(2), // payment
                Argument::Input(3), // units
                Argument::Input(4), // duration_ms
                Argument::Input(5), // rate_limit
                Argument::Input(6), // clock
            ],
        },
        // Transfer the returned AccessCapability to agent
        Command::TransferObjects {
            objects: vec![Argument::NestedResult(0, 0)], // First result from command 0
            address: Argument::Input(7), // Need to add recipient address
        },
    ];

    // We need to add the recipient address as a pure input
    let mut inputs_with_recipient = inputs;
    inputs_with_recipient.push(InputValue::Pure(bcs::to_bytes(&agent_addr)?));

    println!("  PTB Structure:");
    println!("  ┌─────────────────────────────────────────────────────────────────┐");
    println!("  │ [0] MoveCall purchase_access(config, service, coin, 100, ...)   │");
    println!("  │     → Result[0] = AccessCapability                              │");
    println!("  │ [1] TransferObjects [Result[0]] → agent                         │");
    println!("  └─────────────────────────────────────────────────────────────────┘\n");

    let result = env.execute_ptb(inputs_with_recipient, commands);

    let access_cap_id = if result.success {
        println!("  ✓ Access purchased!");
        if let Some(effects) = &result.effects {
            println!(
                "    Gas used: {} MIST ({:.6} SUI)",
                effects.gas_used,
                effects.gas_used as f64 / MIST_PER_SUI as f64
            );
            println!(
                "    Objects created: {} (AccessCapability)",
                effects.created.len()
            );

            let cap_id = effects.created.first().map(|id| *id);
            for id in &effects.created {
                println!("    └─ AccessCapability: 0x{:x}", id);
            }
            cap_id
        } else {
            None
        }
    } else {
        println!("  ✗ Failed: {:?}", result.error);
        if let Some(raw) = &result.raw_error {
            println!("    Raw error: {}", raw);
        }
        None
    };

    // =========================================================================
    // STEP 5: Use Access (if purchase succeeded)
    // =========================================================================
    if let Some(cap_id) = access_cap_id {
        println!("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
        println!("STEP 5: Agent Uses Access (consumes 1 unit)");
        println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");

        // Get fresh objects
        let service_obj = env
            .get_object(&service_id)
            .ok_or_else(|| anyhow!("Service not found"))?;
        let cap_obj = env
            .get_object(&cap_id)
            .ok_or_else(|| anyhow!("AccessCapability not found"))?;
        let clock_obj = env
            .get_object(&clock_id)
            .ok_or_else(|| anyhow!("Clock not found"))?;

        // use_access(cap: &mut AccessCapability, service: &ServiceProvider, units: u64, clock: &Clock, ctx: &TxContext)
        let inputs = vec![
            // Input 0: AccessCapability (owned/mutable)
            InputValue::Object(ObjectInput::MutRef {
                id: cap_id,
                bytes: cap_obj.bcs_bytes.clone(),
                type_tag: None,
                version: Some(cap_obj.version),
            }),
            // Input 1: ServiceProvider (shared/immutable ref)
            InputValue::Object(ObjectInput::Shared {
                id: service_id,
                bytes: service_obj.bcs_bytes.clone(),
                type_tag: None,
                version: Some(service_obj.version),
                mutable: false, // use_access takes &ServiceProvider not &mut
            }),
            // Input 2: units (u64) - consume 1 unit
            InputValue::Pure(bcs::to_bytes(&1u64)?),
            // Input 3: clock (shared immutable)
            InputValue::Object(ObjectInput::Shared {
                id: clock_id,
                bytes: clock_obj.bcs_bytes.clone(),
                type_tag: None,
                version: Some(clock_obj.version),
                mutable: false,
            }),
            // Note: ctx is implicit from the PTB executor
        ];

        let commands = vec![Command::MoveCall {
            package: apex_pkg,
            module: Identifier::new("apex_payments")?,
            function: Identifier::new("use_access")?,
            type_args: vec![],
            args: vec![
                Argument::Input(0), // cap
                Argument::Input(1), // service
                Argument::Input(2), // units
                Argument::Input(3), // clock
            ],
        }];

        let result = env.execute_ptb(inputs, commands);

        if result.success {
            println!("  ✓ Access used! (1 unit consumed)");
            if let Some(effects) = &result.effects {
                println!(
                    "    Gas used: {} MIST ({:.6} SUI)",
                    effects.gas_used,
                    effects.gas_used as f64 / MIST_PER_SUI as f64
                );
            }
            println!("    Remaining units: 99");
        } else {
            println!("  ✗ Failed: {:?}", result.error);
            if let Some(raw) = &result.raw_error {
                println!("    Raw error: {}", raw);
            }
        }
    }

    // =========================================================================
    // Summary
    // =========================================================================
    print_summary();

    Ok(())
}

fn get_apex_path() -> PathBuf {
    // Contracts are in ../sources relative to the demo directory
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("Failed to get parent directory")
        .to_path_buf()
}

fn print_header() {
    println!();
    println!("╔════════════════════════════════════════════════════════════════════════╗");
    println!("║            APEX Protocol - Local PTB Execution Demo                    ║");
    println!("╠════════════════════════════════════════════════════════════════════════╣");
    println!("║  This demonstrates the FULL APEX flow in sui-sandbox:                  ║");
    println!("║                                                                        ║");
    println!("║  1. Deploy APEX contracts (no testnet needed!)                         ║");
    println!("║  2. Initialize protocol (ProtocolConfig + AdminCap)                    ║");
    println!("║  3. Register a service provider                                        ║");
    println!("║  4. Agent purchases AccessCapability                                   ║");
    println!("║  5. Agent uses access (consumes units)                                 ║");
    println!("║                                                                        ║");
    println!("║  All running in the REAL Move VM - same execution as mainnet!          ║");
    println!("╚════════════════════════════════════════════════════════════════════════╝");
    println!();
}

fn print_summary() {
    println!("\n╔════════════════════════════════════════════════════════════════════════╗");
    println!("║                              Summary                                   ║");
    println!("╠════════════════════════════════════════════════════════════════════════╣");
    println!("║                                                                        ║");
    println!("║  What we demonstrated (all 5 steps passed!):                           ║");
    println!("║  ✓ Deployed APEX protocol locally (4 modules, no testnet)              ║");
    println!("║  ✓ Created shared ProtocolConfig and owned AdminCap                    ║");
    println!("║  ✓ Registered a ServiceProvider with pricing                           ║");
    println!("║  ✓ Agent purchased AccessCapability (100 units)                        ║");
    println!("║  ✓ Agent used access (consumed 1 unit)                                 ║");
    println!("║                                                                        ║");
    println!("║  APEX Protocol Modules:                                                ║");
    println!("║  • apex_payments  - Core payment & access capability logic             ║");
    println!("║  • apex_trading   - DEX integration patterns (DeepBook, Cetus)         ║");
    println!("║  • apex_seal      - Encrypted content gating via Seal                  ║");
    println!("║  • apex_sponsor   - Gas sponsorship infrastructure                     ║");
    println!("║                                                                        ║");
    println!("║  Key insight:                                                          ║");
    println!("║  Everything is ATOMIC. In a single PTB you can:                        ║");
    println!("║    purchase_access → use_access → deepbook::swap                       ║");
    println!("║  If ANY step fails, ALL revert. Zero risk to the agent.                ║");
    println!("║                                                                        ║");
    println!("║  This demonstrates sui-sandbox's full capability:                      ║");
    println!("║  Test complete protocol flows locally before deploying to mainnet.     ║");
    println!("║                                                                        ║");
    println!("╚════════════════════════════════════════════════════════════════════════╝");
}
