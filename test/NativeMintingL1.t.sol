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

interface IEtherfiL1SyncPoolETH {
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

    function endpoint() external view returns (address);
}


contract NativeMintingL1 is TestSetup, NativeMintingConfigs {

    IEtherfiL1SyncPoolETH l1SyncPool = IEtherfiL1SyncPoolETH(l1SyncPoolAddress);
    address hypernative = 0x2b237B887daF752A57Eca25a163CC7A96F973FE8;

    function setUp() public {
        initializeRealisticFork(MAINNET_FORK);

        _perform_etherfi_upgrade();

        assertEq(l1SyncPool.endpoint(), l1Endpoint);
        ILayerZeroEndpointV2 endpoint = ILayerZeroEndpointV2(address(l1SyncPool.endpoint()));

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