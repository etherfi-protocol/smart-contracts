// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./interfaces/ITNFT.sol";
import "./interfaces/IBNFT.sol";
import "./interfaces/IAuctionManager.sol";
import "./interfaces/IStakingManager.sol";
import "./interfaces/IDepositContract.sol";
import "./interfaces/IEtherFiNode.sol";
import "./interfaces/IEtherFiNodesManager.sol";
import "./interfaces/INodeOperatorManager.sol";
import "./interfaces/ILiquidityPool.sol";
import "./TNFT.sol";
import "./BNFT.sol";
import "./EtherFiNode.sol";
import "./LiquidityPool.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin-upgradeable/contracts/proxy/beacon/IBeaconUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/PausableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "./libraries/DepositRootGenerator.sol";


contract StakingManager is
    Initializable,
    IStakingManager,
    IBeaconUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    
    /*
    uint128 public maxBatchDepositSize;
    uint128 public stakeAmount;

    address public implementationContract;
    address public liquidityPoolContract;

    bool public isFullStakeEnabled;
    bytes32 public merkleRoot;

    ITNFT public TNFTInterfaceInstance;
    IBNFT public BNFTInterfaceInstance;
    IAuctionManager public auctionManager;
    IDepositContract public depositContractEth2;
    IEtherFiNodesManager public nodesManager;
    UpgradeableBeacon private upgradableBeacon;

    mapping(uint256 => StakerInfo) public bidIdToStakerInfo;

    address public DEPRECATED_admin;
    address public nodeOperatorManager;
    mapping(address => bool) public admins;
    */

    // TODO(dave): fix storage shift
    UpgradeableBeacon private upgradableBeacon;
    address public etherFiNodeImplementation;

    IEtherFiNodesManager public immutable etherFiNodesManager;
    IDepositContract public immutable depositContractEth2;
    IAuctionManager public immutable auctionManager;
    ITNFT public immutable tnft;
    IBNFT public immutable bnft;
    address public immutable etherfiOracle;

    error InvalidCaller();
    error UnlinkedPubkey();
    error IncorrectBeaconRoot();
    error InvalidPubKeyLength();
    error InvalidDepositData();
    error InactiveBid();
    error IncorrectValidatorFunds();
    error InvalidEtherFiNode();

    event validatorCreated(bytes32 indexed pubkeyHash, address indexed etherFiNode, bytes pubkey);
    event validatorConfirmed(bytes32 indexed pubkeyHash, address indexed bnftRecipient, address indexed tnftRecipient, bytes pubkey);
    event linkLegacyValidatorId(bytes32 indexed pubkeyHash, uint256 indexed legacyId);


    //--------------------------------------------------------------------------------------
    //----------------------------  STATE-CHANGING FUNCTIONS  ------------------------------
    //--------------------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function _authorizeUpgrade(address newImplementation) internal override {}

    // TODO(dave): are we using a slightly different proxy for this contract?

    /// @notice Fetches the address of the implementation contract currently being used by the proxy
    /// @return the address of the currently used implementation contract
    function getImplementation() external view returns (address) {
        return _getImplementation();
    }


     /// @notice send 1 eth to deposit contract to create the validator.
    ///    The rest of the eth will not be sent until the oracle confirms the withdrawal credentials
    function createBeaconValidators(DepositData[] calldata depositData, uint256[] calldata bidIds, address etherFiNode, address nodeOperator) external payable {
        if (msg.sender != etherfiOracle) revert InvalidCaller();
        if (depositData.length != bidIds.length) revert InvalidDepositData();
        if (msg.value != 1 ether * depositData.length) revert IncorrectValidatorFunds();
        if (address(IEtherFiNode(etherFiNode).getEigenPod()) == address(0)) revert InvalidEtherFiNode();

        // process each 1 eth deposit to create validators for later verification from oracle
        for (uint256 i = 0; i < depositData.length; i++) {

            // claim the bid
            if (!auctionManager.isBidActive(bidIds[i])) revert InactiveBid();
            auctionManager.updateSelectedBidInformation(bidIds[i]);

            // verify deposit root
            bytes memory withdrawalCredentials = etherFiNodesManager.addressToWithdrawalCredentials(etherFiNode);
            bytes32 computedDataRoot = depositRootGenerator.generateDepositRoot(depositData[i].publicKey, depositData[i].signature, withdrawalCredentials, 1 ether);
            if (computedDataRoot != depositData[i].depositDataRoot) revert IncorrectBeaconRoot();

            // Link the pubkey to a node. Will revert if this pubkey is already registered to a different target
            etherFiNodesManager.linkPubkeyToNode(depositData[i].publicKey, etherFiNode, bidIds[i]);

            // Deposit to the Beacon Chain
            depositContractEth2.deposit{value: 1 ether}(depositData[i].publicKey, withdrawalCredentials, depositData[i].signature, computedDataRoot);

            bytes32 pubkeyHash = calculateValidatorPubkeyHash(depositData[i].publicKey);
            emit validatorCreated(pubkeyHash, etherFiNode, depositData[i].publicKey);
            emit linkLegacyValidatorId(pubkeyHash, bidIds[i]); // can remove this once we fully transition to pubkeys
        }
    }

    /// @notice send 31 eth to activate validators created by "createBeaconValidators"
    ///    The oracle is expected to have confirmed the withdrawal credentials
    function confirmAndFundBeaconValidators(DepositData[] calldata depositData, address BnftRecipient, address TnftRecipient) external payable {
        if (msg.sender != etherfiOracle) revert InvalidCaller();

        for (uint256 i = 0; i < depositData.length; i++) {

            // check that withdrawal credentials for pubkey match what we originally intended
            // It is expected that the oracle will not call the function for any key that was front-run
            bytes32 pubkeyHash = calculateValidatorPubkeyHash(depositData[i].publicKey);
            IEtherFiNode etherFiNode = etherFiNodesManager.etherFiNodeFromPubkeyHash(pubkeyHash);
            if (address(etherFiNode) == address(0x0)) revert UnlinkedPubkey();

            // verify deposit root
            bytes memory withdrawalCredentials = etherFiNodesManager.addressToWithdrawalCredentials(address(etherFiNode.getEigenPod()));
            bytes32 computedDataRoot = depositRootGenerator.generateDepositRoot(depositData[i].publicKey, depositData[i].signature, withdrawalCredentials, 31 ether);
            if (computedDataRoot != depositData[i].depositDataRoot) revert IncorrectBeaconRoot();

            // Deposit the remaining 31 eth to activate validator
            depositContractEth2.deposit{value: 31 ether}(depositData[i].publicKey, withdrawalCredentials, depositData[i].signature, computedDataRoot);

            // Use pubkey hash as the minted token ID
            tnft.mint(BnftRecipient, uint256(pubkeyHash));
            bnft.mint(TnftRecipient, uint256(pubkeyHash));

            emit validatorConfirmed(pubkeyHash, BnftRecipient, TnftRecipient, depositData[i].publicKey);
        }

        // TODO: emission of the ipfs key has been left out to await the decisions
        // around validator key management changes, as they will effect this.
    }

    ///@notice Calculates the pubkey hash of a validator's pubkey as per SSZ spec
    function calculateValidatorPubkeyHash(bytes memory pubkey) public pure returns (bytes32) {
        if (pubkey.length != 48) revert InvalidPubKeyLength();
        return sha256(abi.encodePacked(pubkey, bytes16(0)));
    }



    ///////////////////////////////////////////////////////////////////////////////////////

    /// @notice Upgrades the etherfi node
    /// @param _newImplementation The new address of the etherfi node
    function upgradeEtherFiNode(address _newImplementation) public onlyOwner {
        require(_newImplementation != address(0), "ZERO_ADDRESS");
        
        upgradableBeacon.upgradeTo(_newImplementation);
        etherFiNodeImplementation = _newImplementation;
    }

    // TODO(dave): reimplement pausing with role registry
    function pauseContract() external { _pause(); }
    function unPauseContract() external { _unpause(); }


    //--------------------------------------------------------------------------------------
    //--------------------- EtherFiNode Beacon Proxy ----------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Fetches the address of the beacon contract for future EtherFiNodes (withdrawal safes)
    function getEtherFiNodeBeacon() external view returns (address) {
        return address(upgradableBeacon);
    }

    /// @notice Fetches the address of the implementation contract currently being used by the beacon proxy
    /// @return the address of the currently used implementation contract
    function getEtherFiNodeImplementation() public view returns (address) {
        return upgradableBeacon.implementation();
    }
}
