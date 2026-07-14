// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

interface IWithdrawNFT {
    function lastFinalizedRequestId() external view returns (uint32);
    function claimWithdraw(uint256 tokenId) external;
    function ethAmountLockedForWithdrawal() external view returns (uint128);
}

interface ILP {
    function totalValueInLp() external view returns (uint128);
}

/// @notice Claims a batch of withdraw requests, isolating failures: one recipient that
/// rejects ETH (or an already-claimed id) cannot revert the rest of the batch. Claims are
/// permissionless and payouts always go to each request's NFT owner, so this helper holds
/// no funds and needs no access control.
contract ClaimFlusher {
    function flush(address nft, uint256[] calldata ids) external returns (uint256 claimed) {
        for (uint256 i; i < ids.length; ++i) {
            (bool ok,) = nft.call(abi.encodeWithSelector(IWithdrawNFT.claimWithdraw.selector, ids[i]));
            if (ok) claimed++;
        }
    }
}

/// @notice Flushes all finalized-but-unclaimed withdraw requests listed in claim_batches.json
/// (produced by fetch_unclaimed_finalized_requests.py in this directory).
///
/// Usage:
///   forge script script/operations/withdrawals/ExecuteClaims.s.sol:ExecuteClaims \
///     --rpc-url $MAINNET_RPC_URL --account <foundry-keystore-name> --sender <its-address> \
///     --broadcast -vv
///
/// Omit --broadcast for a dry run (full simulation with the summary logs, nothing sent).
/// Optional env: CHUNK_SIZE (ids per flush tx, default 100),
///               CLAIM_BATCHES (path to json, default script/operations/withdrawals/claim_batches.json).
contract ExecuteClaims is Script {
    address constant WITHDRAW_REQUEST_NFT = 0x7d5706f6ef3F89B3951E23e557CDFBC3239D4E2c;
    address constant LIQUIDITY_POOL = 0x308861A430be4cce5502d0A12724771Fc6DaF216;

    function run() external {
        string memory path =
            vm.envOr("CLAIM_BATCHES", string.concat(vm.projectRoot(), "/script/operations/withdrawals/claim_batches.json"));
        string memory json = vm.readFile(path);

        // The claimed set moves with mainnet state: refuse stale inputs.
        uint256 jsonLastFinalized = vm.parseJsonUint(json, ".lastFinalizedRequestId");
        uint256 chainLastFinalized = IWithdrawNFT(WITHDRAW_REQUEST_NFT).lastFinalizedRequestId();
        require(
            jsonLastFinalized == chainLastFinalized,
            "stale claim_batches.json - re-run fetch_unclaimed_finalized_requests.py"
        );
        // lastFinalizedRequestId alone cannot detect every drift: the claimable set also
        // changes when a request is claimed, invalidated, or validateRequest'd after the
        // fetch. The contract's escrow accounting is exactly the wei sum over valid,
        // finalized, unclaimed requests, so requiring it to equal the fetch-time sum
        // catches any such change.
        uint256 jsonTotalClaimableWei = vm.parseJsonUint(json, ".totalClaimableWei");
        uint256 escrowAccounting = IWithdrawNFT(WITHDRAW_REQUEST_NFT).ethAmountLockedForWithdrawal();
        require(
            jsonTotalClaimableWei == escrowAccounting,
            "claimable set drifted since fetch - re-run fetch_unclaimed_finalized_requests.py"
        );

        uint256[][] memory eoaChunks =
            abi.decode(vm.parseJson(json, ".batchClaimWithdraw_chunks_eoa_owners"), (uint256[][]));
        uint256[] memory contractIds =
            abi.decode(vm.parseJson(json, ".claim_individually_contract_owners"), (uint256[]));

        uint256 total = contractIds.length;
        for (uint256 i; i < eoaChunks.length; ++i) total += eoaChunks[i].length;
        uint256[] memory ids = new uint256[](total);
        uint256 n;
        for (uint256 i; i < eoaChunks.length; ++i) {
            for (uint256 j; j < eoaChunks[i].length; ++j) ids[n++] = eoaChunks[i][j];
        }
        for (uint256 i; i < contractIds.length; ++i) ids[n++] = contractIds[i];

        console2.log("claimable ids:", total);
        console2.log("escrow before (ETH):", WITHDRAW_REQUEST_NFT.balance / 1e18);

        uint256 chunkSize = vm.envOr("CHUNK_SIZE", uint256(100));
        uint256 claimed;

        vm.startBroadcast();
        ClaimFlusher flusher = new ClaimFlusher();
        for (uint256 start; start < total; start += chunkSize) {
            uint256 len = total - start < chunkSize ? total - start : chunkSize;
            uint256[] memory chunk = new uint256[](len);
            for (uint256 i; i < len; ++i) chunk[i] = ids[start + i];
            claimed += flusher.flush(WITHDRAW_REQUEST_NFT, chunk);
        }
        vm.stopBroadcast();

        uint256 lpBalance = LIQUIDITY_POOL.balance;
        uint256 tvlInLp = ILP(LIQUIDITY_POOL).totalValueInLp();
        console2.log("claimed:", claimed, "skipped:", total - claimed);
        console2.log("escrow after (wei):", WITHDRAW_REQUEST_NFT.balance);
        console2.log("escrow accounting (wei):", IWithdrawNFT(WITHDRAW_REQUEST_NFT).ethAmountLockedForWithdrawal());
        console2.log("LP balance == totalValueInLp:", lpBalance == tvlInLp);
    }
}
