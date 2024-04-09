// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OwnableUpgradeable} from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OAppReceiverUpgradeable, OAppCoreUpgradeable} from "@layerzerolabs/lz-evm-oapp-v2/contracts-upgradeable/oapp/OAppReceiverUpgradeable.sol";
import {Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import {IL1SyncPool} from "./interfaces/IL1SyncPool.sol";
import {Constants} from "../lib/Constants.sol";

/**
 * @title L1 Base Sync Pool
 * @dev Base contract for L1 Sync Pools
 * A sync pool is an OApp that allows users to deposit tokens on Layer 2, and then sync them to Layer 1
 * using the LayerZero messaging protocol.
 * The L1 sync pool takes care of the actual syncing process, it receives different messages from L2s
 * and handles the anticipated deposits and the actual deposits.
 * The L1 sync pool is responsible for managing the lock box making sure it is backed by the correct amount of tokens.
 * Fast messages are used to anticipate the deposit, and slow messages are used to finalize the deposit.
 * For example, a user can deposit 100 ETH on L2, the L2 sync pool will send a fast message to the L1 sync pool
 * anticipating the actual 100 ETH deposit (as it takes ~7 days to finalize the deposit), and finalize the deposit
 * when the 100 ETH is actually received from the L2.
 */
abstract contract L1BaseSyncPoolUpgradeable is OAppReceiverUpgradeable, ReentrancyGuardUpgradeable, IL1SyncPool {
    struct L1BaseSyncPoolStorage {
        IERC20 tokenOut;
        address lockBox;
        uint256 totalUnbackedTokens;
        mapping(uint32 => address) receivers;
    }

    // keccak256(abi.encode(uint256(keccak256(syncpools.storage.l1basesyncpool)) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant L1BaseSyncPoolStorageLocation =
        0xd96cd964f71a052084af61290ff53294a8f76de4d8f66ba7682fe6598635ef00;

    function _getL1BaseSyncPoolStorage() internal pure returns (L1BaseSyncPoolStorage storage $) {
        assembly {
            $.slot := L1BaseSyncPoolStorageLocation
        }
    }

    error L1BaseSyncPool__UnauthorizedCaller();
    error L1BaseSyncPool__NativeTransferFailed();

    event ReceiverSet(uint32 indexed originEid, address receiver);
    event TokenOutSet(address tokenOut);
    event LockBoxSet(address lockBox);
    event InsufficientDeposit(
        uint32 indexed originEid,
        bytes32 guid,
        uint256 actualAmountOut,
        uint256 expectedAmountOut,
        uint256 unbackedTokens
    );
    event Fee(uint32 indexed originEid, bytes32 guid, uint256 actualAmountOut, uint256 expectedAmountOut, uint256 fee);
    event Sweep(address token, address receiver, uint256 amount);

    /**
     * @dev Constructor for L1 Base Sync Pool
     * @param endpoint Address of the LayerZero endpoint
     */
    constructor(address endpoint) OAppCoreUpgradeable(endpoint) {}

    function __L1BaseSyncPool_init(address tokenOut, address lockBox, address delegate) internal onlyInitializing {
        __OAppCore_init(delegate);
        __L1BaseSyncPool_init_unchained(tokenOut, lockBox);
    }

    function __L1BaseSyncPool_init_unchained(address tokenOut, address lockBox) internal onlyInitializing {
        _setTokenOut(tokenOut);
        _setLockBox(lockBox);
    }

    /**
     * @dev Get the main token address
     * @return The main token address
     */
    function getTokenOut() public view virtual returns (address) {
        L1BaseSyncPoolStorage storage $ = _getL1BaseSyncPoolStorage();
        return address($.tokenOut);
    }

    /**
     * @dev Get the lock box address
     * @return The lock box address
     */
    function getLockBox() public view virtual returns (address) {
        L1BaseSyncPoolStorage storage $ = _getL1BaseSyncPoolStorage();
        return $.lockBox;
    }

    /**
     * @dev Get the receiver address for a specific origin EID
     * @param originEid Origin EID
     * @return The receiver address
     */
    function getReceiver(uint32 originEid) public view virtual returns (address) {
        L1BaseSyncPoolStorage storage $ = _getL1BaseSyncPoolStorage();
        return $.receivers[originEid];
    }

    /**
     * @dev Get the total unbacked tokens
     * @return The total unbacked tokens
     */
    function getTotalUnbackedTokens() public view virtual returns (uint256) {
        L1BaseSyncPoolStorage storage $ = _getL1BaseSyncPoolStorage();
        return $.totalUnbackedTokens;
    }

    /**
     * @dev Receive a message from an L2
     * Will revert if:
     * - The caller is not the receiver
     * @param originEid Origin EID
     * @param guid Message GUID
     * @param tokenIn Token address
     * @param amountIn Amount in
     * @param amountOut Amount out
     */
    function onMessageReceived(uint32 originEid, bytes32 guid, address tokenIn, uint256 amountIn, uint256 amountOut)
        public
        payable
        override
        nonReentrant
    {
        L1BaseSyncPoolStorage storage $ = _getL1BaseSyncPoolStorage();

        if (msg.sender != $.receivers[originEid]) revert L1BaseSyncPool__UnauthorizedCaller();

        _finalizeDeposit(originEid, guid, tokenIn, amountIn, amountOut);
    }

    /**
     * @dev Receive a message from LayerZero
     * Overriden to add reentrancy guard
     * @param origin Origin
     * @param guid Message GUID
     * @param message Message
     * @param executor Executor
     * @param extraData Extra data
     */
    function lzReceive(
        Origin calldata origin,
        bytes32 guid,
        bytes calldata message,
        address executor,
        bytes calldata extraData
    ) public payable virtual override nonReentrant {
        super.lzReceive(origin, guid, message, executor, extraData);
    }

    /**
     * @dev Set the main token address
     * @param tokenOut Address of the main token
     */
    function setTokenOut(address tokenOut) public virtual onlyOwner {
        _setTokenOut(tokenOut);
    }

    /**
     * @dev Set the lock box address
     * @param lockBox Address of the lock box
     */
    function setLockBox(address lockBox) public virtual onlyOwner {
        _setLockBox(lockBox);
    }

    /**
     * @dev Set the receiver address for a specific origin EID
     * @param originEid Origin EID
     * @param receiver Receiver address
     */
    function setReceiver(uint32 originEid, address receiver) public virtual onlyOwner {
        _setReceiver(originEid, receiver);
    }

    /**
     * @dev Sweep tokens from the contract
     * @param token Token address
     * @param receiver Receiver address
     * @param amount Amount to sweep
     */
    function sweep(address token, address receiver, uint256 amount) public virtual onlyOwner {
        if (token == Constants.ETH_ADDRESS) {
            (bool success,) = receiver.call{value: amount}("");
            if (!success) revert L1BaseSyncPool__NativeTransferFailed();
        } else {
            SafeERC20.safeTransfer(IERC20(token), receiver, amount);
        }

        emit Sweep(token, receiver, amount);
    }

    /**
     * @dev Internal function called when a LZ message is received
     * @param origin Origin
     * @param guid Message GUID
     * @param message Message
     */
    function _lzReceive(Origin calldata origin, bytes32 guid, bytes calldata message, address, bytes calldata)
        internal
        virtual
        override
    {
        (address tokenIn, uint256 amountIn, uint256 amountOut) = abi.decode(message, (address, uint256, uint256));

        uint256 actualAmountOut = _anticipatedDeposit(origin.srcEid, guid, tokenIn, amountIn, amountOut);

        _handleAnticipatedDeposit(origin.srcEid, guid, actualAmountOut, amountOut);
    }

    /**
     * @dev Internal function to set the main token address
     * @param tokenOut Address of the main token
     */
    function _setTokenOut(address tokenOut) internal virtual {
        L1BaseSyncPoolStorage storage $ = _getL1BaseSyncPoolStorage();
        $.tokenOut = IERC20(tokenOut);

        emit TokenOutSet(tokenOut);
    }

    /**
     * @dev Internal function to set the receiver address for a specific origin EID
     * @param originEid Origin EID
     * @param receiver Receiver address
     */
    function _setReceiver(uint32 originEid, address receiver) internal virtual {
        L1BaseSyncPoolStorage storage $ = _getL1BaseSyncPoolStorage();
        $.receivers[originEid] = receiver;

        emit ReceiverSet(originEid, receiver);
    }

    /**
     * @dev Internal function to set the lock box address
     * @param lockBox Address of the lock box
     */
    function _setLockBox(address lockBox) internal virtual {
        L1BaseSyncPoolStorage storage $ = _getL1BaseSyncPoolStorage();
        $.lockBox = lockBox;

        emit LockBoxSet(lockBox);
    }

    /**
     * @dev Internal function to handle an anticipated deposit
     * Will emit an InsufficientDeposit event if the actual amount out is less than the expected amount out
     * Will emit a Fee event if the actual amount out is equal or greater than the expected amount out
     * The fee kept in this contract will be used to back any future insufficient deposits
     * When the fee is used, the total unbacked tokens will be lower than the actual missing amount
     * Any time the InsufficientDeposit event is emitted, necessary actions should be taken to back the lock box
     * such as using POL, increasing the deposit fee on the faulty L2, etc.
     * @param originEid Origin EID
     * @param guid Message GUID
     * @param actualAmountOut Actual amount out
     * @param expectedAmountOut Expected amount out
     */
    function _handleAnticipatedDeposit(
        uint32 originEid,
        bytes32 guid,
        uint256 actualAmountOut,
        uint256 expectedAmountOut
    ) internal virtual {
        L1BaseSyncPoolStorage storage $ = _getL1BaseSyncPoolStorage();

        IERC20 tokenOut = $.tokenOut;

        uint256 totalUnbackedTokens = $.totalUnbackedTokens;
        uint256 balance = tokenOut.balanceOf(address(this));

        uint256 totalAmountOut = expectedAmountOut + totalUnbackedTokens;
        uint256 amountToSend;

        if (balance < totalAmountOut) {
            amountToSend = balance;

            $.totalUnbackedTokens = totalAmountOut - balance;
        } else {
            amountToSend = totalAmountOut;

            if (totalUnbackedTokens > 0) $.totalUnbackedTokens = 0;
        }

        if (actualAmountOut < expectedAmountOut) {
            uint256 unbackedTokens = expectedAmountOut - actualAmountOut;
            emit InsufficientDeposit(originEid, guid, actualAmountOut, expectedAmountOut, unbackedTokens);
        } else {
            uint256 fee = actualAmountOut - expectedAmountOut;
            emit Fee(originEid, guid, actualAmountOut, expectedAmountOut, fee);
        }

        SafeERC20.safeTransfer(tokenOut, $.lockBox, amountToSend);
    }

    event Log(string message, uint256 value);

    /**
     * @dev Internal function to anticipate a deposit
     * @param originEid Origin EID
     * @param guid Message GUID
     * @param tokenIn Token address
     * @param amountIn Amount in
     * @param amountOut Amount out
     * @return actualAmountOut Actual amount out
     */
    function _anticipatedDeposit(uint32 originEid, bytes32 guid, address tokenIn, uint256 amountIn, uint256 amountOut)
        internal
        virtual
        returns (uint256 actualAmountOut);

    /**
     * @dev Internal function to finalize a deposit
     * @param originEid Origin EID
     * @param guid Message GUID (will match the one used in the anticipated deposit)
     * @param tokenIn Token address
     * @param amountIn Amount in
     * @param amountOut Amount out
     */
    function _finalizeDeposit(uint32 originEid, bytes32 guid, address tokenIn, uint256 amountIn, uint256 amountOut)
        internal
        virtual;
}