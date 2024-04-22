// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/PausableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import "./EtherFiAvsOperator.sol";

import "./eigenlayer-interfaces/IAVSDirectory.sol";
import "./eigenlayer-interfaces/IServiceManager.sol";


contract EtherFiAvsOperatorsManager is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    UpgradeableBeacon public upgradableBeacon;
    uint256 public nextAvsOperatorId;
 
    mapping(uint256 => EtherFiAvsOperator) public avsOperators;

    IDelegationManager public delegationManager;

    mapping(address => bool) public admins;
    mapping(address => bool) public pausers;

    IAVSDirectory public avsDirectory;
 
    event ForwardedRunnerCall(uint256 indexed id, address target, bytes4 selector, bytes data);
    event CreatedEtherFiAvsOperator(uint256 indexed id, address etherFiAvsOperator);
    event RegisteredBlsKeyAsDelegatedNodeOperator(uint256 indexed id, address avsServiceManager, bytes quorumNumbers, string socket, IBLSApkRegistry.PubkeyRegistrationParams params);
    event RegisteredOperator(uint256 indexed id, address avsServiceManager, bytes quorumNumbers, string socket, IBLSApkRegistry.PubkeyRegistrationParams params, ISignatureUtils.SignatureWithSaltAndExpiry operatorSignature);
    event DeregisteredOperator(uint256 indexed id, address avsServiceManager, bytes quorumNumbers);
    event RegisteredAsOperator(uint256 indexed id, IDelegationManager.OperatorDetails detail);
    event UpdatedSocket(uint256 indexed id, address avsServiceManager, string socket);
    event ModifiedOperatorDetails(uint256 indexed id, IDelegationManager.OperatorDetails newOperatorDetails);
    event UpdatedOperatorMetadataURI(uint256 indexed id, string metadataURI);
    event UpdatedAvsNodeRunner(uint256 indexed id, address avsNodeRunner);
    event UpdatedAvsWhitelist(uint256 indexed id, address avsServiceManager, bool isWhitelisted);
    event UpdatedEcdsaSigner(uint256 indexed id, address ecdsaSigner);

     /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize to set variables on deployment
    function initialize(address _delegationManager, address _avsDirectory, address _etherFiAvsOperatorImpl) external initializer {
        __Pausable_init();
        __Ownable_init();
        __UUPSUpgradeable_init();

        nextAvsOperatorId = 1;
        upgradableBeacon = new UpgradeableBeacon(_etherFiAvsOperatorImpl);      
        delegationManager = IDelegationManager(_delegationManager);
        avsDirectory = IAVSDirectory(_avsDirectory);
    }

    function initializeAvsDirectory(address _avsDirectory) external onlyOwner {
        avsDirectory = IAVSDirectory(_avsDirectory);
    }

    function runnerForwardCall(
        uint256 _id,
        address _target,
        bytes4 _selector, 
        bytes calldata _remainingCalldata
    ) external onlyOperator(_id) {
        avsOperators[_id].runnerForwardCall(_target, _selector, _remainingCalldata);

        emit ForwardedRunnerCall(_id, _target, _selector, _remainingCalldata);
    }

    function registerBlsKeyAsDelegatedNodeOperator(
        uint256 _id, 
        address _avsRegistryCoordinator, 
        bytes calldata _quorumNumbers,
        string calldata _socket,
        IBLSApkRegistry.PubkeyRegistrationParams calldata _params
    ) external onlyOperator(_id) {
        avsOperators[_id].registerBlsKeyAsDelegatedNodeOperator(_avsRegistryCoordinator, _quorumNumbers, _socket, _params);

        emit RegisteredBlsKeyAsDelegatedNodeOperator(_id, _avsRegistryCoordinator, _quorumNumbers, _socket, _params);
    }

    // we got angry with {gnosis, etherscan} to deal with the tuple type
    function registerOperator(
        uint256 _id,
        address _avsRegistryCoordinator,
        bytes calldata _signature,
        bytes32 _salt,
        uint256 _expiry
    ) external onlyOperator(_id) {
        ISignatureUtils.SignatureWithSaltAndExpiry memory _operatorSignature = ISignatureUtils.SignatureWithSaltAndExpiry(_signature, _salt, _expiry);
        return registerOperator(_id, _avsRegistryCoordinator, _operatorSignature);
    }

    function registerOperator(
        uint256 _id,
        address _avsRegistryCoordinator,
        ISignatureUtils.SignatureWithSaltAndExpiry memory _operatorSignature
    ) public onlyOperator(_id) {
        EtherFiAvsOperator.AvsInfo memory avsInfo = avsOperators[_id].getAvsInfo(_avsRegistryCoordinator);
        avsOperators[_id].registerOperator(_avsRegistryCoordinator, _operatorSignature);

        emit RegisteredOperator(_id, _avsRegistryCoordinator, avsInfo.quorumNumbers, avsInfo.socket, avsInfo.params, _operatorSignature);
    }

    function registerOperatorWithChurn(
        uint256 _id,
        address _avsRegistryCoordinator,
        IRegistryCoordinator.OperatorKickParam[] calldata _operatorKickParams,
        ISignatureUtils.SignatureWithSaltAndExpiry memory _churnApproverSignature,
        ISignatureUtils.SignatureWithSaltAndExpiry memory _operatorSignature
    ) external onlyOperator(_id) {
        EtherFiAvsOperator.AvsInfo memory avsInfo = avsOperators[_id].getAvsInfo(_avsRegistryCoordinator);
        avsOperators[_id].registerOperatorWithChurn(_avsRegistryCoordinator, _operatorKickParams, _churnApproverSignature, _operatorSignature);

        emit RegisteredOperator(_id, _avsRegistryCoordinator, avsInfo.quorumNumbers, avsInfo.socket, avsInfo.params, _operatorSignature);
    }

    function deregisterOperator(
        uint256 _id,
        address _avsRegistryCoordinator,
        bytes calldata quorumNumbers
    ) external onlyOperator(_id) {
        avsOperators[_id].deregisterOperator(_avsRegistryCoordinator, quorumNumbers);

        emit DeregisteredOperator(_id, _avsRegistryCoordinator, quorumNumbers);
    }

    function updateSocket(
        uint256 _id,
        address _avsRegistryCoordinator, 
        string memory _socket
    ) external onlyOperator(_id) {
        avsOperators[_id].updateSocket(_avsRegistryCoordinator, _socket);

        emit UpdatedSocket(_id, _avsRegistryCoordinator, _socket);
    }

    // Once an operator is registered, they cannot 'deregister' as an operator, and they will forever be considered "delegated to themself"
    function registerAsOperator(uint256 _id, IDelegationManager.OperatorDetails calldata _detail, string calldata _metaDataURI) external onlyOwner {
        avsOperators[_id].registerAsOperator(delegationManager, _detail, _metaDataURI);

        emit RegisteredAsOperator(_id, _detail);
    }

    function modifyOperatorDetails(uint256 _id, IDelegationManager.OperatorDetails calldata _newOperatorDetails) external onlyAdmin {
        avsOperators[_id].modifyOperatorDetails(delegationManager, _newOperatorDetails);

        emit ModifiedOperatorDetails(_id, _newOperatorDetails);
    }

    function updateOperatorMetadataURI(uint256 _id, string calldata _metadataURI) external onlyAdmin {
        avsOperators[_id].updateOperatorMetadataURI(delegationManager, _metadataURI);

        emit UpdatedOperatorMetadataURI(_id, _metadataURI);
    }

    function updateAvsNodeRunner(uint256 _id, address _avsNodeRunner) external onlyAdmin {
        avsOperators[_id].updateAvsNodeRunner(_avsNodeRunner);

        emit UpdatedAvsNodeRunner(_id, _avsNodeRunner);
    }

    function updateAvsWhitelist(uint256 _id, address _avsRegistryCoordinator, bool _isWhitelisted) external onlyAdmin {
        avsOperators[_id].updateAvsWhitelist(_avsRegistryCoordinator, _isWhitelisted);

        emit UpdatedAvsWhitelist(_id, _avsRegistryCoordinator, _isWhitelisted);
    }

    function updateEcdsaSigner(uint256 _id, address _ecdsaSigner) external onlyAdmin {
        avsOperators[_id].updateEcdsaSigner(_ecdsaSigner);

        emit UpdatedEcdsaSigner(_id, _ecdsaSigner);
    }

    function updateAdmin(address _address, bool _isAdmin) external onlyOwner {
        admins[_address] = _isAdmin;
    }

    function instantiateEtherFiAvsOperator(uint256 _nums) external onlyOwner returns (uint256[] memory _ids) {
        _ids = new uint256[](_nums);
        for (uint256 i = 0; i < _nums; i++) {
            _ids[i] = _instantiateEtherFiAvsOperator();
        }
    }

    function upgradeEtherFiAvsOperator(address _newImplementation) public onlyOwner {
        upgradableBeacon.upgradeTo(_newImplementation);
    }

    // VIEW functions

    function getAvsInfo(uint256 _id, address _avsRegistryCoordinator) external view returns (EtherFiAvsOperator.AvsInfo memory) {
        return avsOperators[_id].getAvsInfo(_avsRegistryCoordinator);
    }

    function isAvsWhitelisted(uint256 _id, address _avsRegistryCoordinator) external view returns (bool) {
        return avsOperators[_id].isAvsWhitelisted(_avsRegistryCoordinator);
    }

    function isAvsRegistered(uint256 _id, address _avsRegistryCoordinator) external view returns (bool) {
        return avsOperators[_id].isAvsRegistered(_avsRegistryCoordinator);
    }

    function isRegisteredBlsKey(uint256 _id, address _avsRegistryCoordinator, bytes calldata _quorumNumbers, string calldata _socket, IBLSApkRegistry.PubkeyRegistrationParams calldata _params) external view returns (bool) {
        return avsOperators[_id].isRegisteredBlsKey(_avsRegistryCoordinator, _quorumNumbers, _socket, _params);
    }

    function avsNodeRunner(uint256 _id) external view returns (address) {
        return avsOperators[_id].avsNodeRunner();
    }

    function ecdsaSigner(uint256 _id) external view returns (address) {
        return avsOperators[_id].ecdsaSigner();
    }

    function operatorDetails(uint256 _id) external view returns (IDelegationManager.OperatorDetails memory) {
        return delegationManager.operatorDetails(address(avsOperators[_id]));
    }

    /**
     * @notice Calculates the digest hash to be signed by an operator to register with an AVS
     * @param _id The id of etherfi avs operator
     * @param _avsServiceManager The AVS's service manager contract address
     * @param _salt A unique and single use value associated with the approver signature.
     * @param _expiry Time after which the approver's signature becomes invalid
     */
    function calculateOperatorAVSRegistrationDigestHash(uint256 _id, address _avsServiceManager, bytes32 _salt, uint256 _expiry) external view returns (bytes32) {
        address _operator = address(avsOperators[_id]);
        return avsDirectory.calculateOperatorAVSRegistrationDigestHash(_operator, _avsServiceManager, _salt, _expiry);
    }

    /// @param _id The id of etherfi avs operator
    /// @param _avsServiceManager The AVS's service manager contract address
    function avsOperatorStatus(uint256 _id, address _avsServiceManager) external view returns (IAVSDirectory.OperatorAVSRegistrationStatus) {
        return avsDirectory.avsOperatorStatus(_avsServiceManager, address(avsOperators[_id]));
    }

    // INTERNAL functions

    function _instantiateEtherFiAvsOperator() internal returns (uint256 _id) {
        _id = nextAvsOperatorId++;
        require(address(avsOperators[_id]) == address(0), "INVALID_ID");

        BeaconProxy proxy = new BeaconProxy(address(upgradableBeacon), "");
        avsOperators[_id] = EtherFiAvsOperator(address(proxy));
        avsOperators[_id].initialize(address(this));

        emit CreatedEtherFiAvsOperator(_id, address(avsOperators[_id]));

        return _id;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function _onlyAdmin() internal view {
        require(admins[msg.sender] || msg.sender == owner(), "INCORRECT_CALLER");
    }

    function _onlyOperator(uint256 _id) internal view {
        require(msg.sender == avsOperators[_id].avsNodeRunner() || admins[msg.sender] || msg.sender == owner(), "INCORRECT_CALLER");
    }

    modifier onlyAdmin() {
        _onlyAdmin();
        _;
    }

    modifier onlyOperator(uint256 _id) {
        _onlyOperator(_id);
        _;
    }

}