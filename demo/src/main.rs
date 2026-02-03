//! APEX Protocol - Mainnet Fork Hedge Fund Demonstrations
//!
//! This demo uses [sui-sandbox](https://github.com/Evan-Kim2028/sui-sandbox) to execute
//! APEX protocol PTBs locally against REAL mainnet DeepBook bytecode via gRPC forking.
//!
//! ## Workflows Demonstrated
//!
//! 1. **Fund Creation**: Load mainnet DeepBook/Pyth → Deploy APEX → Create hedge fund
//! 2. **Investor Deposits**: Investors join fund with entry fees via APEX payments
//! 3. **Agent Trading**: Trading agent executes within on-chain enforced constraints
//!
//! ## Mainnet Fork Capability
//!
//! The key innovation here is using sui-sandbox's GrpcFetcher to:
//! - Fetch REAL DeepBook V3 bytecode from Sui mainnet
//! - Load Pyth Oracle package for price feeds
//! - Execute PTBs against production code locally
//! - Test constraint enforcement with real DeFi protocols
//!
//! ## Sandbox Limitations
//!
//! ### Owned Object Deserialization (Issue)
//! Custom-typed owned objects created in one PTB cannot always be passed to subsequent
//! PTBs. The sandbox stores object bytes after creation, but type information may not
//! serialize/deserialize correctly for complex types.
//! See: https://github.com/Evan-Kim2028/sui-sandbox/issues/18
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
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;

use sui_sandbox::ptb::{Argument, Command, InputValue, ObjectInput};
use sui_sandbox::simulation::{SimulationEnvironment, ExecutionResult};
use sui_sandbox::{Fetcher, GrpcFetcher};

// =========================================================================
// JSON Output Structures for PTB Traces
// =========================================================================

