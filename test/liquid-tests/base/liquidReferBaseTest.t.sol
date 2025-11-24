// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {LiquidRefer} from "src/LiquidRefer.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ILayerZeroTellerWithRateLimiting} from "src/liquid-interfaces/ILayerZeroTellerWithRateLimiting.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/draft-IERC20Permit.sol";


abstract contract LiquidReferBaseTest is Test {
    address internal constant LIQUID_ETH_TELLER = 0x9AA79C84b79816ab920bBcE20f8f74557B514734;
    address internal constant LIQUID_USD_TELLER = 0x4DE413a26fC24c3FC27Cc983be70aA9c5C299387;
    address internal constant LIQUID_BTC_TELLER = 0x8Ea0B382D054dbEBeB1d0aE47ee4AC433C730353;

    struct AssetConfig {
        ILayerZeroTellerWithRateLimiting teller;
        address asset;
        uint256 depositAmount;
    }

    LiquidRefer internal liquidRefer;
    address internal proxy;
    address internal owner;
    address internal user;
    uint256 internal userPrivateKey;
    address internal referrer;
    AssetConfig internal asset;

    function setUp() public virtual {
        _setup();

        owner = makeAddr("owner");
        (user, userPrivateKey) = makeAddrAndKey("user");
        referrer = makeAddr("referrer");

        LiquidRefer implementation = new LiquidRefer();
        bytes memory initData = abi.encodeWithSelector(LiquidRefer.initialize.selector, owner);
        proxy = address(new ERC1967Proxy(address(implementation), initData));
        liquidRefer = LiquidRefer(payable(proxy));

        asset = _assetConfig();
    }

    function _setup() internal virtual {
        vm.createSelectFork(vm.envString(_envVar()));
    }

    function _envVar() internal pure virtual returns (string memory) {
        return "MAINNET_RPC_URL";
    }

    function _assetConfig() internal pure virtual returns (AssetConfig memory);

    function _fund(address receiver) internal {
        deal(asset.asset, receiver, asset.depositAmount);
    }

    function _fundWithAmount(address receiver, uint256 amount) internal {
        deal(asset.asset, receiver, amount);
    }

    function _deposit(address depositor, address referral) internal returns (uint256 shares, address vault) {
        return _depositWithAmount(depositor, referral, asset.depositAmount);
    }

    function _depositWithAmount(address depositor, address referral, uint256 amount)
        internal
        returns (uint256 shares, address vault)
    {
        vault = asset.teller.vault();

        vm.prank(depositor);
        IERC20(asset.asset).approve(address(liquidRefer), amount);

        vm.expectEmit(true, true, false, true);
        emit LiquidRefer.Referral(vault, referral, amount);

        vm.prank(depositor);
        shares = liquidRefer.deposit(asset.teller, asset.asset, amount, 0, referral);
    }

    function _assertDepositResults(address depositor, uint256 shares, address vault) internal view {
        _assertDepositResultsForAmount(depositor, shares, vault, asset.depositAmount);
    }

    function _assertDepositResultsForAmount(
        address depositor,
        uint256 shares,
        address vault,
        uint256 /*spentAmount*/
    )
        internal
        view
    {
        assertGt(shares, 0, "Should receive shares");
        assertEq(IERC20(vault).balanceOf(depositor), shares, "User received shares");
        assertEq(IERC20(asset.asset).balanceOf(depositor), 0, "Depositor spent tokens");
    }

    function test_Deposit() public {
        _fund(user);
        uint256 balanceBefore = IERC20(asset.asset).balanceOf(user);
        assertEq(balanceBefore, asset.depositAmount, "Pre-fund amount mismatch");

        (uint256 shares, address vault) = _deposit(user, referrer);
        _assertDepositResults(user, shares, vault);
    }
    function test_DepositWithZeroReferrer() public {
        _fund(user);

        (uint256 shares, address vault) = _deposit(user, address(0));
        _assertDepositResults(user, shares, vault);
    }

    function test_MultipleDepositsFromDifferentUsers() public {
        address user2 = makeAddr("user2");
        address referrer2 = makeAddr("referrer2");

        _fund(user);
        _fund(user2);

        (uint256 shares1, address vault) = _deposit(user, referrer);
        (uint256 shares2, address vault2) = _deposit(user2, referrer2);

        _assertDepositResults(user, shares1, vault);
        _assertDepositResults(user2, shares2, vault2);
    }

    //Fuzz tests
    function _maxFuzzAmount() internal pure virtual returns (uint256);

     function _boundAmount(uint256 amount) internal view returns (uint256) {
        return bound(amount, asset.depositAmount, _maxFuzzAmount());
    }
    function testFuzz_DepositWithAnyReferrer(uint256 amount,address referral) public {
        amount = _boundAmount(amount);
        _fundWithAmount(user, amount);

        (uint256 shares, address vault) = _depositWithAmount(user, referral, amount);
        _assertDepositResultsForAmount(user, shares, vault, amount);
    }
}

