// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./interfaces/IRoleRegistry.sol";
import "./interfaces/IAuctionManager.sol";
import "./interfaces/IStakingManager.sol";
import "./interfaces/IDepositContract.sol";
import "./interfaces/IEtherFiNode.sol";
import "./interfaces/IEtherFiNodesManager.sol";
import "./libraries/DepositRootGenerator.sol";

import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin-upgradeable/contracts/proxy/beacon/IBeaconUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/PausableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

contract StakingManager is
    Initializable,
    IStakingManager,
    IBeaconUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{

    address public immutable liquidityPool;
    uint256 public constant initialDepositAmount = 1 ether;
    IEtherFiNodesManager public immutable etherFiNodesManager;
    IDepositContract public immutable depositContractEth2;
    IAuctionManager public immutable auctionManager;
    UpgradeableBeacon public immutable etherFiNodeBeacon;
    IRoleRegistry public immutable roleRegistry;

    //---------------------------------------------------------------------------
    //-----------------------------  Storage  -----------------------------------
    //---------------------------------------------------------------------------

    LegacyStakingManagerState legacyState; // all legacy state in this contract has been deprecated

    //---------------------------------------------------------------------------
    //---------------------------  ROLES  ---------------------------------------
    //---------------------------------------------------------------------------

    bytes32 public constant STAKING_MANAGER_NODE_CREATOR_ROLE = keccak256("STAKING_MANAGER_NODE_CREATOR_ROLE");

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
    ) {
        liquidityPool = _liquidityPool;
        etherFiNodesManager = IEtherFiNodesManager(_etherFiNodesManager);
        depositContractEth2 = IDepositContract(_ethDepositContract);
        auctionManager = IAuctionManager(_auctionManager);
        etherFiNodeBeacon = UpgradeableBeacon(_etherFiNodeBeacon);
        roleRegistry = IRoleRegistry(_roleRegistry);

        _disableInitializers();
    }

    function _authorizeUpgrade(address _newImplementation) internal override {
        roleRegistry.onlyProtocolUpgrader(msg.sender);
    }

    function pauseContract() external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_PAUSER(), msg.sender)) revert IncorrectRole();
        _pause();
    }
    function unPauseContract() external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_UNPAUSER(), msg.sender)) revert IncorrectRole();
        _unpause();
    }

    //---------------------------------------------------------------------------
    //------------------------- Deposit Flow ------------------------------------
    //---------------------------------------------------------------------------

    /// @notice send 1 eth to deposit contract to create the validator.
    ///    The rest of the eth will not be sent until the oracle confirms the withdrawal credentials
    function createBeaconValidators(DepositData[] calldata depositData, uint256[] calldata bidIds, address etherFiNode) external payable {
        if (msg.sender != liquidityPool) revert InvalidCaller();
        if (depositData.length != bidIds.length) revert InvalidDepositData();
        if (address(IEtherFiNode(etherFiNode).getEigenPod()) == address(0)) revert InvalidEtherFiNode();

        // process each 1 eth deposit to create validators for later verification from oracle
        for (uint256 i = 0; i < depositData.length; i++) {

            // claim the bid
            if (!auctionManager.isBidActive(bidIds[i])) revert InactiveBid();
            auctionManager.updateSelectedBidInformation(bidIds[i]);

            // verify deposit root
            bytes memory withdrawalCredentials = etherFiNodesManager.addressToWithdrawalCredentials(address(IEtherFiNode(etherFiNode).getEigenPod()));
            bytes32 computedDataRoot = depositRootGenerator.generateDepositRoot(depositData[i].publicKey, depositData[i].signature, withdrawalCredentials, initialDepositAmount);
            if (computedDataRoot != depositData[i].depositDataRoot) revert IncorrectBeaconRoot();

            // Link the pubkey to a node. Will revert if this pubkey is already registered to a different target
            etherFiNodesManager.linkPubkeyToNode(depositData[i].publicKey, etherFiNode, bidIds[i]);

            // Deposit to the Beacon Chain
            depositContractEth2.deposit{value: initialDepositAmount}(depositData[i].publicKey, withdrawalCredentials, depositData[i].signature, computedDataRoot);

            bytes32 pubkeyHash = calculateValidatorPubkeyHash(depositData[i].publicKey);
            emit validatorCreated(pubkeyHash, etherFiNode, depositData[i].publicKey);
            emit linkLegacyValidatorId(pubkeyHash, bidIds[i]); // can remove this once we fully transition to pubkeys

            // legacy event for compatibility with existing tooling
            emit ValidatorRegistered(auctionManager.getBidOwner(bidIds[i]), address(liquidityPool), address(liquidityPool), bidIds[i], depositData[i].publicKey, depositData[i].ipfsHashForEncryptedValidatorKey);
        }
    }

    /// @notice send remaining eth to activate validators created by "createBeaconValidators"
    ///    The oracle is expected to have confirmed the withdrawal credentials
    function confirmAndFundBeaconValidators(DepositData[] calldata depositData, uint256 validatorSizeWei) external payable {
        if (msg.sender != liquidityPool) revert InvalidCaller();
        if (validatorSizeWei < 32 ether || validatorSizeWei > 2048 ether) revert InvalidValidatorSize();

        // we already deposited the initial amount to create the validators in createBeaconValidators()
        uint256 remainingDeposit = validatorSizeWei - initialDepositAmount;

        for (uint256 i = 0; i < depositData.length; i++) {

            // check that withdrawal credentials for pubkey match what we originally intended
            // It is expected that the oracle will not call the function for any key that was front-run by a malicious operator
            bytes32 pubkeyHash = calculateValidatorPubkeyHash(depositData[i].publicKey);
            IEtherFiNode etherFiNode = etherFiNodesManager.etherFiNodeFromPubkeyHash(pubkeyHash);
            if (address(etherFiNode) == address(0x0)) revert UnlinkedPubkey();

            // verify deposit root
            bytes memory withdrawalCredentials = etherFiNodesManager.addressToWithdrawalCredentials(address(etherFiNode.getEigenPod()));
            bytes32 computedDataRoot = depositRootGenerator.generateDepositRoot(depositData[i].publicKey, depositData[i].signature, withdrawalCredentials, remainingDeposit);
            if (computedDataRoot != depositData[i].depositDataRoot) revert IncorrectBeaconRoot();

            // Deposit the remaining eth to the validator
            depositContractEth2.deposit{value: remainingDeposit}(depositData[i].publicKey, withdrawalCredentials, depositData[i].signature, computedDataRoot);

            emit validatorConfirmed(pubkeyHash, liquidityPool, liquidityPool, depositData[i].publicKey);
        }
    }

    ///@notice Calculates the pubkey hash of a validator's pubkey as per SSZ spec
    function calculateValidatorPubkeyHash(bytes memory pubkey) public pure returns (bytes32) {
        if (pubkey.length != 48) revert InvalidPubKeyLength();
        return sha256(abi.encodePacked(pubkey, bytes16(0)));
    }

    //---------------------------------------------------------------------------
    //--------------------- EtherFiNode Beacon Proxy ----------------------------
    //---------------------------------------------------------------------------

    /// @notice Upgrades the etherfi node
    /// @param _newImplementation The new address of the etherfi node
    function upgradeEtherFiNode(address _newImplementation) external {
        roleRegistry.onlyProtocolUpgrader(msg.sender);
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
    function instantiateEtherFiNode(bool _createEigenPod) external returns (address) {
        if (!roleRegistry.hasRole(STAKING_MANAGER_NODE_CREATOR_ROLE, msg.sender)) revert IncorrectRole();

        BeaconProxy proxy = new BeaconProxy(address(etherFiNodeBeacon), "");
        address node = address(proxy);
        if (_createEigenPod) {
            IEtherFiNode(node).createEigenPod();
        }
        return node;
    }

}
