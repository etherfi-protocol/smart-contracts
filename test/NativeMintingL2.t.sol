// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";

import "forge-std/console2.sol";
import "forge-std/console.sol";

import "@openzeppelin-upgradeable/contracts/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/IAccessControlUpgradeable.sol";

import {IOFT} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {IMintableERC20} from "../lib/Etherfi-SyncPools/contracts/interfaces/IMintableERC20.sol";
import {IAggregatorV3} from "../lib/Etherfi-SyncPools/contracts/etherfi/interfaces/IAggregatorV3.sol";
import {IL2ExchangeRateProvider} from "../lib/Etherfi-SyncPools/contracts/interfaces/IL2ExchangeRateProvider.sol";


import "../src/BucketRateLimiter.sol";

import "./NativeMintingConfigs.t.sol";

interface IEtherFiOFT is IOFT, IMintableERC20, IAccessControlUpgradeable {
    function MINTER_ROLE() external view returns (bytes32);
    // function hasRole(bytes32 role, address account) external view returns (bool);
    // function grantRole(bytes32 role, address account) external;
    function owner() external view returns (address);

    function isPeer(uint32 eid, bytes32 peer) external view returns (bool);
}

interface IEtherFiOwnable {
    function owner() external view returns (address);
}

interface IL2SyncPool {
    struct Token {
        uint256 unsyncedAmountIn;
        uint256 unsyncedAmountOut;
        uint256 minSyncAmount;
        address l1Address;
    }

    function owner() external view returns (address);
    function getL2ExchangeRateProvider() external view returns (address);
    function getRateLimiter() external view returns (address);
    function getTokenOut() external view returns (address);
    function getDstEid() external view returns (uint32);
    function getTokenData(address tokenIn) external view returns (Token memory);
    function peers(uint32 eid) external view returns (bytes32);
    
    function deposit(address tokenIn, uint256 amountIn, uint256 minAmountOut) external payable returns (uint256);
    // function sync(address tokenIn, bytes calldata extraOptions, MessagingFee calldata fee) external payable returns (uint256, uint256);
    
    function setL2ExchangeRateProvider(address l2ExchangeRateProvider) external;
    function setRateLimiter(address rateLimiter) external;
    function setTokenOut(address tokenOut) external;
    function setDstEid(uint32 dstEid) external;
    function setMinSyncAmount(address tokenIn, uint256 minSyncAmount) external;
}


