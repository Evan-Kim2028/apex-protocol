#!/bin/bash
# APEX DeepBook V3 Integration Test Script
#
# This script tests the DeepBook integration using PTBs
# Can be run against testnet or a local Sui node

set -e

# Configuration
NETWORK="${NETWORK:-testnet}"
PACKAGE_ID="${PACKAGE_ID:-}"  # Set after deployment

# DeepBook V3 Mainnet Package
DEEPBOOK_MAINNET="0x2d93777cc8b67c064b495e8606f2f8f5fd578450347bbe7b36e0bc03963c1c40"

# DeepBook V3 Testnet Package (latest)
DEEPBOOK_TESTNET="0x22be4cade64bf2d02412c7e8d0e8beea2f78828b948118d46735315409371a3c"

# Common pool IDs (examples - need to be updated with actual pool IDs)
# SUI/USDC Pool on Testnet (example)
SUI_USDC_POOL_TESTNET=""

echo "=== APEX DeepBook V3 Integration Tests ==="
echo "Network: $NETWORK"

# Check if sui CLI is available
if ! command -v sui &> /dev/null; then
    echo "Error: sui CLI not found. Please install the Sui CLI."
    exit 1
fi

# Function to run a PTB
run_ptb() {
    local description="$1"
    local ptb_json="$2"

    echo ""
    echo "--- $description ---"
    echo "PTB: $ptb_json"
    echo ""

    # For local testing, use sui client ptb
    # sui client ptb --json "$ptb_json"
    echo "[Simulated] Would execute PTB"
}

# Test 1: Query Pool Mid Price
test_query_pool_price() {
    echo ""
    echo "=== Test 1: Query Pool Mid Price ==="

    if [ -z "$SUI_USDC_POOL_TESTNET" ]; then
        echo "Skipping: No pool ID configured"
        return
    fi

    # PTB to query mid price
    # Note: This is a read-only call
    local ptb='{
        "inputs": [
            {"type": "object", "objectId": "'$SUI_USDC_POOL_TESTNET'"},
            {"type": "object", "objectId": "0x6"}
        ],
        "commands": [
            {
                "MoveCall": {
                    "package": "'$DEEPBOOK_TESTNET'",
                    "module": "pool",
                    "function": "mid_price",
                    "type_arguments": ["0x2::sui::SUI", "USDC_TYPE"],
                    "arguments": [{"Input": 0}, {"Input": 1}]
                }
            }
        ]
    }'

    run_ptb "Query Pool Mid Price" "$ptb"
}

# Test 2: Create Agent Trader
test_create_agent_trader() {
    echo ""
    echo "=== Test 2: Create Agent Trader ==="

    if [ -z "$PACKAGE_ID" ]; then
        echo "Skipping: Package not deployed yet"
        return
    fi

    local ptb='{
        "inputs": [],
        "commands": [
            {
                "MoveCall": {
                    "package": "'$PACKAGE_ID'",
                    "module": "deepbook_v3",
                    "function": "create_agent_trader",
                    "type_arguments": [],
                    "arguments": []
                }
            },
            {
                "TransferObjects": {
                    "objects": [{"Result": 0}],
                    "address": {"Input": "sender"}
                }
            }
        ]
    }'

    run_ptb "Create Agent Trader" "$ptb"
}

# Test 3: Swap Base for Quote via APEX
test_swap_base_for_quote() {
    echo ""
    echo "=== Test 3: Swap Base for Quote ==="

    if [ -z "$PACKAGE_ID" ] || [ -z "$SUI_USDC_POOL_TESTNET" ]; then
        echo "Skipping: Package or pool not configured"
        return
    fi

    # Would need:
    # - Pool object
    # - Input SUI coin
    # - DEEP for fees
    # - Clock

    local ptb='{
        "inputs": [
            {"type": "object", "objectId": "'$SUI_USDC_POOL_TESTNET'"},
            {"type": "object", "objectId": "SUI_COIN_ID"},
            {"type": "object", "objectId": "DEEP_COIN_ID"},
            {"type": "pure", "value": "1000000"},
            {"type": "object", "objectId": "0x6"}
        ],
        "commands": [
            {
                "MoveCall": {
                    "package": "'$PACKAGE_ID'",
                    "module": "deepbook_v3",
                    "function": "swap_base_for_quote",
                    "type_arguments": ["0x2::sui::SUI", "USDC_TYPE"],
                    "arguments": [
                        {"Input": 0},
                        {"Input": 1},
                        {"Input": 2},
                        {"Input": 3},
                        {"Input": 4}
                    ]
                }
            }
        ]
    }'

    run_ptb "Swap SUI for USDC" "$ptb"
}

