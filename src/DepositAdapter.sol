// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/draft-IERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/ILiquidityPool.sol";
import "./interfaces/ILiquifier.sol";
import "./interfaces/IeETH.sol";
import "./interfaces/IWeETH.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IwstETH.sol";
import "./interfaces/IBlacklister.sol";
import "./utils/RolesLibrary.sol";

contract DepositAdapter is UUPSUpgradeable, OwnableUpgradeable, RolesLibrary {
    using SafeERC20 for IERC20;

    ILiquidityPool public immutable liquidityPool;
    ILiquifier public immutable liquifier;
    IeETH public immutable eETH;
    IWeETH public immutable weETH;
    IWETH public immutable wETH;
    IERC20Upgradeable public immutable stETH;
    IwstETH public immutable wstETH;
    IBlacklister public immutable blacklister;

     enum SourceOfFunds {
        ETH,
        WETH,
        STETH,
        WSTETH
    }

    event AdapterDeposit(address indexed sender, uint256 amount, SourceOfFunds source, address referral);

    error AllowanceExceeded();
    error InsufficientBalance();
    error PermitExpired();
    error EthTransfersNotAccepted();

    constructor(address _liquidityPool, address _liquifier, address _weETH, address _eETH, address _wETH, address _stETH, address _wstETH, address _roleRegistry, address _blacklister) RolesLibrary(_roleRegistry) {
        liquidityPool = ILiquidityPool(_liquidityPool);
        liquifier = ILiquifier(_liquifier);
        eETH = IeETH(_eETH);
        weETH = IWeETH(_weETH);
        wETH = IWETH(_wETH);
        stETH = IERC20Upgradeable(_stETH);
        wstETH = IwstETH(_wstETH);
        blacklister = IBlacklister(_blacklister);

        _disableInitializers();
    }

    function initialize() initializer external {
        __Ownable_init();
        __UUPSUpgradeable_init();
    }

    /// @notice Deposit ETH for weETH
    /// @param _referral Address to credit rewards
    /// @return weEthAmount weETH received by the depositer
    function depositETHForWeETH(address _referral) external payable nonBlacklisted returns (uint256) {
        uint256 eETHShares = liquidityPool.deposit{value: msg.value}(_referral);
        
        emit AdapterDeposit(msg.sender, msg.value, SourceOfFunds.ETH, _referral);
        return _wrapAndReturn(eETHShares);
    }

    /// @notice Deposit WETH for weETH
    /// @dev WETH doesn't support permit, so this function requires an explicit approval before use
    /// @param _amount Amount of WETH to deposit 
    /// @param _referral Address to credit referral
    /// @return weEthAmount weETH received by the depositer
    function depositWETHForWeETH(uint256 _amount, address _referral) external nonBlacklisted returns (uint256) {
        if (wETH.allowance(msg.sender, address(this)) < _amount) revert AllowanceExceeded();
        if (wETH.balanceOf(msg.sender) < _amount) revert InsufficientBalance();
        
        IERC20(address(wETH)).safeTransferFrom(msg.sender, address(this), _amount);
        wETH.withdraw(_amount);

        uint256 eETHShares = liquidityPool.deposit{value: _amount}(_referral);
        
        emit AdapterDeposit(msg.sender, _amount, SourceOfFunds.WETH, _referral);
        return _wrapAndReturn(eETHShares);
    }

    /// @notice Deposit stETH to liquifier for weETH
    /// @dev Permit must be created to this contract 
    /// @param _amount Amount of stETH to deposit
    /// @param _referral Address to credit referral
    /// @param _permit Permit signature
    /// @return weEthAmount weETH received by the depositer
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

    /// @notice Deposit wstETH for weETH
    /// @dev Permit for wsETH must be created to this contract. funds are unwrapped to stETH and deposited to liquifier
    /// @param _amount Amount of wstETH to deposit
    /// @param _referral Address to credit referral
    /// @param _permit Permit signature
    /// @return weEthAmount weETH received by the depositer
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

    receive() external payable {
        if (msg.sender != address(wETH)) revert EthTransfersNotAccepted();
    }

    function _wrapAndReturn(uint256 _eEthShares) internal returns (uint256) {
        uint256 eEthAmount = liquidityPool.amountForShare(_eEthShares);
        IERC20(address(eETH)).safeIncreaseAllowance(address(weETH), eEthAmount);
        uint256 weEthAmount = weETH.wrap(eEthAmount);
        IERC20(address(weETH)).safeTransfer(msg.sender, weEthAmount);

        return weEthAmount;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyUpgradeTimelock {}

    modifier nonBlacklisted() {
        blacklister.nonBlacklisted(msg.sender);
        _;
    }
}
