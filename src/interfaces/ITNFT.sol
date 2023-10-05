// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "@openzeppelin-upgradeable/contracts/token/ERC721/IERC721Upgradeable.sol";

interface ITNFT is IERC721Upgradeable {
    function initialize() external;

    function mint(address _receiver, uint256 _validatorId) external;

    function upgradeTo(address _newImplementation) external;
}
