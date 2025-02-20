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
    // @notice Tracks the last block number at which rewards were processed so delay can be provided
    mapping(address token => uint256 blockNumber) public lastProcessedAtBlock; 
    // @notice Tracks the last block number at which rewards were calculated so backend can know what the next start block is
    mapping(address token => uint256 blockNumber) public rewardsCalculatedToBlock;


    uint256 public constant CLAIM_DELAY = 7200; // 1 day to verify if processRewards was called with wrong amounts
    address public constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    bytes32 public constant REWARDS_MANAGER_ADMIN = keccak256("REWARD_MANAGER_ADMIN");
    RoleRegistry public immutable roleRegistry;

    /// @notice Constructor for RewardsManager contract
    /// @dev Initializes the contract with lastProcessedAtBlock for each token
    /// @param _tokens Array of token addresses to initialize
    /// @param _lastProcessedAtBlocks Array of block numbers corresponding to each token's last processed block
    /// @param _roleRegistry Address of the RoleRegistry contract for permission management
    constructor(address[] memory _tokens, uint256[] memory _lastProcessedAtBlocks, address _roleRegistry) {
        _disableInitializers();
        if (_tokens.length != _lastProcessedAtBlocks.length) {
            revert("Array lengths must match");
        }
        roleRegistry = RoleRegistry(_roleRegistry);
        for (uint256 i = 0; i < _tokens.length; i++) { // initialize lastProcessedAtBlock for each token
            lastProcessedAtBlock[_tokens[i]] = _lastProcessedAtBlocks[i];
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
    /// @param _blockNumber The block number of the last block rewards were distributed
    function processRewards(address _token, address[] calldata _recipients, uint256[] calldata _amounts, uint256 _blockNumber) external {
        if (_recipients.length != _amounts.length) {
            revert("Array lengths must match");
        }
        if (!roleRegistry.hasRole(REWARDS_MANAGER_ADMIN, msg.sender)) {
            revert("Caller must be admin");
        }
        if (lastProcessedAtBlock[_token] + CLAIM_DELAY > block.number) {
            revert("Claim delay not met");
        }
        if (_blockNumber <= rewardsCalculatedToBlock[_token] || _blockNumber > block.number)  {
            revert("Invalid block number");
        }

        lastProcessedAtBlock[_token] = block.number;
        rewardsCalculatedToBlock[_token] = _blockNumber;
        uint256 tokenBalance = IERC20(_token).balanceOf(address(this));
        for (uint256 i = 0; i < _recipients.length; i++) {
            totalClaimableRewards[_token][_recipients[i]] += totalPendingRewards[_token][_recipients[i]];
            totalPendingRewards[_token][_recipients[i]] = _amounts[i];
            totalRewardsToDistribute[_token] += _amounts[i];
        }
        if (totalRewardsToDistribute[_token] > tokenBalance) {
            revert("Insufficient balance");
        }
        emit RewardsAllocated(_token, _recipients, _amounts, _blockNumber);
    }
    
    /// @notice Claims rewards for the caller
    /// @dev Handles both ETH and ERC20 token distributions
    /// @param _token The address of the reward token being claimed
    function claimRewards(address _earner, address _token) external {
        
        address recipient = _earner;
        uint256 amountToClaim = totalClaimableRewards[_token][_earner];
        if(amountToClaim == 0) {
            revert("No rewards to claim");
        }
        if(earnerToRecipient[_earner] != address(0)) {
            recipient = earnerToRecipient[_earner];
        }
        totalClaimableRewards[_token][_earner] = 0;
        totalRewardsToDistribute[_token] -= amountToClaim;

        if(_token == ETH_ADDRESS) {
            totalClaimableRewards[_token][_earner] = 0;
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
        emit RewardsClaimed(_token, _earner, amountToClaim);
    }

    /// @notice Updates pending rewards when previous processRewards call contained incorrect amounts
    /// @dev This function should only be called to correct errors in a previous processRewards call
    ///      The block number and token address serve as a primary key for the RewardsAllocated event,
    ///      allowing frontends to identify which distribution is being corrected
    /// @dev All pending recipients must be provided, even if they have 0 rewards
    /// @param _token The address of the reward token to update
    /// @param _recipients Array of addresses whose rewards need correction
    /// @param _amounts Array of corrected reward amounts for each recipient
    /// @param _blockNumber The block number of the last block rewards were distributed
    function updatePendingRewards(address _token, address[] calldata _recipients, uint256[] calldata _amounts, uint256 _blockNumber) external {
        if (!roleRegistry.hasRole(REWARDS_MANAGER_ADMIN, msg.sender)) {
            revert("Caller must be admin");
        }
        if (_recipients.length != _amounts.length) {
            revert("Array lengths must match");
        }
        if (_blockNumber <= rewardsCalculatedToBlock[_token] || _blockNumber > block.number)  {
            revert("Invalid block number");
        }
        uint256 incorrectRewardsCalculatedToBlock = rewardsCalculatedToBlock[_token];
        uint256 tokenBalance = IERC20(_token).balanceOf(address(this));
        lastProcessedAtBlock[_token] = block.number;
        rewardsCalculatedToBlock[_token] = _blockNumber;
        for (uint256 i = 0; i < _recipients.length; i++) {
            totalRewardsToDistribute[_token] = totalRewardsToDistribute[_token] - totalPendingRewards[_token][_recipients[i]] + _amounts[i];
            totalPendingRewards[_token][_recipients[i]] = _amounts[i];
        }
        if (totalRewardsToDistribute[_token] > tokenBalance) {
            revert("Insufficient balance");
        }
        emit RewardsReverted(incorrectRewardsCalculatedToBlock);
        emit RewardsAllocated(_token, _recipients, _amounts, block.number);

    }

    function getImplementation() external view returns (address) {return _getImplementation();}

    function _authorizeUpgrade(address newImplementation) internal override {
        roleRegistry.onlyProtocolUpgrader(msg.sender);
    }
}
