#!/usr/bin/env bash
set -e

# Configuration
CHAINID="${CHAINID:-private}"
VALIDATOR_HOST="${VALIDATOR_HOST:-celestia-validator}"
VALIDATOR_PORT="${VALIDATOR_PORT:-26657}"
GRPC_PORT="${GRPC_PORT:-9090}"

# Paths
NODE_PATH="/home/celestia/bridge"

echo "🌉 Starting Celestia bridge initialization..."
echo "Chain ID: $CHAINID"
echo "Validator Host: $VALIDATOR_HOST"
echo "Bridge Store Path: $NODE_PATH"

# Clean up any existing bridge data
if [ -d "$NODE_PATH" ]; then
  echo "🧹 Cleaning up existing bridge data..."
  rm -rf "$NODE_PATH"
fi

# Wait for the validator to be ready
echo "⏳ Waiting for validator to be ready..."
MAX_ATTEMPTS=60
ATTEMPT=0
while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
  if curl -s http://${VALIDATOR_HOST}:${VALIDATOR_PORT}/status > /dev/null 2>&1; then
    echo "✅ Validator RPC is ready!"
    break
  fi
  echo "Waiting for validator RPC... (attempt $((ATTEMPT+1))/$MAX_ATTEMPTS)"
  sleep 2
  ATTEMPT=$((ATTEMPT+1))
done

if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
  echo "❌ Validator RPC failed to start in time"
  exit 1
fi

# Wait longer for gRPC to be ready since the validator needs time to start all services
echo "⏳ Waiting extra time for validator services to fully start..."
sleep 20

# Debug: Check what's listening on the validator
echo "🔍 Debugging validator connectivity..."
echo "Validator Host: ${VALIDATOR_HOST} resolves to:"
nslookup ${VALIDATOR_HOST} || echo "nslookup failed"
ping -c 2 ${VALIDATOR_HOST} || echo "ping failed"

echo "Testing connectivity to various ports..."
for port in 26657 9090 1317; do
    echo "Testing port $port..."
    if nc -z ${VALIDATOR_HOST} $port 2>/dev/null; then
        echo "✅ Port $port is reachable"
    else
        echo "❌ Port $port is NOT reachable"
    fi
done

# Try to get more details about the gRPC endpoint
echo "Attempting to query gRPC health..."
grpcurl -plaintext ${VALIDATOR_HOST}:${GRPC_PORT} list 2>&1 || echo "grpcurl failed (might not be installed)"

# Wait for the validator to stabilize and produce blocks
echo "⏳ Waiting for validator to stabilize and produce blocks..."
sleep 15

# Test that we can actually fetch a block and get the trusted hash
echo "🔍 Testing validator connectivity and fetching trusted hash..."
MAX_BLOCK_ATTEMPTS=15
BLOCK_ATTEMPT=0
TRUSTED_HASH=""

while [ $BLOCK_ATTEMPT -lt $MAX_BLOCK_ATTEMPTS ]; do
  BLOCK_RESPONSE=$(curl -s http://${VALIDATOR_HOST}:${VALIDATOR_PORT}/block?height=1)
  if echo "$BLOCK_RESPONSE" | grep -q '"block"' && echo "$BLOCK_RESPONSE" | grep -q '"block_id"'; then
    # Extract the trusted hash from the genesis block
    TRUSTED_HASH=$(echo "$BLOCK_RESPONSE" | jq -r '.result.block_id.hash')
    if [ -n "$TRUSTED_HASH" ] && [ "$TRUSTED_HASH" != "null" ]; then
      echo "✅ Retrieved trusted hash: $TRUSTED_HASH"
      
      # Also check that we can get the latest height
      LATEST_HEIGHT=$(curl -s http://${VALIDATOR_HOST}:${VALIDATOR_PORT}/status | jq -r '.result.sync_info.latest_block_height // "0"')
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
  exit 1
fi

# Initialize the bridge with the private network (no --core.port here, like original)
echo "🔧 Initializing bridge store..."
celestia bridge init \
  --p2p.network private \
  --core.ip "$VALIDATOR_HOST" \
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
  exit 1
fi

# Get the auth token for the bridge
echo "🔑 Generating bridge auth token..."
BRIDGE_AUTH_TOKEN=$(celestia bridge auth admin --p2p.network private --node.store "$NODE_PATH")
echo "🔑 Bridge auth token generated"

# Start the bridge node with retry logic (matching original script)
echo "🌉 Starting Celestia bridge node..."
START_ATTEMPTS=3
BRIDGE_STARTED=false

for i in $(seq 1 $START_ATTEMPTS); do
  echo "Starting bridge (attempt $i/$START_ATTEMPTS)..."
  
  celestia bridge start \
    --p2p.network private \
    --core.ip "$VALIDATOR_HOST" \
    --core.port "$GRPC_PORT" \
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
  echo "✅ Bridge started successfully!"
  echo "✨ Celestia bridge is running!"
  echo "  - Bridge RPC: http://localhost:26658"
  echo "  - Bridge Gateway: http://localhost:26659"
  echo "  - Bridge Auth Token: $BRIDGE_AUTH_TOKEN"
  echo ""
  echo "📝 To interact with the bridge:"
  echo "  curl -X POST -H \"Authorization: Bearer $BRIDGE_AUTH_TOKEN\" \\"
  echo "       -H \"Content-Type: application/json\" \\"
  echo "       -d '{\"id\":1,\"jsonrpc\":\"2.0\",\"method\":\"header.LocalHead\",\"params\":[]}' \\"
  echo "       http://localhost:26658"
  
  # Wait for the bridge process
  wait $BRIDGE_PID
else
  echo "⚠️ Failed to start bridge after $START_ATTEMPTS attempts"
  exit 1
fi
