// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";

import "forge-std/console2.sol";
import "forge-std/console.sol";
import "forge-std/Test.sol";

import "@openzeppelin-upgradeable/contracts/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/IAccessControlUpgradeable.sol";

import {IOFT} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {IMintableERC20} from "../lib/Etherfi-SyncPools/contracts/interfaces/IMintableERC20.sol";
import {IAggregatorV3} from "../lib/Etherfi-SyncPools/contracts/etherfi/interfaces/IAggregatorV3.sol";
import {IL2ExchangeRateProvider} from "../lib/Etherfi-SyncPools/contracts/interfaces/IL2ExchangeRateProvider.sol";
import {IOAppCore} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppCore.sol";
import {EndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/EndpointV2.sol";

import "../src/BucketRateLimiter.sol";

import "./NativeMintingConfigs.t.sol";

interface IEtherFiOFT is IOFT, IMintableERC20, IAccessControlUpgradeable, IOAppCore {
    /**
     * @notice Rate Limit Configuration struct.
     * @param dstEid The destination endpoint id.
     * @param limit This represents the maximum allowed amount within a given window.
     * @param window Defines the duration of the rate limiting window.
     */
    struct RateLimitConfig {
        uint32 dstEid;
        uint256 limit;
        uint256 window;
    }

    function MINTER_ROLE() external view returns (bytes32);
    // function hasRole(bytes32 role, address account) external view returns (bool);
    // function grantRole(bytes32 role, address account) external;
    function owner() external view returns (address);
    function delegate() external view returns (address);

    function isPeer(uint32 eid, bytes32 peer) external view returns (bool);

    function setRateLimits(RateLimitConfig[] calldata _rateLimitConfigs) external;

    function getAmountCanBeSent(uint32 _dstEid) external view returns (uint256 currentAmountInFlight, uint256 amountCanBeSent);
    function rateLimits(uint32 _dstEid) external view returns (uint256, uint256, uint256, uint256);
}

interface IEtherFiOwnable {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

interface IL2SyncPool is IOAppOptionsType3, IOAppCore {
    struct MessagingFee {
        uint256 nativeFee;
        uint256 lzTokenFee;
    }

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
    function sync(address tokenIn, bytes calldata extraOptions, MessagingFee calldata fee) external payable returns (uint256, uint256);
    
    function setL2ExchangeRateProvider(address l2ExchangeRateProvider) external;
    function setRateLimiter(address rateLimiter) external;
    function setTokenOut(address tokenOut) external;
    function setDstEid(uint32 dstEid) external;
    function setMinSyncAmount(address tokenIn, uint256 minSyncAmount) external;

}


contract NativeMintingL2 is Test, NativeMintingConfigs {
    uint256 pk;
    address deployer;
    
    ConfigPerL2 targetL2; 

    EndpointV2 l2Endpoint;

    IL2SyncPool l2SyncPool;
    IEtherFiOFT l2Oft;
    IL2ExchangeRateProvider l2exchangeRateProvider;
    BucketRateLimiter l2SyncPoolRateLimiter;

    bool fix;

    function setUp() public {
        pk = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(pk);
    }

    function _setUp() public {
        if (block.chainid == 59144) targetL2 = LINEA;
        else if (block.chainid == 81457) targetL2 = BLAST;
        else if (block.chainid == 34443) targetL2 = MODE;
        else revert("Unsupported chain id");

        _init();

        l2Endpoint = EndpointV2(targetL2.l2Endpoint);
        l2Oft = IEtherFiOFT(targetL2.l2Oft);
        l2SyncPool = IL2SyncPool(targetL2.l2SyncPool);
        l2exchangeRateProvider = IL2ExchangeRateProvider(targetL2.l2ExchagneRateProvider);
        l2SyncPoolRateLimiter = BucketRateLimiter(l2SyncPool.getRateLimiter());
    }

    function test_verify_BLAST() public {
        vm.createSelectFork(BLAST.rpc_url);
        _setUp();
        _go();
    }

    function test_verify_LINEA() public {
        vm.createSelectFork(LINEA.rpc_url);
        _setUp();
        _go();
    }

    function test_verify_MODE() public {
        vm.createSelectFork(MODE.rpc_url);
        _setUp();
        _go();
    }

    function _go() internal {
        _verify_L2_configurations();
        _verify_oft_wired();
        _verify_syncpool_wired();
        _setup_DVN();

        // _transfer_ownership();
    }

    function _setup_DVN() internal {
        // vm.startPrank(l2Oft.owner());
        // l2Oft.setDelegate(l2Oft.owner());
        // l2SyncPool.setDelegate(l2Oft.owner());

        vm.startBroadcast(pk);
        _setUpOApp(targetL2.l2Oft, targetL2.l2Endpoint, targetL2.send302, targetL2.lzDvn, l1Eid);
        _setUpOApp(targetL2.l2SyncPool, targetL2.l2Endpoint, targetL2.send302, targetL2.lzDvn, l1Eid);
        vm.stopBroadcast();

        // vm.stopPrank();
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

        // use 'require' instead of log to actually force it
        require(l2Oft.isPeer(l1Eid, _toBytes32(l1OftAdapter)), "OFT not wired");
        for (uint256 i = 0; i < l2s.length; i++) {
            if (targetL2.l2Eid == l2s[i].l2Eid) continue; 
            require(l2Oft.isPeer(l2s[i].l2Eid, _toBytes32(l2s[i].l2Oft)), "OFT not wired");
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
        require((l2SyncPool.peers(l1Eid) == _toBytes32(l1SyncPoolAddress)), "SyncPool not wired");
    }

    function _verify_L2_configurations() internal {
        IL2SyncPool.Token memory tokenData = l2SyncPool.getTokenData(ETH_ADDRESS);
        (uint256 amountInFlight, uint256 lastUpdated, uint256 limit, uint256 window) = l2Oft.rateLimits(l2SyncPool.getDstEid());
        (uint64 capacity, uint64 remaining, uint64 lastRefill, uint64 refillRate) = l2SyncPoolRateLimiter.limit();

        console.log("l2Oft.rateLimits(toL1).limit: ", limit);
        console.log("l2Oft.rateLimits(toL1).window: ", window);
        console.log("l2SyncPoolRateLimiter.limit().capacity: ", capacity);

        console.log("l2Oft.hasRole(l2Oft.MINTER_ROLE(), targetL2.l2SyncPool): ", l2Oft.hasRole(l2Oft.MINTER_ROLE(), targetL2.l2SyncPool));
        console.log("l2SyncPool.getDstEid() == l1Eid: ", l2SyncPool.getDstEid() == l1Eid);
        console.log("l2SyncPool.getTokenOut() == targetL2.l2Oft: ", l2SyncPool.getTokenOut() == targetL2.l2Oft);
        console.log("l2SyncPool.getL2ExchangeRateProvider() == targetL2.l2ExchagneRateProvider: ", l2SyncPool.getL2ExchangeRateProvider() == targetL2.l2ExchagneRateProvider);
        console.log("l2SyncPool.getRateLimiter() == targetL2.l2SyncPoolRateLimiter: ", l2SyncPool.getRateLimiter() == targetL2.l2SyncPoolRateLimiter);
        console.log("l2SyncPool.tokens[ETH].l1Address == ETH", tokenData.l1Address == ETH_ADDRESS);
        console.log("l2SyncPool.tokens[ETH].minSyncAmount == 1000 ETH ", tokenData.minSyncAmount == 1000 ether);
        
        console.log("l2exchangeRateProvider.getRateParameters(ETH_ADDRESS).rateOracle == targetL2.l2PriceOracle: ", l2exchangeRateProvider.getRateParameters(ETH_ADDRESS).rateOracle == targetL2.l2PriceOracle);
        console.log("l2exchangeRateProvider.getRateParameters(ETH_ADDRESS).depositFee == 1e15: ", l2exchangeRateProvider.getRateParameters(ETH_ADDRESS).depositFee == 1e15);
        console.log("l2exchangeRateProvider.getConversionAmountUnsafe(ETH_ADDRESS, 10000): ", l2exchangeRateProvider.getConversionAmountUnsafe(ETH_ADDRESS, 10000));

        // Ownership checks
        console.log("l2Oft.owner(): ", l2Oft.owner());
        console.log("l2SyncPool.owner(): ", l2SyncPool.owner());
        console.log("l2SyncPoolRateLimiter.owner(): ", l2SyncPoolRateLimiter.owner());
        console.log("l2exchangeRateProvider.owner(): ", IEtherFiOwnable(address(l2exchangeRateProvider)).owner());
        
        console.log("l2Oft_ProxyAdmin.owner(): ", IEtherFiOwnable(targetL2.l2Oft_ProxyAdmin).owner());
        console.log("l2SyncPool_ProxyAdmin.owner(): ", IEtherFiOwnable(targetL2.l2SyncPool_ProxyAdmin).owner());
        console.log("l2ExchagneRateProvider_ProxyAdmin.owner(): ", IEtherFiOwnable(targetL2.l2ExchagneRateProvider_ProxyAdmin).owner());

        console.log("l2Endpoint.delegates(l2Oft): ", l2Endpoint.delegates(address(l2Oft)));
        console.log("l2Endpoint.delegates(l2SyncPool): ", l2Endpoint.delegates(address(l2SyncPool)));

        // vm.startBroadcast(pk);
        vm.startPrank(l2Oft.owner());
        if (!l2Oft.hasRole(l2Oft.MINTER_ROLE(), targetL2.l2SyncPool)) {
            l2Oft.grantRole(l2Oft.MINTER_ROLE(), targetL2.l2SyncPool);
        }
        if (!(tokenData.minSyncAmount == 1000 ether)) {
            l2SyncPool.setMinSyncAmount(ETH_ADDRESS, 1000 ether);
        }
        if (!(l2exchangeRateProvider.getRateParameters(ETH_ADDRESS).depositFee == 1e15)) {
            // deposit fee = 10 bp, fresh period
            l2exchangeRateProvider.setRateParameters(ETH_ADDRESS, targetL2.l2PriceOracle, 1e15, targetL2.l2PriceOracleHeartBeat);
        }
        if (limit != 3000 ether || window != 6 hours) {
            IEtherFiOFT.RateLimitConfig[] memory rateLimits = new IEtherFiOFT.RateLimitConfig[](1);
            rateLimits[0] = IEtherFiOFT.RateLimitConfig({dstEid: l2SyncPool.getDstEid(), limit: 3000 ether, window: 6 hours});
            l2Oft.setRateLimits(rateLimits);
        }
        if (refillRate != 1 ether / 1e12) {
            l2SyncPoolRateLimiter.setRefillRatePerSecond(1 ether);
        }
        vm.stopPrank();
        // vm.stopBroadcast();

        (amountInFlight, lastUpdated, limit, window) = l2Oft.rateLimits(l2SyncPool.getDstEid());
        (capacity, remaining, lastRefill, refillRate) = l2SyncPoolRateLimiter.limit();

        require(limit == 3000 ether && window == 6 hours, "OFT Transfer Rate limit not set");
        require(l2Oft.hasRole(l2Oft.MINTER_ROLE(), targetL2.l2SyncPool), "MINTER_ROLE not set");
        require(l2SyncPool.getDstEid() == l1Eid, "DstEid not set");
        require(l2SyncPool.getTokenOut() == targetL2.l2Oft, "TokenOut not set");
        require(l2SyncPool.getL2ExchangeRateProvider() == targetL2.l2ExchagneRateProvider, "ExchangeRateProvider not set");
        require(l2SyncPool.getRateLimiter() == targetL2.l2SyncPoolRateLimiter, "RateLimiter not set");
        require(tokenData.l1Address == ETH_ADDRESS, "Token data not set");
        require(refillRate == 1 ether / 1e12, "");
    }

    function _transfer_ownership() internal {
        vm.startBroadcast(pk);

        if (l2Endpoint.delegates(address(l2Oft)) != targetL2.l2ContractControllerSafe) l2Oft.setDelegate(targetL2.l2ContractControllerSafe);
        if (l2Endpoint.delegates(address(l2SyncPool)) != targetL2.l2ContractControllerSafe) l2SyncPool.setDelegate(targetL2.l2ContractControllerSafe);

        if (IEtherFiOwnable(address(l2Oft)).owner() != targetL2.l2ContractControllerSafe) IEtherFiOwnable(address(l2Oft)).transferOwnership(targetL2.l2ContractControllerSafe);
        if (IEtherFiOwnable(address(l2SyncPool)).owner() != targetL2.l2ContractControllerSafe) IEtherFiOwnable(address(l2SyncPool)).transferOwnership(targetL2.l2ContractControllerSafe);
        if (IEtherFiOwnable(address(l2SyncPoolRateLimiter)).owner() != targetL2.l2ContractControllerSafe) IEtherFiOwnable(address(l2SyncPoolRateLimiter)).transferOwnership(targetL2.l2ContractControllerSafe);
        if (IEtherFiOwnable(address(l2exchangeRateProvider)).owner() != targetL2.l2ContractControllerSafe) IEtherFiOwnable(address(l2exchangeRateProvider)).transferOwnership(targetL2.l2ContractControllerSafe);

        if (IEtherFiOwnable(targetL2.l2Oft_ProxyAdmin).owner() != targetL2.l2ContractControllerSafe) IEtherFiOwnable(targetL2.l2Oft_ProxyAdmin).transferOwnership(targetL2.l2ContractControllerSafe);
        if (IEtherFiOwnable(targetL2.l2SyncPool_ProxyAdmin).owner() != targetL2.l2ContractControllerSafe) IEtherFiOwnable(targetL2.l2SyncPool_ProxyAdmin).transferOwnership(targetL2.l2ContractControllerSafe);
        if (IEtherFiOwnable(targetL2.l2ExchagneRateProvider_ProxyAdmin).owner() != targetL2.l2ContractControllerSafe) IEtherFiOwnable(targetL2.l2ExchagneRateProvider_ProxyAdmin).transferOwnership(targetL2.l2ContractControllerSafe);

        vm.stopBroadcast();

        require(l2Endpoint.delegates(address(l2Oft)) == targetL2.l2ContractControllerSafe, "OFT Delegate not set");
        require(l2Endpoint.delegates(address(l2SyncPool)) == targetL2.l2ContractControllerSafe, "SyncPool Delegate not set");

        require(IEtherFiOwnable(address(l2Oft)).owner() == targetL2.l2ContractControllerSafe, "OFT ownership not transferred");
        require(IEtherFiOwnable(address(l2SyncPool)).owner() == targetL2.l2ContractControllerSafe, "SyncPool ownership not transferred");
        require(IEtherFiOwnable(address(l2SyncPoolRateLimiter)).owner() == targetL2.l2ContractControllerSafe, "RateLimiter ownership not transferred");
        require(IEtherFiOwnable(address(l2exchangeRateProvider)).owner() == targetL2.l2ContractControllerSafe, "ExchangeRateProvider ownership not transferred");

        require(IEtherFiOwnable(targetL2.l2Oft_ProxyAdmin).owner() == targetL2.l2ContractControllerSafe, "OFT ProxyAdmin ownership not transferred");
        require(IEtherFiOwnable(targetL2.l2SyncPool_ProxyAdmin).owner() == targetL2.l2ContractControllerSafe, "SyncPool ProxyAdmin ownership not transferred");
        require(IEtherFiOwnable(targetL2.l2ExchagneRateProvider_ProxyAdmin).owner() == targetL2.l2ContractControllerSafe, "ExchangeRateProvider ProxyAdmin ownership not transferred");
    }

    // These are function calls on L2 required to go live on L2
    function _release_L2() internal {
        vm.startPrank(l2Oft.owner());

        l2SyncPoolRateLimiter.setCapacity(0.0001 ether);

        vm.stopPrank();
    }

    function test_paused_by_cap_BLAST() public {
        vm.createSelectFork(BLAST.rpc_url);
        _setUp();
        _test_paused_by_cap();
    }

    function test_paused_by_cap_MODE() public {
        vm.createSelectFork(MODE.rpc_url);
        _setUp();
        _test_paused_by_cap();
    }

    function _test_paused_by_cap() internal {
        address alice = vm.addr(1);
        vm.deal(alice, 100 ether);
        
        vm.prank(alice);
        vm.expectRevert("BucketRateLimiter: rate limit exceeded");
        l2SyncPool.deposit{value: 100}(ETH_ADDRESS, 100, 50);
        
        _release_L2();        
        vm.warp(block.timestamp + 1);

        vm.prank(alice);
        uint256 mintAmount = l2SyncPool.deposit{value: 100}(ETH_ADDRESS, 100, 50);        

        (uint64 capacity, uint64 remaining,,) = l2SyncPoolRateLimiter.limit();
        assertEq(l2Oft.balanceOf(alice), mintAmount);
        assertEq(address(l2SyncPool).balance, 100);
        assertEq(remaining, (0.0001 ether / 1e12) - 1); // 100 is tiny.. counted as '1' (= 1e12 wei)
    }

    function test_sync() public {
        test_paused_by_cap_MODE();
        
        vm.prank(l2Oft.owner());
        l2SyncPool.setMinSyncAmount(ETH_ADDRESS, 0);
    
        l2SyncPool.sync(ETH_ADDRESS, abi.encodePacked(), IL2SyncPool.MessagingFee({nativeFee: 0, lzTokenFee: 0}));
    }

    function test_mint_BLAST() public {
        vm.createSelectFork(BLAST.rpc_url);
        _setUp();

        address alice = vm.addr(1);
        vm.deal(alice, 100 ether);

        uint256 inputAmount = 0.00001 ether;
        uint256 expectedOutputAmount = l2exchangeRateProvider.getConversionAmount(ETH_ADDRESS, inputAmount);

        vm.prank(alice);
        uint256 mintAmount = l2SyncPool.deposit{value: inputAmount}(ETH_ADDRESS, inputAmount, expectedOutputAmount);        
    }

}