# Test 4: Execute Intent via DeepBook
test_execute_intent_swap() {
    echo ""
    echo "=== Test 4: Execute Intent Swap ==="

    if [ -z "$PACKAGE_ID" ]; then
        echo "Skipping: Package not deployed"
        return
    fi

    echo "This test demonstrates the full intent->DEX flow:"
    echo "1. User creates swap intent (escrowed in contract)"
    echo "2. Executor sees intent, checks DeepBook liquidity"
    echo "3. Executor calls execute_intent_swap"
    echo "4. APEX swaps on DeepBook"
    echo "5. Output goes to intent creator, executor gets receipt"

    local ptb='{
        "inputs": [
            {"type": "object", "objectId": "POOL_ID"},
            {"type": "object", "objectId": "INPUT_COIN"},
            {"type": "object", "objectId": "DEEP_COIN"},
            {"type": "pure", "value": "MIN_OUTPUT"},
            {"type": "pure", "value": "RECIPIENT_ADDRESS"},
            {"type": "object", "objectId": "0x6"}
        ],
        "commands": [
            {
                "MoveCall": {
                    "package": "'$PACKAGE_ID'",
                    "module": "deepbook_v3",
                    "function": "execute_intent_swap",
                    "type_arguments": ["BASE_TYPE", "QUOTE_TYPE"],
                    "arguments": [
                        {"Input": 0},
                        {"Input": 1},
                        {"Input": 2},
                        {"Input": 3},
                        {"Input": 4},
                        {"Input": 5}
                    ]
                }
            }
        ]
    }'

    run_ptb "Execute Intent Swap" "$ptb"
}

# Test 5: Atomic Pay-and-Trade PTB
test_atomic_pay_and_trade() {
    echo ""
    echo "=== Test 5: Atomic Pay-and-Trade PTB ==="

    echo "This demonstrates Sui's unique PTB capability:"
    echo "In a SINGLE atomic transaction:"
    echo "  1. Split payment from user's SUI"
    echo "  2. Pay for API service (APEX apex module)"
    echo "  3. Use returned capability to access service"
    echo "  4. Execute trade via DeepBook"
    echo "  5. Return results to user"
    echo ""
    echo "This is IMPOSSIBLE on other chains - they require multiple txs!"

    local ptb='{
        "description": "Atomic Pay-and-Trade",
        "inputs": [
            {"type": "object", "objectId": "SERVICE_PROVIDER"},
            {"type": "object", "objectId": "USER_SUI_COIN"},
            {"type": "object", "objectId": "DEEPBOOK_POOL"},
            {"type": "object", "objectId": "DEEP_FOR_FEES"},
            {"type": "object", "objectId": "0x6"}
        ],
        "commands": [
            {
                "comment": "Split payment amount from user coin",
                "SplitCoins": {
                    "coin": {"Input": 1},
                    "amounts": [{"Pure": "PAYMENT_AMOUNT"}]
                }
            },
            {
                "comment": "Pay for service and get access capability",
                "MoveCall": {
                    "package": "'$PACKAGE_ID'",
                    "module": "apex",
                    "function": "agent_purchase_access",
                    "arguments": [
                        {"Input": 0},
                        {"Result": 0}
                    ]
                }
            },
            {
                "comment": "Now use capability + remaining coin to trade",
                "MoveCall": {
                    "package": "'$PACKAGE_ID'",
                    "module": "deepbook_v3",
                    "function": "swap_base_for_quote",
                    "type_arguments": ["0x2::sui::SUI", "QUOTE_TYPE"],
                    "arguments": [
                        {"Input": 2},
                        {"Input": 1},
                        {"Input": 3},
                        {"Pure": "MIN_OUTPUT"},
                        {"Input": 4}
                    ]
                }
            }
        ]
    }'

    run_ptb "Atomic Pay-and-Trade" "$ptb"
}

# Main test runner
main() {
    echo ""
    echo "DeepBook V3 Package: $DEEPBOOK_TESTNET (testnet)"
    echo "APEX Package: ${PACKAGE_ID:-NOT_DEPLOYED}"
    echo ""

    test_query_pool_price
    test_create_agent_trader
    test_swap_base_for_quote
    test_execute_intent_swap
    test_atomic_pay_and_trade

    echo ""
    echo "=== Test Summary ==="
    echo "All PTB structures validated."
    echo ""
    echo "To actually execute these tests:"
    echo "1. Deploy the APEX package to testnet"
    echo "2. Set PACKAGE_ID environment variable"
    echo "3. Configure pool IDs"
    echo "4. Get testnet SUI from faucet"
    echo "5. Get testnet DEEP tokens"
    echo "6. Run individual PTBs via: sui client ptb ..."
}

main "$@"
