
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/access/IAccessControlUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/token/ERC20/IERC20Upgradeable.sol";


import "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import "@layerzerolabs/lz-evm-oapp-v2/contracts-upgradeable/oapp/libs/OptionsBuilder.sol";
import "@layerzerolabs/lz-evm-oapp-v2/contracts-upgradeable/oapp/interfaces/IOAppOptionsType3.sol";
import "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/UlnBase.sol";
import "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/OFTAdapter.sol";


import {IOFT, SendParam, MessagingFee} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {IMintableERC20} from "../lib/Etherfi-SyncPools/contracts/interfaces/IMintableERC20.sol";
import {IAggregatorV3} from "../lib/Etherfi-SyncPools/contracts/etherfi/interfaces/IAggregatorV3.sol";
import {IL2ExchangeRateProvider} from "../lib/Etherfi-SyncPools/contracts/interfaces/IL2ExchangeRateProvider.sol";
import {IOAppCore} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppCore.sol";
import {IOAppReceiver} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppReceiver.sol";
import {EndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/EndpointV2.sol";
import { RateLimiter } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/utils/RateLimiter.sol";

import "./L2Constants.sol";

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

    /**
    * @dev Struct representing OFT receipt information.
    */
    struct OFTReceipt {
        uint256 amountSentLD; // Amount of tokens ACTUALLY debited from the sender in local decimals.
        // @dev In non-default implementations, the amountReceivedLD COULD differ from this value.
        uint256 amountReceivedLD; // Amount of tokens to be received on the remote side.
    }

    function MINTER_ROLE() external view returns (bytes32);
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
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
    function hasRole(bytes32 role, address account) external view returns (bool);

    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;

    function grantRole(bytes32 role, address account) external;
    function renounceRole(bytes32 role, address account) external;

}


