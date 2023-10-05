// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface IEtherFiAdmin {
    function numValidatorsToSpinUp() external view returns (uint32);
}
