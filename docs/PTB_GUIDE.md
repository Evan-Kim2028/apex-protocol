# APEX Protocol PTB Guide

Quick reference for all PTB operations executed in the demo. Shows function signatures and outputs from local Move VM simulation.

> Run `cd demo && cargo run` to execute all demos and generate `ptb_traces.json`

---

## Demo Overview

| Demo | Purpose | Key Functions |
|------|---------|---------------|
| **1. Basic Flow** | Core payment lifecycle | `register_service` → `purchase_access` → `use_access` |
| **2. Delegated Auth** | Agent spending limits | `create_agent_wallet` → `agent_purchase_access` |
| **3. Service Registry** | On-chain discovery | `register_in_registry` → `discover_services` |
| **4. Nautilus + Seal** | TEE + encrypted access | `verify_nautilus_attestation` → `dry_run_seal_access` |
| **5. Hedge Fund** | Multi-agent trading | `create_fund` → `join_fund` → `execute_trade` → `settle_fund` → `withdraw_shares` |

---

## Demo 1: Basic Flow

### register_service
```
apex_payments::register_service(config, name, description, price_per_unit, payment)
```
| Output | Type |
|--------|------|
| ServiceProvider | Shared object |
| Change coin | Owned by sender |

### purchase_access
```
apex_payments::purchase_access(config, service, payment, units, duration_ms, rate_limit, clock)
→ AccessCapability
```
| Output | Type |
|--------|------|
| AccessCapability | Owned by recipient |
| Change coin | Owned by sender |

### use_access
```
apex_payments::use_access(capability, service, units, clock) → bool
```
| Output | Type |
|--------|------|
| (mutates capability) | Units decremented |
| Returns `true` | Success |

---

## Demo 2: Delegated Authorization

### create_agent_wallet
```
apex_payments::create_agent_wallet(config, agent_id, spend_limit, daily_limit, funding, clock)
→ AgentWallet
```
| Output | Type |
|--------|------|
| AgentWallet | Owned by creator (human) |

### agent_purchase_access
```
apex_payments::agent_purchase_access(wallet, config, service, units, duration_ms, rate_limit, clock)
→ AccessCapability
```
| Output | Type |
|--------|------|
| AccessCapability | Owned by agent address |
| (mutates wallet) | Balance/limits updated |

**Enforced limits:**
- Per-transaction spend limit
- Daily spending cap
- Wallet pause capability

---

## Demo 3: Service Registry

### register_in_registry
```
apex_workflows::register_in_registry(registry, service, category)
```
| Output | Type |
|--------|------|
| (mutates registry) | Service added to category |

### discover_services
```
apex_workflows::discover_services(registry, category) → vector<ServiceInfo>
```
| Output | Type |
|--------|------|
| ServiceInfo[] | Array of matching services |

---

## Demo 4: Nautilus TEE + Seal Encryption

### verify_nautilus_attestation
```
apex_seal::verify_nautilus_attestation(config, capability, attestation, signature, timestamp, clock)
→ VerificationResult
```
| Output | Type |
|--------|------|
| VerificationResult | TEE attestation verified |
| (mutates capability) | Marked as TEE-verified |

### dry_run_seal_access
```
apex_seal::dry_run_seal_access(config, capability, content_id, seal_key_request)
→ SealAccessProof
```
| Output | Type |
|--------|------|
| SealAccessProof | Proof for decryption request |

**Note:** Full Seal integration requires key server network (simulated locally).

---

## Demo 5: Agentic Hedge Fund

### create_fund
```
apex_fund::create_fund(config, name, description, management_fee_bps, performance_fee_bps, payment, clock)
→ HedgeFund
```
| Output | Type |
|--------|------|
| HedgeFund | Shared object |
| ManagerCap | Owned by creator |

### join_fund
```
apex_fund::join_fund(config, fund, entry_service, entry_payment, investment, clock)
→ InvestorPosition
```
| Output | Type |
|--------|------|
| InvestorPosition | Owned by investor |
| (mutates fund) | Capital + shares increased |

### execute_trade
```
apex_fund::execute_margin_trade(fund, manager_cap, direction, size, entry_price, leverage, clock)
→ TradeRecord
```
| Output | Type |
|--------|------|
| TradeRecord | Trade history |
| (mutates fund) | P&L updated |

**Direction:** `0` = Long, `1` = Short

### settle_fund
```
apex_fund::settle_fund(fund, manager_cap, exit_price, clock)
```
| Output | Type |
|--------|------|
| (mutates fund) | State → SETTLED |
| Fees | Deducted from capital pool |

### withdraw_shares
```
apex_fund::withdraw_shares(fund, position, clock)
→ Coin<SUI>
```
| Output | Type |
|--------|------|
| Coin<SUI> | Proportional share of capital + profits |
| (burns position) | InvestorPosition deleted |

---

## Output Summary by Demo

### Demo 1 Objects Created
```
ServiceProvider     → 0xfa38...2b88  (Shared)
AccessCapability    → 0xfdd6...6da8  (Owned)
```

### Demo 2 Objects Created
```
AgentWallet         → 0x7a31...c4e2  (Owned by human)
AccessCapability    → 0x8b42...d5f3  (Owned by agent)
```

### Demo 5 Objects Created
```
HedgeFund           → 0xc9e2...1a7f  (Shared)
ManagerCap          → 0xd3f4...2b8e  (Owned by manager)
InvestorPosition×3  → 0xe5g6...3c9f  (Owned by investors)
TradeRecord×3       → 0xf7h8...4d0e  (Trade history)
Coin<SUI>×3         → 0x1i2j...5e1f  (Withdrawals)
```

---

## Gas Costs (Local Simulation)

| Operation | Gas Units |
|-----------|-----------|
| register_service | ~2,575 |
| purchase_access | ~6,596 |
| use_access | ~5,022 |
| create_fund | ~3,200 |
| join_fund | ~7,100 |
| execute_trade | ~4,800 |
| settle_fund | ~5,500 |
| withdraw_shares | ~6,200 |

---

## PTB Composition Patterns

### Atomic Purchase + Use (Demo 1)
```
Command 0: purchase_access → Result[0] = AccessCapability
Command 1: use_access(Result[0], ...)
Command 2: TransferObjects([Result[0]]) → recipient
```
All-or-nothing: if `use_access` fails, purchase reverts.

### Atomic Join + Trade (Demo 5)
```
Command 0: SplitCoins(gas, [entry_fee, investment])
Command 1: join_fund(Result[0][0], Result[0][1]) → InvestorPosition
Command 2: TransferObjects([Result[1]]) → investor
```

### Multi-Investor Withdrawal (Demo 5)
```
PTB 1: withdraw_shares(fund, position_1) → Coin to investor_1
PTB 2: withdraw_shares(fund, position_2) → Coin to investor_2
PTB 3: withdraw_shares(fund, position_3) → Coin to investor_3
```

---

## JSON Trace Output

After running the demo, inspect `demo/ptb_traces.json`:

```bash
# List all operations
jq '.traces[] | "\(.demo): \(.step)"' demo/ptb_traces.json

# Get created objects
jq '.traces[].outputs.created_objects[]' demo/ptb_traces.json

# Total gas
jq '[.traces[].outputs.gas_used] | add' demo/ptb_traces.json
```

See [PTB_TRACES.md](PTB_TRACES.md) for full trace schema and decoding guide.
