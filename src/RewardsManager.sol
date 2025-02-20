// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRewardsManager} from "./interfaces/IRewardsManager.sol";

import {RoleRegistry} from "./RoleRegistry.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @title RewardsManager
/// @notice Manages the distribution and claiming of rewards for the EtherFi protocol
/// @dev Implements reward distribution logic for both ETH and ERC20 tokens
contract RewardsManager is IRewardsManager, OwnableUpgradeable, UUPSUpgradeable {

    mapping (address token => mapping(address earner => uint256 amount)) public totalClaimableRewards; 
    /// @notice Tracks the total pending rewards for each token and recipient claimable next time claimRewards is called
    mapping(address token => mapping(address earner => uint256 amount)) public totalPendingRewards; 
    mapping(address token => uint256 amount) public totalRewardsToDistribute;
    mapping(address earner => address recipient) public earnerToRecipient; 
    mapping(address token => uint256 blockNumber) public lastProcessedBlock; 


    uint256 public constant CLAIM_DELAY = 7200; // 1 day to verify if processRewards was called with wrong amounts
    address public constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    bytes32 public constant REWARDS_MANAGER_ADMIN = keccak256("REWARD_MANAGER_ADMIN");
    RoleRegistry public immutable roleRegistry;

    /// @notice Constructor for RewardsManager contract
    /// @dev Initializes the contract with lastProcessedBlock for each token
    /// @param _tokens Array of token addresses to initialize
    /// @param _lastProcessedBlocks Array of block numbers corresponding to each token's last processed block
    /// @param _roleRegistry Address of the RoleRegistry contract for permission management
    constructor(address[] memory _tokens, uint256[] memory _lastProcessedBlocks, address _roleRegistry) {
        _disableInitializers();
        if (_tokens.length != _lastProcessedBlocks.length) {
            revert("Array lengths must match");
        }
        roleRegistry = RoleRegistry(_roleRegistry);
        for (uint256 i = 0; i < _tokens.length; i++) { // initialize lastProcessedBlock for each token
            lastProcessedBlock[_tokens[i]] = _lastProcessedBlocks[i];
        }
    }

    function initialize() external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
    }
    /// @notice Updates the recipient address for a specific earner's rewards
    /// @dev Can be called by either the earner themselves or a rewards manager admin
    /// @param _earner The address of the rewards earner
    /// @param _recipient The new address to receive the earner's rewards
    function updateRewardsRecipient(address _earner, address _recipient) external {
        if(!roleRegistry.hasRole(REWARDS_MANAGER_ADMIN, msg.sender) && msg.sender != _earner) {
            revert IncorrectRole();
        }
        if (_earner == _recipient || _recipient == address(0)) {
            revert("Invalid recipient");
        }
        earnerToRecipient[_earner] = _recipient;
        emit RewardsRecipientUpdated(_earner, _recipient);
    }

    /// @notice Process and allocate rewards for multiple recipients
    /// @dev Moves current pending rewards to claimable and sets new pending amounts.
    ///      When removing a recipient, their entry in the next processRewards call
    ///      should have amount = 0 to properly move their pending rewards to claimable.
    /// 
    /// @param _token The address of the reward token being distributed
    /// @param _recipients Array of addresses to receive rewards
    /// @param _amounts Array of reward amounts corresponding to each recipient
    function processRewards(address _token, address[] calldata _recipients, uint256[] calldata _amounts) external {
        if (_recipients.length != _amounts.length) {
            revert("Array lengths must match");
        }
        if (!roleRegistry.hasRole(REWARDS_MANAGER_ADMIN, msg.sender)) {
            revert("Caller must be admin");
        }
        if (lastProcessedBlock[_token] + CLAIM_DELAY > block.number) {
            revert("Claim delay not met");
        }

        lastProcessedBlock[_token] = block.number;
        uint256 tokenBalance = IERC20(_token).balanceOf(address(this));
        for (uint256 i = 0; i < _recipients.length; i++) {
            totalClaimableRewards[_token][_recipients[i]] += totalPendingRewards[_token][_recipients[i]];
            totalPendingRewards[_token][_recipients[i]] = _amounts[i];
            totalRewardsToDistribute[_token] += _amounts[i];
        }
        if (totalRewardsToDistribute[_token] > tokenBalance) {
            revert("Insufficient balance");
        }
        emit RewardsAllocated(_token, _recipients, _amounts, block.number);
    }
    
    /// @notice Claims rewards for the caller
    /// @dev Handles both ETH and ERC20 token distributions
    /// @param _token The address of the reward token being claimed
    function claimRewards(address _token) external {
        address recipient = msg.sender;
        uint256 amountToClaim = totalClaimableRewards[_token][msg.sender];
        if(amountToClaim == 0) {
            revert("No rewards to claim");
        }
        if(earnerToRecipient[msg.sender] != address(0)) {
            recipient = earnerToRecipient[msg.sender];
        }
        totalClaimableRewards[_token][msg.sender] = 0;
        totalRewardsToDistribute[_token] -= amountToClaim;

        if(_token == ETH_ADDRESS) {
            totalClaimableRewards[_token][msg.sender] = 0;
            (bool success, ) = recipient.call{value: amountToClaim}("");
            if(!success) {
                revert("ETH Transfer failed");
            }
        } else { //erc20
            bool success = IERC20(_token).transfer(recipient, amountToClaim);
            if(!success) {
                revert("ERC20 Transfer failed");
            }
        }
        emit RewardsClaimed(_token, msg.sender, totalClaimableRewards[_token][msg.sender]);
    }

    /// @notice Updates pending rewards when previous processRewards call contained incorrect amounts
    /// @dev This function should only be called to correct errors in a previous processRewards call
    ///      The block number and token address serve as a primary key for the RewardsAllocated event,
    ///      allowing frontends to identify which distribution is being corrected
    /// 
    /// @param _token The address of the reward token to update
    /// @param _recipients Array of addresses whose rewards need correction
    /// @param _amounts Array of corrected reward amounts for each recipient
    function updatePendingRewards(address _token, address[] calldata _recipients, uint256[] calldata _amounts) external {
        if (!roleRegistry.hasRole(REWARDS_MANAGER_ADMIN, msg.sender)) {
            revert("Caller must be admin");
        }
        if (_recipients.length != _amounts.length) {
            revert("Array lengths must match");
        }
        uint256 incorrectDistributionBlock = lastProcessedBlock[_token];
        uint256 tokenBalance = IERC20(_token).balanceOf(address(this));
        lastProcessedBlock[_token] = block.number;
        for (uint256 i = 0; i < _recipients.length; i++) {
            totalRewardsToDistribute[_token] = totalRewardsToDistribute[_token] - totalPendingRewards[_token][_recipients[i]] + _amounts[i];
            totalPendingRewards[_token][_recipients[i]] = _amounts[i];
        }
        if (totalRewardsToDistribute[_token] > tokenBalance) {
            revert("Insufficient balance");
        }
        emit RewardsReverted(incorrectDistributionBlock);
        emit RewardsAllocated(_token, _recipients, _amounts, block.number);

    }

    function getImplementation() external view returns (address) {return _getImplementation();}

    function _authorizeUpgrade(address newImplementation) internal override {
        roleRegistry.onlyProtocolUpgrader(msg.sender);
    }
}
