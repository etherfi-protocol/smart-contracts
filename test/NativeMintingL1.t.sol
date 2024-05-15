// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";

import "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";

import "forge-std/console2.sol";
import "forge-std/console.sol";

import "./NativeMintingConfigs.t.sol";

interface IL1Receiver {
    function onMessageReceived(bytes calldata message) external;
}


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

    function setReceiver(uint32 originEid, address receiver) external;

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

    function owner() external view returns (address);
}

contract NativeMintingL1Suite is Test, NativeMintingConfigs {
    uint256 pk;
    address deployer;

    EndpointV2 endpoint;
    IEtherfiL1SyncPoolETH l1SyncPool;
    OFTAdapter oftAdapter;

    address hypernative = 0x2b237B887daF752A57Eca25a163CC7A96F973FE8;


    function _setUp() internal {
        pk = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(pk);

        l1SyncPool = IEtherfiL1SyncPoolETH(l1SyncPoolAddress);
        endpoint = EndpointV2(address(l1Endpoint));
        oftAdapter = OFTAdapter(l1OftAdapter);

        _init();
    }

    function _go() internal {
        // if (endpoint.delegates(address(oftAdapter)) != deployer) oftAdapter.setDelegate(deployer);
        // if (endpoint.delegates(address(l1SyncPool)) != deployer) l1SyncPool.setDelegate(deployer);

        // _verify_oft_wired();
        _verify_syncpool_wired();

        // _transfer_ownership();
        
        _setup_DVN(true, true); // only once, DONE
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
            if (l2s[i].l2SyncPool == address(0)) continue;
            bool isPeer = (l1SyncPool.peers(l2s[i].l2Eid) == _toBytes32(l2s[i].l2SyncPool));
            console.log("SyncPool Wired? - ", l2s[i].name, isPeer);
            if (!isPeer) {
                // emit Transaction(address(l1SyncPool), abi.encodeWithSelector(l1SyncPool.setPeer.selector, l2s[i].l2Eid, _toBytes32(l2s[i].l2SyncPool)));
                l1SyncPool.setPeer(l2s[i].l2Eid, _toBytes32(l2s[i].l2SyncPool));
            }
        }

        for (uint256 i = 0; i < bannedL2s.length; i++) {
            if (l2s[i].l2SyncPool == address(0)) continue;
            bool isPeer = (l1SyncPool.peers(bannedL2s[i].l2Eid) == _toBytes32(bannedL2s[i].l2SyncPool));
            console.log("SyncPool Wired? - ", bannedL2s[i].name, isPeer);

            if (isPeer) {
                l1SyncPool.setPeer(bannedL2s[i].l2Eid, _toBytes32(address(0)));
            }
        }
        vm.stopBroadcast();
    }

    function _setup_DVN(bool _oft, bool _syncPool) internal {
        vm.startBroadcast(pk);
        if (_oft && endpoint.delegates(address(oftAdapter)) != deployer) oftAdapter.setDelegate(deployer);
        if (_syncPool && endpoint.delegates(address(l1SyncPool)) != deployer) l1SyncPool.setDelegate(deployer);

        // - _setUpOApp(ethereum.oftToken, ETHEREUM.endpoint, ETHEREUM.send302, ETHEREUM.lzDvn, {L2s}.originEid);
        for (uint256 i = 0; i < l2s.length; i++) {
            if (_oft) _setUpOApp(l1OftAdapter, l1Endpoint, l1Send302, l1Receive302, l1Dvn, l2s[i].l2Eid, false);
            if (_syncPool) _setUpOApp(l1SyncPoolAddress, l1Endpoint, l1Send302, l1Receive302, l1Dvn, l2s[i].l2Eid, true);
        }
        vm.stopBroadcast();
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
        _20240428_updateDepositCap();
        
        uint256 amountIn = 1000e18;
        uint256 amountOut = 900e18;
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

    function test_fill_the_gaps() public {
        bytes memory withdrawal_tx_data;
        IERC20 dummyToken = IERC20(MODE.l1dummyToken);

        uint256 previousLiquifierBalance = address(0x9FFDF407cDe9a93c47611799DA23924Af3EF764F).balance;
        uint256 previousDummyTokenBalance = dummyToken.balanceOf(address(0x9FFDF407cDe9a93c47611799DA23924Af3EF764F));

        // - https://explorer.mode.network/tx/0xd09ec792a04f27f84282c117cb6686fd2a5778c5ff090d773ba3cc98fae3749f
        withdrawal_tx_data = hex"d764ad0b000100000000000000000000000000000000000000000000000000000000000000000000000000000000000052c4221cb805479954cde5accff8c4dcaf96623b000000000000000000000000c8ad0949f33f02730cff3b96e7f067e83de1696f00000000000000000000000000000000000000000000005baba2490a2ddcc956000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000000e43a69197e000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000007634cbc9734011ca69e502a8180c7c00160435712b342200c6ae1b25f21cd7eebce6000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000000000000000005baba2490a2ddcc9560000000000000000000000000000000000000000000000585a9fec6d427f07d400000000000000000000000000000000000000000000000000000000";
        // withdrawal_txs_data.push(withdrawal_tx_data);
        _fill_the_gap(withdrawal_tx_data);

        // - https://explorer.mode.network/tx/0x5e0c8328e4541a8cfdeada8d645130b06782b570d1ec40d9694f6d429605d31c
        withdrawal_tx_data = hex"d764ad0b000100000000000000000000000000000000000000000000000000000000000100000000000000000000000052c4221cb805479954cde5accff8c4dcaf96623b000000000000000000000000c8ad0949f33f02730cff3b96e7f067e83de1696f000000000000000000000000000000000000000000000051595e1ab9a4fda2df000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000000e43a69197e000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000007634d20917f39259d5e1f63997aa83943676e2bffd84caaf99b41cf8bea923b7e943000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee000000000000000000000000000000000000000000000051595e1ab9a4fda2df00000000000000000000000000000000000000000000004e713a1b913f290d0e00000000000000000000000000000000000000000000000000000000";
        // withdrawal_txs_data.push(withdrawal_tx_data);
        _fill_the_gap(withdrawal_tx_data);

        // - https://explorer.mode.network/tx/0x08e7a03f6a0391bec7d09829ae854ce5b9b8a91df5ef5ec999fc9b5a39dfd5ae
        withdrawal_tx_data = hex"d764ad0b000100000000000000000000000000000000000000000000000000000000000200000000000000000000000052c4221cb805479954cde5accff8c4dcaf96623b000000000000000000000000c8ad0949f33f02730cff3b96e7f067e83de1696f00000000000000000000000000000000000000000000000b93f449a33421ce11000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000000e43a69197e000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000076347f529ec0ca43ba7cfe321ce4586c1e9ae2d918deffa2207915f47b292d930f8b000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000000000000000000b93f449a33421ce1100000000000000000000000000000000000000000000000b29771981e789cb2b00000000000000000000000000000000000000000000000000000000";
        // withdrawal_txs_data.push(withdrawal_tx_data);
        _fill_the_gap(withdrawal_tx_data);
        
        // - https://explorer.mode.network/tx/0xc7537232f8c1ba03b1bfe92782ebd28d9cd359b682918e751672475eae5b4a31
        withdrawal_tx_data = hex"d764ad0b000100000000000000000000000000000000000000000000000000000000000300000000000000000000000052c4221cb805479954cde5accff8c4dcaf96623b000000000000000000000000c8ad0949f33f02730cff3b96e7f067e83de1696f000000000000000000000000000000000000000000000020cdb4e527f596c6de000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000000e43a69197e000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000076344cf823fc555a0f574d0b481b492741747dd5abe476368ec0d2c2e9651204a864000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee000000000000000000000000000000000000000000000020cdb4e527f596c6de00000000000000000000000000000000000000000000001f9f53c09836b9508400000000000000000000000000000000000000000000000000000000";
        // withdrawal_txs_data.push(withdrawal_tx_data);
        _fill_the_gap(withdrawal_tx_data);
        
        // - https://explorer.mode.network/tx/0x803c0fc86ad9d12a42c3cda863971c661943e8be819d353e02d8be6141ffe3e3
        withdrawal_tx_data = hex"d764ad0b000100000000000000000000000000000000000000000000000000000000000400000000000000000000000052c4221cb805479954cde5accff8c4dcaf96623b000000000000000000000000c8ad0949f33f02730cff3b96e7f067e83de1696f00000000000000000000000000000000000000000000002f2d775d16e05327b1000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000000e43a69197e000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000763482eaa12954abba8fd75b013e1868c075439242f49e68b00254029d71aa9100d0000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000000000000000002f2d775d16e05327b100000000000000000000000000000000000000000000002d78b9f25cfa5b50b800000000000000000000000000000000000000000000000000000000";
        // withdrawal_txs_data.push(withdrawal_tx_data);
        _fill_the_gap(withdrawal_tx_data);

        uint256 diffInBalance = address(0x9FFDF407cDe9a93c47611799DA23924Af3EF764F).balance - previousLiquifierBalance;
        uint256 diffInDummyTokenBalance =  previousDummyTokenBalance - dummyToken.balanceOf(address(0x9FFDF407cDe9a93c47611799DA23924Af3EF764F));
        console.log("Delta(Liquifier.balance): +", diffInBalance);
        console.log("Delta(Liquifier.DummyToken..balance): -", diffInDummyTokenBalance);

        // What if we have one more tx to fill the gap?
        //   amountIn 870273161071118460849
        //   amountOut 838802733953323847864
        {
            withdrawal_tx_data = hex"d764ad0b000100000000000000000000000000000000000000000000000000000000000400000000000000000000000052c4221cb805479954cde5accff8c4dcaf96623b000000000000000000000000c8ad0949f33f02730cff3b96e7f067e83de1696f00000000000000000000000000000000000000000000002f2d775d16e05327b1000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000000e43a69197e000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000763482eaa12954abba8fd75b013e1868c075439242f49e68b00254029d71aa9100d0000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000000000000000002f2d775d16e05327b100000000000000000000000000000000000000000000002d78b9f25cfa5b50b800000000000000000000000000000000000000000000000000000000";

            previousLiquifierBalance = address(0x9FFDF407cDe9a93c47611799DA23924Af3EF764F).balance;
            previousDummyTokenBalance = dummyToken.balanceOf(address(0x9FFDF407cDe9a93c47611799DA23924Af3EF764F));
            uint256 previousL1SyncPoolBalance = address(l1SyncPool).balance;
            _fill_the_gap(withdrawal_tx_data);
            diffInBalance = address(0x9FFDF407cDe9a93c47611799DA23924Af3EF764F).balance - previousLiquifierBalance;
            diffInDummyTokenBalance =  previousDummyTokenBalance - dummyToken.balanceOf(address(0x9FFDF407cDe9a93c47611799DA23924Af3EF764F));
            uint256 diffInL1SyncPoolBalance = address(l1SyncPool).balance - previousL1SyncPoolBalance;
            console.log("Delta(Liquifier.balance): +", diffInBalance);
            console.log("Delta(Liquifier.DummyToken.balance): -", diffInDummyTokenBalance);
            console.log("Delta(L1SyncPool.balance): +", diffInL1SyncPoolBalance);
        }
    }


    function _fill_the_gap(bytes memory withdrawal_tx_data) internal {
        (uint32 originEid, bytes32 guid, address tokenIn, uint256 amountIn, uint256 amountOut) = _fetchMessageToSyncPool(withdrawal_tx_data);
        // guid = hex"";
        // amountIn = 0.001 ether;
        // amountOut = weEthInstance.getWeETHByeETH(amountIn);

        console.log("originEid", originEid);
        console.log("guid");
        console.logBytes32(guid);
        console.log("tokenIn", tokenIn);
        console.log("amountIn", amountIn);
        console.log("amountOut", amountOut);

        address currentReceiver = l1SyncPool.getReceiver(originEid);

        // 1. prepare for ETH
        vm.deal(l1ContractController, amountIn);

        // 2. update so that the contract controller can trigger `onMessageReceived`
        vm.prank(l1ContractController);
        l1SyncPool.setReceiver(originEid, l1ContractController);
        emit Transaction(address(l1SyncPool), 0, abi.encodeWithSelector(l1SyncPool.setReceiver.selector, originEid, l1ContractController));
        // _dump_gnosis_txn(address(l1SyncPool), 0, abi.encodeWithSelector(l1SyncPool.setReceiver.selector, originEid, l1ContractController));
        vm.warp(block.timestamp + 1);

        // 3. do it
        vm.prank(l1ContractController);
        l1SyncPool.onMessageReceived{value: amountIn}(originEid, guid, tokenIn, amountIn, amountOut);
        emit Transaction(address(l1SyncPool), amountIn, abi.encodeWithSelector(l1SyncPool.onMessageReceived.selector, originEid, guid, tokenIn, amountIn, amountOut));
        // _dump_gnosis_txn(address(l1SyncPool), amountIn, abi.encodeWithSelector(l1SyncPool.onMessageReceived.selector, originEid, guid, tokenIn, amountIn, amountOut));
        vm.warp(block.timestamp + 1);

        // 4. revert back the receiver setup
        vm.prank(l1ContractController);
        l1SyncPool.setReceiver(originEid, currentReceiver);
        emit Transaction(address(l1SyncPool), 0, abi.encodeWithSelector(l1SyncPool.setReceiver.selector, originEid, currentReceiver));
        // _dump_gnosis_txn(address(l1SyncPool), 0, abi.encodeWithSelector(l1SyncPool.setReceiver.selector, originEid, currentReceiver));
        vm.warp(block.timestamp + 1);
    }

    function _fetchMessageToReceiver(bytes memory withdrawal_tx_data) internal returns (bytes memory) {
        bytes memory tmp = this.removeSignature(withdrawal_tx_data);
        (,,address target,,,bytes memory message) = abi.decode(tmp, (uint256, address, address, uint256, uint256, bytes));
        return message;
    }

    function _fetchMessageToSyncPool(bytes memory withdrawal_tx_data) internal returns (uint32 originEid, bytes32 guid, address tokenIn, uint256 amountIn, uint256 amountOut) {
        bytes memory message = _fetchMessageToReceiver(withdrawal_tx_data);

        bytes memory tmp = this.removeSignature(message);
        (bytes memory data) = abi.decode(tmp, (bytes));

        (originEid, guid, tokenIn, amountIn, amountOut) = abi.decode(data, (uint32, bytes32, address, uint256, uint256));        
    }

    // remove signature
    function removeSignature(bytes calldata data) public returns (bytes memory) {
        return abi.encodePacked(data[4:]);
    }
}