// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface IRegulationsManager {
    function initialize() external;

    function confirmEligibility(bytes32 hash) external;

    function removeFromWhitelist(address _user) external;

    function initializeNewWhitelist(bytes32 _newVersionHash) external;

    function isEligible(uint32 _whitelistVersion, address _user) external view returns (bool);

    function whitelistVersion() external view returns (uint32);

}
