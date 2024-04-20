// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";

import "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";

import "forge-std/console2.sol";
import "forge-std/console.sol";

import "./NativeMintingConfigs.t.sol";

contract IDummyToken is ERC20BurnableUpgradeable {    
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) public {
        _burn(from, amount);
    }
}

interface IEtherfiL1SyncPoolETH is IOAppCore {
    function getLiquifier() external view returns (address);

    function getEEth() external view returns (address);

    function getDummyToken(uint32 originEid) external view returns (address);

    function getReceiver(uint32 originEid) external view returns (address);

    function setLiquifier(address liquifier) external;

    function setEEth(address eEth) external;

    function setDummyToken(uint32 originEid, address dummyToken) external;

    function lzReceive(
        Origin calldata origin,
        bytes32 guid,
        bytes calldata message,
        address executor,
        bytes calldata extraData
    ) external payable;

    function onMessageReceived(uint32 originEid, bytes32 guid, address tokenIn, uint256 amountIn, uint256 amountOut)
        external
        payable;

    // function endpoint() external view returns (ILayerZeroEndpointV2 iEndpoint);

    // function peers(uint32 eid) external view returns (bytes32);
}

contract NativeMintingL1Suite is Test, NativeMintingConfigs {
    EndpointV2 endpoint;
    IEtherfiL1SyncPoolETH l1SyncPool;
    OFTAdapter oftAdapter;

    address hypernative = 0x2b237B887daF752A57Eca25a163CC7A96F973FE8;

    function _setUp() internal {
        pk = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(pk);

        l1SyncPool = IEtherfiL1SyncPoolETH(l1SyncPoolAddress);
        endpoint = EndpointV2(address(l1SyncPool.endpoint()));
        oftAdapter = OFTAdapter(l1OftAdapter);

        _init();

        assertEq(address(l1SyncPool.endpoint()), l1Endpoint);
    }

    function _go() internal {
        // if (endpoint.delegates(address(oftAdapter)) != deployer) oftAdapter.setDelegate(deployer);
        // if (endpoint.delegates(address(l1SyncPool)) != deployer) l1SyncPool.setDelegate(deployer);

        _verify_oft_wired();
        _verify_syncpool_wired();
        _ensure_caps();

        _transfer_ownership();
        
        // _setup_DVN(); // only once, DONE
    }

    function test_verify_L1() public {
        _go();
    }

    function _transfer_ownership() internal {
        vm.startBroadcast(pk);
        if (endpoint.delegates(address(l1SyncPool)) != l1ContractController) l1SyncPool.setDelegate(l1ContractController);
        if (endpoint.delegates(address(oftAdapter)) != l1ContractController) oftAdapter.setDelegate(l1ContractController);

        if (IEtherFiOwnable(l1SyncPool_ProxyAdmin).owner() != l1ContractController) IEtherFiOwnable(l1SyncPool_ProxyAdmin).transferOwnership(l1ContractController);

        for (uint256 i = 0; i < l2s.length; i++) {
            // Do the same above with
            // - l2s[i].l1dummyToken
            // - l2s[i].l1Receiver
            // - l2s[i].l1dummyToken_ProxyAdmin
            // - l2s[i].l1Receiver_ProxyAdmin

            console.log(l2s[i].name, l2s[i].l1dummyToken);
            
            if (!IEtherFiOwnable(l2s[i].l1dummyToken).hasRole(bytes32(0), l1ContractController)) {
                address prevOwner = deployer;
                IEtherFiOwnable(l2s[i].l1dummyToken).grantRole(bytes32(0), l1ContractController);
                IEtherFiOwnable(l2s[i].l1dummyToken).renounceRole(bytes32(0), prevOwner);
            }
            if (IEtherFiOwnable(l2s[i].l1Receiver).owner() != l1ContractController) IEtherFiOwnable(l2s[i].l1Receiver).transferOwnership(l1ContractController);
            
            if (IEtherFiOwnable(l2s[i].l1dummyToken_ProxyAdmin).owner() != l1ContractController) IEtherFiOwnable(l2s[i].l1dummyToken_ProxyAdmin).transferOwnership(l1ContractController);
            if (IEtherFiOwnable(l2s[i].l1Receiver_ProxyAdmin).owner() != l1ContractController) IEtherFiOwnable(l2s[i].l1Receiver_ProxyAdmin).transferOwnership(l1ContractController);

            require(IEtherFiOwnable(l2s[i].l1dummyToken).hasRole(bytes32(0), l1ContractController));
            require(IEtherFiOwnable(l2s[i].l1Receiver).owner() == l1ContractController);
            require(IEtherFiOwnable(l2s[i].l1dummyToken_ProxyAdmin).owner() == l1ContractController);
            require(IEtherFiOwnable(l2s[i].l1Receiver_ProxyAdmin).owner() == l1ContractController);
        }

        vm.stopBroadcast();
    }

    function _verify_oft_wired() internal {
        vm.startBroadcast(pk);
        for (uint256 i = 0; i < l2s.length; i++) {
            bool isPeer = oftAdapter.isPeer(l2s[i].l2Eid, _toBytes32(l2s[i].l2Oft));
            console.log("OFT Wired? - ", l2s[i].name, isPeer);
            if (!isPeer) {
                oftAdapter.setPeer(l2s[i].l2Eid, _toBytes32(l2s[i].l2Oft));
            }
        }
        for (uint256 i = 0; i < bannedL2s.length; i++) {
            bool isPeer = oftAdapter.isPeer(bannedL2s[i].l2Eid, _toBytes32(bannedL2s[i].l2Oft));
            console.log("OFT Wired? - ", bannedL2s[i].name, isPeer);

            if (isPeer) {
                oftAdapter.setPeer(bannedL2s[i].l2Eid, _toBytes32(address(0)));
            }
        }
        vm.stopBroadcast();
    }
    
    function _verify_syncpool_wired() internal {
        vm.startBroadcast(pk);
        for (uint256 i = 0; i < l2s.length; i++) {
            bool isPeer = (l1SyncPool.peers(l2s[i].l2Eid) == _toBytes32(l2s[i].l2SyncPool));
            console.log("SyncPool Wired? - ", l2s[i].name, isPeer);
            if (!isPeer) {
                l1SyncPool.setPeer(l2s[i].l2Eid, _toBytes32(l2s[i].l2SyncPool));
            }
        }

        for (uint256 i = 0; i < bannedL2s.length; i++) {
            bool isPeer = (l1SyncPool.peers(bannedL2s[i].l2Eid) == _toBytes32(bannedL2s[i].l2SyncPool));
            console.log("SyncPool Wired? - ", bannedL2s[i].name, isPeer);

            if (isPeer) {
                l1SyncPool.setPeer(bannedL2s[i].l2Eid, _toBytes32(address(0)));
            }
        }
        vm.stopBroadcast();
    }

    function _setup_DVN() internal {
        vm.startBroadcast(pk);
        // - _setUpOApp(ethereum.oftToken, ETHEREUM.endpoint, ETHEREUM.send302, ETHEREUM.lzDvn, {L2s}.originEid);
        for (uint256 i = 0; i < l2s.length; i++) {
            _setUpOApp(l1OftAdapter, l1Endpoint, l1Send302, l1Receive302, l1Dvn, l2s[i].l2Eid);
            _setUpOApp_setConfig(l1SyncPoolAddress, l1Endpoint, l1Send302, l1Receive302, l1Dvn, l2s[i].l2Eid);
        }
        vm.stopBroadcast();
    }
    
    function _ensure_caps() internal {
        uint256 target_briding_cap = 0 ether;
        uint256 briding_cap_window = 24 hours;
    }
}

