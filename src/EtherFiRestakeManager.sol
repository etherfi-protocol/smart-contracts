// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import "./Liquifier.sol";
import "./EtherFiRestaker.sol";

contract EtherFiRestakeManager is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{

    LiquidityPool public liquidityPool;
    Liquifier public liquifier;
    ILidoWithdrawalQueue public lidoWithdrawalQueue;
    ILido public lido;

    mapping(address => bool) public pausers;
    mapping(address => bool) public admins;

    UpgradeableBeacon public upgradableBeacon;
    uint256 public nextAvsOperatorId;
    mapping(uint256 => EtherFiRestaker) public etherFiRestaker;

    event QueuedStEthWithdrawals(uint256[] _reqIds);
    event CompletedStEthQueuedWithdrawals(uint256[] _reqIds);
    event CreatedEtherFiRestaker(uint256 indexed id, address etherFiRestaker);

    error IncorrectCaller();
    error IncorrectAmount();
    error NotEnoughBalance();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _liquidityPool, address _liquifier) initializer external {
        __Ownable_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        liquidityPool = LiquidityPool(payable(_liquidityPool));
        liquifier = Liquifier(payable(_liquifier));

        lido = liquifier.lido();
        lidoWithdrawalQueue = liquifier.lidoWithdrawalQueue();
    }

    function instantiateEtherFiRestaker(uint256 _nums) external onlyOwner returns (uint256[] memory _ids) {
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

    function delegateTo(uint256 index, address operator, IDelegationManager.SignatureWithExpiry memory approverSignatureAndExpiry, bytes32 approverSalt) external {
        return etherFiRestaker[index].delegateTo(operator, approverSignatureAndExpiry, approverSalt);
    }

    function undelegate(uint256 index) external returns (bytes32[] memory) {
        return etherFiRestaker[index].undelegate();
    }

    function depositIntoStrategy(
        uint256 index,
        address token,
        uint256 amount
    ) external  returns (uint256) {
        IERC20(token).transfer(address(etherFiRestaker[index]), amount);
        return etherFiRestaker[index].depositIntoStrategy(token);
    }

    function queueWithdrawals(
        uint256 index,
        address token,
        uint256 amount
    ) external returns (bytes32[] memory) {
        return etherFiRestaker[index].queueWithdrawals(token, amount);
    }

    function queueWithdrawalsAdvanced(
        uint256 index,
        IDelegationManager.QueuedWithdrawalParams[] memory queuedWithdrawalParams
    ) external returns (bytes32[] memory) {
        return etherFiRestaker[index].queueWithdrawals(queuedWithdrawalParams);
    }

    function completeQueuedWithdrawals(
        uint256 index,
        uint256 max_cnt
    ) external {
        etherFiRestaker[index].completeQueuedWithdrawals(max_cnt);
    }

    function completeQueuedWithdrawalsAdvanced(
        uint256 index,
        IDelegationManager.Withdrawal[] memory _queuedWithdrawals,
        IERC20[][] memory _tokens,
        uint256[] memory _middlewareTimesIndexes
    ) external {
        etherFiRestaker[index].completeQueuedWithdrawals(
            _queuedWithdrawals,
            _tokens,
            _middlewareTimesIndexes
        );
    }

    // |--------------------------------------------------------------------------------------------|
    // |                                   Handling Lido's stETH                                    |
    // |--------------------------------------------------------------------------------------------|

    /// Initiate the redemption of stETH for ETH 
    /// @notice Request for all stETH holdings
    function stEthRequestWithdrawal() external onlyAdmin returns (uint256[] memory) {
        uint256 amount = lido.balanceOf(address(this));
        return stEthRequestWithdrawal(amount);
    }

    /// @notice Request for a specific amount of stETH holdings
    /// @param _amount the amount of stETH to request
    function stEthRequestWithdrawal(uint256 _amount) public onlyAdmin returns (uint256[] memory) {
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
    function stEthClaimWithdrawals(uint256[] calldata _requestIds, uint256[] calldata _hints) external onlyAdmin {
        uint256 balance = address(this).balance;
        lidoWithdrawalQueue.claimWithdrawals(_requestIds, _hints);

        withdrawEther();

        emit CompletedStEthQueuedWithdrawals(_requestIds);
    }

    // Send the ETH back to the liquidity pool
    function withdrawEther() public onlyAdmin {
        uint256 amountToLiquidityPool = address(this).balance;
        (bool sent, ) = payable(address(liquidityPool)).call{value: amountToLiquidityPool, gas: 20000}("");
        require(sent, "ETH_SEND_TO_LIQUIDITY_POOL_FAILED");
    }

    // |--------------------------------------------------------------------------------------------|
    // |                                    VIEW functions                                          |
    // |--------------------------------------------------------------------------------------------|

    /// @notice Returns the total stETH {staked, unstaked}
    function getTotalPooledStETH() external view returns (uint256 amount){
        uint256 amount = lido.balanceOf(address(this));
        for (uint256 i = 0; i < nextAvsOperatorId; i++) {
            amount += etherFiRestaker[i].getRestakedAmount();
        }
        return amount;
    }

    receive() external payable {}

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function _requireAdmin() internal view virtual {
        if (!(admins[msg.sender] || msg.sender == owner())) revert IncorrectCaller();
    }

    function _requirePauser() internal view virtual {
        if (!(pausers[msg.sender] || admins[msg.sender] || msg.sender == owner())) revert IncorrectCaller();
    }

    /* MODIFIER */
    modifier onlyAdmin() {
        _requireAdmin();
        _;
    }

    modifier onlyPauser() {
        _requirePauser();
        _;
    }
}