contract NativeMintingL2 is TestSetup, NativeMintingConfigs {
    address deployer;
    
    ConfigPerL2 targetL2; 

    IL2SyncPool l2SyncPool;
    IEtherFiOFT l2Oft;
    IL2ExchangeRateProvider l2exchangeRateProvider;
    IAggregatorV3 l2priceOracle;
    BucketRateLimiter l2SyncPoolRateLimiter;

    bool fix;

    function setUp() public {
        // _setUp(BLAST.rpc_url);
    }

    function _setUp(string memory rpc_url) public {
        // initializeRealisticFork(MAINNET_FORK);
        // vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        uint256 pk = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(pk);

        vm.createSelectFork(rpc_url);

        if (block.chainid == 59144) targetL2 = LINEA;
        else if (block.chainid == 81457) targetL2 = BLAST;
        else if (block.chainid == 34443) targetL2 = MODE;
        else revert("Unsupported chain id");

        _init();

        l2Oft = IEtherFiOFT(targetL2.l2Oft);
        l2SyncPool = IL2SyncPool(targetL2.l2SyncPool);
        l2exchangeRateProvider = IL2ExchangeRateProvider(targetL2.l2ExchagneRateProvider);
        l2priceOracle = IAggregatorV3(l2exchangeRateProvider.getRateParameters(ETH_ADDRESS).rateOracle);
        l2SyncPoolRateLimiter = BucketRateLimiter(l2SyncPool.getRateLimiter());

    }

    function test_verify_BLAST() public {
        _setUp(BLAST.rpc_url);
        _go();
    }

    function test_verify_LINEA() public {
        _setUp(LINEA.rpc_url);
        _go();
    }

    function test_verify_MODE() public {
        _setUp(MODE.rpc_url);
        _go();
    }

    function _go() internal {
        vm.startPrank(deployer);
        _verify_L2_configurations();
        _verify_oft_wired();
        _verify_syncpool_wired();
        vm.stopPrank();
    }

    function _verify_oft_wired() internal {
        console.log(targetL2.name, "L2Oft.IsPeer of");
        bool isPeer = l2Oft.isPeer(l1Eid, _toBytes32(l1OftAdapter));
        console.log("- ETH", isPeer);

        for (uint256 i = 0; i < l2s.length; i++) {
            if (targetL2.l2Eid == l2s[i].l2Eid) continue; 
            bool isPeer = l2Oft.isPeer(l2s[i].l2Eid, _toBytes32(l2s[i].l2Oft));
            console.log("- ", l2s[i].name, isPeer);

            if (!isPeer) {
                console.log("eid, dest");
                console.log(l2s[i].l2Eid);
                console.logBytes32(_toBytes32(l2s[i].l2Oft));
            }
        }
    }

    function _verify_syncpool_wired() internal {
        console.log(targetL2.name, "L2SyncPool.IsPeer of");
        bool isPeer = (l2SyncPool.peers(l1Eid) == _toBytes32(l1SyncPoolAddress));
        console.log("- ETH", isPeer);

        if (!isPeer) {
            console.log("call setPeer(eid, dest)");
            console.log(l1Eid);
            console.logBytes32(_toBytes32(l1SyncPoolAddress));
        }
    }

    function _verify_L2_configurations() internal {
        IL2SyncPool.Token memory tokenData = l2SyncPool.getTokenData(ETH_ADDRESS);

        console.log("l2Oft.hasRole(l2Oft.MINTER_ROLE(), targetL2.l2SyncPool): ", l2Oft.hasRole(l2Oft.MINTER_ROLE(), targetL2.l2SyncPool));
        console.log("l2SyncPool.getDstEid() == l1Eid: ", l2SyncPool.getDstEid() == l1Eid);
        console.log("l2SyncPool.getTokenOut() == targetL2.l2Oft: ", l2SyncPool.getTokenOut() == targetL2.l2Oft);
        console.log("l2SyncPool.getL2ExchangeRateProvider() == targetL2.l2ExchagneRateProvider: ", l2SyncPool.getL2ExchangeRateProvider() == targetL2.l2ExchagneRateProvider);
        console.log("l2SyncPool.getRateLimiter() == targetL2.l2SyncPoolRateLimiter: ", l2SyncPool.getRateLimiter() == targetL2.l2SyncPoolRateLimiter);
        console.log("l2SyncPool.tokens[ETH].l1Address == ETH", tokenData.l1Address == ETH_ADDRESS);
        

        // (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = l2priceOracle.latestRoundData();
        console.log("l2exchangeRateProvider.getRateParameters(ETH_ADDRESS).rateOracle == targetL2.l2PriceOracle: ", l2exchangeRateProvider.getRateParameters(ETH_ADDRESS).rateOracle == targetL2.l2PriceOracle);
        // console.log("l2priceOracle.latestRoundData().answer: ", uint256(answer));
        // console.log("l2exchangeRateProvider.getConversionAmountUnsafe(ETH_ADDRESS, 10000): ", l2exchangeRateProvider.getConversionAmountUnsafe(ETH_ADDRESS, 10000));

        // Ownership checks
        console.log("l2Oft.owner(): ", l2Oft.owner());
        console.log("l2SyncPool.owner(): ", l2SyncPool.owner());
        console.log("l2SyncPoolRateLimiter.owner(): ", l2SyncPoolRateLimiter.owner());
        console.log("l2exchangeRateProvider.owner(): ", l2exchangeRateProvider.owner());
        
        console.log("l2Oft_ProxyAdmin.owner(): ", IEtherFiOwnable(targetL2.l2Oft_ProxyAdmin).owner());
        console.log("l2SyncPool_ProxyAdmin.owner(): ", IEtherFiOwnable(targetL2.l2SyncPool_ProxyAdmin).owner());
        console.log("l2ExchagneRateProvider_ProxyAdmin.owner(): ", IEtherFiOwnable(targetL2.l2ExchagneRateProvider_ProxyAdmin).owner());

        if (!l2Oft.hasRole(l2Oft.MINTER_ROLE(), targetL2.l2SyncPool)) {
            l2Oft.grantRole(l2Oft.MINTER_ROLE(), targetL2.l2SyncPool);
        }

        // require(l2Oft.hasRole(l2Oft.MINTER_ROLE(), targetL2.l2SyncPool), "MINTER_ROLE not set");
        // require(l2SyncPool.getDstEid() == l1Eid, "DstEid not set");
        // require(l2SyncPool.getTokenOut() == targetL2.l2Oft, "TokenOut not set");
        // require(l2SyncPool.getL2ExchangeRateProvider() == targetL2.l2ExchagneRateProvider, "ExchangeRateProvider not set");
        // require(l2SyncPool.getRateLimiter() == targetL2.l2SyncPoolRateLimiter, "RateLimiter not set");
        // require(tokenData.l1Address == ETH_ADDRESS, "Token data not set");
    }

    // These are function calls on L2 required to go live on L2
    function _release_L2() internal {
        vm.startPrank(l2Oft.owner());
        
        // Grant the MINTER ROLE
        l2Oft.grantRole(l2Oft.MINTER_ROLE(), targetL2.l2SyncPool);

        // Configure the rate limits
        l2exchangeRateProvider.setRateParameters(ETH_ADDRESS, targetL2.l2PriceOracle, 0, 24 hours);
        l2SyncPoolRateLimiter.setCapacity(0.0001 ether);
        l2SyncPoolRateLimiter.setRefillRatePerSecond(0.0001 ether);
        
        // TODO: Transfer the ownership
        // ...
        // address l2Oft;
        // address l2SyncPool;
        // address l2SyncPoolRateLimiter;
        // address l2ExchagneRateProvider;
        // address l2PriceOracle;
        vm.stopPrank();
    }

    function test_l2Oft_mint_BLAST() public {
        _setUp(BLAST.rpc_url);
        _release_L2();

        vm.deal(alice, 100 ether);

        vm.prank(alice);
        vm.expectRevert("BucketRateLimiter: rate limit exceeded");
        l2SyncPool.deposit{value: 100}(ETH_ADDRESS, 100, 50);

        vm.warp(block.timestamp + 1);

        vm.prank(alice);
        uint256 mintAmount = l2SyncPool.deposit{value: 100}(ETH_ADDRESS, 100, 50);        

        (uint64 capacity, uint64 remaining,,) = l2SyncPoolRateLimiter.limit();
        assertEq(l2Oft.balanceOf(alice), mintAmount);
        assertEq(address(l2SyncPool).balance, 100);
        assertEq(remaining, (0.0001 ether / 1e12) - 1); // 100 is tiny.. counted as '1' (= 1e12 wei)
    }


}