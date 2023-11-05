// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface IEtherFiAdmin {
    function lastHandledReportRefSlot() external view returns (uint32);
    function lastHandledReportRefBlock() external view returns (uint32);
    function numValidatorsToSpinUp() external view returns (uint32);
}
