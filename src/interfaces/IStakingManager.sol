// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./ILiquidityPool.sol";

interface IStakingManager {

    struct DepositData {
        bytes publicKey;
        bytes signature;
        bytes32 depositDataRoot;
        string ipfsHashForEncryptedValidatorKey;
    }

    // Possible values for validator creation status
    enum ValidatorCreationStatus {
        NOT_REGISTERED,
        REGISTERED,
        CONFIRMED,
        INVALIDATED
    }

    // deposit flow
    function registerBeaconValidators(DepositData[] calldata depositData, uint256[] calldata bidIds, address etherFiNode) external;
    function createBeaconValidators(DepositData[] calldata depositData, uint256[] calldata bidIds, address etherFiNode) external payable;
    function invalidateRegisteredBeaconValidator(DepositData calldata depositData, uint256 bidId, address etherFiNode) external;
    function confirmAndFundBeaconValidators(DepositData[] calldata depositData, uint256 validatorSizeWei) external payable;
    function calculateValidatorPubkeyHash(bytes memory pubkey) external pure returns (bytes32);
    function initialDepositAmount() external returns (uint256);
    function generateDepositDataRoot(bytes memory pubkey, bytes memory signature, bytes memory withdrawalCredentials, uint256 amount) external pure returns (bytes32);

    // EtherFiNode Beacon Proxy
    function upgradeEtherFiNode(address _newImplementation) external;
    function getEtherFiNodeBeacon() external view returns (address);
    function deployedEtherFiNodes(address etherFiNode) external view returns (bool);

    // protocol
    function pauseContract() external;
    function unPauseContract() external;

    // prevent storage shift on upgrade
    struct LegacyStakingManagerState {
        uint256[14] legacyState;
        /*
        |------------------------+-------------------------------------------------------+------+--------+-------+---------------------------------------|
        | stakeAmount            | uint128                                               | 301  | 16     | 16    | src/StakingManager.sol:StakingManager |
        |------------------------+-------------------------------------------------------+------+--------+-------+---------------------------------------|
        | implementationContract | address                                               | 302  | 0      | 20    | src/StakingManager.sol:StakingManager |
        |------------------------+-------------------------------------------------------+------+--------+-------+---------------------------------------|
        | liquidityPoolContract  | address                                               | 303  | 0      | 20    | src/StakingManager.sol:StakingManager |
        |------------------------+-------------------------------------------------------+------+--------+-------+---------------------------------------|
        | isFullStakeEnabled     | bool                                                  | 303  | 20     | 1     | src/StakingManager.sol:StakingManager |
        |------------------------+-------------------------------------------------------+------+--------+-------+---------------------------------------|
        | merkleRoot             | bytes32                                               | 304  | 0      | 32    | src/StakingManager.sol:StakingManager |
        |------------------------+-------------------------------------------------------+------+--------+-------+---------------------------------------|
        | TNFTInterfaceInstance  | contract ITNFT                                        | 305  | 0      | 20    | src/StakingManager.sol:StakingManager |
        |------------------------+-------------------------------------------------------+------+--------+-------+---------------------------------------|
        | BNFTInterfaceInstance  | contract IBNFT                                        | 306  | 0      | 20    | src/StakingManager.sol:StakingManager |
        |------------------------+-------------------------------------------------------+------+--------+-------+---------------------------------------|
        | auctionManager         | contract IAuctionManager                              | 307  | 0      | 20    | src/StakingManager.sol:StakingManager |
        |------------------------+-------------------------------------------------------+------+--------+-------+---------------------------------------|
        | depositContractEth2    | contract IDepositContract                             | 308  | 0      | 20    | src/StakingManager.sol:StakingManager |
        |------------------------+-------------------------------------------------------+------+--------+-------+---------------------------------------|
        | nodesManager           | contract IEtherFiNodesManager                         | 309  | 0      | 20    | src/StakingManager.sol:StakingManager |
        |------------------------+-------------------------------------------------------+------+--------+-------+---------------------------------------|
        | upgradableBeacon       | contract UpgradeableBeacon                            | 310  | 0      | 20    | src/StakingManager.sol:StakingManager |
        |------------------------+-------------------------------------------------------+------+--------+-------+---------------------------------------|
        | bidIdToStakerInfo      | mapping(uint256 => struct IStakingManager.StakerInfo) | 311  | 0      | 32    | src/StakingManager.sol:StakingManager |
        |------------------------+-------------------------------------------------------+------+--------+-------+---------------------------------------|
        | DEPRECATED_admin       | address                                               | 312  | 0      | 20    | src/StakingManager.sol:StakingManager |
        |------------------------+-------------------------------------------------------+------+--------+-------+---------------------------------------|
        | nodeOperatorManager    | address                                               | 313  | 0      | 20    | src/StakingManager.sol:StakingManager |
        |------------------------+-------------------------------------------------------+------+--------+-------+---------------------------------------|
        | admins                 | mapping(address => bool)                              | 314  | 0      | 32    | src/StakingManager.sol:StakingManager |
        ╰------------------------+-------------------------------------------------------+------+--------+-------+---------------------------------------╯
        */
    }

    //---------------------------------------------------------------------------
    //-----------------------------  Events  -----------------------------------
    //---------------------------------------------------------------------------

    event validatorCreated(bytes32 indexed pubkeyHash, address indexed etherFiNode, bytes pubkey);
    event validatorConfirmed(bytes32 indexed pubkeyHash, address indexed bnftRecipient, address indexed tnftRecipient, bytes pubkey);
    event linkLegacyValidatorId(bytes32 indexed pubkeyHash, uint256 indexed legacyId);
    event EtherFiNodeDeployed(address indexed etheFiNode);

    // legacy event still being emitted in its original form to play nice with existing external tooling
    event ValidatorRegistered(address indexed operator, address indexed bNftOwner, address indexed tNftOwner, uint256 validatorId, bytes validatorPubKey, string ipfsHashForEncryptedValidatorKey);

    event ValidatorCreationStatusUpdated(DepositData depositData, uint256 bidId, address etherFiNode, bytes32 hashedAllData, ValidatorCreationStatus indexed status);

    //--------------------------------------------------------------------------
    //-----------------------------  Errors  -----------------------------------
    //--------------------------------------------------------------------------

    error InvalidCaller();
    error UnlinkedPubkey();
    error IncorrectBeaconRoot();
    error InvalidPubKeyLength();
    error InvalidDepositData();
    error InactiveBid();
    error InvalidEtherFiNode();
    error InvalidValidatorSize();
    error IncorrectRole();
    error InvalidUpgrade();
    error InvalidValidatorCreationStatus();

}
