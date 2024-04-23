// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";

import "forge-std/console2.sol";
import "forge-std/console.sol";
import "forge-std/Test.sol";

import "../src/BucketRateLimiter.sol";

import "./NativeMintingConfigs.t.sol";


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

    function quoteSync(address tokenIn, bytes calldata extraOptions, bool payInLzToken)
        external
        view
        returns (MessagingFee memory msgFee);

}


contract NativeMintingL2 is Test, NativeMintingConfigs {
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
        else if (block.chainid == 56) targetL2 = BNB;
        else if (block.chainid == 8453) targetL2 = BASE;
        else revert("Unsupported chain id");

        _init();

        l2Endpoint = EndpointV2(targetL2.l2Endpoint);
        l2Oft = IEtherFiOFT(targetL2.l2Oft);
        l2SyncPool = IL2SyncPool(targetL2.l2SyncPool);
        l2exchangeRateProvider = IL2ExchangeRateProvider(targetL2.l2ExchagneRateProvider);
        if (targetL2.l2SyncPoolRateLimiter != address(0))
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
    
    function _go_oft() internal {
        _verify_L2_OFT_configuratinos();
        // _verify_oft_wired();

        _setup_DVN(true, false); // only once
        // _transfer_ownership(true, false); // only at last
    }

    function _verify_L2_OFT_configuratinos() internal {
        (uint256 amountInFlight, uint256 lastUpdated, uint256 limit, uint256 window) = l2Oft.rateLimits(l1Eid);

        console.log("l2Oft.rateLimits(toL1).limit: ", limit);
        console.log("l2Oft.rateLimits(toL1).window: ", window);
        
        console.log("l2Oft.owner(): ", l2Oft.owner());
        console.log("l2Oft_ProxyAdmin.owner(): ", IEtherFiOwnable(targetL2.l2Oft_ProxyAdmin).owner());
        console.log("l2Endpoint.delegates(l2Oft): ", l2Endpoint.delegates(address(l2Oft)));

        vm.startBroadcast(pk);

        // Bridging Cap
        uint256 target_briding_cap = 4_000 ether;
        uint256 briding_cap_window = 4 hours;

        // - L2 -> L1
        if (limit != target_briding_cap || window != briding_cap_window) {
            IEtherFiOFT.RateLimitConfig[] memory rateLimits = new IEtherFiOFT.RateLimitConfig[](1);
            rateLimits[0] = IEtherFiOFT.RateLimitConfig({dstEid: l1Eid, limit: target_briding_cap, window: briding_cap_window});
            l2Oft.setRateLimits(rateLimits);
        }
        (amountInFlight, lastUpdated, limit, window) = l2Oft.rateLimits(l1Eid);
        require(limit == target_briding_cap && window == briding_cap_window, "OFT Transfer Rate limit not set");

        // - L2 -> {L2}
        for (uint256 i = 0; i < l2s.length; i++) {
            if (targetL2.l2Eid == l2s[i].l2Eid) continue;
            if (l2s[i].send302 == address(0) || l2s[i].receive302 == address(0)) continue;

            (amountInFlight, lastUpdated, limit, window) = l2Oft.rateLimits(l2s[i].l2Eid);
            if (limit != target_briding_cap || window != briding_cap_window) {
                IEtherFiOFT.RateLimitConfig[] memory rateLimits = new IEtherFiOFT.RateLimitConfig[](1);
                rateLimits[0] = IEtherFiOFT.RateLimitConfig({dstEid: l2s[i].l2Eid, limit: target_briding_cap, window: briding_cap_window});
                l2Oft.setRateLimits(rateLimits);
            }
        
            (amountInFlight, lastUpdated, limit, window) = l2Oft.rateLimits(l2s[i].l2Eid);
            require(limit == target_briding_cap && window == briding_cap_window, "OFT Transfer Rate limit not set");
        }
        vm.stopBroadcast();

    }

    function _go() internal {
        _verify_L2_configurations();
        _verify_oft_wired();
        _verify_syncpool_wired();

        // _setup_DVN(true, true); // only once

        // _transfer_ownership(true, true); // only at last
    }

    function _setup_DVN(bool _oft, bool _syncPool) internal {
        vm.startBroadcast(pk);
        if (_oft) _setUpOApp(targetL2.l2Oft, targetL2.l2Endpoint, targetL2.send302, targetL2.receive302, targetL2.lzDvn, l1Eid);
        if (_syncPool) _setUpOApp_setConfig(targetL2.l2SyncPool, targetL2.l2Endpoint, targetL2.send302, targetL2.receive302, targetL2.lzDvn, l1Eid);

        for (uint256 i = 0; i < l2s.length; i++) {
            if (targetL2.l2Eid == l2s[i].l2Eid) continue;
            if (l2s[i].send302 == address(0) || l2s[i].receive302 == address(0)) continue;
            if (_oft) _setUpOApp(targetL2.l2Oft, targetL2.l2Endpoint, targetL2.send302, targetL2.receive302, targetL2.lzDvn, l2s[i].l2Eid);
            if (_syncPool) _setUpOApp_setConfig(targetL2.l2SyncPool, targetL2.l2Endpoint, targetL2.send302,targetL2.receive302, targetL2.lzDvn, l2s[i].l2Eid);
        }
        vm.stopBroadcast();
    }

    function _verify_oft_wired() internal {
        vm.startBroadcast(pk);

        console.log(targetL2.name, "L2Oft.IsPeer of");
        bool isPeer = l2Oft.isPeer(l1Eid, _toBytes32(l1OftAdapter));
        console.log("- ETH", isPeer);
        if (!isPeer) {
            l2Oft.setPeer(l1Eid, _toBytes32(l1OftAdapter));
        }

        for (uint256 i = 0; i < l2s.length; i++) {
            if (targetL2.l2Eid == l2s[i].l2Eid) continue; 
            bool isPeer = l2Oft.isPeer(l2s[i].l2Eid, _toBytes32(l2s[i].l2Oft));
            console.log("- ", l2s[i].name, isPeer);
            if (!isPeer) {
                l2Oft.setPeer(l2s[i].l2Eid, _toBytes32(l2s[i].l2Oft));
            }
        }

        for (uint256 i = 0; i < bannedL2s.length; i++) {
            if (targetL2.l2Eid == bannedL2s[i].l2Eid) continue; 
            bool isPeer = l2Oft.isPeer(bannedL2s[i].l2Eid, _toBytes32(bannedL2s[i].l2Oft));
            if (isPeer) {
                l2Oft.setPeer(bannedL2s[i].l2Eid, _toBytes32(address(0)));
            }
        }

        // use 'require' instead of log to actually force it
        require(l2Oft.isPeer(l1Eid, _toBytes32(l1OftAdapter)), "OFT not wired");
        for (uint256 i = 0; i < l2s.length; i++) {
            if (targetL2.l2Eid == l2s[i].l2Eid) continue; 
            require(l2Oft.isPeer(l2s[i].l2Eid, _toBytes32(l2s[i].l2Oft)), "OFT not wired");
        }
        for (uint256 i = 0; i < bannedL2s.length; i++) {
            if (targetL2.l2Eid == bannedL2s[i].l2Eid) continue; 
            require(!l2Oft.isPeer(bannedL2s[i].l2Eid, _toBytes32(bannedL2s[i].l2Oft)), "OFT wired, but shouldn't");
        }

        vm.stopBroadcast();
    }

    function _verify_syncpool_wired() internal {
        console.log(targetL2.name, "L2SyncPool.IsPeer of");
        bool isPeer = (l2SyncPool.peers(l1Eid) == _toBytes32(l1SyncPoolAddress));
        console.log("- ETH", isPeer);
        

        require((l2SyncPool.peers(l1Eid) == _toBytes32(l1SyncPoolAddress)), "SyncPool not wired");
    }

    function _verify_L2_configurations() internal {
        IL2SyncPool.Token memory tokenData = l2SyncPool.getTokenData(ETH_ADDRESS);
        (uint256 amountInFlight, uint256 lastUpdated, uint256 limit, uint256 window) = l2Oft.rateLimits(l2SyncPool.getDstEid());
        (uint64 capacity, uint64 remaining, uint64 lastRefill, uint64 refillRate) = l2SyncPoolRateLimiter.limit();

        uint256 minSyncAmount = 50 ether;

        console.log("l2Oft.rateLimits(toL1).limit: ", limit);
        console.log("l2Oft.rateLimits(toL1).window: ", window);
        console.log("l2SyncPoolRateLimiter.limit().capacity: ", capacity);

        console.log("l2Oft.hasRole(l2Oft.MINTER_ROLE(), targetL2.l2SyncPool): ", l2Oft.hasRole(l2Oft.MINTER_ROLE(), targetL2.l2SyncPool));
        console.log("l2SyncPool.getDstEid() == l1Eid: ", l2SyncPool.getDstEid() == l1Eid);
        console.log("l2SyncPool.getTokenOut() == targetL2.l2Oft: ", l2SyncPool.getTokenOut() == targetL2.l2Oft);
        console.log("l2SyncPool.getL2ExchangeRateProvider() == targetL2.l2ExchagneRateProvider: ", l2SyncPool.getL2ExchangeRateProvider() == targetL2.l2ExchagneRateProvider);
        console.log("l2SyncPool.getRateLimiter() == targetL2.l2SyncPoolRateLimiter: ", l2SyncPool.getRateLimiter() == targetL2.l2SyncPoolRateLimiter);
        console.log("l2SyncPool.tokens[ETH].l1Address == ETH", tokenData.l1Address == ETH_ADDRESS);
        console.log("l2SyncPool.tokens[ETH].minSyncAmount == minSyncAmount (= 50 ETH) ", tokenData.minSyncAmount == minSyncAmount);
        
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

        vm.startBroadcast(pk);
        if (!l2Oft.hasRole(l2Oft.MINTER_ROLE(), targetL2.l2SyncPool)) {
            l2Oft.grantRole(l2Oft.MINTER_ROLE(), targetL2.l2SyncPool);
        }
        if (!(tokenData.minSyncAmount == minSyncAmount)) {
            l2SyncPool.setMinSyncAmount(ETH_ADDRESS, minSyncAmount);
        }
        if (!(l2exchangeRateProvider.getRateParameters(ETH_ADDRESS).depositFee == 1e15)) {
            // deposit fee = 10 bp, fresh period
            l2exchangeRateProvider.setRateParameters(ETH_ADDRESS, targetL2.l2PriceOracle, 1e15, targetL2.l2PriceOracleHeartBeat);
        }

        // Bridging Cap
        uint256 target_briding_cap = 0 ether;
        uint256 briding_cap_window = 24 hours;

        // - L2 -> L1
        if (limit != target_briding_cap || window != briding_cap_window) {
            IEtherFiOFT.RateLimitConfig[] memory rateLimits = new IEtherFiOFT.RateLimitConfig[](1);
            rateLimits[0] = IEtherFiOFT.RateLimitConfig({dstEid: l2SyncPool.getDstEid(), limit: target_briding_cap, window: briding_cap_window});
            l2Oft.setRateLimits(rateLimits);
        }

        // - L2 -> {L2}
        for (uint256 i = 0; i < l2s.length; i++) {
            if (targetL2.l2Eid == l2s[i].l2Eid) continue;
            if (l2s[i].send302 == address(0) || l2s[i].receive302 == address(0)) continue;

            (amountInFlight, lastUpdated, limit, window) = l2Oft.rateLimits(l2s[i].l2Eid);
            if (limit != target_briding_cap || window != briding_cap_window) {
                IEtherFiOFT.RateLimitConfig[] memory rateLimits = new IEtherFiOFT.RateLimitConfig[](1);
                rateLimits[0] = IEtherFiOFT.RateLimitConfig({dstEid: l2s[i].l2Eid, limit: target_briding_cap, window: briding_cap_window});
                l2Oft.setRateLimits(rateLimits);
            }
        }

        // Native Minting Cap
        uint256 target_native_minting_cap = 0.0001 ether;
        if (refillRate != target_native_minting_cap / 1e12) {
            l2SyncPoolRateLimiter.setRefillRatePerSecond(target_native_minting_cap);
        }
        vm.stopBroadcast();

        (amountInFlight, lastUpdated, limit, window) = l2Oft.rateLimits(l2SyncPool.getDstEid());
        (capacity, remaining, lastRefill, refillRate) = l2SyncPoolRateLimiter.limit();

        require(limit == target_briding_cap && window == briding_cap_window, "OFT Transfer Rate limit not set");
        require(refillRate == target_native_minting_cap / 1e12, "");

        require(l2Oft.hasRole(l2Oft.MINTER_ROLE(), targetL2.l2SyncPool), "MINTER_ROLE not set");
        require(l2SyncPool.getDstEid() == l1Eid, "DstEid not set");
        require(l2SyncPool.getTokenOut() == targetL2.l2Oft, "TokenOut not set");
        require(l2SyncPool.getL2ExchangeRateProvider() == targetL2.l2ExchagneRateProvider, "ExchangeRateProvider not set");
        require(l2SyncPool.getRateLimiter() == targetL2.l2SyncPoolRateLimiter, "RateLimiter not set");
        require(tokenData.l1Address == ETH_ADDRESS, "Token data not set");
    }

    function _transfer_ownership(bool _oft, bool _syncPool) internal {
        vm.startBroadcast(pk);

        if (_oft) {
            if (l2Endpoint.delegates(address(l2Oft)) != targetL2.l2ContractControllerSafe) l2Oft.setDelegate(targetL2.l2ContractControllerSafe);
            if (IEtherFiOwnable(address(l2Oft)).owner() != targetL2.l2ContractControllerSafe) IEtherFiOwnable(address(l2Oft)).transferOwnership(targetL2.l2ContractControllerSafe);
            if (IEtherFiOwnable(targetL2.l2Oft_ProxyAdmin).owner() != targetL2.l2ContractControllerSafe) IEtherFiOwnable(targetL2.l2Oft_ProxyAdmin).transferOwnership(targetL2.l2ContractControllerSafe);

            require(l2Endpoint.delegates(address(l2Oft)) == targetL2.l2ContractControllerSafe, "OFT Delegate not set");
            require(IEtherFiOwnable(address(l2Oft)).owner() == targetL2.l2ContractControllerSafe, "OFT ownership not transferred");
            require(IEtherFiOwnable(targetL2.l2Oft_ProxyAdmin).owner() == targetL2.l2ContractControllerSafe, "OFT ProxyAdmin ownership not transferred");
        }

        if (_syncPool) {
            if (l2Endpoint.delegates(address(l2SyncPool)) != targetL2.l2ContractControllerSafe) l2SyncPool.setDelegate(targetL2.l2ContractControllerSafe);

            if (IEtherFiOwnable(address(l2SyncPool)).owner() != targetL2.l2ContractControllerSafe) IEtherFiOwnable(address(l2SyncPool)).transferOwnership(targetL2.l2ContractControllerSafe);
            if (IEtherFiOwnable(address(l2SyncPoolRateLimiter)).owner() != targetL2.l2ContractControllerSafe) IEtherFiOwnable(address(l2SyncPoolRateLimiter)).transferOwnership(targetL2.l2ContractControllerSafe);
            if (IEtherFiOwnable(address(l2exchangeRateProvider)).owner() != targetL2.l2ContractControllerSafe) IEtherFiOwnable(address(l2exchangeRateProvider)).transferOwnership(targetL2.l2ContractControllerSafe);

            if (IEtherFiOwnable(targetL2.l2SyncPool_ProxyAdmin).owner() != targetL2.l2ContractControllerSafe) IEtherFiOwnable(targetL2.l2SyncPool_ProxyAdmin).transferOwnership(targetL2.l2ContractControllerSafe);
            if (IEtherFiOwnable(targetL2.l2ExchagneRateProvider_ProxyAdmin).owner() != targetL2.l2ContractControllerSafe) IEtherFiOwnable(targetL2.l2ExchagneRateProvider_ProxyAdmin).transferOwnership(targetL2.l2ContractControllerSafe);

        
            require(l2Endpoint.delegates(address(l2SyncPool)) == targetL2.l2ContractControllerSafe, "SyncPool Delegate not set");

            require(IEtherFiOwnable(address(l2SyncPool)).owner() == targetL2.l2ContractControllerSafe, "SyncPool ownership not transferred");
            require(IEtherFiOwnable(address(l2SyncPoolRateLimiter)).owner() == targetL2.l2ContractControllerSafe, "RateLimiter ownership not transferred");
            require(IEtherFiOwnable(address(l2exchangeRateProvider)).owner() == targetL2.l2ContractControllerSafe, "ExchangeRateProvider ownership not transferred");

            require(IEtherFiOwnable(targetL2.l2SyncPool_ProxyAdmin).owner() == targetL2.l2ContractControllerSafe, "SyncPool ProxyAdmin ownership not transferred");
            require(IEtherFiOwnable(targetL2.l2ExchagneRateProvider_ProxyAdmin).owner() == targetL2.l2ContractControllerSafe, "ExchangeRateProvider ProxyAdmin ownership not transferred");
        }
        vm.stopBroadcast();
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
        vm.createSelectFork(BLAST.rpc_url);
        _setUp();

        vm.deal(l2Oft.owner(), 1 ether);
        
        vm.prank(l2Oft.owner());
        l2SyncPool.setMinSyncAmount(ETH_ADDRESS, 0);
   
        IL2SyncPool.MessagingFee memory fee = l2SyncPool.quoteSync(ETH_ADDRESS, abi.encodePacked(), false);
    
        uint256 nativeFee;
        l2SyncPool.sync{value: fee.nativeFee}(ETH_ADDRESS, abi.encodePacked(), fee);
    }

    function test_oft_send_FAIL_RateLimitExceeded_1() public {
        _oft_send_FAIL_RateLimitExceeded(BLAST, MODE);
    }

    function test_oft_send_FAIL_RateLimitExceeded_2() public {
        _oft_send_FAIL_RateLimitExceeded(MODE, BLAST);
    }

    function _oft_send_FAIL_RateLimitExceeded(ConfigPerL2 memory _from, ConfigPerL2 memory _to) public {
        vm.createSelectFork(_from.rpc_url);
        _setUp();

        address alice = vm.addr(1);
        vm.deal(alice, 10 ether);

        vm.startPrank(l2SyncPoolRateLimiter.owner());
        l2SyncPoolRateLimiter.setRefillRatePerSecond(100 ether);
        l2SyncPoolRateLimiter.setCapacity(100 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);

        uint256 inputAmount = 10 ether;
        uint256 expectedOutputAmount = l2exchangeRateProvider.getConversionAmount(ETH_ADDRESS, inputAmount);

        vm.prank(alice);
        uint256 mintAmount = l2SyncPool.deposit{value: inputAmount}(ETH_ADDRESS, inputAmount, expectedOutputAmount);

        SendParam memory param = SendParam({
            dstEid: _to.l2Eid,
            to: _toBytes32(alice),
            amountLD: 1 ether,
            minAmountLD: 0.5 ether,
            extraOptions: hex"",
            composeMsg: hex"",
            oftCmd: hex""
        });

        MessagingFee memory msgFee = MessagingFee({nativeFee: 0, lzTokenFee: 0});

        vm.expectRevert(RateLimiter.RateLimitExceeded.selector);
        l2Oft.send(param, msgFee, alice);
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

    function test_setRateLimits_BLAST() public {
        vm.createSelectFork(BLAST.rpc_url);
        _setUp();

        vm.startBroadcast(BLAST.l2ContractControllerSafe);

        uint256 target_briding_cap = 4_000 ether;
        uint256 briding_cap_window = 4 hours;

        IEtherFiOFT.RateLimitConfig[] memory rateLimits = new IEtherFiOFT.RateLimitConfig[](1);
        rateLimits[0] = IEtherFiOFT.RateLimitConfig({dstEid: l1Eid, limit: target_briding_cap, window: briding_cap_window});
        l2Oft.setRateLimits(rateLimits);

        vm.stopPrank();
    }

}