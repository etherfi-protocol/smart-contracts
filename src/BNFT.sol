// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "@openzeppelin-upgradeable/contracts/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";

contract BNFT is ERC721Upgradeable, UUPSUpgradeable, OwnableUpgradeable {
    //--------------------------------------------------------------------------------------
    //---------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------

    address public stakingManagerAddress;
    address public etherFiNodesManagerAddress;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  STATE-CHANGING FUNCTIONS  ------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice initialize to set variables on deployment
    function initialize(address _stakingManagerAddress) initializer external {
        require(_stakingManagerAddress != address(0), "No zero addresses");
        __ERC721_init("Bond NFT", "BNFT");
        __Ownable_init();
        __UUPSUpgradeable_init();

        stakingManagerAddress = _stakingManagerAddress;
    }

    /// @notice initialization function that should be called after phase 2.0 contract upgrade
    function initializeOnUpgrade(address _etherFiNodesManagerAddress) onlyOwner external {
        require(_etherFiNodesManagerAddress != address(0), "Cannot initialize to zero address");

        etherFiNodesManagerAddress = _etherFiNodesManagerAddress;
    }

    /// @notice Mints NFT to required user
    /// @dev Only through the staking contract and not by an EOA
    /// @param _receiver receiver of the NFT
    /// @param _validatorId the ID of the NFT
    function mint(address _receiver, uint256 _validatorId) external onlyStakingManager {
        _mint(_receiver, _validatorId);
    }

    /// @notice burn the associated bNFT when a full withdrawal is processed
    function burnFromWithdrawal(uint256 _validatorId) external onlyEtherFiNodesManager {
        _burn(_validatorId);
    }

    /// @notice burn the associated one
    function burnFromCancelBNftFlow(uint256 _validatorId) external onlyStakingManager {
        _burn(_validatorId);
    }

    //ERC721 function being overridden to make it soulbound
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256, // firstTokenId
        uint256  // batchSize
    ) internal virtual override(ERC721Upgradeable ){
        // only allow mint or burn
        require(from == address(0) || to == address(0), "Err: token is SOUL BOUND");
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------  INTERNAL FUNCTIONS   --------------------------------
    //--------------------------------------------------------------------------------------

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

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
