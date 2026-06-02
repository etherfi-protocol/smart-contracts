// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin-upgradeable/contracts/proxy/beacon/IBeaconUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import "@etherfi/staking/interfaces/IAuctionManager.sol";
import "@etherfi/staking/interfaces/IStakingManager.sol";
import "@etherfi/interfaces/IDepositContract.sol";
import "@etherfi/staking/interfaces/IEtherFiNode.sol";
import "@etherfi/staking/interfaces/IEtherFiNodesManager.sol";
import "@etherfi/staking/libraries/DepositDataRootGenerator.sol";
import "@etherfi/governance/utils/RolesLibrary.sol";
import "@etherfi/governance/utils/DeprecatedOZPausable.sol";
import "@etherfi/governance/utils/DeprecatedOZReentrancyGuard.sol";

contract StakingManager is
    Initializable,
    IStakingManager,
    IBeaconUpgradeable,
    OwnableUpgradeable,
    DeprecatedOZPausable,
    DeprecatedOZReentrancyGuard,
    UUPSUpgradeable,
    RolesLibrary
{

    address public immutable liquidityPool;
    uint256 public constant INITIAL_DEPOSIT_AMOUNT = 1 ether;
    uint256 public constant MIN_VALIDATOR_SIZE_WEI = 32 ether;
    uint256 public constant MAX_VALIDATOR_SIZE_WEI = 2048 ether;
    uint256 public constant VALIDATOR_PUBKEY_LENGTH = 48;
    IEtherFiNodesManager public immutable etherFiNodesManager;
    IDepositContract public immutable depositContractEth2;
    IAuctionManager public immutable auctionManager;
    UpgradeableBeacon public immutable etherFiNodeBeacon;

    //---------------------------------------------------------------------------
    //-----------------------------  Storage  -----------------------------------
    //---------------------------------------------------------------------------

    LegacyStakingManagerState legacyState; // all legacy state in this contract has been deprecated
    mapping(address => bool) public deployedEtherFiNodes;
    mapping(bytes32 => ValidatorCreationStatus) public validatorCreationStatus;

    //-------------------------------------------------------------------------
    //-----------------------------  Admin  -----------------------------------
    //-------------------------------------------------------------------------

    constructor(
        address _liquidityPool,
        address _etherFiNodesManager,
        address _ethDepositContract,
        address _auctionManager,
        address _etherFiNodeBeacon,
        address _roleRegistry
    ) RolesLibrary(_roleRegistry) {
        liquidityPool = _liquidityPool;
        etherFiNodesManager = IEtherFiNodesManager(_etherFiNodesManager);
        depositContractEth2 = IDepositContract(_ethDepositContract);
        auctionManager = IAuctionManager(_auctionManager);
        etherFiNodeBeacon = UpgradeableBeacon(_etherFiNodeBeacon);

        _disableInitializers();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyUpgradeTimelock {}

    //---------------------------------------------------------------------------
    //------------------------- Deposit Flow ------------------------------------
    //---------------------------------------------------------------------------
    
    function invalidateRegisteredBeaconValidator(DepositData calldata depositData, uint256 bidId, address etherFiNode) external onlyOracleOperations {
        bytes32 validatorCreationDataHash = keccak256(abi.encode(depositData.publicKey, depositData.signature, depositData.depositDataRoot, depositData.ipfsHashForEncryptedValidatorKey, bidId, etherFiNode));
        if (validatorCreationStatus[validatorCreationDataHash] != ValidatorCreationStatus.REGISTERED) revert InvalidValidatorCreationStatus();
        validatorCreationStatus[validatorCreationDataHash] = ValidatorCreationStatus.INVALIDATED;
        emit ValidatorCreationStatusUpdated(depositData, bidId, etherFiNode, validatorCreationDataHash, ValidatorCreationStatus.INVALIDATED);
    }

   /// @notice send 1 eth to deposit contract to create the validator.
    ///    The rest of the eth will not be sent until the oracle confirms the withdrawal credentials
    function createBeaconValidators(DepositData[] calldata depositData, uint256[] calldata bidIds, address etherFiNode) external payable {
        if (msg.sender != liquidityPool) revert InvalidCaller();
        if (depositData.length != bidIds.length) revert InvalidDepositData();

        for (uint256 i = 0; i < depositData.length; i++) {
            DepositData memory d = depositData[i];
            bytes32 validatorCreationDataHash = keccak256(abi.encode(d.publicKey, d.signature, d.depositDataRoot, d.ipfsHashForEncryptedValidatorKey, bidIds[i], etherFiNode));
            if (validatorCreationStatus[validatorCreationDataHash] != ValidatorCreationStatus.REGISTERED) revert InvalidValidatorCreationStatus();

            bytes memory withdrawalCredentials = etherFiNodesManager.addressToCompoundingWithdrawalCredentials(address(IEtherFiNode(etherFiNode).getEigenPod()));
            bytes32 computedDataRoot = generateDepositDataRoot(d.publicKey, d.signature, withdrawalCredentials, INITIAL_DEPOSIT_AMOUNT);
            if (computedDataRoot != d.depositDataRoot) revert IncorrectBeaconRoot();

            validatorCreationStatus[validatorCreationDataHash] = ValidatorCreationStatus.CONFIRMED;
            auctionManager.updateSelectedBidInformation(bidIds[i]);

            // Link the pubkey to a node. Will revert if this pubkey is already registered to a different target
            etherFiNodesManager.linkPubkeyToNode(d.publicKey, etherFiNode, bidIds[i]);

            // Deposit to the Beacon Chain
            depositContractEth2.deposit{value: INITIAL_DEPOSIT_AMOUNT}(d.publicKey, withdrawalCredentials, d.signature, computedDataRoot);

            bytes32 pubkeyHash = calculateValidatorPubkeyHash(d.publicKey);
            emit validatorCreated(pubkeyHash, etherFiNode, d.publicKey);
            emit linkLegacyValidatorId(pubkeyHash, bidIds[i]); // can remove this once we fully transition to pubkeys

            // legacy event for compatibility with existing tooling
            emit ValidatorRegistered(auctionManager.getBidOwner(bidIds[i]), address(liquidityPool), address(liquidityPool), bidIds[i], d.publicKey, d.ipfsHashForEncryptedValidatorKey);
            emit ValidatorCreationStatusUpdated(d, bidIds[i], etherFiNode, validatorCreationDataHash, ValidatorCreationStatus.CONFIRMED);
        }
    }

    /// @notice register the beacon validators data for later confirmation from the oracle before the 1eth deposit
    /// @dev provided deposit data must be for a 0x02 compounding validator
    function registerBeaconValidators(DepositData[] calldata depositData, uint256[] calldata bidIds, address etherFiNode) external {
        if (msg.sender != liquidityPool) revert InvalidCaller();
        if (depositData.length != bidIds.length) revert InvalidDepositData();
        if (address(IEtherFiNode(etherFiNode).getEigenPod()) == address(0) || !deployedEtherFiNodes[etherFiNode]) revert InvalidEtherFiNode();

        // process each 1 eth deposit to create validators for later verification from oracle
        for (uint256 i = 0; i < depositData.length; i++) {

            // claim the bid
            if (!auctionManager.isBidActive(bidIds[i])) revert InactiveBid();

            // verify deposit root
            bytes memory withdrawalCredentials = etherFiNodesManager.addressToCompoundingWithdrawalCredentials(address(IEtherFiNode(etherFiNode).getEigenPod()));
            bytes32 computedDataRoot = generateDepositDataRoot(depositData[i].publicKey, depositData[i].signature, withdrawalCredentials, INITIAL_DEPOSIT_AMOUNT);
            if (computedDataRoot != depositData[i].depositDataRoot) revert IncorrectBeaconRoot();

            bytes32 validatorCreationDataHash = keccak256(abi.encode(depositData[i].publicKey, depositData[i].signature, depositData[i].depositDataRoot, depositData[i].ipfsHashForEncryptedValidatorKey, bidIds[i], etherFiNode));
            if (validatorCreationStatus[validatorCreationDataHash] != ValidatorCreationStatus.NOT_REGISTERED) revert InvalidValidatorCreationStatus();
            validatorCreationStatus[validatorCreationDataHash] = ValidatorCreationStatus.REGISTERED;
            emit ValidatorCreationStatusUpdated(depositData[i], bidIds[i], etherFiNode, validatorCreationDataHash, ValidatorCreationStatus.REGISTERED);
        }
    }

    /// @notice send remaining eth to activate validators created by "createBeaconValidators"
    ///    The oracle is expected to have confirmed the withdrawal credentials
    /// @dev note that since this is considered a "validator top up" by the beacon chain,
    ///   The signatures are not actually verified by the beacon chain, as key ownership was
    ///   already proved during the previous deposit. The "deposit data root" i.e. (checksum) however must be valid.
    ///   The caller can use generateDepositDataRoot() to generate a valid root.
    function confirmAndFundBeaconValidators(DepositData[] calldata depositData, uint256 validatorSizeWei) external payable {
        if (msg.sender != liquidityPool) revert InvalidCaller();
        if (validatorSizeWei < MIN_VALIDATOR_SIZE_WEI || validatorSizeWei > MAX_VALIDATOR_SIZE_WEI) revert InvalidValidatorSize();

        // we already deposited the initial amount to create the validators in createBeaconValidators()
        uint256 remainingDeposit = validatorSizeWei - INITIAL_DEPOSIT_AMOUNT;

        for (uint256 i = 0; i < depositData.length; i++) {

            // check that withdrawal credentials for pubkey match what we originally intended
            // It is expected that the oracle will not call the function for any key that was front-run by a malicious operator
            bytes32 pubkeyHash = calculateValidatorPubkeyHash(depositData[i].publicKey);
            IEtherFiNode etherFiNode = etherFiNodesManager.etherFiNodeFromPubkeyHash(pubkeyHash);
            if (address(etherFiNode) == address(0x0)) revert UnlinkedPubkey();

            // verify deposit root
            bytes memory withdrawalCredentials = etherFiNodesManager.addressToCompoundingWithdrawalCredentials(address(etherFiNode.getEigenPod()));
            bytes32 computedDataRoot = generateDepositDataRoot(depositData[i].publicKey, depositData[i].signature, withdrawalCredentials, remainingDeposit);
            if (computedDataRoot != depositData[i].depositDataRoot) revert IncorrectBeaconRoot();

            // Deposit the remaining eth to the validator
            depositContractEth2.deposit{value: remainingDeposit}(depositData[i].publicKey, withdrawalCredentials, depositData[i].signature, computedDataRoot);

            emit validatorConfirmed(pubkeyHash, liquidityPool, liquidityPool, depositData[i].publicKey);
        }
    }

    /// @notice Calculates the pubkey hash of a validator's pubkey as per SSZ spec
    function calculateValidatorPubkeyHash(bytes memory pubkey) public pure returns (bytes32) {
        if (pubkey.length != VALIDATOR_PUBKEY_LENGTH) revert InvalidPubKeyLength();
        return sha256(abi.encodePacked(pubkey, bytes16(0)));
    }

    /// @notice compute deposit_data_root for the provide deposit data
    //    The deposit_data_root is essentially a checksum of the provided deposit over the (pubkey, signature, withdrawalCreds, amount)
    //    and represents the "node" that will be inserted into the beacon deposit merkle tree.
    //    Note that this is separate from the from the top level beacon deposit_root
    function generateDepositDataRoot(bytes memory pubkey, bytes memory signature, bytes memory withdrawalCredentials, uint256 amount) public pure returns (bytes32) {
        return depositDataRootGenerator.generateDepositDataRoot(pubkey, signature, withdrawalCredentials, amount);
    }

    //---------------------------------------------------------------------------
    //--------------------- EtherFiNode Beacon Proxy ----------------------------
    //---------------------------------------------------------------------------

    /// @notice Upgrades the etherfi node
    /// @param _newImplementation The new address of the etherfi node
    function upgradeEtherFiNode(address _newImplementation) external onlyUpgradeTimelock {
        if (_newImplementation == address(0)) revert InvalidUpgrade();

        etherFiNodeBeacon.upgradeTo(_newImplementation);
    }

    /// @notice Fetches the address of the beacon contract for future EtherFiNodes (withdrawal safes)
    function getEtherFiNodeBeacon() external view returns (address) {
        return address(etherFiNodeBeacon);
    }

    /// @notice Fetches the address of the implementation contract currently being used by the beacon proxy
    /// @return the address of the currently used implementation contract
    function implementation() public view override returns (address) {
        return etherFiNodeBeacon.implementation();
    }

    /// @dev create a new proxy instance of the etherFiNode withdrawal safe contract.
    /// @param _createEigenPod whether or not to create an associated eigenPod contract.
    function instantiateEtherFiNode(bool _createEigenPod) external onlyExecutorOperations returns (address) {
        BeaconProxy proxy = new BeaconProxy(address(etherFiNodeBeacon), "");
        address node = address(proxy);

        deployedEtherFiNodes[node] = true;
        emit EtherFiNodeDeployed(node);

        if (_createEigenPod) {
            etherFiNodesManager.createEigenPod(node);
        }

        return node;
    }

    /// @dev this method is for backfilling the addresses of etherFiNodes the protocol has previously deployed
    ///    Once this data has been backfilled we can delete this method
    function backfillExistingEtherFiNodes(address[] calldata nodes) external onlyOperatingMultisig {
        for (uint256 i = 0; i < nodes.length; i++) {
            address node = nodes[i];
            if (deployedEtherFiNodes[node]) continue; // already linked

            deployedEtherFiNodes[node] = true;
            emit EtherFiNodeDeployed(node);
        }
    }
}
