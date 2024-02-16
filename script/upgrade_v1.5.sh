#!/bin/bash

set -e  # Exit immediately if any command fails

network=$1

targets=(
  upgrade-${network}-staking-manager
  upgrade-${network}-auction-manager
  upgrade-${network}-etherfi-node
  upgrade-${network}-bnft
  upgrade-${network}-tnft
  upgrade-${network}-eeth
  upgrade-${network}-etherfi_nodes_manager
  upgrade-${network}-liquidity-pool
  upgrade-${network}-membership-manager
  upgrade-${network}-membership-nft
  upgrade-${network}-weeth
)

for target in "${targets[@]}"; do
  make "$target"
done

