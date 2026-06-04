// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {AssetRecovery} from "@etherfi/utils/AssetRecovery.sol";
import {PausableUntil} from "@etherfi/governance/utils/PausableUntil.sol";
import {RolesLibrary} from "@etherfi/governance/utils/RolesLibrary.sol";
import {DeprecatedOZOwnable} from "@etherfi/governance/utils/DeprecatedOZOwnable.sol";
import {DeprecatedOZPausable} from "@etherfi/governance/utils/DeprecatedOZPausable.sol";
import {ICumulativeMerkleRewardsDistributor}  from "@etherfi/rewards/interfaces/ICumulativeMerkleRewardsDistributor.sol";

contract CumulativeMerkleRewardsDistributor is ICumulativeMerkleRewardsDistributor, DeprecatedOZOwnable, DeprecatedOZPausable, UUPSUpgradeable, PausableUntil, AssetRecovery {
    using SafeERC20 for IERC20;

    //--------------------------------------------------------------------------------------
    //---------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------
    mapping(address token => uint256 timestamp) public lastPendingMerkleUpdatedToTimestamp;
    mapping(address token => uint256 blockNo) public lastRewardsCalculatedToBlock;
    mapping(address token => bytes32 merkleRoot) public claimableMerkleRoots;
    mapping(address token => bytes32 merkleRoot) public pendingMerkleRoots;
    mapping(address token => mapping(address user => uint256 cumulativeBalance)) public cumulativeClaimed;
    mapping(address user => bool isWhitelisted) public whitelistedRecipient;

    uint256 public claimDelay;
    // deprecated storage slot — pause state migrated to the namespaced {Pausable} storage
    uint8 private __gap_0;

    //--------------------------------------------------------------------------------------
    //-------------------------------------  CONSTANTS  -------------------------------------
    //--------------------------------------------------------------------------------------
    address public constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    //--------------------------------------------------------------------------------------
    //----------------------------  STATE-CHANGING FUNCTIONS  ------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Constructor
     * @param _roleRegistry The address of the role registry
     */
    constructor(address _roleRegistry) RolesLibrary(_roleRegistry) {
        _disableInitializers();
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  INITIALIZERS  ------------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Initialize the CumulativeMerkleRewardsDistributor
     */
    function initialize() external initializer {
        __UUPSUpgradeable_init();
        claimDelay = 2 days; // 48 hours
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  RECEIVE FUNCTIONS  -------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Receive ETH
     */
    receive() external payable {}

    //--------------------------------------------------------------------------------------
    //-------------------------------  ADMIN FUNCTIONS  ------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Set the claim delay
     * @param _claimDelay The claim delay
     */
    function setClaimDelay(uint256 _claimDelay) external onlyAdmin {
        claimDelay = _claimDelay;
        emit ClaimDelayUpdated(claimDelay);
    }

    /**
     * @notice Update the whitelisted recipient
     * @param user The address of the recipient
     * @param isWhitelisted The boolean value indicating if the recipient is whitelisted
     */
    function updateWhitelistedRecipient(address user, bool isWhitelisted) external onlyAdmin {
        whitelistedRecipient[user] = isWhitelisted;
        emit RecipientStatusUpdated(user, isWhitelisted);
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------  OPERATIONAL FUNCTIONS  ------------------------------
    //--------------------------------------------------------------------------------------
    /**
    * @notice Sets a new pending Merkle root for token rewards distribution
    * @dev Only callable by accounts with EXECUTOR_OPERATIONS_ROLE role
    * @dev The pending root must be finalized after CLAIM_DELAY blocks before it becomes active
    * @param _token Address of the reward token (use ETH_ADDRESS for ETH rewards)
    * @param _merkleRoot New Merkle root containing the reward data
    */
    function setPendingMerkleRoot(address _token, bytes32 _merkleRoot) external whenNotPaused onlyExecutorOperations {
        pendingMerkleRoots[_token] = _merkleRoot;
        lastPendingMerkleUpdatedToTimestamp[_token] = block.timestamp;
        emit PendingMerkleRootUpdated(_token, _merkleRoot);
    }

    /**
    * @notice Finalizes a pending Merkle root after the required delay period
    * @dev Only callable by accounts with EXECUTOR_OPERATIONS_ROLE role
    * @dev Must wait CLAIM_DELAY blocks after setPendingMerkleRoot before finalizing
    * @param _token Address of the reward token (use ETH_ADDRESS for ETH rewards)
    * @param _finalizedBlock Block number up to which rewards are calculated
    */
    function finalizeMerkleRoot(address _token, uint256 _finalizedBlock) external whenNotPaused onlyExecutorOperations {
        if(!(block.timestamp >= lastPendingMerkleUpdatedToTimestamp[_token] + claimDelay)) revert InsufficentDelay();
        if(_finalizedBlock < lastRewardsCalculatedToBlock[_token] || _finalizedBlock > block.number) revert InvalidFinalizedBlock();
        bytes32 oldClaimableMerkleRoot = claimableMerkleRoots[_token];
        claimableMerkleRoots[_token] = pendingMerkleRoots[_token];
        lastRewardsCalculatedToBlock[_token] = _finalizedBlock;
        emit ClaimableMerkleRootUpdated(_token, oldClaimableMerkleRoot, claimableMerkleRoots[_token], _finalizedBlock);
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------  CLAIM FUNCTION  -------------------------------------
    //--------------------------------------------------------------------------------------
    /**
    * @notice Claims rewards for an account using Merkle proof verification
    * @dev Supports both ERC20 tokens and ETH (using ETH_ADDRESS)
    * @dev Uses cumulative amounts to prevent double-claiming and allow partial claims
    * @param token Address of the reward token (use ETH_ADDRESS for ETH)
    * @param account Address that will receive the rewards
    * @param cumulativeAmount Total amount claimable by account, including previous claims
    * @param expectedMerkleRoot The Merkle root containing the reward data
    * @param merkleProof Array of hashes proving the claim's inclusion in the Merkle tree
    **/
    function claim(
        address token,
        address account,
        uint256 cumulativeAmount,
        bytes32 expectedMerkleRoot,
        bytes32[] calldata merkleProof
    ) external whenNotPaused override {
        if (claimableMerkleRoots[token] != expectedMerkleRoot) revert MerkleRootWasUpdated();
        if (!whitelistedRecipient[account]) revert NonWhitelistedUser();

        // Verify the merkle proof
        bytes32 leaf = keccak256(abi.encodePacked(account, cumulativeAmount));
        if (!_verifyAsm(merkleProof, expectedMerkleRoot, leaf)) revert InvalidProof();

        // Mark it claimed
        uint256 preclaimed = cumulativeClaimed[token][account];
        if (preclaimed >= cumulativeAmount) revert NothingToClaim();
        cumulativeClaimed[token][account] = cumulativeAmount;


        uint256 amount = cumulativeAmount - preclaimed;
        // Send the token
        if(token == ETH_ADDRESS){
            (bool success, ) = account.call{value: amount}("");
            if(!success) {
                revert ETHTransferFailed(); 
            }
        } else {
            IERC20(token).safeTransfer(account, amount);
        }
        emit Claimed(token, account, amount);
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  RECOVERY FUNCTIONS  ----------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Recover ETH from the contract
     * @param to The address to recover the ETH to
     * @param amount The amount of ETH to recover
     */
    function recoverETH(address payable to, uint256 amount) external onlyAdmin {
        _recoverETH(to, amount);
    }

    /**
     * @notice Recover ERC20 tokens from the contract
     * @param token The address of the ERC20 token
     * @param to The address to recover the tokens to
     * @param amount The amount of tokens to recover
     */
    function recoverERC20(address token, address to, uint256 amount) external onlyAdmin {
        _recoverERC20(token, to, amount);
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  INTERNAL FUNCTIONS  ----------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Verify the Merkle proof
     * @param proof The Merkle proof
     * @param root The Merkle root
     * @param leaf The leaf
     * @return valid The boolean value indicating if the proof is valid
     */
    function _verifyAsm(bytes32[] calldata proof, bytes32 root, bytes32 leaf) private pure returns (bool valid) {
        if(proof.length > 1000) revert InvalidProof();
        assembly ("memory-safe") { // solhint-disable-line no-inline-assembly
            let ptr := proof.offset

            for { let end := add(ptr, mul(0x20, proof.length)) } lt(ptr, end) { ptr := add(ptr, 0x20) } {
                let node := calldataload(ptr)

                switch lt(leaf, node)
                case 1 {
                    mstore(0x00, leaf)
                    mstore(0x20, node)
                }
                default {
                    mstore(0x00, node)
                    mstore(0x20, leaf)
                }

                leaf := keccak256(0x00, 0x40)
            }

            valid := eq(root, leaf)
        }
    }

    /**
     * @notice Authorize contract upgrades
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyUpgradeTimelock {}

    //--------------------------------------------------------------------------------------
    //---------------------------------  GETTERS  ------------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Get the implementation
     * @return The implementation
     */
    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  MODIFIERS  --------------------------------------
    //--------------------------------------------------------------------------------------
}