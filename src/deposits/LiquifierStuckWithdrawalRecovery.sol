/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@etherfi/deposits/Liquifier.sol";
import {IDelegationManager} from "@etherfi/interfaces/eigenlayer-interfaces/IDelegationManager.sol";

/// @title LiquifierStuckWithdrawalRecovery
/// @notice One-shot Liquifier implementation that completes EigenLayer withdrawals naming the
///         Liquifier as withdrawer, which only the Liquifier can complete. EigenLayer pays the
///         tokens to each withdrawal's staker, so the Liquifier never holds them.
/// @dev Adds no storage. The upgrade timelock runs `upgradeToAndCall(this, recoverStuckWithdrawals)`
///      and then `upgradeTo(previousImplementation)` in one batch, so the proxy ends on the
///      implementation it started on.
contract LiquifierStuckWithdrawalRecovery is Liquifier {
    IDelegationManager public constant DELEGATION_MANAGER =
        IDelegationManager(0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A);

    event StuckWithdrawalRecovered(bytes32 indexed withdrawalRoot, address indexed staker);

    error LiquifierOwnedWithdrawal();
    error LengthMismatch();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        ConstructorAddresses memory _constructorAddresses,
        uint256 _minDiscountInBasisPoints,
        uint256 _stalePriceWindow,
        uint256 _maxPriceDeviationInBps,
        uint256 _maxPriceThreshold
    ) Liquifier(_constructorAddresses, _minDiscountInBasisPoints, _stalePriceWindow, _maxPriceDeviationInBps, _maxPriceThreshold) {}

    /// @notice Completes user withdrawals queued with the Liquifier as withdrawer, paying each staker in tokens.
    /// @param _withdrawals The withdrawals exactly as stored by the DelegationManager.
    /// @param _tokens The underlying token of each strategy, per withdrawal.
    function recoverStuckWithdrawals(IDelegationManager.Withdrawal[] calldata _withdrawals, IERC20[][] calldata _tokens)
        external
        onlyUpgradeTimelock
    {
        uint256 count = _withdrawals.length;
        if (count != _tokens.length) revert LengthMismatch();

        bool[] memory receiveAsTokens = new bool[](count);
        for (uint256 i = 0; i < count; i++) {
            if (_withdrawals[i].staker == address(this)) revert LiquifierOwnedWithdrawal();
            receiveAsTokens[i] = true;
            emit StuckWithdrawalRecovered(DELEGATION_MANAGER.calculateWithdrawalRoot(_withdrawals[i]), _withdrawals[i].staker);
        }

        DELEGATION_MANAGER.completeQueuedWithdrawals(_withdrawals, _tokens, receiveAsTokens);
    }
}
