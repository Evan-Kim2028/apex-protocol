# APEX Protocol - Design Decisions

This document explains the design rationale behind APEX and provides honest comparisons with alternative approaches, including analysis of existing agent infrastructure projects.

## Table of Contents

1. [Problem Statement](#problem-statement)
2. [Alternative Approaches](#alternative-approaches)
3. [Agent Infrastructure Landscape](#agent-infrastructure-landscape)
4. [APEX Design Choices](#apex-design-choices)
5. [Honest Tradeoffs](#honest-tradeoffs)
6. [When to Use What](#when-to-use-what)
7. [APEX Evolution: Fully On-Chain with Seal + Nautilus](#apex-evolution-fully-on-chain-with-seal--nautilus)
8. [Cross-Chain Composability](#cross-chain-composability)
9. [Implementation Plan: High-Impact Additions](#implementation-plan-high-impact-additions)
10. [Open Questions](#open-questions)

---

## Problem Statement

AI agents need to pay for services programmatically. This requires:

1. **Authorization**: Prove the agent has permission to spend
2. **Payment**: Transfer value from agent to service
3. **Verification**: Service confirms payment before/after serving
4. **Limits**: Constrain agent spending to prevent runaway costs
5. **Privacy**: Protect sensitive data while enabling verification

Different solutions make different tradeoffs on these requirements.

---

## Alternative Approaches

### x402 Protocol (Coinbase)

**How it works:**

1. Client requests resource, server returns HTTP 402 with payment requirements
2. Client signs an off-chain authorization (EIP-3009 `transferWithAuthorization`)
3. Client sends request with signed authorization header
4. Server validates signature, serves content optimistically
5. Facilitator settles payment on-chain (batched for efficiency)

**Key mechanism - EIP-3009:**

```
transferWithAuthorization(
  from,           // payer address
  to,             // recipient address
  value,          // amount
  validAfter,     // earliest valid time
  validBefore,    // latest valid time
  nonce,          // unique per authorization
  v, r, s         // signature
)
```

The payer signs this off-chain. Anyone holding the signature can submit it on-chain to execute the transfer. This enables:
- **Gasless for payer**: Facilitator pays gas when settling
- **Optimistic serving**: Server doesn't wait for on-chain settlement
- **Batching**: Multiple payments settled in one transaction

**Facilitator role:**
- Validates payment signatures
- Submits transactions (pays gas)
- Provides trust layer between client and server
- Can reject invalid/duplicate authorizations

### Privy Agentic Wallets

**How it works:**

1. Wallet keys are sharded and stored in Trusted Execution Environments (TEEs)
2. Policy engine enforces spending rules before signing
3. Server-side signing (no client wallet management)
4. Acquired by Stripe (June 2025) - likely integrated into Stripe's payment infrastructure

**Key properties:**
- **Custodial**: Privy/Stripe holds key shards, not the user
- **Policy-enforced**: Rules checked before signing, not on-chain
- **Infrastructure play**: You use their system, they handle complexity
- **Multi-chain**: Works across any EVM chain

**Security model:**
- TEE attestation verifies code running in enclave
- Key sharding means no single point has full key
- Policy engine is trusted to enforce rules correctly

---

## Agent Infrastructure Landscape

Based on thorough analysis of existing agent payment infrastructure projects:

### Sokosumi (Masumi Protocol)

**Architecture:** Agent marketplace on Cardano with hybrid custody model.

**Payment Flow:**
```
User → Stripe (Fiat) → Credits (PostgreSQL) → Job Payment (Cardano UTxO)
```

**Key Components:**
- **Credit Buckets**: FIFO consumption model, stored in PostgreSQL
- **Cardano Smart Contracts**: Job escrow via Masumi Protocol
- **Hash Verification**: Input/output hashes for non-repudiation

**Custody Model:**
| Layer | Custodian | Type |
|-------|-----------|------|
| Fiat (USD) | Stripe | Fully Custodial |
| Credits | Sokosumi (PostgreSQL) | Custodial |
| Job Funds | Cardano Smart Contract | Non-Custodial |

**Strengths:**
- FIFO credit consumption prevents expiry issues
- On-chain job escrow protects both parties
- Hash verification enables dispute resolution

**Weaknesses:**
- Credits stored in centralized database
- Depends on Masumi Protocol external service
- No direct crypto wallet integration for users

### OpenClaw Base Agent

**Architecture:** Autonomous DeFi agent framework on Base (documentation-heavy, implementation planned).

**Key Components:**
- **CDP SDK**: Coinbase Developer Platform for wallet management
- **Strategy Engine**: Yield Hunter, Delta Neutral, Momentum strategies
- **Social Publisher**: X/Farcaster transaction posting

**Custody Model:**
| Tier | Method | Security |
|------|--------|----------|
| Tier 1 | CDP Secure Wallet | Coinbase-managed keys (Production) |
| Tier 2 | Local Encrypted Store | AES-256 encryption (Testing) |
| Tier 3 | Environment Variables | Never for mainnet |

**Safety Controls:**
```json
{
  "maxTransactionSize": "1000 USDC",
  "maxDailyVolume": "5000 USDC",
  "maxSlippage": 0.005,
  "minHealthFactor": 1.5,
  "emergencyPause": true
}
```

**Strengths:**
- Transparent social posting of all transactions
- Configurable spending limits
- Emergency pause mechanisms

**Weaknesses:**
- Relies on CDP (Coinbase) for key management
- Limits enforced by trusted service, not on-chain
- Single-chain (Base only)

### PayRam (x402 Implementation)

**Architecture:** Self-hosted multi-chain payment gateway using x402 protocol.

**Payment Flow:**
```
HTTP Request → 402 Response → Client Signs (EIP-3009) →
Facilitator Verifies → On-Chain Settlement → Resource Delivered
```

**Key Innovation - No Server Keys:**
- Private keys never touch internet-connected servers
- Smart contracts handle fund movements
- Bitcoin: Mobile signing, off-server
- EVM: Smart wallet sweep automation

**Multi-Chain Support:**
| Chain | Status | Features |
|-------|--------|----------|
| Bitcoin | Production | Mobile signing |
| Ethereum | Production | Smart wallet sweeps |
| Base | Production | Primary x402 settlement |
| Polygon | Production | USDT/USDC |
| Tron | Production | USDT/USDC |
| Solana | Planned | Q2 2026 |

**Strengths:**
- Non-custodial: "No keys on server"
- Multi-chain with unified interface
- Idempotent webhooks for reliability

**Weaknesses:**
- Still requires facilitator trust for x402 settlement
- Users need infrastructure to self-host
- Optimistic serving means settlement risk

### Comparison Matrix

| Aspect | Sokosumi | OpenClaw | PayRam | APEX |
|--------|----------|----------|--------|------|
| **Blockchain** | Cardano | Base | Multi-chain | Sui |
| **Key Custody** | Hybrid | CDP (Coinbase) | Self-hosted | Self-custody |
| **Limits Enforced** | Database | Trusted service | Policy engine | On-chain (Move) |
| **Payment Model** | Credit → Escrow | Direct wallet | x402 facilitator | PTB atomic |
| **Atomicity** | Contract-level | Transaction | Depends on chain | PTB native |
| **Privacy** | Hash verification | None | x402 headers | Seal integration |
| **Gas Abstraction** | Yes (credits) | Partially (CDP) | Yes (facilitator) | No (user pays) |

---

## APEX Design Choices

### Choice 1: On-Chain Payment in PTB

**What we chose:** Payment happens on-chain as part of the PTB, not via off-chain signature.

**Why:**
- Sui's PTB model makes this cheap (sub-cent transactions)
- No facilitator trust required
- Payment and action are atomic (can't pay then fail to receive)

**What we gave up:**
- No optimistic serving (must wait for tx confirmation ~400ms)
- User pays gas (no abstraction)
- Requires PTB construction, not just signing

### Choice 2: Capability Objects for Access

**What we chose:** AccessCapability is an on-chain object representing prepaid access.

```move
public struct AccessCapability has key, store {
    id: UID,
    service_id: ID,
    remaining_units: u64,
    expires_at: u64,
    rate_limit: u64,
    // ...
}
```

**Why:**
- Transferable: Agent can give access to another agent
- Composable: Pass between PTB commands
- Verifiable: Anyone can check capability on-chain
- Self-custodial: User owns the object

**What we gave up:**
- Must purchase before use (no instant-pay-per-call)
- Object management complexity
- Can't easily revoke (would need to track capability IDs)

### Choice 3: Provider-Recorded Consumption (Streams)

**What we chose:** For streaming payments, the service provider records consumption and pulls from escrow.

**Why:**
- Consumer can't lie about usage
- Provider has direct incentive to record accurately (gets paid per unit)
- Escrow limits exposure

**What we gave up:**
- Consumer trusts provider to record honestly
- Provider could over-report (but consumer can stop stream)
- Requires provider to submit transactions

### Choice 4: Agent Wallets with On-Chain Limits

**What we chose:** Spending limits enforced in Move contracts.

```move
public struct AgentWallet has key, store {
    spend_limit: u64,    // max per transaction
    daily_limit: u64,    // max per day
    daily_spent: u64,
    paused: bool,
    // ...
}
```

**Why:**
- Limits enforced by blockchain, not trusted service
- Owner can pause without revoking agent's keys
- Transparent and auditable

**What we gave up:**
- Agent must use specific wallet contract (can't use raw address)
- Limits are public on-chain
- Can't do fine-grained rules (e.g., "only pay for service X" without additional capability restrictions)

---

## Honest Tradeoffs

### Atomicity is NOT a Differentiator

All three chains support atomic transactions:

| Chain | Atomicity Mechanism |
|-------|-------------------|
| Sui | PTB - all commands succeed or all fail |
| Solana | Transaction - all instructions succeed or all fail |
| Ethereum/Base | Multicall3 or bundled contract calls |

**The difference is in composition:**
- Sui: Client builds PTB with up to 1024 operations
- Solana: Client builds transaction with instructions
- Ethereum: Requires deployed aggregator contract

### Gas Abstraction

| Approach | Who Pays Gas | How |
|----------|-------------|-----|
| x402 | Facilitator | Settles on behalf of user |
| Privy | User (abstracted) | Bundled into transaction |
| Sokosumi | Credits | Gas covered by platform |
| APEX | User | Part of PTB execution |

APEX currently requires users to pay gas. This could be added via:
- Sponsored transactions (Sui supports this)
- Prepaid gas pools
- But this adds complexity and trust

### Custody Model

| Approach | Key Custody | Trust Assumption |
|----------|-------------|------------------|
| x402 | User holds keys | Facilitator trusted to settle |
| Privy | Privy/Stripe holds shards | TEE + policy engine trusted |
| Sokosumi | User + Platform | Platform database trusted |
| OpenClaw | CDP (Coinbase) | CDP infrastructure trusted |
| PayRam | Self-hosted | User's infrastructure trusted |
| APEX | User holds keys | Only trust blockchain |

**Neither is universally better:**
- Self-custody: More responsibility, more control
- Custodial: Easier UX, trust third party

### Latency

| Approach | Time to Access |
|----------|---------------|
| x402 (optimistic) | Immediate after signature |
| Privy | After server-side signing |
| APEX | After on-chain confirmation (~400ms) |

x402's optimistic serving is genuinely faster. The facilitator takes settlement risk.

---

## When to Use What

### Use x402 When:

- You want gasless UX for end users
- Latency matters (need optimistic serving)
- You're on Base/Solana with existing EIP-3009/Permit2 infrastructure
- You trust or are the facilitator
- You want to batch settlements for efficiency

### Use Privy When:

- You want managed infrastructure (don't want to build wallet management)
- Policy enforcement at signing time is acceptable
- You're building within Stripe's ecosystem
- Multi-chain support matters
- Custodial model is acceptable for your use case

### Use Sokosumi When:

- You want an agent marketplace with discovery
- Credit-based payments fit your model
- You're on Cardano ecosystem
- Fiat on-ramp via Stripe is important

### Use APEX When:

- You're on Sui and want to leverage PTB composition
- Self-custody is important
- You want payment + action atomic (not optimistic)
- Access as transferable objects fits your model
- You want limits enforced on-chain, not by trusted service
- ~400ms latency is acceptable

---

## APEX Evolution: Fully On-Chain with Seal + Nautilus

The goal: Make APEX **solely reliant on Sui Move smart contracts** with **Seal** for encrypted access control and **Nautilus** for verified compute where needed.

### Seal Integration for Encrypted Access

**What Seal Provides:**
- Decentralized secrets management via threshold encryption (t-of-n key servers)
- Access control defined by Move smart contracts
- Data encrypted to policies, not specific addresses
- Plaintext never exists on servers

**How APEX Can Use Seal:**

#### Pattern 1: Encrypted API Credentials

```
Service Provider encrypts API credentials to policy:
  identity = "apex_protocol:service_0x123:capability_holder"

Policy (Move contract):
  public fun seal_approve(identity: String, clock: &Clock): bool {
      // Extract capability ID from identity
      let cap_id = extract_cap_id(identity);

      // Check if requester holds valid AccessCapability
      let requester = tx_context::sender();
      has_valid_capability(requester, cap_id, clock)
  }

Flow:
1. Provider encrypts API key with Seal policy
2. Agent purchases AccessCapability via APEX
3. Agent requests decryption from Seal key servers
4. Key servers verify agent holds capability (on-chain check)
5. Agent receives decrypted API key
6. Agent uses API directly (no payment verification needed per-call)
```

**Benefits:**
- No per-call payment verification overhead
- API credentials only accessible to capability holders
- Decryption tied to on-chain state (capability ownership)

#### Pattern 2: Time-Locked Content Releases

```
Scenario: Paid research report released to subscribers at specific time

Policy:
  public fun seal_approve(identity: String, clock: &Clock): bool {
      let release_time = extract_time(identity);
      let subscription_id = extract_subscription(identity);

      clock::timestamp_ms(clock) >= release_time &&
      has_active_subscription(tx_context::sender(), subscription_id)
  }

Flow:
1. Content creator encrypts report with Seal
2. Users purchase subscriptions via APEX
3. At release time, subscribers can decrypt
4. Non-subscribers cannot decrypt (policy fails)
```

#### Pattern 3: Provider-Encrypted Streaming Data

```
Scenario: Streaming data service where provider encrypts chunks

Policy:
  public fun seal_approve(identity: String, clock: &Clock): bool {
      let stream_id = extract_stream(identity);
      let consumer = tx_context::sender();

      // Check if consumer has open stream with sufficient escrow
      has_active_stream(consumer, stream_id) &&
      get_stream_escrow(consumer, stream_id) > minimum_balance()
  }

Flow:
1. Provider encrypts data chunks with per-stream identities
2. Consumer opens PaymentStream via APEX (escrow deposited)
3. Consumer requests decryption from Seal
4. Key servers verify stream is active and funded
5. Consumer receives decrypted data
6. Provider records consumption, pulls from escrow
```

### Nautilus Integration for Verified Compute

**What Nautilus Provides:**
- Off-chain computation in AWS Nitro Enclaves (TEEs)
- On-chain verification via attestation and signatures
- Reproducible builds ensure code integrity
- Results cryptographically signed by enclave

**How APEX Can Use Nautilus:**

#### Pattern 1: Verified Usage Metering

```
Problem: Provider-recorded consumption is trusted
Solution: Meter usage in Nautilus enclave with verified reports

Architecture:
┌─────────────────────────────────────────────────────────┐
│  Nautilus Enclave (TEE)                                 │
│  ┌─────────────────────────────────────────────────────┐│
│  │  Metering Logic                                     ││
│  │  - Counts API calls                                 ││
│  │  - Validates request/response pairs                 ││
│  │  - Signs usage report with enclave key              ││
│  └─────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────┘
              │
              ↓ (signed usage report)
┌─────────────────────────────────────────────────────────┐
│  Sui Blockchain                                         │
│  ┌─────────────────────────────────────────────────────┐│
│  │  APEX Move Contract                                 ││
│  │  - Verify enclave signature                         ││
│  │  - Verify enclave is registered                     ││
│  │  - Update consumption based on verified report      ││
│  │  - Pull from escrow only for verified units         ││
│  └─────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────┘

Benefits:
- Neither party can lie about usage
- Reproducible build ensures metering code is correct
- On-chain verification of TEE attestation
- Consumer and provider both trust the meter
```

#### Pattern 2: Verified Trading Intent Execution

```
Problem: Intent executor could front-run or manipulate fills
Solution: Execute fills in Nautilus with verified pricing

Flow:
1. Agent creates SwapIntent via APEX (escrow locked)
2. Executor runs fill logic in Nautilus enclave
3. Enclave fetches price from oracles (inside TEE)
4. Enclave computes optimal route and signs result
5. Result submitted to Sui with enclave signature
6. APEX contract verifies enclave, releases escrow
7. Agent receives verified fair execution

Move verification:
  public fun fill_intent_verified(
      intent: &mut SwapIntent,
      fill_result: vector<u8>,
      enclave_signature: vector<u8>,
      enclave_id: address
  ) {
      // Verify enclave is registered and trusted
      assert!(is_registered_enclave(enclave_id), EInvalidEnclave);

      // Verify signature
      let enclave_pubkey = get_enclave_pubkey(enclave_id);
      assert!(verify_signature(fill_result, enclave_signature, enclave_pubkey), EInvalidSignature);

      // Parse and execute fill
      let (output_amount, price_proof) = parse_fill_result(fill_result);
      execute_fill(intent, output_amount);
  }
```

#### Pattern 3: Private AI Inference with Verified Results

```
Scenario: Agent pays for AI inference, needs proof of model version

Architecture:
1. AI model runs inside Nautilus enclave
2. Model weights encrypted with Seal (provider controls access)
3. Agent submits query + payment via APEX
4. Enclave decrypts weights (via Seal, authorized by payment)
5. Enclave runs inference, signs result
6. Result includes: output + model_hash + input_hash
7. Sui contract verifies enclave signature
8. Agent receives verified inference result

Benefits:
- Model weights remain private (Seal encrypted)
- Inference is verified (Nautilus attestation)
- Payment is atomic (APEX PTB)
- Neither party can dispute what was computed
```

### Full Stack: APEX + Seal + Nautilus + Walrus

```
┌─────────────────────────────────────────────────────────────────┐
│                    Complete Architecture                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Walrus (Decentralized Storage)                                  │
│  └── Stores encrypted content, data, model weights               │
│                                                                  │
│  Seal (Threshold Encryption)                                     │
│  └── Controls decryption via Move policies                       │
│  └── Ties access to APEX AccessCapability ownership              │
│                                                                  │
│  Nautilus (Verified Compute)                                     │
│  └── Runs sensitive logic in TEE                                 │
│  └── Verifies usage metering, intent fills, AI inference         │
│  └── Results verified on-chain via attestation                   │
│                                                                  │
│  APEX Protocol (Payment Infrastructure)                          │
│  └── PTB atomic payments                                         │
│  └── AccessCapability objects                                    │
│  └── Agent wallets with on-chain limits                          │
│  └── Payment streams with escrow                                 │
│                                                                  │
│  Sui Blockchain (Trust Anchor)                                   │
│  └── All state, policies, verification on-chain                  │
│  └── Move smart contracts enforce everything                     │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Migration Path

**Phase 1: Seal Integration (Encrypted Access)**
1. Add `apex_seal.move` integration with Seal key server protocol
2. Define policy patterns for capability-gated decryption
3. Enable encrypted API credentials tied to AccessCapability

**Phase 2: Nautilus Integration (Verified Metering)**
1. Define enclave registration in APEX contracts
2. Implement verified consumption recording
3. Replace trusted provider consumption with TEE-metered consumption

**Phase 3: Full Privacy Stack**
1. Integrate Walrus for encrypted content storage
2. Combine Seal + Nautilus for private verifiable compute
3. Enable AI inference marketplace with payment + privacy + verification

### What This Eliminates

| Current Trust Assumption | With Seal + Nautilus |
|-------------------------|---------------------|
| Provider records consumption honestly | TEE-verified metering |
| API credentials managed off-chain | Seal-encrypted, on-chain gated |
| Intent executor acts fairly | TEE-verified execution |
| Content access managed externally | Seal policy enforcement |

### What Remains Off-Chain

Even with full integration, some components remain off-chain:
- **Seal Key Servers**: Distributed but not on Sui
- **Nautilus Enclaves**: AWS Nitro hardware
- **Walrus Storage**: Decentralized but separate from Sui

However, **all verification and policy enforcement happens on Sui**. The off-chain components are:
- Distributed (no single point of failure)
- Verifiable (attestation, threshold cryptography)
- Replaceable (multiple providers)

---

## Cross-Chain Composability

### The Multi-Chain Reality

AI agents will operate across multiple chains. Different assets, liquidity, and services exist on different networks. A realistic agent infrastructure must account for this.

**Current Cross-Chain Landscape:**

| Infrastructure | Chains Supported | Composability Model |
|---------------|------------------|---------------------|
| x402 | Base, Solana (planned) | EIP-3009 on EVM, different on Solana |
| PayRam | BTC, ETH, Base, Polygon, Tron, Solana (planned) | Unified API, chain-specific settlement |
| Privy | Any EVM | Custodial abstraction |
| Sokosumi | Cardano | Single chain |
| **APEX** | **Sui only** | Deep Sui integration |

### APEX's Position: Sui-Native, Not Multi-Chain

APEX is explicitly **not** trying to be multi-chain. The design choice is to go deep on Sui rather than broad across chains.

**What this means:**
- Full use of Sui-specific features (PTBs, object model, Seal, Nautilus)
- No abstraction layers that would limit capabilities
- Agents operating on Sui get native experience
- Agents needing other chains need separate infrastructure

### How Multi-Chain Agents Could Work with APEX

**Option 1: APEX for Sui, Other Infrastructure Elsewhere**
```
Agent
├── Sui operations → APEX
├── Base operations → x402 or PayRam
└── Solana operations → x402 (when available)
```

**Option 2: Bridge-Based Composition**
```
Agent on Sui (APEX)
    │
    ├── Native Sui services (APEX AccessCapability)
    │
    └── Cross-chain via Wormhole/bridges
        ├── Lock SUI on Sui
        └── Receive wrapped asset on destination
```

**Option 3: Intent-Based Cross-Chain**
```
Agent creates SwapIntent on APEX
    │
    └── Executor fills cross-chain
        ├── Takes escrowed SUI on Sui
        └── Delivers USDC on Base (via their own infra)
```

### What APEX Doesn't Solve

1. **Native multi-chain payments**: Agent paying for Base service with Base ETH requires Base infrastructure, not APEX
2. **Cross-chain atomicity**: No atomic guarantees across chains (this is a fundamental limitation, not APEX-specific)
3. **Unified agent wallet across chains**: Each chain needs its own wallet/limits

### Research Questions

1. **Wormhole integration**: Could APEX AccessCapability be bridged? (Probably not - Sui objects don't bridge naturally)
2. **Cross-chain intents**: Could APEX trading intents be filled cross-chain by specialized executors?
3. **Multi-chain agent wallets**: Could a single human owner control agent spending across multiple chains with unified limits?

### Honest Assessment

APEX is a good fit for:
- Agents primarily operating on Sui
- Services deployed on Sui (DeFi, AI inference, data providers)
- Use cases where Sui's features (PTBs, Seal, Nautilus) provide clear value

APEX is not a good fit for:
- Agents needing seamless multi-chain operation
- Services on other chains
- Teams wanting single infrastructure across all chains

For multi-chain agents, a hybrid approach is likely necessary: APEX on Sui, x402/PayRam on EVM chains.

---

## Implementation Plan: High-Impact Additions

Based on market research and direct integration with Seal/Nautilus APIs.

### 1. Seal Integration: Capability-Gated Decryption

**Goal:** Providers encrypt API credentials/secrets with Seal. Only AccessCapability holders can decrypt.

**How Seal Works (Direct Integration):**
- Each Move package controls identity namespace `[PackageId]*`
- Key servers call `seal_approve(id: vector<u8>, ...)` to verify access
- Function must abort on denial (no return value)
- Client-side encryption/decryption via `@mysten/seal` SDK

**APEX seal_approve Implementation:**

```move
/// Called by Seal key servers to verify decryption access
/// Identity format: [APEX_PACKAGE_ID][service_id][capability_holder_check]
entry fun seal_approve(
    id: vector<u8>,
    cap: &AccessCapability,
    clock: &Clock,
    ctx: &TxContext
) {
    // Extract service_id from identity bytes
    let service_id = extract_service_id(&id);

    // Verify capability matches service
    assert!(cap.service_id == service_id, EServiceMismatch);

    // Verify capability not expired
    assert!(cap.expires_at == 0 || clock::timestamp_ms(clock) < cap.expires_at, ECapabilityExpired);

    // Verify capability has remaining units (or is unlimited)
    assert!(cap.remaining_units > 0, ENoUnitsRemaining);

    // Verify caller owns the capability
    assert!(object::owner(cap) == ctx.sender(), ENotCapabilityOwner);

    // If we reach here without aborting, key servers release decryption keys
}
```

**Provider Workflow:**
1. Provider deploys service, gets `service_id`
2. Provider encrypts API credentials with Seal using identity `[APEX_PKG][service_id]`
3. Provider stores encrypted blob on Walrus
4. Agent purchases AccessCapability
5. Agent requests decryption from Seal key servers
6. Key servers call `seal_approve`, verify agent holds capability
7. Agent receives decrypted credentials, uses API directly

**Files to Modify:**
- `apex_seal.move` - Add `seal_approve` entry function

---

### 2. Nautilus Integration: Verified Consumption Metering

**Goal:** Replace trusted provider consumption recording with TEE-verified metering.

**How Nautilus Works (Direct Integration):**
- Enclaves registered on-chain with public key + PCR values (one-time, expensive)
- Ongoing operations use Ed25519 signature verification (cheap)
- `sui::ed25519::ed25519_verify(&signature, &pubkey, &message)` for verification

**APEX Nautilus Implementation:**

```move
/// Registered Nautilus enclave for metering
public struct TrustedMeter has key, store {
    id: UID,
    enclave_pubkey: vector<u8>,  // 32-byte Ed25519 public key
    pcr_values: vector<u8>,       // Enclave code measurement
    registered_by: address,
}

/// Meter registry (shared object)
public struct MeterRegistry has key {
    id: UID,
    meters: Table<vector<u8>, ID>,  // pubkey -> TrustedMeter ID
}

/// Admin registers a trusted metering enclave
public fun register_meter(
    registry: &mut MeterRegistry,
    admin: &AdminCap,
    enclave_pubkey: vector<u8>,
    pcr_values: vector<u8>,
    attestation: vector<u8>,  // AWS Nitro attestation doc
    ctx: &mut TxContext
) {
    // In production: verify AWS certificate chain in attestation
    // This is gas-expensive, only done during registration

    let meter = TrustedMeter {
        id: object::new(ctx),
        enclave_pubkey,
        pcr_values,
        registered_by: ctx.sender(),
    };

    table::add(&mut registry.meters, enclave_pubkey, object::id(&meter));
    transfer::share_object(meter);
}

/// Consume stream units with enclave-verified usage report
public fun record_verified_consumption(
    stream: &mut PaymentStream,
    service: &mut ServiceProvider,
    meter: &TrustedMeter,
    usage_report: vector<u8>,   // BCS-encoded: {units: u64, timestamp: u64, stream_id: ID}
    signature: vector<u8>,       // 64-byte Ed25519 signature
    clock: &Clock,
    ctx: &mut TxContext
) {
    // Verify signature from registered enclave
    let is_valid = ed25519::ed25519_verify(
        &signature,
        &meter.enclave_pubkey,
        &usage_report
    );
    assert!(is_valid, EInvalidEnclaveSignature);

    // Parse usage report
    let (units, timestamp, reported_stream_id) = parse_usage_report(&usage_report);

    // Verify report is for this stream
    assert!(reported_stream_id == object::id(stream), EStreamMismatch);

    // Verify timestamp is recent (prevent replay)
    assert!(clock::timestamp_ms(clock) - timestamp < MAX_REPORT_AGE, EStaleReport);

    // Now we trust the units count - pull from escrow
    let cost = units * service.unit_price;
    assert!(stream.escrow >= cost, EInsufficientEscrow);

    stream.escrow = stream.escrow - cost;
    stream.total_consumed = stream.total_consumed + units;
    service.revenue = service.revenue + cost;
}
```

**Metering Enclave Workflow:**
1. Admin registers trusted metering enclave (one-time)
2. Consumer opens PaymentStream with escrow
3. Consumer uses service, traffic routed through metering enclave
4. Enclave counts API calls, signs usage report
5. Anyone can submit signed report on-chain
6. Contract verifies enclave signature, pulls from escrow

**Files to Modify:**
- `apex_payments.move` - Add `TrustedMeter`, `MeterRegistry`, `record_verified_consumption`

---

### 3. Delegated Agent Authorization

**Goal:** Human owner authorizes multiple agents with different limits and service restrictions.

```move
/// Authorization from human to agent
public struct AgentAuthorization has key, store {
    id: UID,
    owner: address,                   // Human who created this
    agent: address,                   // Authorized agent address
    allowed_services: vector<ID>,     // Empty = all services allowed
    spend_limit_per_tx: u64,          // Max per transaction (0 = unlimited)
    daily_limit: u64,                 // Max per day (0 = unlimited)
    daily_spent: u64,
    last_reset_epoch: u64,
    expires_at: u64,                  // 0 = never expires
    paused: bool,
}

/// Create authorization for an agent
public fun create_authorization(
    config: &ProtocolConfig,
    agent: address,
    allowed_services: vector<ID>,
    spend_limit_per_tx: u64,
    daily_limit: u64,
    duration_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext
): AgentAuthorization {
    AgentAuthorization {
        id: object::new(ctx),
        owner: ctx.sender(),
        agent,
        allowed_services,
        spend_limit_per_tx,
        daily_limit,
        daily_spent: 0,
        last_reset_epoch: clock::timestamp_ms(clock) / MS_PER_DAY,
        expires_at: if (duration_ms == 0) { 0 } else { clock::timestamp_ms(clock) + duration_ms },
        paused: false,
    }
}

/// Agent purchases access using authorization
public fun authorized_purchase(
    auth: &mut AgentAuthorization,
    config: &ProtocolConfig,
    service: &mut ServiceProvider,
    payment: Coin<SUI>,
    units: u64,
    clock: &Clock,
    ctx: &mut TxContext
): AccessCapability {
    // Verify caller is the authorized agent
    assert!(ctx.sender() == auth.agent, ENotAuthorizedAgent);

    // Verify not paused
    assert!(!auth.paused, EAuthorizationPaused);

    // Verify not expired
    assert!(auth.expires_at == 0 || clock::timestamp_ms(clock) < auth.expires_at, EAuthorizationExpired);

    // Verify service is allowed (empty = all allowed)
    if (!vector::is_empty(&auth.allowed_services)) {
        assert!(vector::contains(&auth.allowed_services, &object::id(service)), EServiceNotAllowed);
    }

    // Check and update daily limit
    let current_day = clock::timestamp_ms(clock) / MS_PER_DAY;
    if (current_day > auth.last_reset_epoch) {
        auth.daily_spent = 0;
        auth.last_reset_epoch = current_day;
    }

    let cost = coin::value(&payment);

    // Verify limits
    assert!(auth.spend_limit_per_tx == 0 || cost <= auth.spend_limit_per_tx, EExceedsSpendLimit);
    assert!(auth.daily_limit == 0 || auth.daily_spent + cost <= auth.daily_limit, EExceedsDailyLimit);

    auth.daily_spent = auth.daily_spent + cost;

    // Delegate to standard purchase
    purchase_access(config, service, payment, units, 0, 0, clock, ctx)
}

/// Owner pauses authorization
public fun pause_authorization(auth: &mut AgentAuthorization, ctx: &TxContext) {
    assert!(ctx.sender() == auth.owner, ENotOwner);
    auth.paused = true;
}

/// Owner revokes (destroys) authorization
public fun revoke_authorization(auth: AgentAuthorization, ctx: &TxContext) {
    assert!(ctx.sender() == auth.owner, ENotOwner);
    let AgentAuthorization { id, .. } = auth;
    object::delete(id);
}
```

**Files to Modify:**
- `apex_payments.move` - Add `AgentAuthorization` and related functions

---

### 4. Service Discovery Registry

**Goal:** On-chain registry for browsing/discovering services.

```move
/// Service metadata for discovery
public struct ServiceMetadata has store, copy, drop {
    name: String,
    description: String,
    category: String,
    endpoint_blob_id: vector<u8>,  // Walrus blob ID for encrypted endpoint (via Seal)
    unit_price: u64,
    min_purchase: u64,
}

/// Registry of all services (shared object)
public struct ServiceRegistry has key {
    id: UID,
    services: Table<ID, ServiceMetadata>,         // service_id -> metadata
    by_category: Table<String, vector<ID>>,       // category -> service_ids
    featured: vector<ID>,                          // Admin-curated featured list
}

/// Register service in discovery registry
public fun register_in_registry(
    registry: &mut ServiceRegistry,
    service: &ServiceProvider,
    name: String,
    description: String,
    category: String,
    endpoint_blob_id: vector<u8>,
    ctx: &TxContext
) {
    // Only service owner can register
    assert!(ctx.sender() == service.owner, ENotServiceOwner);

    let metadata = ServiceMetadata {
        name,
        description,
        category,
        endpoint_blob_id,
        unit_price: service.unit_price,
        min_purchase: service.min_purchase,
    };

    let service_id = object::id(service);
    table::add(&mut registry.services, service_id, metadata);

    // Add to category index
    if (!table::contains(&registry.by_category, category)) {
        table::add(&mut registry.by_category, category, vector::empty());
    }
    let category_list = table::borrow_mut(&mut registry.by_category, category);
    vector::push_back(category_list, service_id);
}
```

**Files to Modify:**
- `apex_payments.move` - Add `ServiceMetadata`, `ServiceRegistry`, registration functions

---

### 5. Additional Agentic Examples

Beyond DeepBook, demonstrate these patterns:

**A. Oracle Data Access**
```
PTB {
    // Purchase oracle access
    oracle_cap = apex::purchase_access(oracle_service, payment, 10)

    // Get price (oracle verifies capability)
    price = oracle::get_price(oracle_cap, "SUI/USD")

    // Use price in decision
    if (price > threshold) {
        deepbook::swap(...)
    }
}
```

**B. AI Inference Service**
```
PTB {
    // Purchase inference credits
    ai_cap = apex::purchase_access(inference_service, payment, 1)

    // Inference happens off-chain:
    // 1. Agent requests decryption of API endpoint from Seal (holds ai_cap)
    // 2. Agent calls inference API
    // 3. Result signed by Nautilus enclave
    // 4. Agent submits verified result on-chain if needed
}
```

**C. Agent-to-Agent Task Delegation**
```move
public struct TaskEscrow has key {
    id: UID,
    delegator: address,      // Agent A
    executor: address,       // Agent B (0x0 = open)
    payment: Balance<SUI>,
    task_hash: vector<u8>,   // Hash of task description
    result_hash: vector<u8>, // Expected result format hash
    deadline: u64,
    completed: bool,
}

public fun create_task(
    payment: Coin<SUI>,
    task_hash: vector<u8>,
    executor: address,  // 0x0 for open task
    deadline: u64,
    ctx: &mut TxContext
): TaskEscrow { ... }

public fun complete_task(
    task: &mut TaskEscrow,
    result: vector<u8>,
    ctx: &TxContext
) {
    // Verify caller is executor (or anyone if open)
    // Verify result_hash matches expected format
    // Release payment to executor
}
```

**Files to Create:**
- `demo/examples/oracle_access.rs`
- `demo/examples/ai_inference.rs`
- `demo/examples/task_delegation.rs`

---

### Implementation Priority

| Feature | Impact | Complexity | Dependencies |
|---------|--------|------------|--------------|
| 1. Delegated Agent Authorization | High | Low | None |
| 2. Service Discovery Registry | High | Low | None |
| 3. Seal `seal_approve` | High | Medium | Seal SDK |
| 4. Nautilus Verified Metering | Very High | High | Nautilus enclave |
| 5. Additional Examples | Medium | Low | 1-4 above |

**Recommended Order:**
1. Delegated Agent Authorization (self-contained, fills competitor gap)
2. Service Discovery Registry (self-contained, enables marketplace)
3. Seal integration (requires Seal SDK setup)
4. Nautilus metering (requires enclave deployment)
5. Examples (demonstrate all above)

---

## Open Questions

### Things APEX Doesn't Solve Yet

1. **Gas abstraction**: Users pay gas. Sponsored transactions could help but add complexity.

2. **Off-chain coordination**: If an agent needs to coordinate multiple services, each service sees separate PTBs. No built-in orchestration.

3. **Revocation**: Once an AccessCapability is transferred, revoking it requires the holder's cooperation or tracking IDs.

4. **Fine-grained policies**: Agent wallets have spend limits but can't express "only pay for service X" without additional capability restrictions.

5. **Cross-chain**: APEX is Sui-only. Agent operating on multiple chains needs different infrastructure per chain.

### Research Directions

1. **Optimistic serving with escrow**: Could APEX support optimistic serving where payment is escrowed and released on confirmation?

2. **Facilitator role on Sui**: Could a facilitator model work on Sui for gas abstraction? What would the trust model be?

3. **Seal policy composability**: Can complex multi-condition policies be efficiently expressed and verified?

4. **Nautilus latency**: What's the overhead of TEE verification for high-frequency operations?

5. **Economic security**: How do threshold parameters (t-of-n) affect practical security guarantees?

---

## References

### Protocols
- [EIP-3009: Transfer With Authorization](https://eips.ethereum.org/EIPS/eip-3009)
- [x402 Protocol Specification](https://x402.org/)
- [Sui Programmable Transaction Blocks](https://docs.sui.io/concepts/transactions/prog-txn-blocks)
- [Sui Sponsored Transactions](https://docs.sui.io/concepts/transactions/sponsored-transactions)

### Agent Infrastructure
- [Sokosumi (Masumi Protocol)](https://github.com/masumi-network/sokosumi)
- [OpenClaw Base Agent](https://github.com/KcPele/openclaw-base-agent)
- [PayRam x402 Gateway](https://payram.com/)
- [Privy Documentation](https://docs.privy.io/)

### Sui Privacy Stack
- [Seal: Decentralized Secrets Management](https://seal.mystenlabs.com/)
- [Seal Design Document](https://github.com/MystenLabs/seal/blob/main/Design.md)
- [Nautilus: Verified Off-Chain Compute](https://docs.sui.io/concepts/cryptography/nautilus)
- [Walrus: Decentralized Storage](https://www.walrus.xyz/)

### Cryptography
- [Boneh-Franklin IBE](https://crypto.stanford.edu/~dabo/papers/bfibe.pdf)
- [BLS12-381 Curve](https://hackmd.io/@benjaminion/bls12-381)
- [AWS Nitro Enclaves](https://aws.amazon.com/ec2/nitro/nitro-enclaves/)
