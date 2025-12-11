// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/draft-IERC20Permit.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILayerZeroTellerWithRateLimiting} from "../liquid-interfaces/ILayerZeroTellerWithRateLimiting.sol";
import {PausableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/security/PausableUpgradeable.sol";


contract LiquidRefer is Initializable, UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    event Referral(address indexed vault, address indexed referrer, uint256 amount);

    mapping(address => bool) public tellerWhiteList;

    modifier onlyWhitelistedTeller(address teller) {
        require(tellerWhiteList[teller], "Teller not whitelisted");
        _;
    }   

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner) public initializer {
        __Ownable_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        transferOwnership(owner);
    }

    function deposit(
        ILayerZeroTellerWithRateLimiting teller,
        address depositAsset,
        uint256 depositAmount,
        uint256 minimumMint,
        address referrer
    )whenNotPaused onlyWhitelistedTeller(address(teller)) external returns (uint256 shares) {
        address vault = teller.vault();

        IERC20(depositAsset).safeTransferFrom(msg.sender, address(this), depositAmount);

        IERC20(depositAsset).safeIncreaseAllowance(vault, depositAmount);

        shares = teller.deposit(depositAsset, depositAmount, minimumMint);

        IERC20(vault).safeTransfer(msg.sender, shares);

        emit Referral(vault, referrer, depositAmount);
    }

    function depositWithPermit(
        ILayerZeroTellerWithRateLimiting teller,
        address depositAsset,
        uint256 depositAmount,
        uint256 minimumMint,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s,
        address referrer
    ) whenNotPaused onlyWhitelistedTeller(address(teller)) external returns (uint256 shares) {
        address vault = teller.vault();

        IERC20Permit(depositAsset).permit(msg.sender, address(this), depositAmount, deadline, v, r, s);

        IERC20(depositAsset).safeTransferFrom(msg.sender, address(this), depositAmount);

        IERC20(depositAsset).safeIncreaseAllowance(vault, depositAmount);

        shares = teller.deposit(depositAsset, depositAmount, minimumMint);

        IERC20(vault).safeTransfer(msg.sender, shares);

        emit Referral(vault, referrer, depositAmount);
    }

    function toggleWhiteList(address teller, bool status) external onlyOwner {
        tellerWhiteList[teller] = status;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

   function _authorizeUpgrade(address /* newImplementation */) internal view override {
        _checkOwner();
    }
     function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    
}
