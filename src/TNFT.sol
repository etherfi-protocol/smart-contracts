// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/token/ERC721/ERC721Upgradeable.sol";

import "./interfaces/IEtherFiNodesManager.sol";

contract TNFT is ERC721Upgradeable, UUPSUpgradeable, OwnableUpgradeable {
    //--------------------------------------------------------------------------------------
    //---------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------
    address public stakingManagerAddress;
    address public etherFiNodesManagerAddress;

    //--------------------------------------------------------------------------------------
    //----------------------------  STATE-CHANGING FUNCTIONS  ------------------------------
    //--------------------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice initialize to set variables on deployment
    function initialize(address _stakingManagerAddress) external initializer {
        require(_stakingManagerAddress != address(0), "No zero addresses");

        __ERC721_init("Transferrable NFT", "TNFT");
        __Ownable_init();
        __UUPSUpgradeable_init();

        stakingManagerAddress = _stakingManagerAddress;
    }

    /// @notice initialization function that should be called after phase 2.0 contract upgrade
    function initializeOnUpgrade(address _etherFiNodesManagerAddress) external onlyOwner {
        require(_etherFiNodesManagerAddress != address(0), "Cannot initialize to zero address");

        etherFiNodesManagerAddress = _etherFiNodesManagerAddress;
    }

    /// @notice Mints NFT to required user
    /// @dev Only through the staking contract and not by an EOA
    /// @param _receiver Receiver of the NFT
    /// @param _validatorId The ID of the NFT
    function mint(address _receiver, uint256 _validatorId) external onlyStakingManager {
        _mint(_receiver, _validatorId);
    }

    /// @notice burn the associated tNFT when a full withdrawal is processed
    function burnFromWithdrawal(uint256 _validatorId) external onlyEtherFiNodesManager {
        _burn(_validatorId);
    }

    /// @notice burn the associated one
    function burnFromCancelBNftFlow(uint256 _validatorId) external onlyStakingManager {
        _burn(_validatorId);
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------  INTERNAL FUNCTIONS   --------------------------------
    //--------------------------------------------------------------------------------------

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    //--------------------------------------------------------------------------------------
    //--------------------------------------  GETTER  --------------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Fetches the address of the implementation contract currently being used by the proxy
    /// @return the address of the currently used implementation contract
    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    //--------------------------------------------------------------------------------------
    //------------------------------------  MODIFIERS  -------------------------------------
    //--------------------------------------------------------------------------------------

    modifier onlyStakingManager() {
        require(msg.sender == stakingManagerAddress, "Only staking manager contract");
        _;
    }

    modifier onlyEtherFiNodesManager() {
        require(msg.sender == etherFiNodesManagerAddress, "Only etherFiNodesManager contract");
        _;
    }
}