contract NativeMintingL1 is TestSetup, NativeMintingL1Suite {

    function setUp() public {
        _setUp();

        initializeRealisticFork(MAINNET_FORK);

        vm.prank(liquifierInstance.owner());
        liquifierInstance.updatePauser(hypernative, true);
    }

    function test_sanity_check() public {
        assertEq(l1SyncPool.getLiquifier(), address(liquifierInstance));
        assertEq(l1SyncPool.getEEth(), address(eETHInstance));
        assertEq(liquifierInstance.l1SyncPool(), address(l1SyncPool));
    }

    function test_MODE_slow_sync() public {
        uint256 amountIn = 1e18;
        uint256 amountOut = 0.9e18;

        _test_slow_sync(MODE, amountIn, amountOut, "", "");
    }

    function test_LINEA_fast_sync_fail_after_pause_by_etherfiadmin() public {
        vm.prank(etherFiAdminInstance.owner());
        etherFiAdminInstance.pause(true, true, true, true, true, true);

        uint256 amountIn = 1e18;
        uint256 amountOut = 0.9e18;

        _test_fast_sync(LINEA, amountIn, amountOut, "Pausable: paused");
    }

    function test_LINEA_fast_sync_fail_after_pause_by_liquifier_pauser() public {
        uint256 amountIn = 1e18;
        uint256 amountOut = 0.9e18;

        vm.prank(hypernative);
        liquifierInstance.pauseContract();

        _test_fast_sync(LINEA, amountIn, amountOut, "Pausable: paused");
    }

    function test_LINEA_slow_sync_fail_after_pause() public {
        uint256 amountIn = 1e18;
        uint256 amountOut = 0.9e18;

        _test_fast_sync(LINEA, amountIn, amountOut, "");

        vm.prank(hypernative);
        liquifierInstance.pauseContract();

        _onMessageReceived(LINEA, amountIn);
    }

    function test_LINEA_fast_sync() public {
        uint256 amountIn = 1e18;
        uint256 amountOut = 0.9e18;

        _test_fast_sync(LINEA, amountIn, amountOut, "");

        _test_fast_sync(LINEA, amountIn, amountOut, "CAPPED");

        vm.prank(liquifierInstance.owner());
        liquifierInstance.updateWhitelistedToken(LINEA.l1dummyToken, false);
        _test_fast_sync(LINEA, amountIn, amountOut, "NOT_ALLOWED");
    }

    function test_LINEA_slow_sync() public {
        uint256 amountIn = 1e18;
        uint256 amountOut = 0.9e18;

        _test_slow_sync(LINEA, amountIn, amountOut, "", "");
    }

    function test_BLAST_fast_sync() public {
        uint256 amountIn = 1e18;
        uint256 amountOut = 0.9e18;
        _test_fast_sync(BLAST, amountIn, amountOut, "");
    }

    function test_BLAST_slow_sync_1() public {
        uint256 amountIn = 1e18;
        uint256 amountOut = 1.1e18;

        _test_slow_sync(BLAST, amountIn, amountOut, "", "");
    }

    function test_BLAST_slow_sync_2() public {
        uint256 amountIn = 1e18;
        uint256 amountOut = 0.9e18;

        _test_slow_sync(BLAST, amountIn, amountOut, "", "");
    }

    function _test_fast_sync(ConfigPerL2 memory config, uint256 amountIn, uint256 amountOut, string memory lzReceiveRevert) public {
        _lzReceive(config, amountIn, amountOut, lzReceiveRevert);
    }

    function _test_slow_sync(ConfigPerL2 memory config, uint256 amountIn, uint256 amountOut, string memory lzReceiveRevert, string memory onMessageReceivedRevert) public {
        uint256 liquifier_eth_balance = address(liquifierInstance).balance;
        uint256 liquifier_dummy_balance = IDummyToken(config.l1dummyToken).balanceOf(address(liquifierInstance));
        uint256 lockbox_balance = weEthInstance.balanceOf(address(l1OftAdapter));
        uint256 actualAmountOut = _sharesForDepositAmount(amountIn);

        _lzReceive(config, amountIn, amountOut, lzReceiveRevert);

        if (actualAmountOut > amountOut) {
            // Fee flow
            // 'amountOut' is less than the actual weETH amount that can be minted with 'amountIn' ETH
            // so the diff is considered as a fee and stay in the syncpool
            assertEq(weEthInstance.balanceOf(address(l1OftAdapter)), lockbox_balance + amountOut);
        } else {
            // Dept flow
            assertEq(weEthInstance.balanceOf(address(l1OftAdapter)), lockbox_balance + actualAmountOut);
        }
        assertEq(address(liquifierInstance).balance, liquifier_eth_balance);
        assertEq(IDummyToken(config.l1dummyToken).balanceOf(address(liquifierInstance)), liquifier_dummy_balance + amountIn);
        
        if (bytes(onMessageReceivedRevert).length != 0) {
            vm.expectRevert(bytes(onMessageReceivedRevert));
        }
        _onMessageReceived(config, amountIn);

        assertEq(address(liquifierInstance).balance, liquifier_eth_balance + amountIn);
        assertEq(IDummyToken(config.l1dummyToken).balanceOf(address(liquifierInstance)), liquifier_dummy_balance);
        if (actualAmountOut > amountOut) {
            // Fee flow
            assertEq(weEthInstance.balanceOf(address(l1OftAdapter)), lockbox_balance + amountOut);
        } else {
            // Dept flow
            assertEq(weEthInstance.balanceOf(address(l1OftAdapter)), lockbox_balance + actualAmountOut);
        }

    }

    // Slow Sync with the ETH bridged down to the L1
    // - transfer the `amountIn` dummyETH
    function _onMessageReceived(ConfigPerL2 memory config, uint256 amountIn) internal { 
        vm.deal(config.l1Receiver, amountIn);

        vm.prank(config.l1Receiver);
        l1SyncPool.onMessageReceived{value: amountIn}(config.l2Eid, 0, ETH_ADDRESS, amountIn, 0);
    }

    // Fast Sync for native minting (input:`amountIn` ETH, output: `amountOut` weETH) at Layer 2 of Eid = `l2Eid`
    // - mint the `amountIn` amount of dummy token & transfer it to the Liquifier
    // - mint the <`amountIn` amount of eETH token & wrap it to weETH & transfer min(weETH balance, owed amount) to the lockbox (= L1 OFT Adapter)
    function _lzReceive(ConfigPerL2 memory config, uint256 amountIn, uint256 amountOut, string memory revert) internal {
        assertEq(address(l1SyncPool.getDummyToken(config.l2Eid)), config.l1dummyToken);
        assertEq(l1SyncPool.getReceiver(config.l2Eid), config.l1Receiver);
        IDummyToken dummyToken = IDummyToken(l1SyncPool.getDummyToken(config.l2Eid));

        bytes memory message = abi.encode(ETH_ADDRESS, amountIn, amountOut);

        if (bytes(revert).length != 0) {
            vm.expectRevert(bytes(revert));
        }
        vm.prank(address(l1Endpoint));
        l1SyncPool.lzReceive(Origin(config.l2Eid, _toBytes32(config.l2SyncPool), 0), 0, message, address(0), "");
    }

    function _sharesForDepositAmount(uint256 _depositAmount) internal view returns (uint256) {
        uint256 totalPooledEther = liquidityPoolInstance.getTotalPooledEther();
        if (totalPooledEther == 0) {
            return _depositAmount;
        }
        return (_depositAmount * eETHInstance.totalShares()) / totalPooledEther - 1; // rounding down
    }

}