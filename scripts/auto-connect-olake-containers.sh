#!/bin/bash
# Script to automatically connect OLake dynamically created containers to the network

NETWORK_NAME="ch-demo_clickhouse_lakehouse-net"

echo "Watching for OLake test containers and connecting them to network $NETWORK_NAME..."
echo "Press Ctrl+C to stop"

while true; do
  # Find containers that match OLake test patterns but aren't on our network
  CONTAINERS=$(docker ps --filter "name=test-connection" --filter "name=fetch-spec" --format "{{.Names}}" 2>/dev/null)
  
  for container in $CONTAINERS; do
    # Check if container is already on our network
    if ! docker inspect "$container" --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}} {{end}}' 2>/dev/null | grep -q "$NETWORK_NAME"; then
      echo "[$(date +'%Y-%m-%d %H:%M:%S')] Connecting $container to $NETWORK_NAME..."
      docker network connect "$NETWORK_NAME" "$container" 2>/dev/null && echo "  ✓ Connected $container" || echo "  ✗ Failed to connect $container"
    fi
  done
  
  sleep 2
done

