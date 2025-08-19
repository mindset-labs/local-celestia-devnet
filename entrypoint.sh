#!/usr/bin/env bash
set -e

# Configuration
CHAINID="${CHAINID:-private}"
VALIDATOR_NAME="${VALIDATOR_NAME:-validator}"
MONIKER="${MONIKER:-celestia-devnet}"
STAKE_AMOUNT="${STAKE_AMOUNT:-5000000000utia}"
COIN_AMOUNT="${COIN_AMOUNT:-1000000000000utia}"  # Much larger than stake amount
KEYRING_BACKEND="${KEYRING_BACKEND:-test}"

# Paths
APP_PATH="/home/celestia/.celestia-app"
NODE_PATH="/home/celestia/bridge"

echo "🚀 Starting Celestia devnet initialization..."
echo "Chain ID: $CHAINID"
echo "Validator: $VALIDATOR_NAME"
echo "Initial Balance: $COIN_AMOUNT"
echo "Stake Amount: $STAKE_AMOUNT"

# Cleanup existing data
if [ -d "$APP_PATH" ]; then
  echo "🧹 Cleaning up existing app data..."
  rm -rf "$APP_PATH"
fi

echo "⚙️ Initializing celestia-app..."
# Initialize the chain
celestia-appd init "$MONIKER" --chain-id "$CHAINID"

echo "🔑 Creating validator key..."
# Create validator key
celestia-appd keys add "$VALIDATOR_NAME" --keyring-backend="$KEYRING_BACKEND"

echo "💰 Adding genesis account with balance..."
# Get validator address and add to genesis with sufficient balance
VALIDATOR_ADDR=$(celestia-appd keys show "$VALIDATOR_NAME" -a --keyring-backend="$KEYRING_BACKEND")
celestia-appd genesis add-genesis-account "$VALIDATOR_ADDR" "$COIN_AMOUNT"

echo "📝 Creating genesis transaction..."
# Create genesis transaction in offline mode to avoid connection issues
celestia-appd genesis gentx "$VALIDATOR_NAME" "$STAKE_AMOUNT" \
  --chain-id="$CHAINID" \
  --keyring-backend="$KEYRING_BACKEND" \
  --offline \
  --account-number=0 \
  --sequence=0

echo "📋 Collecting genesis transactions..."
# Collect genesis transactions
celestia-appd genesis collect-gentxs

# Set minimum gas price to 0 for devnet to avoid genesis transaction fee issues
echo "💸 Setting minimum gas price to 0 for devnet..."
GENESIS_FILE="$HOME/.celestia-app/config/genesis.json"
jq '.app_state.minfee.network_min_gas_price = "0.000000000000000000" | .app_state.minfee.params.network_min_gas_price = "0.000000000000000000"' "$GENESIS_FILE" > "${GENESIS_FILE}.tmp" && mv "${GENESIS_FILE}.tmp" "$GENESIS_FILE"

# Update configuration for external access
echo "🔧 Updating configuration..."
CONFIG_FILE="$HOME/.celestia-app/config/config.toml"
sed -i 's#"tcp://127.0.0.1:26657"#"tcp://0.0.0.0:26657"#g' "$CONFIG_FILE"
sed -i 's/^timeout_commit\s*=.*/timeout_commit = "2s"/g' "$CONFIG_FILE"
sed -i 's/^timeout_propose\s*=.*/timeout_propose = "2s"/g' "$CONFIG_FILE"
sed -i 's/^cors_allowed_origins\s*=.*/cors_allowed_origins = ["*"]/g' "$CONFIG_FILE"

# Update app.toml
APP_CONFIG_FILE="$HOME/.celestia-app/config/app.toml"
sed -i 's/enable = false/enable = true/g' "$APP_CONFIG_FILE"
sed -i 's/address = "127.0.0.1:9090"/address = "0.0.0.0:9090"/g' "$APP_CONFIG_FILE"

echo "🚀 Starting celestia-app..."
celestia-appd start --grpc.enable --api.enable --force-no-bbr &
APP_PID=$!

# Wait for the validator to be ready
echo "⏳ Waiting for validator to be ready..."
MAX_ATTEMPTS=30
ATTEMPT=0
while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
  if curl -s http://localhost:26657/status > /dev/null 2>&1; then
    echo "✅ Validator is ready!"
    break
  fi
  echo "Waiting for validator... (attempt $((ATTEMPT+1))/$MAX_ATTEMPTS)"
  sleep 2
  ATTEMPT=$((ATTEMPT+1))
done

if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
  echo "❌ Validator failed to start in time"
  exit 1
fi

# Initialize and start the bridge node
echo "🌉 Initializing Celestia bridge node..."

# Clean up any existing bridge data
if [ -d "$NODE_PATH" ]; then
  echo "🧹 Cleaning up existing bridge data..."
  rm -rf "$NODE_PATH"
fi

# Wait for the validator to stabilize and produce blocks
echo "⏳ Waiting for validator to stabilize and produce blocks..."
sleep 10

# Test that we can actually fetch a block and get the trusted hash
echo "🔍 Testing validator connectivity and fetching trusted hash..."
MAX_BLOCK_ATTEMPTS=15
BLOCK_ATTEMPT=0
TRUSTED_HASH=""

