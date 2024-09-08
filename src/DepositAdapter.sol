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

    function depositETHForWeETH(address _referral) external payable returns (uint256) {
        uint256 eETHShares = liquidityPool.depositWithAdapter{value: msg.value}(msg.sender, msg.value, _referral);
        
        return _wrapAndReturn(eETHShares);
    }

    function depositWETHForWeETH(uint256 _amount, address _referral) external returns (uint256) {
        require(wETH.allowance(msg.sender, address(this)) >= _amount, "ALLOWANCE_EXCEEDED");
        require(wETH.balanceOf(msg.sender) >= _amount, "INSUFFICIENT_BALANCE");
        
        wETH.transferFrom(msg.sender, address(this), _amount);
        wETH.withdraw(_amount);

        uint256 eETHShares = liquidityPool.depositWithAdapter{value: _amount}(msg.sender, _amount, _referral);
        
        return _wrapAndReturn(eETHShares);
    }

    function depositStETHForWeETHWithPermit(uint256 _amount, address _referral, ILiquifier.PermitInput calldata _permit) external returns (uint256) {
        try IERC20PermitUpgradeable(address(stETH)).permit(msg.sender, address(this), _permit.value, _permit.deadline, _permit.v, _permit.r, _permit.s) {} catch {}

        stETH.transferFrom(msg.sender, address(this), _amount);
        stETH.approve(address(liquifier), _amount);
        uint256 eETHShares = liquifier.depositWithAdapter(msg.sender, address(stETH), _amount, _referral);
        
        return _wrapAndReturn(eETHShares);
    }

    function depositWstETHForWeETHWithPermit(uint256 _amount, address _referral, ILiquifier.PermitInput calldata _permit) external returns (uint256) {
        try wstETH.permit(msg.sender, address(this), _permit.value, _permit.deadline, _permit.v, _permit.r, _permit.s) {} catch {}

        wstETH.transferFrom(msg.sender, address(this), _amount);
        uint256 stETHAmount = wstETH.unwrap(_amount);

        stETH.approve(address(liquifier), stETHAmount);
        uint256 eETHShares = liquifier.depositWithAdapter(msg.sender, address(stETH), stETHAmount, _referral);
        
        return _wrapAndReturn(eETHShares);
    }

    receive() external payable {}

    function _wrapAndReturn(uint256 _eEthShares) internal returns (uint256) {
        uint256 eEthAmount = liquidityPool.amountForShare(_eEthShares);
        eETH.approve(address(weETH), eEthAmount);
        uint256 weEthAmount = weETH.wrap(eEthAmount);
        weETH.transfer(msg.sender, weEthAmount);

        return weEthAmount;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
