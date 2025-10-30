// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RoleRegistry} from "./RoleRegistry.sol";
import {ICumulativeMerkleRewardsDistributor} from "./interfaces/ICumulativeMerkleRewardsDistributor.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract CumulativeMerkleRewardsDistributor is ICumulativeMerkleRewardsDistributor, OwnableUpgradeable, UUPSUpgradeable {
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
    bool public paused;

    //--------------------------------------------------------------------------------------
    //-------------------------------------  ROLES  ---------------------------------------
    //--------------------------------------------------------------------------------------

    address public constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    bytes32 public constant CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR_ADMIN_ROLE = keccak256("CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR_ADMIN_ROLE");
    bytes32 public constant CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR_CLAIM_DELAY_SETTER_ROLE = keccak256("CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR_CLAIM_DELAY_SETTER_ROLE");
    RoleRegistry public immutable roleRegistry;

    //--------------------------------------------------------------------------------------
    //----------------------------  STATE-CHANGING FUNCTIONS  ------------------------------
    //--------------------------------------------------------------------------------------

    constructor(address _roleRegistry) {
        _disableInitializers();
        roleRegistry = RoleRegistry(_roleRegistry);
    }

    function initialize() external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        paused = false;
        claimDelay = 172_800; // 48 hours
    }

    function setClaimDelay(uint256 _claimDelay) external {
        if (!roleRegistry.hasRole(CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR_CLAIM_DELAY_SETTER_ROLE, msg.sender)) {
            revert IncorrectRole();
        }
        claimDelay = _claimDelay;
        emit ClaimDelayUpdated(claimDelay);
    }
    /**
     * @notice Sets a new pending Merkle root for token rewards distribution
     * @dev Only callable by accounts with CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR_ADMIN_ROLE role
     * @dev The pending root must be finalized after CLAIM_DELAY blocks before it becomes active
     * @param _token Address of the reward token (use ETH_ADDRESS for ETH rewards)
     * @param _merkleRoot New Merkle root containing the reward data
     *
     */

    function setPendingMerkleRoot(address _token, bytes32 _merkleRoot) external whenNotPaused {
        if (!roleRegistry.hasRole(CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR_ADMIN_ROLE, msg.sender)) {
            revert IncorrectRole();
        }
        pendingMerkleRoots[_token] = _merkleRoot;
        lastPendingMerkleUpdatedToTimestamp[_token] = block.timestamp;
        emit PendingMerkleRootUpdated(_token, _merkleRoot);
    }

    /**
     * @notice Finalizes a pending Merkle root after the required delay period
     * @dev Only callable by accounts with CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR_ADMIN_ROLE role
     * @dev Must wait CLAIM_DELAY blocks after setPendingMerkleRoot before finalizing
     * @param _token Address of the reward token (use ETH_ADDRESS for ETH rewards)
     * @param _finalizedBlock Block number up to which rewards are calculated
     */
    function finalizeMerkleRoot(address _token, uint256 _finalizedBlock) external whenNotPaused {
        if (!roleRegistry.hasRole(CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR_ADMIN_ROLE, msg.sender)) {
            revert IncorrectRole();
        }
        if (!(block.timestamp >= lastPendingMerkleUpdatedToTimestamp[_token] + claimDelay)) {
            revert InsufficentDelay();
        }
        if (_finalizedBlock < lastRewardsCalculatedToBlock[_token] || _finalizedBlock > block.number) {
            revert InvalidFinalizedBlock();
        }
        bytes32 oldClaimableMerkleRoot = claimableMerkleRoots[_token];
        claimableMerkleRoots[_token] = pendingMerkleRoots[_token];
        lastRewardsCalculatedToBlock[_token] = _finalizedBlock;
        emit ClaimableMerkleRootUpdated(_token, oldClaimableMerkleRoot, claimableMerkleRoots[_token], _finalizedBlock);
    }

    /**
     * @notice Claims rewards for an account using Merkle proof verification
     * @dev Supports both ERC20 tokens and ETH (using ETH_ADDRESS)
     * @dev Uses cumulative amounts to prevent double-claiming and allow partial claims
     * @param token Address of the reward token (use ETH_ADDRESS for ETH)
     * @param account Address that will receive the rewards
     * @param cumulativeAmount Total amount claimable by account, including previous claims
     * @param expectedMerkleRoot The Merkle root containing the reward data
     * @param merkleProof Array of hashes proving the claim's inclusion in the Merkle tree
     *
     */
    function claim(address token, address account, uint256 cumulativeAmount, bytes32 expectedMerkleRoot, bytes32[] calldata merkleProof) external override whenNotPaused {
        if (claimableMerkleRoots[token] != expectedMerkleRoot) {
            revert MerkleRootWasUpdated();
        }
        if (!whitelistedRecipient[account]) {
            revert NonWhitelistedUser();
        }

        // Verify the merkle proof
        bytes32 leaf = keccak256(abi.encodePacked(account, cumulativeAmount));
        if (!_verifyAsm(merkleProof, expectedMerkleRoot, leaf)) {
            revert InvalidProof();
        }

        // Mark it claimed
        uint256 preclaimed = cumulativeClaimed[token][account];
        if (preclaimed >= cumulativeAmount) {
            revert NothingToClaim();
        }
        cumulativeClaimed[token][account] = cumulativeAmount;

        uint256 amount = cumulativeAmount - preclaimed;
        // Send the token
        if (token == ETH_ADDRESS) {
            (bool success,) = account.call{value: amount}("");
            if (!success) {
                revert ETHTransferFailed();
            }
        } else {
            IERC20(token).safeTransfer(account, amount);
        }
        emit Claimed(token, account, amount);
    }

    function updateWhitelistedRecipient(address user, bool isWhitelisted) external {
        if (!roleRegistry.hasRole(CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR_ADMIN_ROLE, msg.sender)) {
            revert IncorrectRole();
        }
        whitelistedRecipient[user] = isWhitelisted;
        emit RecipientStatusUpdated(user, isWhitelisted);
    }

    function pause() external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_PAUSER(), msg.sender)) {
            revert IncorrectRole();
        }
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_UNPAUSER(), msg.sender)) {
            revert IncorrectRole();
        }
        paused = false;
        emit UnPaused(msg.sender);
    }

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  INTERNAL FUNCTIONS  ----------------------------------
    //--------------------------------------------------------------------------------------

    function _authorizeUpgrade(address newImplementation) internal override {
        roleRegistry.onlyProtocolUpgrader(msg.sender);
    }

    function _verifyAsm(bytes32[] calldata proof, bytes32 root, bytes32 leaf) private pure returns (bool valid) {
        if (proof.length > 1000) {
            revert InvalidProof();
        }
        assembly ("memory-safe") {
            // solhint-disable-line no-inline-assembly
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

    function _requireNotPaused() internal view virtual {
        if (paused) {
            revert ContractPaused();
        }
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  MODIFIERS  --------------------------------------
    //--------------------------------------------------------------------------------------

    modifier whenNotPaused() {
        _requireNotPaused();
        _;
    }
}
