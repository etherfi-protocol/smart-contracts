// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";

import "forge-std/console2.sol";
import "forge-std/console.sol";

import "@openzeppelin-upgradeable/contracts/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/IAccessControlUpgradeable.sol";

import {IOFT} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {IRateLimiter} from "../lib/Etherfi-SyncPools/contracts/interfaces/IRateLimiter.sol";
import {IMintableERC20} from "../lib/Etherfi-SyncPools/contracts/interfaces/IMintableERC20.sol";
import {IAggregatorV3} from "../lib/Etherfi-SyncPools/contracts/etherfi/interfaces/IAggregatorV3.sol";
import {IL2ExchangeRateProvider} from "../lib/Etherfi-SyncPools/contracts/interfaces/IL2ExchangeRateProvider.sol";


import "../src/BucketRateLimiter.sol";
import "./NativeMintingConfigs.t.sol";

interface IEtherFiOFT is IOFT, IRateLimiter, IMintableERC20, IAccessControlUpgradeable {
    function MINTER_ROLE() external view returns (bytes32);
    // function hasRole(bytes32 role, address account) external view returns (bool);
    // function grantRole(bytes32 role, address account) external;
    function owner() external view returns (address);
}


interface IL2SyncPool {
    struct Token {
        uint256 unsyncedAmountIn;
        uint256 unsyncedAmountOut;
        uint256 minSyncAmount;
        address l1Address;
    }

    function getL2ExchangeRateProvider() external view returns (address);
    function getRateLimiter() external view returns (address);
    function getTokenOut() external view returns (address);
    function getDstEid() external view returns (uint32);
    function getTokenData(address tokenIn) external view returns (Token memory);
    
    function deposit(address tokenIn, uint256 amountIn, uint256 minAmountOut) external payable returns (uint256);
    // function sync(address tokenIn, bytes calldata extraOptions, MessagingFee calldata fee) external payable returns (uint256, uint256);
    
    function setL2ExchangeRateProvider(address l2ExchangeRateProvider) external;
    function setRateLimiter(address rateLimiter) external;
    function setTokenOut(address tokenOut) external;
    function setDstEid(uint32 dstEid) external;
    function setMinSyncAmount(address tokenIn, uint256 minSyncAmount) external;
}


contract NativeMintingL2 is TestSetup, NativeMintingConfigs {
    ConfigPerL2 targetL2; 

    IL2SyncPool l2SyncPool;
    IEtherFiOFT oft;
    IL2ExchangeRateProvider exchangeRateProvider;
    IAggregatorV3 priceOracle;
    BucketRateLimiter l2SyncPoolRateLimiter;

    function setUp() public {
        _setUp(BLAST.rpc_url);
    }

    function _setUp(string memory rpc_url) public {
        // initializeRealisticFork(MAINNET_FORK);
        // vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        vm.createSelectFork(rpc_url);

        if (block.chainid == 59144) targetL2 = LINEA;
        else if (block.chainid == 81457) targetL2 = BLAST;
        else if (block.chainid == 34443) targetL2 = MODE;
        else revert("Unsupported chain id");

        oft = IEtherFiOFT(targetL2.l2Oft);
        l2SyncPool = IL2SyncPool(targetL2.l2SyncPool);
        exchangeRateProvider = IL2ExchangeRateProvider(targetL2.l2ExchagneRateProvider);
        priceOracle = IAggregatorV3(exchangeRateProvider.getRateParameters(ETH_ADDRESS).rateOracle);
        l2SyncPoolRateLimiter = BucketRateLimiter(l2SyncPool.getRateLimiter());
    }

    function test_verify_BLAST() public {
        _setUp(BLAST.rpc_url);
        _verify_L2_configuration();
    }

    function test_verify_LINEA() public {
        _setUp(LINEA.rpc_url);
        _verify_L2_configuration();
    }

    function test_verify_MODE() public {
        _setUp(MODE.rpc_url);
        _verify_L2_configuration();
    }

    function _verify_L2_configuration() internal {
        IL2SyncPool.Token memory tokenData = l2SyncPool.getTokenData(targetL2.l1dummyToken);
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = priceOracle.latestRoundData();

        console.log("oft.hasRole(oft.MINTER_ROLE(), targetL2.l2SyncPool): ", oft.hasRole(oft.MINTER_ROLE(), targetL2.l2SyncPool));
        console.log("l2SyncPool.getDstEid() == l1Eid: ", l2SyncPool.getDstEid() == l1Eid);
        console.log("l2SyncPool.getTokenOut() == targetL2.l2Oft: ", l2SyncPool.getTokenOut() == targetL2.l2Oft);
        console.log("l2SyncPool.getL2ExchangeRateProvider() == targetL2.l2ExchagneRateProvider: ", l2SyncPool.getL2ExchangeRateProvider() == targetL2.l2ExchagneRateProvider);
        console.log("l2SyncPool.getRateLimiter() == targetL2.l2SyncPoolRateLimiter: ", l2SyncPool.getRateLimiter() == targetL2.l2SyncPoolRateLimiter);
        console.log("l2SyncPool.tokens[ETH].l1Address == ETH", tokenData.l1Address == ETH_ADDRESS);
        console.log("priceOracle.latestRoundData().answer: ", uint256(answer));
        console.log("exchangeRateProvider.getConversionAmountUnsafe(ETH_ADDRESS, 10000): ", exchangeRateProvider.getConversionAmountUnsafe(ETH_ADDRESS, 10000));

        // require(oft.hasRole(oft.MINTER_ROLE(), targetL2.l2SyncPool), "MINTER_ROLE not set");
        // require(l2SyncPool.getDstEid() == l1Eid, "DstEid not set");
        // require(l2SyncPool.getTokenOut() == targetL2.l2Oft, "TokenOut not set");
        // require(l2SyncPool.getL2ExchangeRateProvider() == targetL2.l2ExchagneRateProvider, "ExchangeRateProvider not set");
        // require(l2SyncPool.getRateLimiter() == targetL2.l2SyncPoolRateLimiter, "RateLimiter not set");
        // require(tokenData.l1Address == ETH_ADDRESS, "Token data not set");
    }

    function _release_L2() internal {
        vm.startPrank(oft.owner());
        oft.grantRole(oft.MINTER_ROLE(), targetL2.l2SyncPool);
        exchangeRateProvider.setRateParameters(ETH_ADDRESS, targetL2.l2PriceOracle, 0, 24 hours);
        l2SyncPool.
        vm.stopPrank();
    }

    function test_oft_mint_BLAST() public {
        _setUp(BLAST.rpc_url);
        _release_L2();

        vm.deal(alice, 100 ether);

        vm.prank(alice);
        l2SyncPool.deposit{value: 10}(ETH_ADDRESS, 10, 5);
        
        console.log("totalSupply: %s", oft.totalSupply());
    }


}