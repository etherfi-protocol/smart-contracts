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

    IEtherfiL1SyncPoolETH l1SyncPool;

    address l1OftAdapter = 0xFE7fe01F8B9A76803aF3750144C2715D9bcf7D0D;
    address l1Endpoint = 0x1a44076050125825900e736c501f859c50fE728c;

    function setUp() public {
        initializeRealisticFork(MAINNET_FORK);

        l1SyncPool = IEtherfiL1SyncPoolETH(0xD789870beA40D056A4d26055d0bEFcC8755DA146);
        l1OftAdapter = 0x361a67a81A4694612004fA79E23EA8e307d10289;

        _perform_etherfi_upgrade();
    }


    function test_sanity_check() public {
        assertEq(l1SyncPool.getLiquifier(), address(liquifierInstance));
        assertEq(l1SyncPool.getEEth(), address(eETHInstance));
        assertEq(liquifierInstance.l1SyncPool(), address(l1SyncPool));
    }

    function test_lzReceive_1() public {
        uint32 l2Eid = 30243; // BLAST
        address l2Oft = 0x04C0599Ae5A44757c0af6F9eC3b93da8976c150A;
        address l2SyncPool = 0x52c4221Cb805479954CDE5accfF8C4DcaF96623B;
        address l1dummyToken = 0x83998e169026136760bE6AF93e776C2F352D4b28;
        address l1Receiver = 0x27e120C518a339c3d8b665E56c4503DF785985c2;
        
        assertEq(address(l1SyncPool.getDummyToken(l2Eid)), l1dummyToken);
        assertEq(l1SyncPool.getReceiver(l2Eid), l1Receiver);
        assertEq(l1SyncPool.endpoint(), l1Endpoint);

        IDummyToken dummyToken = IDummyToken(l1SyncPool.getDummyToken(l2Eid));

        vm.prank(liquifierInstance.owner());
        liquifierInstance.registerToken(address(dummyToken), address(0), true, 0, 1, 1, true);
        // liquifierInstance.registerToken(address(dummyToken), address(0), true, 0, 50, 1000, true);

        uint256 amountIn = 1e18;
        uint256 amountOut = 0.9e18;
        address ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        bytes memory message = abi.encode(ETH_ADDRESS, amountIn, amountOut);

        ILayerZeroEndpointV2 endpoint = ILayerZeroEndpointV2(address(l1SyncPool.endpoint()));

        vm.prank(address(endpoint));
        l1SyncPool.lzReceive(Origin(l2Eid, _toBytes32(l2SyncPool), 0), 0, message, address(0), "");

    }

    function _toBytes32(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }
}