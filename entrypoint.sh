#!/usr/bin/env bash
set -e

# Configuration with environment variable support
CHAINID="${CHAINID:-private}"
VALIDATOR_NAME="${VALIDATOR_NAME:-validator}"
MONIKER="${MONIKER:-celestia-devnet}"
STAKE_AMOUNT="${STAKE_AMOUNT:-5000000000utia}"
KEYRING_BACKEND="${KEYRING_BACKEND:-test}"

# Paths
APP_PATH="/home/celestia/.celestia-app"
NODE_PATH="/home/celestia/bridge"

echo "🚀 Starting Celestia devnet initialization..."
echo "Chain ID: $CHAINID"
echo "Validator: $VALIDATOR_NAME"
echo "Moniker: $MONIKER"

# Cleanup existing data if present
if [ -d "$APP_PATH" ]; then
  echo "🧹 Cleaning up existing app data at $APP_PATH..."
  rm -rf "$APP_PATH"
fi

if [ -d "$NODE_PATH" ]; then
  echo "🧹 Cleaning up existing bridge data at $NODE_PATH..."
  rm -rf "$NODE_PATH"
fi

echo "⚙️ Initializing celestia-app..."

# Initialize the app
celestia-appd init "$MONIKER" --chain-id "$CHAINID"

# Create validator key
echo "🔑 Creating validator key..."
celestia-appd keys add "$VALIDATOR_NAME" --keyring-backend="$KEYRING_BACKEND"

# Create genesis transaction (this replaces add-genesis-account + gentx)
echo "📝 Creating genesis transaction..."
celestia-appd genesis gentx "$VALIDATOR_NAME" "$STAKE_AMOUNT" \
  --chain-id "$CHAINID" \
  --moniker "$MONIKER" \
  --keyring-backend="$KEYRING_BACKEND"

# Collect genesis transactions
echo "📋 Collecting genesis transactions..."
celestia-appd collect-gentxs

# Update configuration for external access
echo "🔧 Updating configuration..."

# Update config.toml
CONFIG_FILE="$HOME/.celestia-app/config/config.toml"
sed -i 's#"tcp://127.0.0.1:26657"#"tcp://0.0.0.0:26657"#g' "$CONFIG_FILE"
sed -i 's/^timeout_commit\s*=.*/timeout_commit = "2s"/g' "$CONFIG_FILE"
sed -i 's/^timeout_propose\s*=.*/timeout_propose = "2s"/g' "$CONFIG_FILE"
sed -i 's/^cors_allowed_origins\s*=.*/cors_allowed_origins = ["*"]/g' "$CONFIG_FILE"

# Update app.toml for API access
APP_CONFIG_FILE="$HOME/.celestia-app/config/app.toml"
sed -i 's/enable = false/enable = true/g' "$APP_CONFIG_FILE"
sed -i 's/address = "127.0.0.1:9090"/address = "0.0.0.0:9090"/g' "$APP_CONFIG_FILE"

echo "🚀 Starting celestia-app..."
celestia-appd start --grpc.enable --api.enable &

# Wait for the first block
echo "⏳ Waiting for first block..."
GENESIS=""
CNT=0
MAX=60

while [ ${#GENESIS} -le 4 ] && [ $CNT -lt $MAX ]; do
    echo "Attempt $((CNT+1))/$MAX - Checking for genesis block..."
    
    if curl -s http://127.0.0.1:26657/status > /dev/null 2>&1; then
        GENESIS=$(curl -s http://127.0.0.1:26657/block?height=1 2>/dev/null | jq -r '.result.block_id.hash // empty' 2>/dev/null || echo "")
        if [ -n "$GENESIS" ] && [ "$GENESIS" != "null" ]; then
            echo "✅ Genesis block found: $GENESIS"
            break
        fi
    fi
    
    ((CNT++))
    sleep 2
done

if [ $CNT -eq $MAX ]; then
    echo "❌ Failed to get genesis hash after $MAX attempts"
    exit 1
fi

# Set up custom network
export CELESTIA_CUSTOM="$CHAINID:$GENESIS"
echo "🌐 Custom network: $CELESTIA_CUSTOM"

# Setup bridge node
echo "🌉 Initializing bridge node..."
mkdir -p "$NODE_PATH/keys"

# Copy keyring for bridge node
if [ -d "$APP_PATH/keyring-test/" ]; then
    cp -r "$APP_PATH/keyring-test/" "$NODE_PATH/keys/keyring-test/"
fi

# Initialize bridge node
celestia bridge init --node.store "$NODE_PATH"

echo "🚀 Starting bridge node..."
celestia bridge start \
  --node.store "$NODE_PATH" \
  --gateway \
  --core.ip 127.0.0.1 \
  --core.rpc.port 26657 \
  --core.grpc.port 9090 \
  --keyring.accname "$VALIDATOR_NAME" \
  --gateway.addr 0.0.0.0 \
  --gateway.port 26659 \
  --rpc.addr 0.0.0.0 \
  --rpc.port 26658 \
  --p2p.network "$CHAINID" &

echo "✅ Celestia devnet started successfully!"
echo "🔗 Available endpoints:"
echo "  - Consensus RPC: http://localhost:26657"
echo "  - Bridge RPC: http://localhost:26658" 
echo "  - Bridge REST: http://localhost:26659"
echo "  - gRPC: localhost:9090"

# Keep the container running
wait
