// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@etherfi/interfaces/IWETH.sol";
import "@etherfi/interfaces/IwstETH.sol";
import "@etherfi/core/interfaces/ILiquidityPool.sol";
import "@etherfi/core/interfaces/IeETH.sol";
import "@etherfi/core/interfaces/IWeETH.sol";
import "@etherfi/deposits/interfaces/IDepositAdapter.sol";
import "@etherfi/governance/interfaces/IBlacklister.sol";
import "@etherfi/governance/utils/RolesLibrary.sol";
import "@etherfi/governance/utils/DeprecatedOZOwnable.sol";

contract DepositAdapter is UUPSUpgradeable, DeprecatedOZOwnable, RolesLibrary, IDepositAdapter {
    using SafeERC20 for IERC20;

    //--------------------------------------------------------------------------------------
    //---------------------------------  IMMUTABLES  ---------------------------------------
    //--------------------------------------------------------------------------------------
    ILiquidityPool public immutable liquidityPool;
    ILiquifier public immutable liquifier;
    IeETH public immutable eETH;
    IWeETH public immutable weETH;
    IWETH public immutable wETH;
    IERC20Upgradeable public immutable stETH;
    IwstETH public immutable wstETH;
    IBlacklister public immutable blacklister;

    //--------------------------------------------------------------------------------------
    //---------------------------------  EVENTS  ---------------------------------------
    //--------------------------------------------------------------------------------------
    event AdapterDeposit(address indexed sender, uint256 amount, SourceOfFunds source, address referral);
    event DustSwept(address indexed token, address indexed to, uint256 amount);

    //--------------------------------------------------------------------------------------
    //---------------------------------  ERRORS  ---------------------------------------
    //--------------------------------------------------------------------------------------
    error AllowanceExceeded();
    error InsufficientBalance();
    error PermitExpired();
    error EthTransfersNotAccepted();
    error InvalidRecipient();

    //--------------------------------------------------------------------------------------
    //---------------------------------  CONSTRUCTOR  ---------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Constructor
     * @param _constructorAddresses The addresses of the constructor addresses
     */
    constructor(ConstructorAddresses memory _constructorAddresses) RolesLibrary(_constructorAddresses.roleRegistry) {
        liquidityPool = ILiquidityPool(_constructorAddresses.liquidityPool);
        liquifier = ILiquifier(_constructorAddresses.liquifier);
        eETH = IeETH(_constructorAddresses.eETH);
        weETH = IWeETH(_constructorAddresses.weETH);
        wETH = IWETH(_constructorAddresses.wETH);
        stETH = IERC20Upgradeable(_constructorAddresses.stETH);
        wstETH = IwstETH(_constructorAddresses.wstETH);
        blacklister = IBlacklister(_constructorAddresses.blacklister);

        _disableInitializers();
    }

    //--------------------------------------------------------------------------------------
    //---------------------------------  INITIALIZERS  ---------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Initialize the contract
     */
    function initialize() initializer external {
        __Ownable_init();
        __UUPSUpgradeable_init();
    }

    //--------------------------------------------------------------------------------------
    //---------------------------------  DEPOSIT FUNCTIONS  ---------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Deposit ETH for weETH
     * @param _referral Address to credit rewards
     * @return weEthAmount weETH received by the depositer
     */
    function depositETHForWeETH(address _referral) external payable nonBlacklisted returns (uint256) {
        uint256 eETHShares = liquidityPool.deposit{value: msg.value}(_referral);
        
        emit AdapterDeposit(msg.sender, msg.value, SourceOfFunds.ETH, _referral);
        return _wrapAndReturn(eETHShares);
    }

    /**
     * @notice Deposit WETH for weETH
     * @param _amount Amount of WETH to deposit 
     * @param _referral Address to credit referral
     * @return weEthAmount weETH received by the depositer
     * @dev WETH doesn't support permit, so this function requires an explicit approval before use
     */
    function depositWETHForWeETH(uint256 _amount, address _referral) external nonBlacklisted returns (uint256) {
        if (wETH.allowance(msg.sender, address(this)) < _amount) revert AllowanceExceeded();
        if (wETH.balanceOf(msg.sender) < _amount) revert InsufficientBalance();
        
        IERC20(address(wETH)).safeTransferFrom(msg.sender, address(this), _amount);
        wETH.withdraw(_amount);

        uint256 eETHShares = liquidityPool.deposit{value: _amount}(_referral);
        
        emit AdapterDeposit(msg.sender, _amount, SourceOfFunds.WETH, _referral);
        return _wrapAndReturn(eETHShares);
    }

    /**
     * @notice Deposit stETH to liquifier for weETH
     * @param _amount Amount of stETH to deposit
     * @param _referral Address to credit referral
     * @param _permit Permit signature
     * @return weEthAmount weETH received by the depositer
     * @dev Permit must be created to this contract 
     */
    function depositStETHForWeETHWithPermit(uint256 _amount, address _referral, ILiquifier.PermitInput calldata _permit) external nonBlacklisted returns (uint256) {
        try IERC20PermitUpgradeable(address(stETH)).permit(msg.sender, address(this), _permit.value, _permit.deadline, _permit.v, _permit.r, _permit.s) {}
        catch {
            if (_permit.deadline < block.timestamp) revert PermitExpired();
        }

        // Accounting for the 1-2 wei corner case
        uint256 initialBalance = stETH.balanceOf(address(this));
        IERC20(address(stETH)).safeTransferFrom(msg.sender, address(this), _amount);
        uint256 actualTransferredAmount = stETH.balanceOf(address(this)) - initialBalance;

        IERC20(address(stETH)).safeIncreaseAllowance(address(liquifier), actualTransferredAmount);
        uint256 eETHShares = liquifier.depositWithERC20(address(stETH), actualTransferredAmount, _referral);
        
        emit AdapterDeposit(msg.sender, actualTransferredAmount, SourceOfFunds.STETH, _referral);
        return _wrapAndReturn(eETHShares);
    }

    /**
     * @notice Deposit wstETH for weETH
     * @param _amount Amount of wstETH to deposit
     * @param _referral Address to credit referral
     * @param _permit Permit signature
     * @return weEthAmount weETH received by the depositer
     * @dev Permit for wsETH must be created to this contract. funds are unwrapped to stETH and deposited to liquifier
     */
    function depositWstETHForWeETHWithPermit(uint256 _amount, address _referral, ILiquifier.PermitInput calldata _permit) external nonBlacklisted returns (uint256) {
        try wstETH.permit(msg.sender, address(this), _permit.value, _permit.deadline, _permit.v, _permit.r, _permit.s) {}
        catch {
            if (_permit.deadline < block.timestamp) revert PermitExpired();
        }

        IERC20(address(wstETH)).safeTransferFrom(msg.sender, address(this), _amount);

        // Accounting for the 1-2 wei corner case
        uint256 initialBalance = stETH.balanceOf(address(this));
        uint256 stETHAmount = wstETH.unwrap(_amount);
        uint256 actualTransferredAmount = stETH.balanceOf(address(this)) - initialBalance;

        IERC20(address(stETH)).safeIncreaseAllowance(address(liquifier), actualTransferredAmount);
        uint256 eETHShares = liquifier.depositWithERC20(address(stETH), actualTransferredAmount, _referral);
        
        emit AdapterDeposit(msg.sender, actualTransferredAmount, SourceOfFunds.WSTETH, _referral);
        return _wrapAndReturn(eETHShares);
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  OPERATIONAL FUNCTIONS  -------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Sweep dust accumulated in the adapter to a recipient.
     * @param _token Address of the ERC20 to sweep
     * @param _to Recipient of the swept tokens
     * @dev Each deposit strands 1-2 wei of eETH due to floor-rounding in both
     *      amountForShare (shares -> ETH) and wrap (ETH -> shares). This function
     *      lets operations recover the residual balance of any ERC20 left here.
     */
    function sweepDust(address _token, address _to) external onlyOperatingMultisig {
        if (_to == address(0)) revert InvalidRecipient();
        uint256 balance = IERC20(_token).balanceOf(address(this));
        if (balance == 0) revert InsufficientBalance();
        IERC20(_token).safeTransfer(_to, balance);
        emit DustSwept(_token, _to, balance);
    }

    /**
     * @notice Receive ETH
     * @dev Only callable when the msg.sender is the wETH contract
     */
    receive() external payable {
        if (msg.sender != address(wETH)) revert EthTransfersNotAccepted();
    }

    //--------------------------------------------------------------------------------------
    //---------------------------------  INTERNAL FUNCTIONS  ---------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Wrap eETH shares and return weETH
     * @param _eEthShares Amount of eETH shares to wrap
     * @return weEthAmount weETH received by the depositer
     */
    function _wrapAndReturn(uint256 _eEthShares) internal returns (uint256) {
        uint256 eEthAmount = liquidityPool.amountForShare(_eEthShares);
        IERC20(address(eETH)).safeIncreaseAllowance(address(weETH), eEthAmount);
        uint256 weEthAmount = weETH.wrap(eEthAmount);
        IERC20(address(weETH)).safeTransfer(msg.sender, weEthAmount);

        return weEthAmount;
    }

    /**
     * @notice Authorize contract upgrades
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyUpgradeTimelock {}

    //--------------------------------------------------------------------------------------
    //---------------------------------  MODIFIERS  ---------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Check if the sender is not blacklisted
     */
    modifier nonBlacklisted() {
        blacklister.nonBlacklisted(msg.sender);
        _;
    }
}
