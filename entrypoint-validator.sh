#!/usr/bin/env bash
set -e

# Configuration
CHAINID="${CHAINID:-private}"
VALIDATOR_NAME="${VALIDATOR_NAME:-validator}"
MONIKER="${MONIKER:-celestia-devnet}"
STAKE_AMOUNT="${STAKE_AMOUNT:-5000000000utia}"
COIN_AMOUNT="${COIN_AMOUNT:-1000000000000utia}"
KEYRING_BACKEND="${KEYRING_BACKEND:-test}"

# Paths
APP_PATH="/home/celestia/.celestia-app"

echo "🚀 Starting Celestia validator initialization..."
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
GENESIS_FILE="$APP_PATH/config/genesis.json"
jq '.app_state.minfee.network_min_gas_price = "0.000000000000000000" | .app_state.minfee.params.network_min_gas_price = "0.000000000000000000"' "$GENESIS_FILE" > "${GENESIS_FILE}.tmp" && mv "${GENESIS_FILE}.tmp" "$GENESIS_FILE"

# Update configuration for external access
echo "🔧 Updating configuration..."
CONFIG_FILE="$APP_PATH/config/config.toml"
sed -i 's#"tcp://127.0.0.1:26657"#"tcp://0.0.0.0:26657"#g' "$CONFIG_FILE"
sed -i 's/^timeout_commit\s*=.*/timeout_commit = "2s"/g' "$CONFIG_FILE"
sed -i 's/^timeout_propose\s*=.*/timeout_propose = "2s"/g' "$CONFIG_FILE"
sed -i 's/^cors_allowed_origins\s*=.*/cors_allowed_origins = ["*"]/g' "$CONFIG_FILE"

# Update app.toml with proper gRPC configuration
echo "🔧 Configuring gRPC and API services..."
APP_CONFIG_FILE="$APP_PATH/config/app.toml"

# Enable and configure API server
sed -i '/^\[api\]/,/^\[/ { s/^enable = false/enable = true/ }' "$APP_CONFIG_FILE"
sed -i 's/^address = "tcp:\/\/localhost:1317"/address = "tcp:\/\/0.0.0.0:1317"/' "$APP_CONFIG_FILE"
sed -i '/^\[api\]/,/^\[/ { s/^enabled-unsafe-cors = false/enabled-unsafe-cors = true/ }' "$APP_CONFIG_FILE"

# Enable and configure gRPC server  
sed -i '/^\[grpc\]/,/^\[/ { s/^enable = false/enable = true/ }' "$APP_CONFIG_FILE"
sed -i '/^\[grpc\]/,/^\[/ { s/^address = "localhost:9090"/address = "0.0.0.0:9090"/ }' "$APP_CONFIG_FILE"

# Enable gRPC web
sed -i '/^\[grpc-web\]/,/^\[/ { s/^enable = false/enable = true/ }' "$APP_CONFIG_FILE"
sed -i '/^\[grpc-web\]/,/^\[/ { s/^address = "localhost:9091"/address = "0.0.0.0:9091"/ }' "$APP_CONFIG_FILE"

echo "🚀 Starting celestia-app..."
echo "🔧 Configuration files:"
echo "  Config: $CONFIG_FILE"
echo "  App Config: $APP_CONFIG_FILE"

# Debug: Show the gRPC configuration
echo "🔍 gRPC configuration:"
grep -A 5 -B 1 '\[grpc\]' "$APP_CONFIG_FILE" || echo "Could not find gRPC section"

# Start with explicit configuration to ensure gRPC is enabled
celestia-appd start \
  --grpc.enable=true \
  --grpc.address="0.0.0.0:9090" \
  --api.enable=true \
  --api.enabled-unsafe-cors=true \
  --api.address="tcp://0.0.0.0:1317" \
  --force-no-bbr \
  --log_level info &

APP_PID=$!
echo "🔄 Validator started with PID: $APP_PID"

# Wait a moment for services to start
sleep 5

# Debug: Check what ports are actually listening
echo "🔍 Checking what ports are listening..."
netstat -tlnp 2>/dev/null | grep ':9090\|:26657\|:1317' || echo "No matching ports found with netstat"
ss -tlnp 2>/dev/null | grep ':9090\|:26657\|:1317' || echo "No matching ports found with ss"

# Test gRPC port locally
echo "🔍 Testing gRPC port locally..."
if nc -z localhost 9090 2>/dev/null; then
    echo "✅ gRPC port 9090 is reachable locally"
else
    echo "❌ gRPC port 9090 is NOT reachable locally"
fi

# Test on all interfaces
if nc -z 0.0.0.0 9090 2>/dev/null; then
    echo "✅ gRPC port 9090 is reachable on all interfaces"
else
    echo "❌ gRPC port 9090 is NOT reachable on all interfaces"
fi

# Wait for the validator process
wait $APP_PID