while [ $BLOCK_ATTEMPT -lt $MAX_BLOCK_ATTEMPTS ]; do
  BLOCK_RESPONSE=$(curl -s http://localhost:26657/block?height=1)
  if echo "$BLOCK_RESPONSE" | grep -q '"block"' && echo "$BLOCK_RESPONSE" | grep -q '"block_id"'; then
    # Extract the trusted hash from the genesis block
    TRUSTED_HASH=$(echo "$BLOCK_RESPONSE" | jq -r '.result.block_id.hash')
    if [ -n "$TRUSTED_HASH" ] && [ "$TRUSTED_HASH" != "null" ]; then
      echo "✅ Retrieved trusted hash: $TRUSTED_HASH"
      
      # Also check that we can get the latest height
      LATEST_HEIGHT=$(curl -s http://localhost:26657/status | jq -r '.result.sync_info.latest_block_height // "0"')
      echo "📊 Latest block height: $LATEST_HEIGHT"
      
      if [ "$LATEST_HEIGHT" -gt "0" ]; then
        echo "✅ Validator is producing blocks!"
        break
      fi
    fi
  fi
  echo "Waiting for blocks to be available... (attempt $((BLOCK_ATTEMPT+1))/$MAX_BLOCK_ATTEMPTS)"
  sleep 3
  BLOCK_ATTEMPT=$((BLOCK_ATTEMPT+1))
done

if [ $BLOCK_ATTEMPT -eq $MAX_BLOCK_ATTEMPTS ] || [ -z "$TRUSTED_HASH" ]; then
  echo "❌ Failed to retrieve trusted hash from validator"
  echo "Continuing without bridge - validator will still work"
  wait $APP_PID
  exit 0
fi

# Initialize the bridge with the private network
echo "🔧 Initializing bridge store..."
celestia bridge init \
  --p2p.network private \
  --core.ip 127.0.0.1 \
  --node.store "$NODE_PATH"

# Update the bridge configuration with the trusted hash
echo "📝 Updating bridge configuration with trusted hash..."
BRIDGE_CONFIG="$NODE_PATH/config.toml"
sed -i "s/TrustedHash = \"\"/TrustedHash = \"$TRUSTED_HASH\"/" "$BRIDGE_CONFIG"

# Verify the configuration was updated
if grep -q "TrustedHash = \"$TRUSTED_HASH\"" "$BRIDGE_CONFIG"; then
  echo "✅ Bridge configuration updated successfully"
else
  echo "❌ Failed to update bridge configuration"
  wait $APP_PID
  exit 1
fi

# Get the auth token for the bridge
BRIDGE_AUTH_TOKEN=$(celestia bridge auth admin --p2p.network private --node.store "$NODE_PATH")
echo "🔑 Bridge auth token generated"

# Start the bridge node with retry logic
echo "🌉 Starting Celestia bridge node..."
START_ATTEMPTS=3
BRIDGE_STARTED=false

for i in $(seq 1 $START_ATTEMPTS); do
  echo "Starting bridge (attempt $i/$START_ATTEMPTS)..."
  
  celestia bridge start \
    --p2p.network private \
    --core.ip 127.0.0.1 \
    --core.port 9090 \
    --rpc.addr 0.0.0.0 \
    --rpc.port 26658 \
    --node.store "$NODE_PATH" \
    --gateway \
    --gateway.addr 0.0.0.0 \
    --gateway.port 26659 \
    --log.level INFO &
  BRIDGE_PID=$!
  
  # Give it time to start
  sleep 5
  
  # Check if the bridge is still running
  if kill -0 $BRIDGE_PID 2>/dev/null; then
    # Additional verification: try to make an RPC call
    sleep 3
    if curl -s -X POST \
         -H "Authorization: Bearer $BRIDGE_AUTH_TOKEN" \
         -H "Content-Type: application/json" \
         -d '{"id":1,"jsonrpc":"2.0","method":"header.LocalHead","params":[]}' \
         http://localhost:26658 > /dev/null 2>&1; then
      echo "✅ Bridge started successfully and responding to RPC!"
      BRIDGE_STARTED=true
      break
    else
      echo "⚠️ Bridge process is running but not responding to RPC yet..."
      # Give it more time
      sleep 5
      if curl -s -X POST \
           -H "Authorization: Bearer $BRIDGE_AUTH_TOKEN" \
           -H "Content-Type: application/json" \
           -d '{"id":1,"jsonrpc":"2.0","method":"header.LocalHead","params":[]}' \
           http://localhost:26658 > /dev/null 2>&1; then
        echo "✅ Bridge is now responding to RPC!"
        BRIDGE_STARTED=true
        break
      fi
    fi
  else
    echo "❌ Bridge process failed to start"
    wait $BRIDGE_PID
    EXIT_CODE=$?
    echo "Bridge exit code: $EXIT_CODE"
    
    if [ $i -lt $START_ATTEMPTS ]; then
      echo "Retrying in 5 seconds..."
      sleep 5
    fi
  fi
done

if [ "$BRIDGE_STARTED" = true ]; then
  echo "✨ Celestia devnet is running!"
  echo "  - Validator RPC: http://localhost:26657"
  echo "  - Validator gRPC: localhost:9090"
  echo "  - Bridge RPC: http://localhost:26658"
  echo "  - Bridge Gateway: http://localhost:26659"
  echo "  - Bridge Auth Token: $BRIDGE_AUTH_TOKEN"
  echo ""
  echo "📝 To interact with the bridge:"
  echo "  curl -X POST -H \"Authorization: Bearer $BRIDGE_AUTH_TOKEN\" \\"
  echo "       -H \"Content-Type: application/json\" \\"
  echo "       -d '{\"id\":1,\"jsonrpc\":\"2.0\",\"method\":\"header.LocalHead\",\"params\":[]}' \\"
  echo "       http://localhost:26658"
  
  # Wait for both processes
  wait $APP_PID $BRIDGE_PID
else
  echo "⚠️ Failed to start bridge after $START_ATTEMPTS attempts"
  echo "Celestia validator is still running!"
  echo "  - Validator RPC: http://localhost:26657"
  echo "  - Validator gRPC: localhost:9090"
  
  # Wait for validator process only
  wait $APP_PID
fi