contract NativeMintingConfigs is L2Constants {
    event L2Transaction(address to, uint256 value, bytes data);

    using OptionsBuilder for bytes;

    struct L2Params {
        uint256 minSyncAmount;
        uint256 target_briding_cap ;
        uint256 target_l2_to_l1_briding_cap;
        uint256 briding_cap_window;
        uint256 target_native_minting_cap;
        uint256 target_native_minting_refill_rate; // per second
        uint64 target_native_minting_fee; // 1e15 for 10 bps
    }

    L2Params prod = L2Params({
        minSyncAmount: 50 ether,
        target_briding_cap: 4_000 ether,
        target_l2_to_l1_briding_cap: 100 ether,
        briding_cap_window: 1 hours,
        target_native_minting_cap: 1_000 ether,
        target_native_minting_refill_rate: 1 ether,
        target_native_minting_fee: uint64(35 * 1e14)
    });

    L2Params standby = L2Params({
        minSyncAmount: 50 ether,
        target_briding_cap: 0.0001 ether,
        target_l2_to_l1_briding_cap: 0.0001 ether,
        briding_cap_window: 1 minutes,
        target_native_minting_cap: 0.0001 ether,
        target_native_minting_refill_rate: 1 ether,
        target_native_minting_fee: 0
    });

    L2Params standby_oftonly = L2Params({
        minSyncAmount: 0 ether,
        target_briding_cap: 0.0001 ether,
        target_l2_to_l1_briding_cap: 0.0001 ether,
        briding_cap_window: 4 hours,
        target_native_minting_cap: 0,
        target_native_minting_refill_rate: 0,
        target_native_minting_fee: 0
    });

    L2Params targetL2Params;

    ConfigPerL2[] l2s;
    ConfigPerL2[] bannedL2s;

    function _init() public {
        if (l2s.length != 0) return;
        l2s.push(BLAST);
        l2s.push(MODE);
        l2s.push(BNB);
        l2s.push(BASE);
        l2s.push(LINEA);
    }

    function _toBytes32(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }


    // Call in L1
    // - _setUpOApp(ethereum.oftToken, ETHEREUM.endpoint, ETHEREUM.send302, ETHEREUM.lzDvn, {L2s}.originEid);
    // ethereum.tokenIn = Constants.ETH_ADDRESS;
    // ethereum.tokenOut = EtherfiAddresses.weEth;
    // ethereum.liquifier = liquifier;
    // ethereum.oftToken = oftAdapter;
    // ethereum.syncPool = syncPool;
    // 
    // Call in L2 
    // - _setUpOApp(linea.tokenOut, LINEA.endpoint, LINEA.send302, LINEA.lzDvn, ETHEREUM.originEid);
    // - _setUpOApp(linea.syncPool, LINEA.endpoint, LINEA.send302, LINEA.lzDvn, ETHEREUM.originEid);
    // - _setUpOApp(linea.tokenOut, LINEA.endpoint, LINEA.send302, LINEA.lzDvn, {Other L2s}.originEid);
    // - _setUpOApp(linea.syncPool, LINEA.endpoint, LINEA.send302, LINEA.lzDvn, {Other L2s}.originEid);
    // linea.tokenIn = Constants.ETH_ADDRESS;
    // linea.tokenOut = oftToken;
    function _setUpOApp(
        address oApp,
        address originEndpoint,
        address originSend302,
        address originReceive302,
        address[2] memory originDvns,
        uint32 dstEid
    ) internal {
        bytes memory options1 = IOAppOptionsType3(oApp).combineOptions(dstEid, 1, "");
        bytes memory options2 = IOAppOptionsType3(oApp).combineOptions(dstEid, 2, "");
        
        if (options1.length == 0 || options2.length == 0) {
            EnforcedOptionParam[] memory enforcedOptions = new EnforcedOptionParam[](2);
            enforcedOptions[0] = EnforcedOptionParam({
                eid: dstEid,
                msgType: 1,
                options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(1_000_000, 0)
            });
            enforcedOptions[1] = EnforcedOptionParam({
                eid: dstEid,
                msgType: 2,
                options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(1_000_000, 0)
            });

            IOAppOptionsType3(oApp).setEnforcedOptions(enforcedOptions);
            emit L2Transaction(address(oApp), 0, abi.encodeWithSelector(IOAppOptionsType3(oApp).setEnforcedOptions.selector, enforcedOptions));
        } 

        _setUpOApp_setConfig(oApp, originEndpoint, originSend302, originReceive302, originDvns, dstEid);
    }

    function _setUpOApp_setConfig(
        address oApp,
        address originEndpoint,
        address originSend302,
        address originReceive302,
        address[2] memory originDvns,
        uint32 dstEid
    ) internal {
        SetConfigParam[] memory params = new SetConfigParam[](1);
        address[] memory requiredDVNs = new address[](2);
        requiredDVNs[0] = originDvns[0];
        requiredDVNs[1] = originDvns[1];

        UlnConfig memory ulnConfig = UlnConfig({
            confirmations: 64,
            requiredDVNCount: 2,
            optionalDVNCount: 0,
            optionalDVNThreshold: 0,
            requiredDVNs: requiredDVNs,
            optionalDVNs: new address[](0)
        });

        params[0] = SetConfigParam(dstEid, 2, abi.encode(ulnConfig));

        bytes memory configSend = ILayerZeroEndpointV2(originEndpoint).getConfig(oApp, originSend302, dstEid, 2);
        bytes memory configReceive = ILayerZeroEndpointV2(originEndpoint).getConfig(oApp, originReceive302, dstEid, 2);

        if (configSend.length == 0) {
            ILayerZeroEndpointV2(originEndpoint).setConfig(oApp, originSend302, params);
            emit L2Transaction(address(originEndpoint), 0, abi.encodeWithSelector(ILayerZeroEndpointV2(originEndpoint).setConfig.selector, oApp, originSend302, params));
        }
        
        if (configReceive.length == 0) {
            ILayerZeroEndpointV2(originEndpoint).setConfig(oApp, originReceive302, params);
            emit L2Transaction(address(originEndpoint), 0, abi.encodeWithSelector(ILayerZeroEndpointV2(originEndpoint).setConfig.selector, oApp, originReceive302, params));
        }
    }

    function _selector(bytes memory signature) internal pure returns (bytes4) {
        return bytes4(keccak256(signature));
    }
}