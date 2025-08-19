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

wait
