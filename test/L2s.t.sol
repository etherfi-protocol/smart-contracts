// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";

import "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";

import "forge-std/console2.sol";
import "forge-std/console.sol";

struct Origin {
    uint32 srcEid;
    bytes32 sender;
    uint64 nonce;
}

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

interface ILayerZeroEndpointV2 {
    // function quote(MessagingParams calldata _params, address _sender) external view returns (MessagingFee memory);

    // function send(
    //     MessagingParams calldata _params,
    //     address _refundAddress
    // ) external payable returns (MessagingReceipt memory);

    function verify(Origin calldata _origin, address _receiver, bytes32 _payloadHash) external;

    function verifiable(Origin calldata _origin, address _receiver) external view returns (bool);

    function initializable(Origin calldata _origin, address _receiver) external view returns (bool);

    function lzReceive(
        Origin calldata _origin,
        address _receiver,
        bytes32 _guid,
        bytes calldata _message,
        bytes calldata _extraData
    ) external payable;

    // oapp can burn messages partially by calling this function with its own business logic if messages are verified in order
    function clear(address _oapp, Origin calldata _origin, bytes32 _guid, bytes calldata _message) external;

    function setLzToken(address _lzToken) external;

    function lzToken() external view returns (address);

    function nativeToken() external view returns (address);

    function setDelegate(address _delegate) external;
}



contract L2sTest is TestSetup {
    struct ConfigPerL2 {
        uint32 l2Eid;
        address l2Oft;
        address l2SyncPool;
        address l1dummyToken;
        address l1Receiver;
    }

    IEtherfiL1SyncPoolETH l1SyncPool = IEtherfiL1SyncPoolETH(0xD789870beA40D056A4d26055d0bEFcC8755DA146);
    address l1OftAdapter = 0xFE7fe01F8B9A76803aF3750144C2715D9bcf7D0D;
    address l1Endpoint = 0x1a44076050125825900e736c501f859c50fE728c;
    address ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    ConfigPerL2 BLAST = ConfigPerL2({
        l2Eid: 30243,
        l2Oft: 0x04C0599Ae5A44757c0af6F9eC3b93da8976c150A,
        l2SyncPool: 0x52c4221Cb805479954CDE5accfF8C4DcaF96623B,
        l1dummyToken: 0x83998e169026136760bE6AF93e776C2F352D4b28,
        l1Receiver: 0x27e120C518a339c3d8b665E56c4503DF785985c2
    });

    function setUp() public {
        initializeRealisticFork(MAINNET_FORK);

        _perform_etherfi_upgrade();

        assertEq(l1SyncPool.endpoint(), l1Endpoint);
        ILayerZeroEndpointV2 endpoint = ILayerZeroEndpointV2(address(l1SyncPool.endpoint()));
    }


    function test_sanity_check() public {
        assertEq(l1SyncPool.getLiquifier(), address(liquifierInstance));
        assertEq(l1SyncPool.getEEth(), address(eETHInstance));
        assertEq(liquifierInstance.l1SyncPool(), address(l1SyncPool));
    }

    function test_BLAST_fast_sync() public {
        uint256 amountIn = 1e18;
        uint256 amountOut = 0.9e18;

        _test_fast_sync(BLAST.l2Eid, BLAST.l2Oft, BLAST.l2SyncPool, BLAST.l1dummyToken, BLAST.l1Receiver, amountIn, amountOut);
    }

    function test_BLAST_slow_sync() public {
        // 'amountOut' is less than the actual weETH amount that can be minted with 'amountIn' ETH
        // so the diff is considered as a fee and stay in the syncpool
        uint256 amountIn = 1e18;
        uint256 amountOut = 0.9e18;

        uint256 liquifier_eth_balance = address(liquifierInstance).balance;
        uint256 liquifier_dummy_balance = IDummyToken(BLAST.l1dummyToken).balanceOf(address(liquifierInstance));
        uint256 lockbox_balance = weEthInstance.balanceOf(address(l1OftAdapter));
        uint256 actualAmountOut = _sharesForDepositAmount(amountIn);

        _test_fast_sync(BLAST.l2Eid, BLAST.l2Oft, BLAST.l2SyncPool, BLAST.l1dummyToken, BLAST.l1Receiver, amountIn, amountOut);

        assertLt(amountOut, actualAmountOut);
        assertEq(address(liquifierInstance).balance, liquifier_eth_balance);
        assertEq(IDummyToken(BLAST.l1dummyToken).balanceOf(address(liquifierInstance)), liquifier_dummy_balance + amountIn);
        assertEq(weEthInstance.balanceOf(address(l1OftAdapter)), lockbox_balance + amountOut);
        
        _test_slow_sync(BLAST.l2Eid, BLAST.l1Receiver, amountIn);

        assertEq(address(liquifierInstance).balance, liquifier_eth_balance + amountIn);
        assertEq(IDummyToken(BLAST.l1dummyToken).balanceOf(address(liquifierInstance)), liquifier_dummy_balance);
        assertEq(weEthInstance.balanceOf(address(l1OftAdapter)), lockbox_balance + amountOut);
    }

    // Slow Sync with the ETH bridged down to the L1
    // - transfer the `amountIn` dummyETH
    function _test_slow_sync(uint32 l2Eid, address receiver, uint256 amountIn) internal { 
        vm.deal(receiver, amountIn);

        vm.prank(receiver);
        l1SyncPool.onMessageReceived{value: amountIn}(l2Eid, 0, ETH_ADDRESS, amountIn, 0);
    }

    // Fast Sync for native minting (input:`amountIn` ETH, output: `amountOut` weETH) at Layer 2 of Eid = `l2Eid`
    // - mint the `amountIn` amount of dummy token & transfer it to the Liquifier
    // - mint the <`amountIn` amount of eETH token & wrap it to weETH & transfer min(weETH balance, owed amount) to the lockbox (= L1 OFT Adapter)
    function _test_fast_sync(uint32 l2Eid, address l2Oft, address l2SyncPool, address l1dummyToken, address l1Receiver, uint256 amountIn, uint256 amountOut) internal {
        assertEq(address(l1SyncPool.getDummyToken(l2Eid)), l1dummyToken);
        assertEq(l1SyncPool.getReceiver(l2Eid), l1Receiver);

        IDummyToken dummyToken = IDummyToken(l1SyncPool.getDummyToken(l2Eid));

        bytes memory message = abi.encode(ETH_ADDRESS, amountIn, amountOut);

        vm.prank(address(l1Endpoint));
        l1SyncPool.lzReceive(Origin(l2Eid, _toBytes32(l2SyncPool), 0), 0, message, address(0), "");
    }

    function _sharesForDepositAmount(uint256 _depositAmount) internal view returns (uint256) {
        uint256 totalPooledEther = liquidityPoolInstance.getTotalPooledEther() - _depositAmount;
        if (totalPooledEther == 0) {
            return _depositAmount;
        }
        return (_depositAmount * eETHInstance.totalShares()) / totalPooledEther;
    }

    function _toBytes32(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }
}