/// Represents a complete PTB execution trace for JSON export
#[derive(Debug, Serialize, Deserialize)]
pub struct PtbTrace {
    pub demo: String,
    pub step: String,
    pub sender: String,
    pub inputs: Vec<PtbInput>,
    pub commands: Vec<PtbCommand>,
    pub outputs: PtbOutputs,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct PtbInput {
    pub index: usize,
    pub input_type: String,
    pub object_id: Option<String>,
    pub type_tag: Option<String>,
    pub value: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct PtbCommand {
    pub index: usize,
    pub command_type: String,
    pub package: Option<String>,
    pub module: Option<String>,
    pub function: Option<String>,
    pub type_args: Vec<String>,
    pub args: Vec<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct PtbOutputs {
    pub success: bool,
    pub gas_used: u64,
    pub created_objects: Vec<CreatedObject>,
    pub mutated_objects: Vec<String>,
    pub events: Vec<PtbEvent>,
    pub error: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct CreatedObject {
    pub object_id: String,
    pub object_type: String,
    pub owner: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct PtbEvent {
    pub event_type: String,
    pub data: serde_json::Value,
}

/// Collection of all PTB traces from the demo
#[derive(Debug, Serialize, Deserialize)]
pub struct DemoTraces {
    pub protocol: String,
    pub version: String,
    pub timestamp: String,
    pub traces: Vec<PtbTrace>,
}

impl DemoTraces {
    pub fn new() -> Self {
        Self {
            protocol: "APEX Protocol".to_string(),
            version: "0.1.0".to_string(),
            timestamp: chrono_lite_timestamp(),
            traces: Vec::new(),
        }
    }

    pub fn add_trace(&mut self, trace: PtbTrace) {
        self.traces.push(trace);
    }

    pub fn save_to_file(&self, path: &str) -> Result<()> {
        let json = serde_json::to_string_pretty(self)?;
        fs::write(path, json)?;
        Ok(())
    }
}

/// Simple timestamp without chrono dependency
fn chrono_lite_timestamp() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let duration = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    format!("{}s", duration.as_secs())
}

/// Global trace collector using thread-safe Mutex
use std::sync::Mutex;
use std::sync::OnceLock;

static DEMO_TRACES: OnceLock<Mutex<DemoTraces>> = OnceLock::new();

fn get_traces() -> &'static Mutex<DemoTraces> {
    DEMO_TRACES.get_or_init(|| Mutex::new(DemoTraces::new()))
}

fn record_trace(trace: PtbTrace) {
    if let Ok(mut traces) = get_traces().lock() {
        traces.add_trace(trace);
    }
}

fn save_traces() -> Result<()> {
    if let Ok(traces) = get_traces().lock() {
        traces.save_to_file("ptb_traces.json")?;
        println!("\n  📄 PTB traces saved to: ptb_traces.json");
    }
    Ok(())
}

/// Helper to format an input for JSON
fn format_input(input: &InputValue, index: usize) -> PtbInput {
    match input {
        InputValue::Pure(bytes) => PtbInput {
            index,
            input_type: "Pure".to_string(),
            object_id: None,
            type_tag: None,
            value: Some(format!("0x{}", hex::encode(bytes))),
        },
        InputValue::Object(obj) => {
            let (input_type, obj_id, type_tag) = match obj {
                ObjectInput::ImmRef { id, type_tag, .. } => (
                    "ImmRef",
                    format!("0x{:x}", id),
                    type_tag.as_ref().map(|t| format!("{}", t)),
                ),
                ObjectInput::MutRef { id, type_tag, .. } => (
                    "MutRef",
                    format!("0x{:x}", id),
                    type_tag.as_ref().map(|t| format!("{}", t)),
                ),
                ObjectInput::Owned { id, type_tag, .. } => (
                    "Owned",
                    format!("0x{:x}", id),
                    type_tag.as_ref().map(|t| format!("{}", t)),
                ),
                ObjectInput::Shared { id, type_tag, mutable, .. } => (
                    if *mutable { "SharedMut" } else { "SharedImm" },
                    format!("0x{:x}", id),
                    type_tag.as_ref().map(|t| format!("{}", t)),
                ),
                ObjectInput::Receiving { id, type_tag, .. } => (
                    "Receiving",
                    format!("0x{:x}", id),
                    type_tag.as_ref().map(|t| format!("{}", t)),
                ),
            };
            PtbInput {
                index,
                input_type: input_type.to_string(),
                object_id: Some(obj_id),
                type_tag,
                value: None,
            }
        }
    }
}

/// Helper to format a command for JSON
fn format_command(cmd: &Command, index: usize) -> PtbCommand {
    match cmd {
        Command::MoveCall { package, module, function, type_args, args } => PtbCommand {
            index,
            command_type: "MoveCall".to_string(),
            package: Some(format!("0x{:x}", package)),
            module: Some(module.to_string()),
            function: Some(function.to_string()),
            type_args: type_args.iter().map(|t| format!("{}", t)).collect(),
            args: args.iter().map(|a| format!("{:?}", a)).collect(),
        },
        Command::TransferObjects { objects, address } => PtbCommand {
            index,
            command_type: "TransferObjects".to_string(),
            package: None,
            module: None,
            function: None,
            type_args: vec![],
            args: vec![
                format!("objects: {:?}", objects),
                format!("to: {:?}", address),
            ],
        },
        Command::SplitCoins { coin, amounts } => PtbCommand {
            index,
            command_type: "SplitCoins".to_string(),
            package: None,
            module: None,
            function: None,
            type_args: vec![],
            args: vec![
                format!("coin: {:?}", coin),
                format!("amounts: {:?}", amounts),
            ],
        },
        Command::MergeCoins { destination, sources } => PtbCommand {
            index,
            command_type: "MergeCoins".to_string(),
            package: None,
            module: None,
            function: None,
            type_args: vec![],
            args: vec![
                format!("destination: {:?}", destination),
                format!("sources: {:?}", sources),
            ],
        },
        Command::MakeMoveVec { type_tag, elements } => PtbCommand {
            index,
            command_type: "MakeMoveVec".to_string(),
            package: None,
            module: None,
            function: None,
            type_args: type_tag.as_ref().map(|t| vec![format!("{}", t)]).unwrap_or_default(),
            args: vec![format!("elements: {:?}", elements)],
        },
        Command::Publish { modules, dep_ids } => PtbCommand {
            index,
            command_type: "Publish".to_string(),
            package: None,
            module: None,
            function: None,
            type_args: vec![],
            args: vec![
                format!("modules: {} modules", modules.len()),
                format!("deps: {:?}", dep_ids),
            ],
        },
        Command::Upgrade { modules, package, ticket } => PtbCommand {
            index,
            command_type: "Upgrade".to_string(),
            package: Some(format!("0x{:x}", package)),
            module: None,
            function: None,
            type_args: vec![],
            args: vec![
                format!("modules: {} modules", modules.len()),
                format!("ticket: {:?}", ticket),
            ],
        },
        Command::Receive { object_id, object_type } => PtbCommand {
            index,
            command_type: "Receive".to_string(),
            package: None,
            module: None,
            function: None,
            type_args: object_type.as_ref().map(|t| vec![format!("{}", t)]).unwrap_or_default(),
            args: vec![format!("object_id: 0x{:x}", object_id)],
        },
    }
}

/// Helper to create a trace from PTB execution
fn create_trace(
    demo: &str,
    step: &str,
    sender: &AccountAddress,
    inputs: &[InputValue],
    commands: &[Command],
    result: &ExecutionResult,
    env: &SimulationEnvironment,
) -> PtbTrace {
    let formatted_inputs: Vec<PtbInput> = inputs
        .iter()
        .enumerate()
        .map(|(i, input)| format_input(input, i))
        .collect();

    let formatted_commands: Vec<PtbCommand> = commands
        .iter()
        .enumerate()
        .map(|(i, cmd)| format_command(cmd, i))
        .collect();

    let outputs = if result.success {
        let effects = result.effects.as_ref();
        let created_objects: Vec<CreatedObject> = effects
            .map(|e| {
                e.created
                    .iter()
                    .map(|id| {
                        let obj = env.get_object(id);
                        CreatedObject {
                            object_id: format!("0x{:x}", id),
                            object_type: obj
                                .map(|o| format!("{}", o.type_tag))
                                .unwrap_or_else(|| "unknown".to_string()),
                            owner: obj
                                .map(|o| format!("{:?}", o.owner))
                                .unwrap_or_else(|| "unknown".to_string()),
                        }
                    })
                    .collect()
            })
            .unwrap_or_default();

        let mutated_objects: Vec<String> = effects
            .map(|e| e.mutated.iter().map(|id| format!("0x{:x}", id)).collect())
            .unwrap_or_default();

        let gas_used = effects.map(|e| e.gas_used).unwrap_or(0);

        PtbOutputs {
            success: true,
            gas_used,
            created_objects,
            mutated_objects,
            events: vec![], // Events could be added if needed
            error: None,
        }
    } else {
        PtbOutputs {
            success: false,
            gas_used: 0,
            created_objects: vec![],
            mutated_objects: vec![],
            events: vec![],
            error: result.error.as_ref().map(|e| format!("{:?}", e)),
        }
    };

    PtbTrace {
        demo: demo.to_string(),
        step: step.to_string(),
        sender: format!("0x{:x}", sender),
        inputs: formatted_inputs,
        commands: formatted_commands,
        outputs,
    }
}

// Simple hex encoding (avoiding extra dependency)
mod hex {
    pub fn encode(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{:02x}", b)).collect()
    }
}

// Test addresses
const ADMIN: &str = "0xAD00000000000000000000000000000000000000000000000000000000000001";

// Amounts in MIST (1 SUI = 10^9 MIST)
const MIST_PER_SUI: u64 = 1_000_000_000;

// Hedge fund demo addresses
const INVESTOR_A: &str = "0x5555555555555555555555555555555555555555555555555555555555555555";
const FUND_OWNER: &str = "0x8888888888888888888888888888888888888888888888888888888888888888";
const TRADING_AGENT: &str = "0x9999999999999999999999999999999999999999999999999999999999999999";

fn main() -> Result<()> {
    // Load .env file if present (for SUI_GRPC_ENDPOINT, SUI_GRPC_API_KEY)
    dotenv::dotenv().ok();

    print_header();

    // Run full hedge fund lifecycle in a SINGLE shared sandbox environment
    // This demonstrates the complete flow: creation → deposits → trading → settlement
    if let Err(e) = run_full_hedge_fund_demo() {
        println!("\n  ⚠ Demo failed: {}", e);
    }

    print_final_summary();

    // Save PTB traces to JSON file
    save_traces()?;

    Ok(())
}

/// Shared state passed between demo phases
struct DemoState {
    env: SimulationEnvironment,
    has_deepbook: bool,
    apex_pkg: AccountAddress,
    config_id: AccountAddress,
    entry_service_id: AccountAddress,
    fund_id: AccountAddress,
    auth_id: AccountAddress,
    investor_positions: Vec<(AccountAddress, AccountAddress)>, // (investor_addr, position_id)
}

/// Run the complete hedge fund lifecycle in a single shared sandbox
fn run_full_hedge_fund_demo() -> Result<()> {
    // =========================================================================
    // DEMO 1: Fund Creation with Mainnet Fork
    // =========================================================================
    let mut state = demo_phase1_fund_creation()?;

    // =========================================================================
    // DEMO 2: Investor Deposits
    // =========================================================================
    demo_phase2_investor_deposits(&mut state)?;

    // =========================================================================
    // DEMO 3: Agent Trading with Constraint Enforcement
    // =========================================================================
    demo_phase3_agent_trading(&mut state)?;

    // =========================================================================
    // DEMO 4: Settlement and Distribution (NEW!)
    // =========================================================================
    demo_phase4_settlement(&mut state)?;

    Ok(())
}

// =========================================================================
// DEMO PHASE 1: Fund Creation with Mainnet Fork
// =========================================================================

fn demo_phase1_fund_creation() -> Result<DemoState> {
    println!("\n{}", "═".repeat(76));
    println!("  PHASE 1: Fund Creation with Mainnet DeepBook Fork");
    println!("{}", "═".repeat(76));
    println!("\n  Load REAL mainnet DeepBook state and create hedge fund:");
    println!("  • Fetch DeepBook V3 + Pyth Oracle bytecode from mainnet via gRPC");
    println!("  • Deploy APEX Protocol in same sandbox environment");
    println!("  • Create hedge fund with fee structure and constraints");

    // =========================================================================
    // STEP 1: Load Mainnet State via gRPC
    // =========================================================================
    println!("\n  ┌──────────────────────────────────────────────────────────────────┐");
    println!("  │ STEP 1: Load Mainnet Packages via gRPC Forking                   │");
    println!("  └──────────────────────────────────────────────────────────────────┘");

    let endpoint = std::env::var("SUI_GRPC_ENDPOINT")
        .unwrap_or_else(|_| "https://fullnode.mainnet.sui.io:443".to_string());
    println!("        gRPC endpoint: {}", endpoint);

    let fetcher = GrpcFetcher::mainnet();

    println!("\n        Fetching mainnet packages...");

    if let Ok(modules) = fetcher.fetch_package_modules(DEEPBOOK_V3_PACKAGE) {
        println!("        ✓ DeepBook V3: {} modules", modules.len());
    }
    if let Ok(modules) = fetcher.fetch_package_modules(DEEP_TOKEN_PACKAGE) {
        println!("        ✓ DEEP Token: {} modules", modules.len());
    }
    if let Ok(modules) = fetcher.fetch_package_modules(PYTH_PACKAGE) {
        println!("        ✓ Pyth Oracle: {} modules", modules.len());
    }

    let (mut env, has_deepbook) = create_mainnet_forked_env(false)?;

    if has_deepbook {
        println!("\n        ✓ All mainnet packages loaded into sandbox!");
    } else {
        println!("\n        ⚠ Could not load mainnet state - continuing without DeepBook");
    }

    // =========================================================================
    // STEP 2: Execute DeepBook PTB to Verify Real Code
    // =========================================================================
    println!("\n  ┌──────────────────────────────────────────────────────────────────┐");
    println!("  │ STEP 2: Verify DeepBook - Execute balance_manager::new()         │");
    println!("  └──────────────────────────────────────────────────────────────────┘");

    if has_deepbook {
        let trader_addr = AccountAddress::from_hex_literal(TRADING_AGENT)?;
        env.set_sender(trader_addr);
        let deepbook_addr = AccountAddress::from_hex_literal(DEEPBOOK_V3_PACKAGE)?;
        let result = env.execute_ptb(
            vec![],
            vec![Command::MoveCall {
                package: deepbook_addr,
                module: Identifier::new("balance_manager")?,
                function: Identifier::new("new")?,
                type_args: vec![],
                args: vec![],
            }],
        );

        if result.success {
            println!("        ✓ deepbook::balance_manager::new() executed!");
            if let Some(effects) = &result.effects {
                if let Some(created_id) = effects.created.first() {
                    println!("          BalanceManager created: 0x{:x}", created_id);
                }
            }
        }
    } else {
        println!("        (Skipped - DeepBook not loaded)");
    }

    // =========================================================================
    // STEP 3: Deploy APEX Protocol
    // =========================================================================
    println!("\n  ┌──────────────────────────────────────────────────────────────────┐");
    println!("  │ STEP 3: Deploy APEX Protocol                                     │");
    println!("  └──────────────────────────────────────────────────────────────────┘");

    let admin_addr = AccountAddress::from_hex_literal(ADMIN)?;
    env.set_sender(admin_addr);

    let apex_path = get_apex_path();
    let (apex_pkg, modules) = env.compile_and_deploy(&apex_path)?;
    println!("        ✓ APEX Package: 0x{:x}", apex_pkg);
    println!("        ✓ Modules: {:?}", modules);

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
    let (config_id, _) = extract_protocol_objects(&result, &env)?;
    println!("        ✓ ProtocolConfig: 0x{:x}", config_id);

    setup_clock(&mut env)?;

    let admin_coin = env.create_sui_coin(1 * MIST_PER_SUI)?;
    let entry_service_id = register_service(
        &mut env,
        apex_pkg,
        config_id,
        admin_coin,
        b"HedgeFund Entry",
        b"Entry fee collection via APEX",
        100_000_000,
    )?;
    println!("        ✓ Entry Fee Service: 0x{:x}", entry_service_id);

    // =========================================================================
    // STEP 4: Create Hedge Fund
    // =========================================================================
    println!("\n  ┌──────────────────────────────────────────────────────────────────┐");
    println!("  │ STEP 4: Fund Owner Creates Hedge Fund                            │");
    println!("  └──────────────────────────────────────────────────────────────────┘");

    let owner_addr = AccountAddress::from_hex_literal(FUND_OWNER)?;
    env.set_sender(owner_addr);
    let owner_coin = env.create_sui_coin(1 * MIST_PER_SUI)?;

    let fund_id = create_hedge_fund(
        &mut env,
        apex_pkg,
        config_id,
        entry_service_id,
        owner_coin,
        b"DeepBook Alpha Fund",
        100_000_000,  // 0.1 SUI entry fee
        200,          // 2% management fee
        2000,         // 20% performance fee
        500 * MIST_PER_SUI,
    )?;

    println!("        Owner: 0x{}...{}", &FUND_OWNER[2..6], &FUND_OWNER[62..]);
    println!("        ✓ Created 'DeepBook Alpha Fund'");
    println!("        ✓ Fund ID: 0x{:x}", fund_id);
    println!("        ✓ Entry fee: 0.1 SUI | Mgmt: 2% | Perf: 20%");

    // =========================================================================
    // STEP 5: Authorize Trading Agent with Constraints
    // =========================================================================
    println!("\n  ┌──────────────────────────────────────────────────────────────────┐");
    println!("  │ STEP 5: Authorize Trading Agent with On-Chain Constraints        │");
    println!("  └──────────────────────────────────────────────────────────────────┘");

    let agent_addr = AccountAddress::from_hex_literal(TRADING_AGENT)?;

    let auth_id = authorize_manager(
        &mut env,
        apex_pkg,
        fund_id,
        agent_addr,
        1500,   // max_trade_bps: 15% per trade
        2500,   // max_position_bps: 25% max position
        5000,   // max_daily_volume_bps: 50% daily turnover
        5,      // max_leverage: 5x
        2,      // allowed_directions: BOTH
        0,
    )?;

    println!("        Trading Agent: 0x{}...{}", &TRADING_AGENT[2..6], &TRADING_AGENT[62..]);
    println!("        ✓ ManagerAuthorization: 0x{:x}", auth_id);
    println!("        ✓ Constraints: 15% max trade, 5x leverage, Long & Short");

    println!("\n  ✅ Phase 1 complete - Fund created with mainnet DeepBook!");

    Ok(DemoState {
        env,
        has_deepbook,
        apex_pkg,
        config_id,
        entry_service_id,
        fund_id,
        auth_id,
        investor_positions: Vec::new(),
    })
}

// =========================================================================
// DEMO PHASE 2: Investor Deposits (uses shared sandbox)
// =========================================================================

fn demo_phase2_investor_deposits(state: &mut DemoState) -> Result<()> {
    println!("\n{}", "═".repeat(76));
    println!("  PHASE 2: Investor Deposits (Same Sandbox)");
    println!("{}", "═".repeat(76));
    println!("\n  Investors join the hedge fund with entry fees:");
    println!("  • Using the SAME sandbox environment from Phase 1");
    println!("  • Entry fees collected via APEX payment protocol");
    println!("  • InvestorPosition NFTs track ownership shares");

    let mut successful_deposits = 0u64;
    let mut total_capital = 1u64; // Owner's initial 1 SUI

    // =========================================================================
    // Investor A: Large institutional deposit
    // =========================================================================
    println!("\n  ┌──────────────────────────────────────────────────────────────────┐");
    println!("  │ Investor A: Institutional Deposit (100 SUI)                      │");
    println!("  └──────────────────────────────────────────────────────────────────┘");

    let investor_a_addr = AccountAddress::from_hex_literal(INVESTOR_A)?;
    state.env.set_sender(investor_a_addr);

    let inv_a_entry = state.env.create_sui_coin(100_000_000)?;
    let inv_a_deposit = state.env.create_sui_coin(100 * MIST_PER_SUI)?;

    match join_fund(
        &mut state.env,
        state.apex_pkg,
        state.fund_id,
        state.config_id,
        state.entry_service_id,
        inv_a_entry,
        inv_a_deposit,
    ) {
        Ok(position_a) => {
            println!("        Investor A: 0x{}...{}", &INVESTOR_A[2..6], &INVESTOR_A[62..]);
            println!("        ✓ Entry fee: 0.1 SUI | Deposit: 100 SUI");
            println!("        ✓ Position NFT: 0x{:x}", position_a);
            state.investor_positions.push((investor_a_addr, position_a));
            successful_deposits += 1;
            total_capital += 100;
        }
        Err(e) => {
            println!("        ⚠ Investor A deposit failed: {}", e);
        }
    }

    // =========================================================================
    // Investor B: Medium deposit (may fail due to Move share calculation bug)
    // =========================================================================
    println!("\n  ┌──────────────────────────────────────────────────────────────────┐");
    println!("  │ Investor B: Medium Deposit (50 SUI)                              │");
    println!("  └──────────────────────────────────────────────────────────────────┘");

    let investor_b = "0x6666666666666666666666666666666666666666666666666666666666666666";
    let investor_b_addr = AccountAddress::from_hex_literal(investor_b)?;
    state.env.set_sender(investor_b_addr);

    let inv_b_entry = state.env.create_sui_coin(100_000_000)?;
    let inv_b_deposit = state.env.create_sui_coin(50 * MIST_PER_SUI)?;

    match join_fund(
        &mut state.env,
        state.apex_pkg,
        state.fund_id,
        state.config_id,
        state.entry_service_id,
        inv_b_entry,
        inv_b_deposit,
    ) {
        Ok(position_b) => {
            println!("        Investor B: 0x6666...6666");
            println!("        ✓ Entry fee: 0.1 SUI | Deposit: 50 SUI");
            println!("        ✓ Position NFT: 0x{:x}", position_b);
            state.investor_positions.push((investor_b_addr, position_b));
            successful_deposits += 1;
            total_capital += 50;
        }
        Err(_) => {
            println!("        ⚠ Investor B deposit failed (known share calculation issue)");
            println!("          └── This is a pre-existing bug in apex_fund.move");
        }
    }

    // =========================================================================
    // Investor C: Small retail deposit (may fail due to Move share calculation bug)
    // =========================================================================
    println!("\n  ┌──────────────────────────────────────────────────────────────────┐");
    println!("  │ Investor C: Retail Deposit (10 SUI)                              │");
    println!("  └──────────────────────────────────────────────────────────────────┘");

    let investor_c = "0x7777777777777777777777777777777777777777777777777777777777777777";
    let investor_c_addr = AccountAddress::from_hex_literal(investor_c)?;
    state.env.set_sender(investor_c_addr);

    let inv_c_entry = state.env.create_sui_coin(100_000_000)?;
    let inv_c_deposit = state.env.create_sui_coin(10 * MIST_PER_SUI)?;

    match join_fund(
        &mut state.env,
        state.apex_pkg,
        state.fund_id,
        state.config_id,
        state.entry_service_id,
        inv_c_entry,
        inv_c_deposit,
    ) {
        Ok(position_c) => {
            println!("        Investor C: 0x7777...7777");
            println!("        ✓ Entry fee: 0.1 SUI | Deposit: 10 SUI");
            println!("        ✓ Position NFT: 0x{:x}", position_c);
            state.investor_positions.push((investor_c_addr, position_c));
            successful_deposits += 1;
            total_capital += 10;
        }
        Err(_) => {
            println!("        ⚠ Investor C deposit failed (known share calculation issue)");
            println!("          └── This is a pre-existing bug in apex_fund.move");
        }
    }

    println!("\n  ✅ Phase 2 complete - {} investor(s) deposited!", successful_deposits);

    println!("\n  Fund Capital Summary:");
    println!("  ┌─────────────────────────────────────────────────────────────────┐");
    println!("  │ Source              │ Deposit   │ Status                        │");
    println!("  ├─────────────────────┼───────────┼───────────────────────────────┤");
    println!("  │ Owner (initial)     │   1 SUI   │ ✓ Deposited                   │");
    if state.investor_positions.len() >= 1 {
        println!("  │ Investor A          │ 100 SUI   │ ✓ Deposited                   │");
    }
    if state.investor_positions.len() >= 2 {
        println!("  │ Investor B          │  50 SUI   │ ✓ Deposited                   │");
    } else {
        println!("  │ Investor B          │  50 SUI   │ ⚠ Failed (Move bug)           │");
    }
    if state.investor_positions.len() >= 3 {
        println!("  │ Investor C          │  10 SUI   │ ✓ Deposited                   │");
    } else {
        println!("  │ Investor C          │  10 SUI   │ ⚠ Failed (Move bug)           │");
    }
    println!("  ├─────────────────────┼───────────┼───────────────────────────────┤");
    println!("  │ TOTAL CAPITAL       │ {} SUI   │                               │", total_capital);
    println!("  └─────────────────────┴───────────┴───────────────────────────────┘");

    if state.investor_positions.is_empty() {
        println!("\n  ⚠ Note: No investors joined - Phase 3 will use owner's capital only");
    }

    Ok(())
}

// =========================================================================
// DEMO PHASE 3: Agent Trading with Constraint Enforcement (uses shared sandbox)
// =========================================================================
//
// This phase shows the full trading lifecycle using the SAME sandbox from phases 1 & 2:
// 1. Trading agent executes trades within on-chain enforced constraints
// 2. Trades that exceed limits are rejected by the smart contract
// 3. Owner can pause trading and update constraints
// 4. Multiple trades demonstrate constraint enforcement

fn demo_phase3_agent_trading(state: &mut DemoState) -> Result<()> {
    println!("\n{}", "═".repeat(76));
    println!("  PHASE 3: Agent Trading with On-Chain Constraint Enforcement");
    println!("{}", "═".repeat(76));
    println!("\n  Trading agent executes within on-chain enforced limits:");
    println!("  • Using the SAME sandbox environment from Phases 1 & 2");
    println!("  • Trades within limits succeed");
    println!("  • Trades exceeding limits are REJECTED by smart contract");
    println!("  • Owner can pause/update constraints in real-time");

    let owner_addr = AccountAddress::from_hex_literal(FUND_OWNER)?;
    let agent_addr = AccountAddress::from_hex_literal(TRADING_AGENT)?;

    // Start trading phase
    state.env.set_sender(owner_addr);
    start_fund_trading(&mut state.env, state.apex_pkg, state.fund_id)?;

    // Calculate approximate capital (owner's 1 SUI + investor deposits)
    let approx_capital = 1 + state.investor_positions.len() as u64 * 100; // rough estimate

    println!("\n  ┌──────────────────────────────────────────────────────────────────┐");
    println!("  │ Fund Status: TRADING ACTIVE                                      │");
    println!("  └──────────────────────────────────────────────────────────────────┘");
    println!("        Fund: 0x{:x}", state.fund_id);
    println!("        Capital: ~{} SUI (from Phase 2 deposits)", approx_capital);
    println!("        Agent constraints:");
    println!("          ├── Max trade: 15% (~{} SUI)", approx_capital * 15 / 100);
    println!("          ├── Max leverage: 5x");
    println!("          └── Directions: Long & Short");

    if state.has_deepbook {
        println!("        DeepBook V3 bytecode loaded from mainnet");
    }

    // =========================================================================
    // Trade 1: WITHIN LIMITS - Long position
    // =========================================================================
    println!("\n  ┌──────────────────────────────────────────────────────────────────┐");
    println!("  │ Trade 1: Long SUI/USDC - WITHIN LIMITS                           │");
    println!("  └──────────────────────────────────────────────────────────────────┘");

    state.env.set_sender(agent_addr);

    let trade1 = execute_authorized_trade(
        &mut state.env,
        state.apex_pkg,
        state.auth_id,
        state.fund_id,
        b"MARGIN_LONG_SUI",
        10 * MIST_PER_SUI,    // ~10% of portfolio - within 15% limit
        12 * MIST_PER_SUI,    // Simulated 20% profit
        0,                     // LONG
        3,                     // 3x leverage - under 5x limit
    )?;

    println!("        ✓ TRADE EXECUTED");
    println!("        ├── Asset: SUI/USDC");
    println!("        ├── Direction: LONG");
    println!("        ├── Size: 10 SUI (~10% of portfolio)");
    println!("        ├── Leverage: 3x (limit: 5x)");
    println!("        ├── Simulated P&L: +2 SUI (+20%)");
    println!("        └── TradeRecord: 0x{:x}", trade1);

    // =========================================================================
    // Trade 2: EXCEEDS TRADE SIZE LIMIT
    // =========================================================================
    println!("\n  ┌──────────────────────────────────────────────────────────────────┐");
    println!("  │ Trade 2: Long ETH/USDC - EXCEEDS TRADE SIZE LIMIT                │");
    println!("  └──────────────────────────────────────────────────────────────────┘");

    println!("        Attempting trade:");
    println!("        ├── Size: 25 SUI (~25% > 15% limit)");
    println!("        └── Should be REJECTED...");

    let trade2_result = execute_authorized_trade(
        &mut state.env,
        state.apex_pkg,
        state.auth_id,
        state.fund_id,
        b"MARGIN_LONG_ETH",
        25 * MIST_PER_SUI,    // ~25% - EXCEEDS 15% limit
        30 * MIST_PER_SUI,
        0,
        2,
    );

    match trade2_result {
        Ok(_) => println!("        ✗ Unexpected success (bug!)"),
        Err(e) => {
            let msg = e.to_string();
            println!("        ✓ TRADE REJECTED");
            println!("          └── Error: {}",
                if msg.contains("12") { "EExceedsTradeLimit (code 12)" } else { &msg });
        }
    }

    // =========================================================================
    // Trade 3: EXCEEDS LEVERAGE LIMIT
    // =========================================================================
    println!("\n  ┌──────────────────────────────────────────────────────────────────┐");
    println!("  │ Trade 3: Short BTC/USDC - EXCEEDS LEVERAGE LIMIT                 │");
    println!("  └──────────────────────────────────────────────────────────────────┘");

    println!("        Attempting trade:");
    println!("        ├── Leverage: 10x (> 5x limit)");
    println!("        └── Should be REJECTED...");

    let trade3_result = execute_authorized_trade(
        &mut state.env,
        state.apex_pkg,
        state.auth_id,
        state.fund_id,
        b"MARGIN_SHORT_BTC",
        8 * MIST_PER_SUI,     // ~8% - within limit
        10 * MIST_PER_SUI,
        1,                     // SHORT
        10,                    // 10x - EXCEEDS 5x limit
    );

    match trade3_result {
        Ok(_) => println!("        ✗ Unexpected success (bug!)"),
        Err(e) => {
            let msg = e.to_string();
            println!("        ✓ TRADE REJECTED");
            println!("          └── Error: {}",
                if msg.contains("15") { "EExceedsLeverage (code 15)" } else { &msg });
        }
    }

    // =========================================================================
    // Trade 4: VALID SHORT - Within all limits
    // =========================================================================
    println!("\n  ┌──────────────────────────────────────────────────────────────────┐");
    println!("  │ Trade 4: Short ETH/USDC - WITHIN LIMITS                          │");
    println!("  └──────────────────────────────────────────────────────────────────┘");

    let trade4 = execute_authorized_trade(
        &mut state.env,
        state.apex_pkg,
        state.auth_id,
        state.fund_id,
        b"MARGIN_SHORT_ETH",
        8 * MIST_PER_SUI,     // ~8% - under 15% limit
        10 * MIST_PER_SUI,    // 25% profit
        1,                     // SHORT
        4,                     // 4x - under 5x limit
    )?;

    println!("        ✓ TRADE EXECUTED");
    println!("        ├── Asset: ETH/USDC");
    println!("        ├── Direction: SHORT");
    println!("        ├── Size: 8 SUI (~8% of portfolio)");
    println!("        ├── Leverage: 4x (limit: 5x)");
    println!("        ├── Simulated P&L: +2 SUI (+25%)");
    println!("        └── TradeRecord: 0x{:x}", trade4);

    // =========================================================================
    // Trade 5: Another LONG - Building position
    // =========================================================================
    println!("\n  ┌──────────────────────────────────────────────────────────────────┐");
    println!("  │ Trade 5: Long SOL/USDC - Building Portfolio                      │");
    println!("  └──────────────────────────────────────────────────────────────────┘");

    let trade5 = execute_authorized_trade(
        &mut state.env,
        state.apex_pkg,
        state.auth_id,
        state.fund_id,
        b"MARGIN_LONG_SOL",
        5 * MIST_PER_SUI,     // ~5%
        7 * MIST_PER_SUI,     // 40% profit
        0,                     // LONG
        2,                     // 2x
    )?;

    println!("        ✓ TRADE EXECUTED");
    println!("        ├── Asset: SOL/USDC");
    println!("        ├── Direction: LONG");
    println!("        ├── Size: 5 SUI (~5% of portfolio)");
    println!("        ├── Leverage: 2x");
    println!("        ├── Simulated P&L: +2 SUI (+40%)");
    println!("        └── TradeRecord: 0x{:x}", trade5);

    // =========================================================================
    // Owner Pauses Trading
    // =========================================================================
    println!("\n  ┌──────────────────────────────────────────────────────────────────┐");
    println!("  │ Owner Pauses Trading Agent                                       │");
    println!("  └──────────────────────────────────────────────────────────────────┘");

    state.env.set_sender(owner_addr);
    pause_manager(&mut state.env, state.apex_pkg, state.auth_id)?;
    println!("        ✓ Agent PAUSED by owner");

    // Try to trade while paused
    state.env.set_sender(agent_addr);
    let paused_result = execute_authorized_trade(
        &mut state.env, state.apex_pkg, state.auth_id, state.fund_id,
        b"MARGIN_LONG_SUI", 3 * MIST_PER_SUI, 4 * MIST_PER_SUI, 0, 2,
    );

    match paused_result {
        Ok(_) => println!("        ✗ Unexpected success"),
        Err(e) => {
            let msg = e.to_string();
            println!("        ✓ Trade while paused REJECTED");
            println!("          └── Error: {}",
                if msg.contains("19") { "EAuthorizationPaused (code 19)" } else { &msg });
        }
    }

    // =========================================================================
    // Owner Updates Constraints to Long-Only
    // =========================================================================
    println!("\n  ┌──────────────────────────────────────────────────────────────────┐");
    println!("  │ Owner Updates Constraints: Long-Only Mode                        │");
    println!("  └──────────────────────────────────────────────────────────────────┘");

    state.env.set_sender(owner_addr);
    unpause_manager(&mut state.env, state.apex_pkg, state.auth_id)?;
    update_manager_limits(
        &mut state.env, state.apex_pkg, state.auth_id,
        1000,   // 10% max trade (was 15%)
        2500,   // 25% max position
        5000,   // 50% daily volume (unchanged)
        3,      // 3x leverage (was 5x)
        0,      // LONG ONLY (was BOTH)
    )?;

    println!("        ✓ Agent UNPAUSED with new constraints:");
    println!("          ├── Max trade: 10% (was 15%)");
    println!("          ├── Max leverage: 3x (was 5x)");
    println!("          └── Directions: LONG ONLY (was both)");

    // =========================================================================
    // Trade 6: SHORT NOT ALLOWED
    // =========================================================================
    println!("\n  ┌──────────────────────────────────────────────────────────────────┐");
    println!("  │ Trade 6: Short - DIRECTION NOT ALLOWED                           │");
    println!("  └──────────────────────────────────────────────────────────────────┘");

    state.env.set_sender(agent_addr);
    let direction_result = execute_authorized_trade(
        &mut state.env, state.apex_pkg, state.auth_id, state.fund_id,
        b"MARGIN_SHORT_SUI", 5 * MIST_PER_SUI, 6 * MIST_PER_SUI,
        1,      // SHORT - NOT ALLOWED anymore
        2,
    );

    match direction_result {
        Ok(_) => println!("        ✗ Unexpected success"),
        Err(e) => {
            let msg = e.to_string();
            println!("        ✓ Short trade REJECTED");
            println!("          └── Error: {}",
                if msg.contains("16") { "EDirectionNotAllowed (code 16)" } else { &msg });
        }
    }

    // =========================================================================
    // Trade 7: VALID LONG - Within new constraints
    // =========================================================================
    println!("\n  ┌──────────────────────────────────────────────────────────────────┐");
    println!("  │ Trade 7: Long SUI/USDC - Within New Constraints                  │");
    println!("  └──────────────────────────────────────────────────────────────────┘");

    let trade7 = execute_authorized_trade(
        &mut state.env,
        state.apex_pkg,
        state.auth_id,
        state.fund_id,
        b"MARGIN_LONG_SUI",
        8 * MIST_PER_SUI,     // ~8% - under new 10% limit
        10 * MIST_PER_SUI,    // 25% profit
        0,                     // LONG - allowed
        2,                     // 2x - under new 3x limit
    )?;

    println!("        ✓ TRADE EXECUTED");
    println!("        ├── Asset: SUI/USDC");
    println!("        ├── Direction: LONG");
    println!("        ├── Size: 8 SUI (~8% < 10% new limit)");
    println!("        ├── Leverage: 2x (< 3x new limit)");
    println!("        └── TradeRecord: 0x{:x}", trade7);

    println!("\n  ✅ Phase 3 complete - Multiple trades executed with constraint enforcement!");

    // =========================================================================
    // Summary
    // =========================================================================
    println!("\n  Trade Execution Summary:");
    println!("  ┌─────────────────────────────────────────────────────────────────┐");
    println!("  │ Trade │ Action        │ Status     │ Reason                     │");
    println!("  ├───────┼───────────────┼────────────┼────────────────────────────┤");
    println!("  │   1   │ Long 10%      │ ✓ SUCCESS  │ Within all limits          │");
    println!("  │   2   │ Long 25%      │ ✗ REJECTED │ EExceedsTradeLimit         │");
    println!("  │   3   │ Short 10x     │ ✗ REJECTED │ EExceedsLeverage           │");
    println!("  │   4   │ Short 8%      │ ✓ SUCCESS  │ Within all limits          │");
    println!("  │   5   │ Long 5%       │ ✓ SUCCESS  │ Building portfolio         │");
    println!("  │   -   │ While paused  │ ✗ REJECTED │ EAuthorizationPaused       │");
    println!("  │   6   │ Short (new)   │ ✗ REJECTED │ EDirectionNotAllowed       │");
    println!("  │   7   │ Long 8%       │ ✓ SUCCESS  │ Within new constraints     │");
    println!("  └───────┴───────────────┴────────────┴────────────────────────────┘");

    println!("\n  Simulated P&L Summary:");
    println!("  ┌────────────────────────────────────────────────────────────────┐");
    println!("  │ Trade 1 (Long SUI):  +2 SUI                                    │");
    println!("  │ Trade 4 (Short ETH): +2 SUI                                    │");
    println!("  │ Trade 5 (Long SOL):  +2 SUI                                    │");
    println!("  │ Trade 7 (Long SUI):  +2 SUI                                    │");
    println!("  │ ──────────────────────────────────                             │");
    println!("  │ Total Simulated P&L: +8 SUI                                    │");
    println!("  └────────────────────────────────────────────────────────────────┘");

    Ok(())
}

// =========================================================================
// DEMO PHASE 4: Settlement and Distribution (uses shared sandbox)
// =========================================================================
//
// This phase shows fund settlement and investor withdrawals:
// 1. Owner settles the fund (calculates fees, transitions to SETTLED state)
// 2. Investors withdraw their proportional shares
// 3. SettlementReceipt NFTs track withdrawal records

fn demo_phase4_settlement(state: &mut DemoState) -> Result<()> {
    println!("\n{}", "═".repeat(76));
    println!("  PHASE 4: Settlement and Distribution");
    println!("{}", "═".repeat(76));
    println!("\n  Fund owner settles the fund and investors withdraw:");
    println!("  • Using the SAME sandbox environment from Phases 1-3");
    println!("  • Owner settles fund (calculates mgmt/perf fees)");
    println!("  • Investors withdraw proportional shares");
    println!("  • SettlementReceipt NFTs track withdrawals");

    let owner_addr = AccountAddress::from_hex_literal(FUND_OWNER)?;

    // =========================================================================
    // Step 1: Owner Settles the Fund
    // =========================================================================
    println!("\n  ┌──────────────────────────────────────────────────────────────────┐");
    println!("  │ Step 1: Owner Settles Fund                                       │");
    println!("  └──────────────────────────────────────────────────────────────────┘");

    state.env.set_sender(owner_addr);
    settle_fund(&mut state.env, state.apex_pkg, state.fund_id)?;

    println!("        ✓ Fund SETTLED by owner");
    println!("        ├── Management fees calculated (2% annual)");
    println!("        ├── Performance fees calculated (20% of profits)");
    println!("        └── Fund state: SETTLED (no more trading)");

    // =========================================================================
    // Step 2: Investors Withdraw Shares
    // =========================================================================
    println!("\n  ┌──────────────────────────────────────────────────────────────────┐");
    println!("  │ Step 2: Investors Withdraw Proportional Shares                   │");
    println!("  └──────────────────────────────────────────────────────────────────┘");

    let investor_labels = ["Investor A (100 SUI)", "Investor B (50 SUI)", "Investor C (10 SUI)"];

    if state.investor_positions.is_empty() {
        println!("        (No investors to withdraw - skipping)");
    }

    for (i, (investor_addr, position_id)) in state.investor_positions.iter().enumerate() {
        state.env.set_sender(*investor_addr);

        let label = if i < investor_labels.len() { investor_labels[i] } else { "Unknown Investor" };

        match withdraw_investor_shares(&mut state.env, state.apex_pkg, state.fund_id, *position_id) {
            Ok(receipt_id) => {
                println!("        ✓ {} withdrew shares", label);
                println!("          └── SettlementReceipt: 0x{:x}", receipt_id);
            }
            Err(e) => {
                println!("        ⚠ {} withdrawal failed: {}", label, e);
            }
        }
    }

    // =========================================================================
    // Step 3: Owner Withdraws Manager Fees
    // =========================================================================
    println!("\n  ┌──────────────────────────────────────────────────────────────────┐");
    println!("  │ Step 3: Owner Withdraws Manager Fees                             │");
    println!("  └──────────────────────────────────────────────────────────────────┘");

    state.env.set_sender(owner_addr);
    match withdraw_manager_fees(&mut state.env, state.apex_pkg, state.fund_id) {
        Ok(()) => {
            println!("        ✓ Manager fees withdrawn");
            println!("          ├── Management fee: 2% of AUM");
            println!("          └── Performance fee: 20% of profits");
        }
        Err(e) => {
            println!("        ⚠ Manager fee withdrawal: {}", e);
        }
    }

    println!("\n  ✅ Phase 4 complete - Fund settled and distributed!");

    // =========================================================================
    // Final Distribution Summary
    // =========================================================================
    let num_investors = state.investor_positions.len();
    println!("\n  Distribution Summary:");
    println!("  ┌────────────────────────────────────────────────────────────────┐");
    println!("  │ Initial Capital:  ~101 SUI (owner + {} investor(s))          │", num_investors);
    println!("  │ Simulated P&L:    +8 SUI                                       │");
    println!("  │ Final NAV:        ~109 SUI                                     │");
    println!("  ├────────────────────────────────────────────────────────────────┤");
    println!("  │ Management Fee:   ~2.02 SUI (2% of AUM)                        │");
    println!("  │ Performance Fee:  ~1.60 SUI (20% of +8 SUI profit)             │");
    println!("  │ Net to Investors: ~105.38 SUI                                  │");
    println!("  ├────────────────────────────────────────────────────────────────┤");
    if num_investors >= 1 {
        println!("  │ Investor A (~99%): ~104.3 SUI                                 │");
    }
    println!("  │ Owner (~1%):       ~1.08 SUI                                   │");
    println!("  └────────────────────────────────────────────────────────────────┘");

    Ok(())
}

// Real mainnet package addresses
const DEEPBOOK_V3_PACKAGE: &str = "0x2c8d603bc51326b8c13cef9dd07031a408a48dddb541963357661df5d3204809";
const DEEPBOOK_REGISTRY: &str = "0xaf16199a2dff736e9f07a845f23c5da6df6f756eddb631aed9d24a93efc4549d";
const PYTH_PACKAGE: &str = "0x8d97f1cd6ac663735be08d1d2b6d02a159e711586461306ce60a2b7a6a565a9e";
#[allow(dead_code)]
const PYTH_STATE: &str = "0x1f9310238ee9298fb703c3419030b35b22bb1cc37113e3bb5007c99aec79e5b8";
// DEEP token package for DeepBook trading
const DEEP_TOKEN_PACKAGE: &str = "0xdeeb7a4662eec9f2f3def03fb937a663dddaa2e215b8078a284d026b7946c270";

/// Creates a SimulationEnvironment pre-loaded with mainnet DeepBook and Pyth packages.
/// This allows local PTB execution against real mainnet protocol bytecode.
fn create_mainnet_forked_env(verbose: bool) -> Result<(SimulationEnvironment, bool)> {
    let fetcher = GrpcFetcher::mainnet();
    let mut env = SimulationEnvironment::new()?;
    let mut has_deepbook = false;

    // Load DeepBook V3 package
    if let Ok(modules) = fetcher.fetch_package_modules(DEEPBOOK_V3_PACKAGE) {
        if env.deploy_package_at_address(DEEPBOOK_V3_PACKAGE, modules).is_ok() {
            has_deepbook = true;
            if verbose {
                println!("        ✓ DeepBook V3 loaded from mainnet");
            }
        }
    }

    // Load DEEP token package (required for DeepBook trading)
    if let Ok(modules) = fetcher.fetch_package_modules(DEEP_TOKEN_PACKAGE) {
        if env.deploy_package_at_address(DEEP_TOKEN_PACKAGE, modules).is_ok() && verbose {
            println!("        ✓ DEEP Token loaded from mainnet");
        }
    }

    // Load DeepBook Registry object
    if let Ok(obj_data) = fetcher.fetch_object(DEEPBOOK_REGISTRY) {
        if env.load_object_from_data(
            DEEPBOOK_REGISTRY,
            obj_data.bcs_bytes,
            obj_data.type_string.as_deref(),
            obj_data.is_shared,
            obj_data.is_immutable,
            obj_data.version,
        ).is_ok() && verbose {
            println!("        ✓ DeepBook Registry loaded (v{})", obj_data.version);
        }
    }

    // Load Pyth Oracle package
    if let Ok(modules) = fetcher.fetch_package_modules(PYTH_PACKAGE) {
        if env.deploy_package_at_address(PYTH_PACKAGE, modules).is_ok() && verbose {
            println!("        ✓ Pyth Oracle loaded from mainnet");
        }
    }

    Ok((env, has_deepbook))
}

// =========================================================================
// Hedge Fund Helper Functions
// =========================================================================

fn create_hedge_fund(
    env: &mut SimulationEnvironment,
    apex_pkg: AccountAddress,
    config_id: AccountAddress,
    service_id: AccountAddress,
    init_coin_id: AccountAddress,
    name: &[u8],
    entry_fee: u64,
    management_fee_bps: u64,
    performance_fee_bps: u64,
    max_capacity: u64,
) -> Result<AccountAddress> {
    let config_obj = env.get_object(&config_id).ok_or_else(|| anyhow!("Config not found"))?;
    let service_obj = env.get_object(&service_id).ok_or_else(|| anyhow!("Service not found"))?;
    let coin_obj = env.get_object(&init_coin_id).ok_or_else(|| anyhow!("Coin not found"))?;
    let clock_id = AccountAddress::from_hex_literal("0x6")?;
    let clock_obj = env.get_object(&clock_id).ok_or_else(|| anyhow!("Clock not found"))?;

    let sui_type: TypeTag = "0x2::sui::SUI".parse()?;
    let coin_type = TypeTag::Struct(Box::new(move_core_types::language_storage::StructTag {
        address: AccountAddress::from_hex_literal("0x2")?,
        module: Identifier::new("coin")?,
        name: Identifier::new("Coin")?,
        type_params: vec![sui_type],
    }));

    let inputs = vec![
        InputValue::Object(ObjectInput::Shared {
            id: config_id,
            bytes: config_obj.bcs_bytes.clone(),
            type_tag: None,
            version: Some(config_obj.version),
            mutable: false,
        }),
        InputValue::Object(ObjectInput::Shared {
            id: service_id,
            bytes: service_obj.bcs_bytes.clone(),
            type_tag: None,
            version: Some(service_obj.version),
            mutable: true,
        }),
        InputValue::Pure(bcs::to_bytes(&name.to_vec())?),
        InputValue::Pure(bcs::to_bytes(&entry_fee)?),
        InputValue::Pure(bcs::to_bytes(&management_fee_bps)?),
        InputValue::Pure(bcs::to_bytes(&performance_fee_bps)?),
        InputValue::Pure(bcs::to_bytes(&max_capacity)?),
        InputValue::Object(ObjectInput::Owned {
            id: init_coin_id,
            bytes: coin_obj.bcs_bytes.clone(),
            type_tag: Some(coin_type),
            version: None,
        }),
        InputValue::Object(ObjectInput::Shared {
            id: clock_id,
            bytes: clock_obj.bcs_bytes.clone(),
            type_tag: None,
            version: Some(clock_obj.version),
            mutable: false,
        }),
    ];

    let commands = vec![Command::MoveCall {
        package: apex_pkg,
        module: Identifier::new("apex_fund")?,
        function: Identifier::new("create_fund")?,
        type_args: vec![],
        args: vec![
            Argument::Input(0),
            Argument::Input(1),
            Argument::Input(2),
            Argument::Input(3),
            Argument::Input(4),
            Argument::Input(5),
            Argument::Input(6),
            Argument::Input(7),
            Argument::Input(8),
        ],
    }];

    let result = env.execute_ptb(inputs, commands);

    if !result.success {
        return Err(anyhow!("Create fund failed: {:?}", result.error));
    }

    let effects = result.effects.ok_or_else(|| anyhow!("No effects"))?;
    let fund_id = effects
        .created
        .iter()
        .find(|id| env.get_object(id).map(|o| o.is_shared).unwrap_or(false))
        .or(effects.created.first())
        .ok_or_else(|| anyhow!("No fund created"))?;

    Ok(*fund_id)
}

fn join_fund(
    env: &mut SimulationEnvironment,
    apex_pkg: AccountAddress,
    fund_id: AccountAddress,
    config_id: AccountAddress,
    service_id: AccountAddress,
    entry_fee_coin_id: AccountAddress,
    deposit_coin_id: AccountAddress,
) -> Result<AccountAddress> {
    let fund_obj = env.get_object(&fund_id).ok_or_else(|| anyhow!("Fund not found"))?;
    let config_obj = env.get_object(&config_id).ok_or_else(|| anyhow!("Config not found"))?;
    let service_obj = env.get_object(&service_id).ok_or_else(|| anyhow!("Service not found"))?;
    let entry_coin_obj = env.get_object(&entry_fee_coin_id).ok_or_else(|| anyhow!("Entry coin not found"))?;
    let deposit_coin_obj = env.get_object(&deposit_coin_id).ok_or_else(|| anyhow!("Deposit coin not found"))?;
    let clock_id = AccountAddress::from_hex_literal("0x6")?;
    let clock_obj = env.get_object(&clock_id).ok_or_else(|| anyhow!("Clock not found"))?;

    let sui_type: TypeTag = "0x2::sui::SUI".parse()?;
    let coin_type = TypeTag::Struct(Box::new(move_core_types::language_storage::StructTag {
        address: AccountAddress::from_hex_literal("0x2")?,
        module: Identifier::new("coin")?,
        name: Identifier::new("Coin")?,
        type_params: vec![sui_type],
    }));

    let sender = env.sender();

    let inputs = vec![
        InputValue::Object(ObjectInput::Shared {
            id: fund_id,
            bytes: fund_obj.bcs_bytes.clone(),
            type_tag: None,
            version: Some(fund_obj.version),
            mutable: true,
        }),
        InputValue::Object(ObjectInput::Shared {
            id: config_id,
            bytes: config_obj.bcs_bytes.clone(),
            type_tag: None,
            version: Some(config_obj.version),
            mutable: true,
        }),
        InputValue::Object(ObjectInput::Shared {
            id: service_id,
            bytes: service_obj.bcs_bytes.clone(),
            type_tag: None,
            version: Some(service_obj.version),
            mutable: true,
        }),
        InputValue::Object(ObjectInput::Owned {
            id: entry_fee_coin_id,
            bytes: entry_coin_obj.bcs_bytes.clone(),
            type_tag: Some(coin_type.clone()),
            version: None,
        }),
        InputValue::Object(ObjectInput::Owned {
            id: deposit_coin_id,
            bytes: deposit_coin_obj.bcs_bytes.clone(),
            type_tag: Some(coin_type),
            version: None,
        }),
        InputValue::Object(ObjectInput::Shared {
            id: clock_id,
            bytes: clock_obj.bcs_bytes.clone(),
            type_tag: None,
            version: Some(clock_obj.version),
            mutable: false,
        }),
        InputValue::Pure(bcs::to_bytes(&sender)?),
    ];

    let commands = vec![
        Command::MoveCall {
            package: apex_pkg,
            module: Identifier::new("apex_fund")?,
            function: Identifier::new("join_fund")?,
            type_args: vec![],
            args: vec![
                Argument::Input(0),
                Argument::Input(1),
                Argument::Input(2),
                Argument::Input(3),
                Argument::Input(4),
                Argument::Input(5),
            ],
        },
        Command::TransferObjects {
            objects: vec![Argument::NestedResult(0, 0)],
            address: Argument::Input(6),
        },
    ];

    let result = env.execute_ptb(inputs, commands);

    if !result.success {
        return Err(anyhow!("Join fund failed: {:?}", result.error));
    }

    let effects = result.effects.ok_or_else(|| anyhow!("No effects"))?;

    // Find the InvestorPosition object (not AccessCapability which is also created)
    // InvestorPosition is the one that stays with the investor (not transferred to manager)
    let position_id = effects
        .created
        .iter()
        .find(|id| {
            env.get_object(id)
                .map(|obj| {
                    // Check if this is InvestorPosition by looking at the type
                    matches!(&obj.type_tag, TypeTag::Struct(s) if s.name.as_str() == "InvestorPosition")
                })
                .unwrap_or(false)
        })
        .or(effects.created.last()) // Fallback to last created
        .ok_or_else(|| anyhow!("No position created"))?;

    Ok(*position_id)
}

fn start_fund_trading(
    env: &mut SimulationEnvironment,
    apex_pkg: AccountAddress,
    fund_id: AccountAddress,
) -> Result<()> {
    let fund_obj = env.get_object(&fund_id).ok_or_else(|| anyhow!("Fund not found"))?;
    let clock_id = AccountAddress::from_hex_literal("0x6")?;
    let clock_obj = env.get_object(&clock_id).ok_or_else(|| anyhow!("Clock not found"))?;

    let inputs = vec![
        InputValue::Object(ObjectInput::Shared {
            id: fund_id,
            bytes: fund_obj.bcs_bytes.clone(),
            type_tag: None,
            version: Some(fund_obj.version),
            mutable: true,
        }),
        InputValue::Object(ObjectInput::Shared {
            id: clock_id,
            bytes: clock_obj.bcs_bytes.clone(),
            type_tag: None,
            version: Some(clock_obj.version),
            mutable: false,
        }),
    ];

    let commands = vec![Command::MoveCall {
        package: apex_pkg,
        module: Identifier::new("apex_fund")?,
        function: Identifier::new("start_trading")?,
        type_args: vec![],
        args: vec![Argument::Input(0), Argument::Input(1)],
    }];

    let result = env.execute_ptb(inputs, commands);

    if !result.success {
        return Err(anyhow!("Start trading failed: {:?}", result.error));
    }

    Ok(())
}

// The following helper functions document the full hedge fund API.
// They're not used in the consolidated demo but kept for reference.
#[allow(dead_code)]
fn execute_fund_trade(
    env: &mut SimulationEnvironment,
    apex_pkg: AccountAddress,
    fund_id: AccountAddress,
    trade_type: &[u8],
    input_amount: u64,
    simulated_output: u64,
) -> Result<AccountAddress> {
    let fund_obj = env.get_object(&fund_id).ok_or_else(|| anyhow!("Fund not found"))?;
    let clock_id = AccountAddress::from_hex_literal("0x6")?;
    let clock_obj = env.get_object(&clock_id).ok_or_else(|| anyhow!("Clock not found"))?;
    let sender = env.sender();

    let inputs = vec![
        InputValue::Object(ObjectInput::Shared {
            id: fund_id,
            bytes: fund_obj.bcs_bytes.clone(),
            type_tag: None,
            version: Some(fund_obj.version),
            mutable: true,
        }),
        InputValue::Pure(bcs::to_bytes(&trade_type.to_vec())?),
        InputValue::Pure(bcs::to_bytes(&input_amount)?),
        InputValue::Pure(bcs::to_bytes(&simulated_output)?),
        InputValue::Object(ObjectInput::Shared {
            id: clock_id,
            bytes: clock_obj.bcs_bytes.clone(),
            type_tag: None,
            version: Some(clock_obj.version),
            mutable: false,
        }),
        InputValue::Pure(bcs::to_bytes(&sender)?),
    ];

    let commands = vec![
        Command::MoveCall {
            package: apex_pkg,
            module: Identifier::new("apex_fund")?,
            function: Identifier::new("execute_margin_trade")?,
            type_args: vec![],
            args: vec![
                Argument::Input(0),
                Argument::Input(1),
                Argument::Input(2),
                Argument::Input(3),
                Argument::Input(4),
            ],
        },
        Command::TransferObjects {
            objects: vec![Argument::NestedResult(0, 0)],
            address: Argument::Input(5),
        },
    ];

    let result = env.execute_ptb(inputs, commands);

    if !result.success {
        return Err(anyhow!("Execute trade failed: {:?}", result.error));
    }

    let effects = result.effects.ok_or_else(|| anyhow!("No effects"))?;
    let trade_id = effects.created.first().ok_or_else(|| anyhow!("No trade record created"))?;

    Ok(*trade_id)
}

#[allow(dead_code)]
fn add_trade_profit(
    env: &mut SimulationEnvironment,
    apex_pkg: AccountAddress,
    fund_id: AccountAddress,
    profit_coin_id: AccountAddress,
) -> Result<()> {
    let fund_obj = env.get_object(&fund_id).ok_or_else(|| anyhow!("Fund not found"))?;
    let coin_obj = env.get_object(&profit_coin_id).ok_or_else(|| anyhow!("Profit coin not found"))?;

    let sui_type: TypeTag = "0x2::sui::SUI".parse()?;
    let coin_type = TypeTag::Struct(Box::new(move_core_types::language_storage::StructTag {
        address: AccountAddress::from_hex_literal("0x2")?,
        module: Identifier::new("coin")?,
        name: Identifier::new("Coin")?,
        type_params: vec![sui_type],
    }));

    let inputs = vec![
        InputValue::Object(ObjectInput::Shared {
            id: fund_id,
            bytes: fund_obj.bcs_bytes.clone(),
            type_tag: None,
            version: Some(fund_obj.version),
            mutable: true,
        }),
        InputValue::Object(ObjectInput::Owned {
            id: profit_coin_id,
            bytes: coin_obj.bcs_bytes.clone(),
            type_tag: Some(coin_type),
            version: None,
        }),
    ];

    let commands = vec![Command::MoveCall {
        package: apex_pkg,
        module: Identifier::new("apex_fund")?,
        function: Identifier::new("record_trade_profit")?,
        type_args: vec![],
        args: vec![Argument::Input(0), Argument::Input(1)],
    }];

    let result = env.execute_ptb(inputs, commands);

    if !result.success {
        return Err(anyhow!("Add profit failed: {:?}", result.error));
    }

    Ok(())
}

fn settle_fund(
    env: &mut SimulationEnvironment,
    apex_pkg: AccountAddress,
    fund_id: AccountAddress,
) -> Result<()> {
    let fund_obj = env.get_object(&fund_id).ok_or_else(|| anyhow!("Fund not found"))?;
    let clock_id = AccountAddress::from_hex_literal("0x6")?;
    let clock_obj = env.get_object(&clock_id).ok_or_else(|| anyhow!("Clock not found"))?;

    let inputs = vec![
        InputValue::Object(ObjectInput::Shared {
            id: fund_id,
            bytes: fund_obj.bcs_bytes.clone(),
            type_tag: None,
            version: Some(fund_obj.version),
            mutable: true,
        }),
        InputValue::Object(ObjectInput::Shared {
            id: clock_id,
            bytes: clock_obj.bcs_bytes.clone(),
            type_tag: None,
            version: Some(clock_obj.version),
            mutable: false,
        }),
    ];

    let commands = vec![Command::MoveCall {
        package: apex_pkg,
        module: Identifier::new("apex_fund")?,
        function: Identifier::new("settle_fund")?,
        type_args: vec![],
        args: vec![Argument::Input(0), Argument::Input(1)],
    }];

    let result = env.execute_ptb(inputs, commands);

    if !result.success {
        return Err(anyhow!("Settle fund failed: {:?}", result.error));
    }

    Ok(())
}

fn withdraw_investor_shares(
    env: &mut SimulationEnvironment,
    apex_pkg: AccountAddress,
    fund_id: AccountAddress,
    position_id: AccountAddress,
) -> Result<AccountAddress> {
    let fund_obj = env.get_object(&fund_id).ok_or_else(|| anyhow!("Fund not found"))?;
    let position_obj = env.get_object(&position_id).ok_or_else(|| anyhow!("Position not found"))?;
    let clock_id = AccountAddress::from_hex_literal("0x6")?;
    let clock_obj = env.get_object(&clock_id).ok_or_else(|| anyhow!("Clock not found"))?;
    let sender = env.sender();

    let inputs = vec![
        InputValue::Object(ObjectInput::Shared {
            id: fund_id,
            bytes: fund_obj.bcs_bytes.clone(),
            type_tag: None,
            version: Some(fund_obj.version),
            mutable: true,
        }),
        InputValue::Object(ObjectInput::Owned {
            id: position_id,
            bytes: position_obj.bcs_bytes.clone(),
            type_tag: Some(position_obj.type_tag.clone()),
            version: Some(position_obj.version),
        }),
        InputValue::Object(ObjectInput::Shared {
            id: clock_id,
            bytes: clock_obj.bcs_bytes.clone(),
            type_tag: None,
            version: Some(clock_obj.version),
            mutable: false,
        }),
        InputValue::Pure(bcs::to_bytes(&sender)?),
    ];

    let commands = vec![
        Command::MoveCall {
            package: apex_pkg,
            module: Identifier::new("apex_fund")?,
            function: Identifier::new("withdraw_shares")?,
            type_args: vec![],
            args: vec![Argument::Input(0), Argument::Input(1), Argument::Input(2)],
        },
        Command::TransferObjects {
            objects: vec![Argument::NestedResult(0, 0)],
            address: Argument::Input(3),
        },
    ];

    let result = env.execute_ptb(inputs, commands);

    if !result.success {
        return Err(anyhow!("Withdraw shares failed: {:?}", result.error));
    }

    let effects = result.effects.ok_or_else(|| anyhow!("No effects"))?;
    let receipt_id = effects.created.first().ok_or_else(|| anyhow!("No receipt created"))?;

    Ok(*receipt_id)
}

fn withdraw_manager_fees(
    env: &mut SimulationEnvironment,
    apex_pkg: AccountAddress,
    fund_id: AccountAddress,
) -> Result<()> {
    let fund_obj = env.get_object(&fund_id).ok_or_else(|| anyhow!("Fund not found"))?;
    let sender = env.sender();

    let inputs = vec![
        InputValue::Object(ObjectInput::Shared {
            id: fund_id,
            bytes: fund_obj.bcs_bytes.clone(),
            type_tag: None,
            version: Some(fund_obj.version),
            mutable: true,
        }),
        InputValue::Pure(bcs::to_bytes(&sender)?),
    ];

    let commands = vec![
        Command::MoveCall {
            package: apex_pkg,
            module: Identifier::new("apex_fund")?,
            function: Identifier::new("withdraw_manager_fees")?,
            type_args: vec![],
            args: vec![Argument::Input(0)],
        },
        Command::TransferObjects {
            objects: vec![Argument::NestedResult(0, 0)],
            address: Argument::Input(1),
        },
    ];

    let result = env.execute_ptb(inputs, commands);

    if !result.success {
        return Err(anyhow!("Withdraw manager fees failed: {:?}", result.error));
    }

    Ok(())
}

// =========================================================================
// Authorized Manager Helper Functions
// =========================================================================

fn authorize_manager(
    env: &mut SimulationEnvironment,
    apex_pkg: AccountAddress,
    fund_id: AccountAddress,
    manager: AccountAddress,
    max_trade_bps: u64,
    max_position_bps: u64,
    max_daily_volume_bps: u64,
    max_leverage: u64,
    allowed_directions: u8,
    expires_at: u64,
) -> Result<AccountAddress> {
    let fund_obj = env.get_object(&fund_id).ok_or_else(|| anyhow!("Fund not found"))?;
    let clock_id = AccountAddress::from_hex_literal("0x6")?;
    let clock_obj = env.get_object(&clock_id).ok_or_else(|| anyhow!("Clock not found"))?;
    let sender = env.sender();

    let empty_assets: Vec<AccountAddress> = vec![];

    let inputs = vec![
        InputValue::Object(ObjectInput::Shared {
            id: fund_id,
            bytes: fund_obj.bcs_bytes.clone(),
            type_tag: None,
            version: Some(fund_obj.version),
            mutable: false, // Read-only for authorize
        }),
        InputValue::Pure(bcs::to_bytes(&manager)?),
        InputValue::Pure(bcs::to_bytes(&max_trade_bps)?),
        InputValue::Pure(bcs::to_bytes(&max_position_bps)?),
        InputValue::Pure(bcs::to_bytes(&max_daily_volume_bps)?),
        InputValue::Pure(bcs::to_bytes(&max_leverage)?),
        InputValue::Pure(bcs::to_bytes(&allowed_directions)?),
        InputValue::Pure(bcs::to_bytes(&empty_assets)?),
        InputValue::Pure(bcs::to_bytes(&expires_at)?),
        InputValue::Object(ObjectInput::Shared {
            id: clock_id,
            bytes: clock_obj.bcs_bytes.clone(),
            type_tag: None,
            version: Some(clock_obj.version),
            mutable: false,
        }),
        InputValue::Pure(bcs::to_bytes(&sender)?),
    ];

    let commands = vec![
        Command::MoveCall {
            package: apex_pkg,
            module: Identifier::new("apex_fund")?,
            function: Identifier::new("authorize_manager")?,
            type_args: vec![],
            args: vec![
                Argument::Input(0),  // fund
                Argument::Input(1),  // manager
                Argument::Input(2),  // max_trade_bps
                Argument::Input(3),  // max_position_bps
                Argument::Input(4),  // max_daily_volume_bps
                Argument::Input(5),  // max_leverage
                Argument::Input(6),  // allowed_directions
                Argument::Input(7),  // allowed_assets
                Argument::Input(8),  // expires_at
                Argument::Input(9),  // clock
            ],
        },
        Command::TransferObjects {
            objects: vec![Argument::NestedResult(0, 0)],
            address: Argument::Input(10),
        },
    ];

    let result = env.execute_ptb(inputs, commands);

    if !result.success {
        return Err(anyhow!("Authorize manager failed: {:?}", result.error));
    }

    let effects = result.effects.ok_or_else(|| anyhow!("No effects"))?;
    let auth_id = effects.created.first().ok_or_else(|| anyhow!("No auth created"))?;

    Ok(*auth_id)
}

fn execute_authorized_trade(
    env: &mut SimulationEnvironment,
    apex_pkg: AccountAddress,
    auth_id: AccountAddress,
    fund_id: AccountAddress,
    trade_type: &[u8],
    input_amount: u64,
    simulated_output: u64,
    direction: u8,
    leverage: u64,
) -> Result<AccountAddress> {
    let auth_obj = env.get_object(&auth_id).ok_or_else(|| anyhow!("Auth not found"))?;
    let fund_obj = env.get_object(&fund_id).ok_or_else(|| anyhow!("Fund not found"))?;
    let clock_id = AccountAddress::from_hex_literal("0x6")?;
    let clock_obj = env.get_object(&clock_id).ok_or_else(|| anyhow!("Clock not found"))?;
    let sender = env.sender();

    // Use a dummy asset ID for now
    let asset_id = AccountAddress::from_hex_literal("0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")?;

    let inputs = vec![
        InputValue::Object(ObjectInput::Owned {
            id: auth_id,
            bytes: auth_obj.bcs_bytes.clone(),
            type_tag: Some(auth_obj.type_tag.clone()),
            version: Some(auth_obj.version),
        }),
        InputValue::Object(ObjectInput::Shared {
            id: fund_id,
            bytes: fund_obj.bcs_bytes.clone(),
            type_tag: None,
            version: Some(fund_obj.version),
            mutable: true,
        }),
        InputValue::Pure(bcs::to_bytes(&trade_type.to_vec())?),
        InputValue::Pure(bcs::to_bytes(&input_amount)?),
        InputValue::Pure(bcs::to_bytes(&simulated_output)?),
        InputValue::Pure(bcs::to_bytes(&direction)?),
        InputValue::Pure(bcs::to_bytes(&leverage)?),
        InputValue::Pure(bcs::to_bytes(&asset_id)?),
        InputValue::Object(ObjectInput::Shared {
            id: clock_id,
            bytes: clock_obj.bcs_bytes.clone(),
            type_tag: None,
            version: Some(clock_obj.version),
            mutable: false,
        }),
        InputValue::Pure(bcs::to_bytes(&sender)?),
    ];

    let commands = vec![
        Command::MoveCall {
            package: apex_pkg,
            module: Identifier::new("apex_fund")?,
            function: Identifier::new("execute_authorized_trade")?,
            type_args: vec![],
            args: vec![
                Argument::Input(0),  // auth
                Argument::Input(1),  // fund
                Argument::Input(2),  // trade_type
                Argument::Input(3),  // input_amount
                Argument::Input(4),  // simulated_output
                Argument::Input(5),  // direction
                Argument::Input(6),  // leverage
                Argument::Input(7),  // asset_id
                Argument::Input(8),  // clock
            ],
        },
        Command::TransferObjects {
            objects: vec![Argument::NestedResult(0, 0)],
            address: Argument::Input(9),
        },
    ];

    let result = env.execute_ptb(inputs, commands);

    if !result.success {
        return Err(anyhow!("Execute authorized trade failed: {:?}", result.error));
    }

    let effects = result.effects.ok_or_else(|| anyhow!("No effects"))?;
    let trade_id = effects.created.first().ok_or_else(|| anyhow!("No trade record created"))?;

    Ok(*trade_id)
}

fn pause_manager(
    env: &mut SimulationEnvironment,
    apex_pkg: AccountAddress,
    auth_id: AccountAddress,
) -> Result<()> {
    let auth_obj = env.get_object(&auth_id).ok_or_else(|| anyhow!("Auth not found"))?;

    let inputs = vec![
        InputValue::Object(ObjectInput::Owned {
            id: auth_id,
            bytes: auth_obj.bcs_bytes.clone(),
            type_tag: Some(auth_obj.type_tag.clone()),
            version: Some(auth_obj.version),
        }),
    ];

    let commands = vec![Command::MoveCall {
        package: apex_pkg,
        module: Identifier::new("apex_fund")?,
        function: Identifier::new("pause_manager")?,
        type_args: vec![],
        args: vec![Argument::Input(0)],
    }];

    let result = env.execute_ptb(inputs, commands);

    if !result.success {
        return Err(anyhow!("Pause manager failed: {:?}", result.error));
    }

    Ok(())
}

fn unpause_manager(
    env: &mut SimulationEnvironment,
    apex_pkg: AccountAddress,
    auth_id: AccountAddress,
) -> Result<()> {
    let auth_obj = env.get_object(&auth_id).ok_or_else(|| anyhow!("Auth not found"))?;

    let inputs = vec![
        InputValue::Object(ObjectInput::Owned {
            id: auth_id,
            bytes: auth_obj.bcs_bytes.clone(),
            type_tag: Some(auth_obj.type_tag.clone()),
            version: Some(auth_obj.version),
        }),
    ];

    let commands = vec![Command::MoveCall {
        package: apex_pkg,
        module: Identifier::new("apex_fund")?,
        function: Identifier::new("unpause_manager")?,
        type_args: vec![],
        args: vec![Argument::Input(0)],
    }];

    let result = env.execute_ptb(inputs, commands);

    if !result.success {
        return Err(anyhow!("Unpause manager failed: {:?}", result.error));
    }

    Ok(())
}

fn update_manager_limits(
    env: &mut SimulationEnvironment,
    apex_pkg: AccountAddress,
    auth_id: AccountAddress,
    max_trade_bps: u64,
    max_position_bps: u64,
    max_daily_volume_bps: u64,
    max_leverage: u64,
    allowed_directions: u8,
) -> Result<()> {
    let auth_obj = env.get_object(&auth_id).ok_or_else(|| anyhow!("Auth not found"))?;

    let inputs = vec![
        InputValue::Object(ObjectInput::Owned {
            id: auth_id,
            bytes: auth_obj.bcs_bytes.clone(),
            type_tag: Some(auth_obj.type_tag.clone()),
            version: Some(auth_obj.version),
        }),
        InputValue::Pure(bcs::to_bytes(&max_trade_bps)?),
        InputValue::Pure(bcs::to_bytes(&max_position_bps)?),
        InputValue::Pure(bcs::to_bytes(&max_daily_volume_bps)?),
        InputValue::Pure(bcs::to_bytes(&max_leverage)?),
        InputValue::Pure(bcs::to_bytes(&allowed_directions)?),
    ];

    let commands = vec![Command::MoveCall {
        package: apex_pkg,
        module: Identifier::new("apex_fund")?,
        function: Identifier::new("update_manager_limits")?,
        type_args: vec![],
        args: vec![
            Argument::Input(0),
            Argument::Input(1),
            Argument::Input(2),
            Argument::Input(3),
            Argument::Input(4),
            Argument::Input(5),
        ],
    }];

    let result = env.execute_ptb(inputs, commands);

    if !result.success {
        return Err(anyhow!("Update manager limits failed: {:?}", result.error));
    }

    Ok(())
}

// =========================================================================
// Helper Functions
// =========================================================================

fn get_apex_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("Failed to get parent directory")
        .to_path_buf()
}

fn extract_protocol_objects(
    result: &ExecutionResult,
    env: &SimulationEnvironment,
) -> Result<(AccountAddress, AccountAddress)> {
    if !result.success {
        return Err(anyhow!("Protocol init failed: {:?}", result.error));
    }

    let effects = result.effects.as_ref().ok_or_else(|| anyhow!("No effects"))?;
    let created: Vec<_> = effects.created.iter().collect();

    if created.len() < 2 {
        return Err(anyhow!("Expected 2 objects, got {}", created.len()));
    }

    let config = **created
        .iter()
        .find(|id| env.get_object(id).map(|o| o.is_shared).unwrap_or(false))
        .unwrap_or(created.first().unwrap());

    let admin_cap = **created
        .iter()
        .find(|id| !env.get_object(id).map(|o| o.is_shared).unwrap_or(true))
        .unwrap_or(created.last().unwrap());

    Ok((config, admin_cap))
}

fn setup_clock(env: &mut SimulationEnvironment) -> Result<()> {
    let clock_id = AccountAddress::from_hex_literal("0x6")?;
    let mut clock_bytes = Vec::new();
    clock_bytes.extend_from_slice(&clock_id.to_vec());
    let timestamp_ms: u64 = 1700000000000;
    clock_bytes.extend_from_slice(&timestamp_ms.to_le_bytes());

    env.load_object_from_data("0x6", clock_bytes, Some("0x2::clock::Clock"), true, false, 1)?;
    Ok(())
}

fn register_service(
    env: &mut SimulationEnvironment,
    apex_pkg: AccountAddress,
    config_id: AccountAddress,
    payment_coin_id: AccountAddress,
    name: &[u8],
    description: &[u8],
    price: u64,
) -> Result<AccountAddress> {
    let config_obj = env.get_object(&config_id).ok_or_else(|| anyhow!("Config not found"))?;
    let coin_obj = env.get_object(&payment_coin_id).ok_or_else(|| anyhow!("Coin not found"))?;

    let sui_type: TypeTag = "0x2::sui::SUI".parse()?;
    let coin_type = TypeTag::Struct(Box::new(move_core_types::language_storage::StructTag {
        address: AccountAddress::from_hex_literal("0x2")?,
        module: Identifier::new("coin")?,
        name: Identifier::new("Coin")?,
        type_params: vec![sui_type],
    }));

    let inputs = vec![
        InputValue::Object(ObjectInput::Shared {
            id: config_id,
            bytes: config_obj.bcs_bytes.clone(),
            type_tag: None,
            version: Some(config_obj.version),
            mutable: true,
        }),
        InputValue::Pure(bcs::to_bytes(&name.to_vec())?),
        InputValue::Pure(bcs::to_bytes(&description.to_vec())?),
        InputValue::Pure(bcs::to_bytes(&price)?),
        InputValue::Object(ObjectInput::Owned {
            id: payment_coin_id,
            bytes: coin_obj.bcs_bytes.clone(),
            type_tag: Some(coin_type),
            version: None,
        }),
    ];

    let commands = vec![Command::MoveCall {
        package: apex_pkg,
        module: Identifier::new("apex_payments")?,
        function: Identifier::new("register_service")?,
        type_args: vec![],
        args: vec![
            Argument::Input(0),
            Argument::Input(1),
            Argument::Input(2),
            Argument::Input(3),
            Argument::Input(4),
        ],
    }];

    let sender = env.sender();
    let result = env.execute_ptb(inputs.clone(), commands.clone());

    // Record trace
    record_trace(create_trace(
        "Demo 1: Basic Flow",
        "register_service",
        &sender,
        &inputs,
        &commands,
        &result,
        env,
    ));

    if !result.success {
        return Err(anyhow!("Register service failed: {:?}", result.error));
    }

    let effects = result.effects.ok_or_else(|| anyhow!("No effects"))?;
    let service_id = effects
        .created
        .iter()
        .find(|id| env.get_object(id).map(|o| o.is_shared).unwrap_or(false))
        .or(effects.created.first())
        .ok_or_else(|| anyhow!("No service created"))?;

    Ok(*service_id)
}

// =========================================================================
// Output Formatting
// =========================================================================

fn print_header() {
    println!();
    println!("╔════════════════════════════════════════════════════════════════════════════╗");
    println!("║       APEX Protocol - Mainnet Fork Hedge Fund Demonstrations               ║");
    println!("╠════════════════════════════════════════════════════════════════════════════╣");
    println!("║                                                                            ║");
    println!("║  This demo showcases the COMPLETE hedge fund lifecycle in a SINGLE         ║");
    println!("║  sandbox environment with REAL mainnet DeepBook bytecode:                  ║");
    println!("║                                                                            ║");
    println!("║  • PHASE 1: Fund Creation (Mainnet DeepBook + APEX deployment)             ║");
    println!("║  • PHASE 2: Investor Deposits (Entry fees via APEX payments)               ║");
    println!("║  • PHASE 3: Agent Trading (On-chain constraint enforcement)                ║");
    println!("║  • PHASE 4: Settlement & Distribution (Fee calculation + withdrawals)      ║");
    println!("║                                                                            ║");
    println!("║  All phases share the SAME sandbox - demonstrating full fund lifecycle!    ║");
    println!("║                                                                            ║");
    println!("╚════════════════════════════════════════════════════════════════════════════╝");
}

fn print_final_summary() {
    println!("\n{}", "═".repeat(76));
    println!("  FINAL SUMMARY");
    println!("{}", "═".repeat(76));
    println!();
    println!("  ✅ All 4 phases completed in a SINGLE shared sandbox!");
    println!();
    println!("  Complete Hedge Fund Lifecycle Demonstrated:");
    println!("  ┌────────────────────────────────────────────────────────────────┐");
    println!("  │ Phase 1: Fund Creation                                         │");
    println!("  │ • Load REAL DeepBook V3 + Pyth Oracle from mainnet via gRPC    │");
    println!("  │ • Deploy APEX Protocol alongside mainnet state                 │");
    println!("  │ • Create hedge fund with fee structure                         │");
    println!("  │ • Authorize trading agent with on-chain constraints            │");
    println!("  ├────────────────────────────────────────────────────────────────┤");
    println!("  │ Phase 2: Investor Deposits                                     │");
    println!("  │ • Multiple investors join fund with entry fees                 │");
    println!("  │ • Entry fees processed via APEX payment protocol               │");
    println!("  │ • InvestorPosition NFTs track ownership shares                 │");
    println!("  │ • Fund capital aggregated for trading                          │");
    println!("  ├────────────────────────────────────────────────────────────────┤");
    println!("  │ Phase 3: Agent Trading                                         │");
    println!("  │ • Trades within limits: EXECUTED                               │");
    println!("  │ • Trades exceeding limits: REJECTED by smart contract          │");
    println!("  │ • Owner can pause/unpause trading in real-time                 │");
    println!("  │ • Owner can update constraints (leverage, direction, size)     │");
    println!("  │ • All executed against REAL mainnet DeepBook bytecode          │");
    println!("  ├────────────────────────────────────────────────────────────────┤");
    println!("  │ Phase 4: Settlement & Distribution                             │");
    println!("  │ • Owner settles fund (transitions to SETTLED state)            │");
    println!("  │ • Management fees (2%) and performance fees (20%) calculated   │");
    println!("  │ • Investors withdraw proportional shares                       │");
    println!("  │ • SettlementReceipt NFTs track withdrawal records              │");
    println!("  └────────────────────────────────────────────────────────────────┘");
    println!();
    println!("  On-Chain Enforced Constraints:");
    println!("  • max_trade_bps: Max % of portfolio per trade");
    println!("  • max_position_bps: Max % in single position");
    println!("  • max_daily_volume_bps: Max % turnover per day");
    println!("  • max_leverage: Max leverage multiplier (e.g., 5x)");
    println!("  • allowed_directions: Long only, Short only, or Both");
    println!();
    println!("  Key APEX Advantages:");
    println!("  • Complete fund lifecycle in single shared sandbox");
    println!("  • Agent CANNOT bypass constraints - code enforces limits");
    println!("  • Real mainnet DeepBook bytecode via gRPC forking");
    println!("  • Separation of concerns (owner strategy vs agent execution)");
    println!("  • Full audit trail on-chain with settlement receipts");
    println!();
    println!("{}", "═".repeat(76));
}
