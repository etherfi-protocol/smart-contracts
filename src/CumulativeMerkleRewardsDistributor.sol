pragma solidity 0.8.24;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {RoleRegistry} from "./RoleRegistry.sol";
import {ICumulativeMerkleRewardsDistributor}  from "./interfaces/ICumulativeMerkleRewardsDistributor.sol";

contract CumulativeMerkleRewardsDistributor is ICumulativeMerkleRewardsDistributor, OwnableUpgradeable, UUPSUpgradeable {
using SafeERC20 for IERC20;

    mapping(address token => uint256 blockNo) public lastPendingMerkleUpdatedToBlock;
    mapping(address token => uint256 blockNo) public lastRewardsCalculatedToBlock;
    mapping(address token => bytes32 merkleRoot) public claimableMerkleRoots;
    mapping(address token => bytes32 merkleRoot) public pendingMerkleRoots;
    mapping(address token => mapping(address user => uint256 cumulativeBalance)) public cumulativeClaimed;
    bool public paused;

    uint256 public constant CLAIM_DELAY = 7200; // 1 day to verify if processRewards was called with wrong amounts
    address public constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    bytes32 public constant REWARDS_MANAGER_ADMIN = keccak256("REWARD_MANAGER_ADMIN");
    RoleRegistry public immutable roleRegistry;


    constructor(address _roleRegistry) {
        _disableInitializers();
        roleRegistry = RoleRegistry(_roleRegistry);
    }

    function initialize() external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        paused = false;
    }

    function setPendingMerkleRoot(address _token, bytes32 _merkleRoot) external whenNotPaused {
        if(!roleRegistry.hasRole(REWARDS_MANAGER_ADMIN, msg.sender)) revert IncorrectRole();
        pendingMerkleRoots[_token] = _merkleRoot;
        lastPendingMerkleUpdatedToBlock[_token] = block.number;
        emit PendingMerkleRootUpdated(_token, _merkleRoot);
    }

    function finalizeMerkleRoot(address _token, uint256 _finalizedBlock) external whenNotPaused {
        if(!roleRegistry.hasRole(REWARDS_MANAGER_ADMIN, msg.sender)) revert IncorrectRole();
        if(!(block.number >= lastPendingMerkleUpdatedToBlock[_token] + CLAIM_DELAY)) revert InsufficentDelay();
        bytes32 oldClaimableMerkleRoot = claimableMerkleRoots[_token];
        claimableMerkleRoots[_token] = pendingMerkleRoots[_token];
        lastRewardsCalculatedToBlock[_token] = _finalizedBlock;
        emit ClaimableMerkleRootUpdated(_token, oldClaimableMerkleRoot, claimableMerkleRoots[_token], _finalizedBlock);
    }

    function pause() external {
        if(!roleRegistry.hasRole(roleRegistry.PROTOCOL_PAUSER(), msg.sender)) revert IncorrectRole();
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external {
        if(!roleRegistry.hasRole(roleRegistry.PROTOCOL_UNPAUSER(), msg.sender)) revert IncorrectRole();
        paused = false;
        emit UnPaused(msg.sender);
    }

    function claim(
        address token,
        address account,
        uint256 cumulativeAmount,
        bytes32 expectedMerkleRoot,
        bytes32[] calldata merkleProof
    ) external whenNotPaused override {
        if (claimableMerkleRoots[token] != expectedMerkleRoot) revert MerkleRootWasUpdated();

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
                revert("ETH Transfer failed");
            }
        } else {
            IERC20(token).safeTransfer(account, amount);
        }
        emit Claimed(token, account, amount);
    }


    function getImplementation() external view returns (address) {return _getImplementation();}

    function _authorizeUpgrade(address newImplementation) internal override {
        roleRegistry.onlyProtocolUpgrader(msg.sender);
    }

    function _verifyAsm(bytes32[] calldata proof, bytes32 root, bytes32 leaf) private pure returns (bool valid) {
        /// @solidity memory-safe-assembly
        assembly {  // solhint-disable-line no-inline-assembly
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
        require(!paused, "Pausable: paused");
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  MODIFIERS  --------------------------------------
    //--------------------------------------------------------------------------------------

    modifier whenNotPaused() {
        _requireNotPaused();
        _;
    }

}