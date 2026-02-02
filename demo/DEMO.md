# APEX Protocol Demo Guide

## What Is This Demo?

This demo is a **local testing environment** that executes APEX Protocol smart contracts in a real Move VM without deploying to any blockchain. It uses [sui-sandbox](https://github.com/Evan-Kim2028/sui-sandbox) to run the exact same bytecode that would execute on Sui mainnet.

**Think of it like this:**
- The `sources/` folder contains the smart contracts (Move code)
- The `demo/` folder is a Rust application that *calls* those contracts locally
- No testnet, no gas fees, instant feedback

## Why Does This Exist?

### The Problem with Blockchain Development

Traditional smart contract testing has friction:

```
Write code → Deploy to testnet → Wait for confirmation → Test → Find bug → Redeploy → Repeat
```

Each cycle takes minutes and costs gas. For a complex protocol like APEX with multiple interacting modules, this becomes painful.

### The Solution: Local Move VM

The demo compiles APEX contracts and executes them in a local Move VM:

```
Write code → Run `cargo run` → See results instantly → Fix bugs → Run again
```

This is possible because:
1. **sui-sandbox** embeds the actual Sui Move VM
2. It simulates object storage, ownership, and PTB execution
3. The bytecode is identical to what would run on mainnet

## How It Works

### Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Your Machine                                 │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  apex-protocol/                                                      │
│  ├── sources/                    ← Move smart contracts              │
│  │   ├── apex_payments.move                                          │
│  │   ├── apex_fund.move                                              │
│  │   └── ...                                                         │
│  │                                                                   │
│  └── demo/                       ← This folder                       │
│      └── src/main.rs             ← Rust code that builds PTBs        │
│                                                                      │
│         │                                                            │
│         ▼                                                            │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                    sui-sandbox                               │    │
│  │  ┌─────────────────┐  ┌─────────────────┐                   │    │
│  │  │   Move VM       │  │ Object Storage  │                   │    │
│  │  │ (real bytecode) │  │  (simulated)    │                   │    │
│  │  └─────────────────┘  └─────────────────┘                   │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### Execution Flow

1. **Compile**: `sui move build` compiles Move contracts to bytecode
2. **Load**: Demo loads the bytecode into sui-sandbox
3. **Execute**: Demo constructs PTBs and executes them
4. **Verify**: Results are checked and printed

## Running the Demo

### Prerequisites

```bash
# Install Sui CLI (for Move compiler)
# See: https://docs.sui.io/guides/developer/getting-started/sui-install

# Install Rust (for running the demo)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

### Steps

```bash
# 1. From the repo root, build the Move contracts
cd apex-protocol
sui move build

# 2. Run the demo
cd demo
cargo run
```

### Expected Output

You'll see 5 demos execute sequentially:

```
╔════════════════════════════════════════════════════════════════════════════╗
║           APEX Protocol - Advanced PTB Workflow Demonstrations             ║
╠════════════════════════════════════════════════════════════════════════════╣
║                                                                            ║
║  • DEMO 1: Basic Flow (Deploy → Register → Purchase → Use)                 ║
║  • DEMO 2: Delegated Agent Authorization (Human → AI delegation)           ║
║  • DEMO 3: Service Registry Discovery (On-chain discovery)                 ║
║  • DEMO 4: Nautilus + Seal Verification (TEE + Encrypted Content)          ║
║  • DEMO 5: Agentic Hedge Fund (Multi-agent fund on DeepBook margin)        ║
║                                                                            ║
╚════════════════════════════════════════════════════════════════════════════╝
```

Each demo prints step-by-step progress and PTB patterns used.

## The 5 Demos Explained

### Demo 1: Basic Flow

**Purpose**: Understand the core payment lifecycle.

**What happens**:
1. Deploy APEX contracts (simulated publish)
2. Initialize protocol (creates `ProtocolConfig`)
3. Provider registers a service (pays registration fee)
4. Agent purchases access (gets `AccessCapability`)
5. Agent uses access (consumes units)

**Key concept**: Objects flow between PTB commands atomically.

```
┌─────────────────────────────────────────────────────────────────┐
│ PTB Command Flow                                                 │
├─────────────────────────────────────────────────────────────────┤
│ [0] purchase_access() → AccessCapability (returned)              │
│ [1] use_access(capability) → success (uses Result[0])           │
│                                                                  │
│ If use_access fails, purchase_access is reverted. All or nothing.│
└─────────────────────────────────────────────────────────────────┘
```

### Demo 2: Delegated Authorization

**Purpose**: Show how humans can authorize AI agents with spending limits.

**What happens**:
1. Human owner creates `AgentAuthorization` with limits
2. Authorization transferred to agent
3. Agent uses authorization to purchase access
4. Spending tracked against daily limits

**Key concept**: Capability-based delegation. The agent holds an object that proves authorization, not a permission mapping.

### Demo 3: Service Registry Discovery

**Purpose**: Demonstrate on-chain service discovery.

**What happens**:
1. Admin creates a `ServiceRegistry`
2. Providers list services with metadata
3. Agent queries registry by category
4. Agent atomically discovers + purchases + uses service

**Key concept**: Everything in one PTB. If the discovered service doesn't exist or is too expensive, the entire transaction reverts.

### Demo 4: Nautilus + Seal Verification

**Purpose**: Show the security pattern for TEE-verified metering with encrypted content.

**What happens**:
1. Register a trusted Nautilus enclave (TEE)
2. Provider registers Seal-encrypted content
3. Agent opens a verified session
4. Seal key servers verify access (simulated `dry_run`)
5. Agent closes session with TEE-signed consumption report

**Key concept**: Two verification layers:
- **Seal**: Threshold encryption ensures only authorized users decrypt content
- **Nautilus**: TEE signs actual consumption, preventing provider fraud

**Note**: In sandbox, TEE signatures and Seal decryption are simulated. Production requires real Nautilus enclaves and Seal key servers.

### Demo 5: Agentic Hedge Fund

**Purpose**: Demonstrate a complex multi-agent financial application.

**What happens**:
1. Fund Manager creates hedge fund with fee structure
2. Investor joins (pays APEX entry fee + deposits capital)
3. Manager executes margin trades (simulated P&L)
4. Manager settles fund (deducts fees)
5. Investor withdraws shares (receives proportional capital + profits)

**Key concept**: Multiple agents interacting through shared state. The fund is a shared object that multiple parties can interact with according to rules enforced by the smart contract.

```
Fund Lifecycle:
┌────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
│  OPEN  │───▶│ TRADING  │───▶│ SETTLED  │───▶│ WITHDRAWN│
└────────┘    └──────────┘    └──────────┘    └──────────┘
 Investors     Manager         Fees            Investors
 join          trades          deducted        withdraw
```

## Understanding the Code

### File Structure

```
demo/
├── Cargo.toml      # Rust dependencies (imports sui-sandbox)
├── Cargo.lock      # Locked dependency versions
├── DEMO.md         # This file
└── src/
    └── main.rs     # All demo code (~2300 lines)
```

### Key Patterns in main.rs

**1. Creating a simulation environment**:
```rust
let mut env = SimulationEnvironment::new()?;
```

**2. Deploying contracts**:
```rust
let package_path = PathBuf::from("../"); // Points to Move.toml
let effects = env.deploy_local_package(&package_path, admin_addr)?;
let package_id = effects.created.first().unwrap();
```

**3. Building a PTB**:
```rust
let mut ptb = env.new_ptb(sender_addr);

// Add inputs
let config_input = ptb.add_object_input(config_obj)?;
let payment_input = ptb.add_object_input(coin_obj)?;

// Add commands
ptb.move_call(
    package_id,
    "apex_payments",
    "purchase_access",
    vec![],  // type args
    vec![config_input, payment_input, ...],  // args
)?;

// Execute
let effects = env.execute_ptb(ptb)?;
```

**4. Extracting results**:
```rust
// Get created objects from effects
let capability_id = effects.created.first().unwrap();
let capability_obj = env.get_object(capability_id).unwrap();
```

## Limitations

### What Works
- Full Move VM execution (same bytecode as mainnet)
- Object creation, mutation, deletion
- PTB composition and atomicity
- Event emission (captured in effects)
- Multi-step workflows across PTBs

### What's Simulated
| Feature | Sandbox Behavior | Production Behavior |
|---------|------------------|---------------------|
| Object storage | In-memory HashMap | Sui validators |
| Consensus | None (instant) | Narwhal/Bullshark |
| Gas metering | Estimated | Precise |
| Randomness | Not available | On-chain VRF |
| Clock | Simulated | Network consensus |

### Known Issues

**Owned object deserialization**: Custom-typed owned objects need explicit `type_tag` when passed between PTBs. The demo handles this, but it's a sandbox limitation.

See: [sui-sandbox#18](https://github.com/Evan-Kim2028/sui-sandbox/issues/18)

## Relationship to Production

### What Transfers Directly
- All Move contract code (`sources/*.move`)
- PTB structure and composition patterns
- Object models and relationships
- Business logic and constraints

### What Changes in Production
- Deployment via `sui client publish`
- Object IDs are deterministic on mainnet
- Gas is real (SUI tokens)
- Transactions go through consensus
- Nautilus requires real TEE hardware
- Seal requires key server infrastructure

## Next Steps

After running the demo successfully:

1. **Deploy to testnet**:
   ```bash
   sui client switch --env testnet
   sui client faucet
   sui client publish --gas-budget 500000000
   ```

2. **Integrate with your agent**: Use the Sui TypeScript SDK to build PTBs programmatically from your AI agent.

3. **Add real integrations**:
   - Connect to DeepBook for actual margin trading
   - Deploy Nautilus enclave for TEE verification
   - Set up Seal key servers for content encryption

## Troubleshooting

### Build Errors

```bash
# If Move build fails
sui move build --fetch-deps-only
sui move build
```

### Demo Crashes

```bash
# Check Rust version (needs 1.70+)
rustc --version

# Clean and rebuild
cd demo
cargo clean
cargo build
cargo run
```

### "Package not found"

Make sure you're running from the `demo/` directory and the Move contracts are built:

```bash
cd apex-protocol
sui move build  # Must run this first
cd demo
cargo run
```

## Contributing

To add a new demo:

1. Add a new function `demo_your_feature()` in `src/main.rs`
2. Call it from `main()`
3. Follow the existing pattern:
   - Print section header
   - Execute steps with progress output
   - Show PTB patterns used
   - Print success message

The demo is designed to be self-documenting - each step prints what it's doing and why.
