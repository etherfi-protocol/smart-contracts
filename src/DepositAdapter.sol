// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/draft-IERC20PermitUpgradeable.sol";

import "./interfaces/ILiquidityPool.sol";
import "./interfaces/ILiquifier.sol";
import "./interfaces/IeETH.sol";
import "./interfaces/IWeETH.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IwstETH.sol";

contract DepositAdapter is UUPSUpgradeable, OwnableUpgradeable {

    ILiquidityPool public immutable liquidityPool;
    ILiquifier public immutable liquifier;
    IeETH public immutable eETH;
    IWeETH public immutable weETH;
    IWETH public immutable wETH;
    IERC20Upgradeable public immutable stETH;
    IwstETH public immutable wstETH;

     enum SourceOfFunds {
        ETH,
        WETH,
        STETH,
        WSTETH
    }

    event AdapterDeposit(address indexed sender, uint256 amount, SourceOfFunds source, address referral);

    constructor(address _liquidityPool, address _liquifier, address _weETH, address _eETH, address _wETH, address _stETH, address _wstETH) {
        liquidityPool = ILiquidityPool(_liquidityPool);
        liquifier = ILiquifier(_liquifier);
        eETH = IeETH(_eETH);
        weETH = IWeETH(_weETH);
        wETH = IWETH(_wETH);
        stETH = IERC20Upgradeable(_stETH);
        wstETH = IwstETH(_wstETH);

        _disableInitializers();
    }

    function initialize() initializer external {
        __Ownable_init();
        __UUPSUpgradeable_init();
    }

    /// @notice Deposit ETH for weETH
    /// @param _referral Address to credit rewards
    /// @return weEthAmount weETH received by the depositer
    function depositETHForWeETH(address _referral) external payable returns (uint256) {
        uint256 eETHShares = liquidityPool.deposit{value: msg.value}(_referral);
        
        emit AdapterDeposit(msg.sender, msg.value, SourceOfFunds.ETH, _referral);
        return _wrapAndReturn(eETHShares);
    }

    /// @notice Deposit WETH for weETH
    /// @dev WETH doesn't support permit, so this function requires an explicit approval before use
    /// @param _amount Amount of WETH to deposit 
    /// @param _referral Address to credit referral
    /// @return weEthAmount weETH received by the depositer
    function depositWETHForWeETH(uint256 _amount, address _referral) external returns (uint256) {
        require(wETH.allowance(msg.sender, address(this)) >= _amount, "ALLOWANCE_EXCEEDED");
        require(wETH.balanceOf(msg.sender) >= _amount, "INSUFFICIENT_BALANCE");
        
        wETH.transferFrom(msg.sender, address(this), _amount);
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
    function depositStETHForWeETHWithPermit(uint256 _amount, address _referral, ILiquifier.PermitInput calldata _permit) external returns (uint256) {
        try IERC20PermitUpgradeable(address(stETH)).permit(msg.sender, address(this), _permit.value, _permit.deadline, _permit.v, _permit.r, _permit.s) {} 
        catch {
            if (_permit.deadline < block.timestamp) revert("PERMIT_EXPIRED");
        }

        // Accounting for the 1-2 wei corner case
        uint256 initialBalance = stETH.balanceOf(address(this));
        stETH.transferFrom(msg.sender, address(this), _amount);
        uint256 actualTransferredAmount = stETH.balanceOf(address(this)) - initialBalance;

        stETH.approve(address(liquifier), actualTransferredAmount);
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
    function depositWstETHForWeETHWithPermit(uint256 _amount, address _referral, ILiquifier.PermitInput calldata _permit) external returns (uint256) {
        try wstETH.permit(msg.sender, address(this), _permit.value, _permit.deadline, _permit.v, _permit.r, _permit.s) {} 
        catch {
            if (_permit.deadline < block.timestamp) revert("PERMIT_EXPIRED");
        }

        wstETH.transferFrom(msg.sender, address(this), _amount);

        // Accounting for the 1-2 wei corner case
        uint256 initialBalance = stETH.balanceOf(address(this));
        uint256 stETHAmount = wstETH.unwrap(_amount);
        uint256 actualTransferredAmount = stETH.balanceOf(address(this)) - initialBalance;

        stETH.approve(address(liquifier), actualTransferredAmount);
        uint256 eETHShares = liquifier.depositWithERC20(address(stETH), actualTransferredAmount, _referral);
        
        emit AdapterDeposit(msg.sender, actualTransferredAmount, SourceOfFunds.WSTETH, _referral);
        return _wrapAndReturn(eETHShares);
    }

    receive() external payable {
        if (msg.sender != address(wETH)) {
            revert("ETH_TRANSFERS_NOT_ACCEPTED");
        }
    }

    function _wrapAndReturn(uint256 _eEthShares) internal returns (uint256) {
        uint256 eEthAmount = liquidityPool.amountForShare(_eEthShares);
        eETH.approve(address(weETH), eEthAmount);
        uint256 weEthAmount = weETH.wrap(eEthAmount);
        weETH.transfer(msg.sender, weEthAmount);

        return weEthAmount;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
