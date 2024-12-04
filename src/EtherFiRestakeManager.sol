// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import "./Liquifier.sol";
import "./EtherFiRestaker.sol";
import "./RoleRegistry.sol";

contract EtherFiRestakeManager is Initializable, OwnableUpgradeable, UUPSUpgradeable {

    LiquidityPool public liquidityPool;
    Liquifier public liquifier;
    RoleRegistry public roleRegistry;
    ILidoWithdrawalQueue public lidoWithdrawalQueue;
    ILido public lido;

    UpgradeableBeacon public upgradableBeacon;
    uint256 public nextAvsOperatorId;
    mapping(uint256 => EtherFiRestaker) public etherFiRestaker;

    bytes32 public constant RESTAKING_MANAGER_ADMIN_ROLE = keccak256("RESTAKING_MANAGER_ADMIN_ROLE");

    event QueuedStEthWithdrawals(uint256[] _reqIds);
    event CompletedStEthQueuedWithdrawals(uint256[] _reqIds);
    event CreatedEtherFiRestaker(uint256 indexed id, address etherFiRestaker);

    error IncorrectAmount();
    error IncorrectRole();
    error NotEnoughBalance();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _liquidityPool, address _liquifier, address _roleRegistry, address _etherFiRestakerImpl) initializer external {
        __Ownable_init();
        __UUPSUpgradeable_init();

        nextAvsOperatorId = 1;
        upgradableBeacon = new UpgradeableBeacon(_etherFiRestakerImpl);
        liquidityPool = LiquidityPool(payable(_liquidityPool));
        liquifier = Liquifier(payable(_liquifier));
        roleRegistry = RoleRegistry(_roleRegistry);

        lido = liquifier.lido();
        lidoWithdrawalQueue = liquifier.lidoWithdrawalQueue();
    }

    function upgradeEtherFiRestaker(address _newImplementation) external onlyOwner {
        upgradableBeacon.upgradeTo(_newImplementation);
    }

    function instantiateEtherFiRestaker(uint256 _nums) external returns (uint256[] memory _ids) {
        if (!roleRegistry.hasRole(RESTAKING_MANAGER_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        _ids = new uint256[](_nums);
        for (uint256 i = 0; i < _nums; i++) {
            _ids[i] = _instantiateEtherFiRestaker();
        }
    }

    function _instantiateEtherFiRestaker() internal returns (uint256 _id) {
        _id = nextAvsOperatorId++;
        require(address(etherFiRestaker[_id]) == address(0), "INVALID_ID");

        BeaconProxy proxy = new BeaconProxy(address(upgradableBeacon), "");
        etherFiRestaker[_id] = EtherFiRestaker(payable(address(proxy)));
        etherFiRestaker[_id].initialize(address(liquidityPool), address(liquifier), address(this));

        emit CreatedEtherFiRestaker(_id, address(etherFiRestaker[_id]));

        return _id;
    }

    // |--------------------------------------------------------------------------------------------|
    // |                                    EigenLayer Restaking                                    |
    // |--------------------------------------------------------------------------------------------|

    /// @notice delegate to an AVS operator for a `EtherFiRestaker` instance by index
    /// @param index `EtherFiRestaker` instance to call `delegate` on
    function delegateTo(uint256 index, address operator, IDelegationManager.SignatureWithExpiry memory approverSignatureAndExpiry, bytes32 approverSalt) external {
        if (!roleRegistry.hasRole(RESTAKING_MANAGER_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        return etherFiRestaker[index].delegateTo(operator, approverSignatureAndExpiry, approverSalt);
    }

    /// @notice undelegate from the current AVS operator & un-restake all
    /// @dev Only considers stETH. Will need modification to support additional tokens
    /// @param index `EtherFiRestaker` instance to call `undelegate` on
    function undelegate(uint256 index) external returns (bytes32[] memory) {
        if (!roleRegistry.hasRole(RESTAKING_MANAGER_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        return etherFiRestaker[index].undelegate();
    }

    /// @notice deposit the token in holding into the restaking strategy
    /// @param index `EtherFiRestaker` instance to deposit from
    function depositIntoStrategy(
        uint256 index,
        address token,
        uint256 amount
    ) external  returns (uint256) {
        if (!roleRegistry.hasRole(RESTAKING_MANAGER_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        IERC20(token).transfer(address(etherFiRestaker[index]), amount);
        return etherFiRestaker[index].depositIntoStrategy(token);
    }

    /// @notice queue withdrawals for un-restaking the token
    /// Made easy for operators
    /// @param index `EtherFiRestaker` instance to withdraw from
    /// @param token the token to withdraw
    /// @param amount the amount of token to withdraw
    function queueWithdrawals(
        uint256 index,
        address token,
        uint256 amount
    ) external returns (bytes32[] memory) {
        if (!roleRegistry.hasRole(RESTAKING_MANAGER_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        return etherFiRestaker[index].queueWithdrawals(token, amount);
    }

    /// Advanced version
    /// @notice queue withdrawals with custom parameters for un-restaking multiple tokens
    /// @param index `EtherFiRestaker` instance to withdraw from
    /// @param queuedWithdrawalParams Array of withdrawal parameters including strategies and share amounts
    function queueWithdrawalsAdvanced(
        uint256 index,
        IDelegationManager.QueuedWithdrawalParams[] memory queuedWithdrawalParams
    ) external returns (bytes32[] memory) {
        if (!roleRegistry.hasRole(RESTAKING_MANAGER_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        return etherFiRestaker[index].queueWithdrawalsAdvanced(queuedWithdrawalParams);
    }

    /// @notice Complete the queued withdrawals that are ready to be withdrawn
    /// @param index `EtherFiRestaker` instance to call `completeQueuedWithdrawals` on
    /// @param max_cnt the maximum number of withdrawals to complete
    function completeQueuedWithdrawals(
        uint256 index,
        uint256 max_cnt
    ) external {
        if (!roleRegistry.hasRole(RESTAKING_MANAGER_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        etherFiRestaker[index].completeQueuedWithdrawals(max_cnt);
    }

    /// Advanced version
    /// @notice Used to complete the specified `queuedWithdrawals`. The function caller must match `queuedWithdrawals[...].withdrawer`
    /// @param index `EtherFiRestaker` instance to call `completeQueuedWithdrawals` on
    /// @param _queuedWithdrawals The QueuedWithdrawals to complete.
    /// @param _tokens Array of tokens for each QueuedWithdrawal. See `completeQueuedWithdrawal` for the usage of a single array.
    /// @param _middlewareTimesIndexes One index to reference per QueuedWithdrawal. See `completeQueuedWithdrawal` for the usage of a single index.
    /// @dev middlewareTimesIndex should be calculated off chain before calling this function by finding the first index that satisfies `slasher.canWithdraw`
    function completeQueuedWithdrawalsAdvanced(
        uint256 index,
        IDelegationManager.Withdrawal[] memory _queuedWithdrawals,
        IERC20[][] memory _tokens,
        uint256[] memory _middlewareTimesIndexes
    ) external {
        if (!roleRegistry.hasRole(RESTAKING_MANAGER_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        etherFiRestaker[index].completeQueuedWithdrawalsAdvanced(
            _queuedWithdrawals,
            _tokens,
            _middlewareTimesIndexes
        );
    }

    // |--------------------------------------------------------------------------------------------|
    // |                                   Handling Lido's stETH                                    |
    // |--------------------------------------------------------------------------------------------|

    /// @notice Initiate the redemption of stETH for ETH 
    function stEthRequestWithdrawal() external returns (uint256[] memory) {
        if (!roleRegistry.hasRole(RESTAKING_MANAGER_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        uint256 amount = lido.balanceOf(address(this));
        return stEthRequestWithdrawal(amount);
    }

    /// @notice Request for a specific amount of stETH holdings
    /// @param _amount the amount of stETH to request
    function stEthRequestWithdrawal(uint256 _amount) public returns (uint256[] memory) {
        if (!roleRegistry.hasRole(RESTAKING_MANAGER_ADMIN_ROLE, msg.sender)) revert IncorrectRole();
        if (_amount < lidoWithdrawalQueue.MIN_STETH_WITHDRAWAL_AMOUNT()) revert IncorrectAmount();
        if (_amount > lido.balanceOf(address(this))) revert NotEnoughBalance();

        uint256 maxAmount = lidoWithdrawalQueue.MAX_STETH_WITHDRAWAL_AMOUNT();
        uint256 numReqs = (_amount + maxAmount - 1) / maxAmount;
        uint256[] memory reqAmounts = new uint256[](numReqs);
        for (uint256 i = 0; i < numReqs; i++) {
            reqAmounts[i] = (i == numReqs - 1) ? _amount - i * maxAmount : maxAmount;
        }
        lido.approve(address(lidoWithdrawalQueue), _amount);
        uint256[] memory reqIds = lidoWithdrawalQueue.requestWithdrawals(reqAmounts, address(this));

        emit QueuedStEthWithdrawals(reqIds);

        return reqIds;
    }

    /// @notice Claim a batch of withdrawal requests if they are finalized sending the ETH to the this contract back
    /// @param _requestIds array of request ids to claim
    /// @param _hints checkpoint hint for each id. Can be obtained with `findCheckpointHints()`
    function stEthClaimWithdrawals(uint256[] calldata _requestIds, uint256[] calldata _hints) external {
        if (!roleRegistry.hasRole(RESTAKING_MANAGER_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        lidoWithdrawalQueue.claimWithdrawals(_requestIds, _hints);

        withdrawEther();

        emit CompletedStEthQueuedWithdrawals(_requestIds);
    }

    /// @notice Sends the ETH in this contract to the liquidity pool
    function withdrawEther() public {
        if (!roleRegistry.hasRole(RESTAKING_MANAGER_ADMIN_ROLE, msg.sender)) revert IncorrectRole();
        
        uint256 amountToLiquidityPool = address(this).balance;
        (bool sent, ) = payable(address(liquidityPool)).call{value: amountToLiquidityPool, gas: 20000}("");
        require(sent, "ETH_SEND_TO_LIQUIDITY_POOL_FAILED");
    }

    // |--------------------------------------------------------------------------------------------|
    // |                                    VIEW functions                                          |
    // |--------------------------------------------------------------------------------------------|

    /// @notice The total amount in wei of assets controlled by the `EtherFiRestakingManager` and `EtherFiRestaker` instances
    /// @dev Only considers stETH. Will need modification to support additional tokens
    function getTotalPooledEther() external view returns (uint256 amount){
        uint256 amount = lido.balanceOf(address(this));
        amount += getEthAmountPendingForRedemption(address(lido));
        for (uint256 i = 1; i < nextAvsOperatorId; i++) {
            amount += etherFiRestaker[i].getTotalPooledEther();
        }
        return amount;
    }

    /// @notice The assets controlled by the manager split between 4 states
    /// - restaked in Eigenlayer from an `EtherFiRestaker` instance
    /// - pending for un-restaking from Eigenlayer
    /// - non-restaked & held by this contract
    /// - non-restaked & pending in redemption for ETH
    /// @dev Only considers stETH. Will need modification to support additional tokens
    function getTotalPooledEtherSplits() public view returns (uint256 holding, uint256 pendingForWithdrawals, uint256 restaked, uint256 unrestaking) {
        holding = lido.balanceOf(address(this));
        pendingForWithdrawals = getEthAmountPendingForRedemption(address(lido));
        for (uint256 i = 1; i < nextAvsOperatorId; i++) {
            (uint256 restakedInInstance, uint256 unrestakedInInstance) = etherFiRestaker[i].getTotalPooledEtherSplits();
            restaked += restakedInInstance;
            unrestaking += unrestakedInInstance;
        }
    }

    function getEthAmountPendingForRedemption(address _token) public view returns (uint256) {
        uint256 total = 0;
        if (_token == address(lido)) {
            uint256[] memory stEthWithdrawalRequestIds = lidoWithdrawalQueue.getWithdrawalRequests(address(this));
            ILidoWithdrawalQueue.WithdrawalRequestStatus[] memory statuses = lidoWithdrawalQueue.getWithdrawalStatus(stEthWithdrawalRequestIds);
            for (uint256 i = 0; i < statuses.length; i++) {
                require(statuses[i].owner == address(this), "Not the owner");
                require(!statuses[i].isClaimed, "Already claimed");
                total += statuses[i].amountOfStETH;
            }
        }
        return total;
    }

    receive() external payable {}

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

}
