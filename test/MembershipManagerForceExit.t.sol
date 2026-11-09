// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@tests/TestSetup.sol";
import "@tests/common/PlaceholderImpl.sol";
import "@etherfi/archive/membership/MembershipManager.sol";
import "@etherfi/archive/membership/MembershipNFT.sol";

/// @dev Exposes test-only seeding of V1 token and tier-vault state. MembershipNFT has no
///      mint path anymore, so the ERC-1155 balance itself is written with stdstore.
contract MembershipManagerForceExitHarness is MembershipManager {
    constructor(address _eETH, address _liquidityPool, address _membershipNFT, address _roleRegistry, address _blacklister)
        MembershipManager(_eETH, _liquidityPool, _membershipNFT, _roleRegistry, _blacklister) {}

    function seedTier() external {
        tierVaults.push(TierVault({totalPooledEEthShares: 0, totalVaultShares: 0}));
    }

    function seedToken(uint256 _tokenId, uint8 _tier, uint96 _vaultShare, uint128 _eEthShare) external {
        tokenData[_tokenId] = TokenData({
            vaultShare: _vaultShare,
            baseLoyaltyPoints: 0,
            baseTierPoints: 0,
            prevPointsAccrualTimestamp: uint32(block.timestamp),
            prevTopUpTimestamp: 0,
            tier: _tier,
            version: 1
        });
        tierVaults[_tier].totalVaultShares += _vaultShare;
        tierVaults[_tier].totalPooledEEthShares += _eEthShare;
    }
}

contract MembershipManagerForceExitTest is TestSetup {
    using stdStorage for StdStorage;

    // slot 261 packs burnFee (offset 14) and burnFeeWaiverPeriodInDays (offset 30)
    uint256 constant FEE_SLOT = 261;

    MembershipManagerForceExitHarness mm;
    MembershipNFT mnft;

    address opsMultisig = makeAddr("opsMultisig");
    address holderA = makeAddr("holderA");
    address holderB = makeAddr("holderB");
    address treasuryRecipient = makeAddr("treasuryRecipient");

    function setUp() public {
        setUpTests();

        UUPSProxy mmProxy = new UUPSProxy(address(new PlaceholderImpl()), "");
        MembershipNFT mnftImpl = new MembershipNFT(
            address(liquidityPoolInstance), address(mmProxy), address(roleRegistryInstance), address(blacklisterInstance)
        );
        UUPSProxy mnftProxy = new UUPSProxy(
            address(mnftImpl), abi.encodeWithSelector(MembershipNFT.initialize.selector, "", address(mmProxy))
        );
        MembershipManagerForceExitHarness mmImpl = new MembershipManagerForceExitHarness(
            address(eETHInstance), address(liquidityPoolInstance), address(mnftProxy), address(roleRegistryInstance), address(blacklisterInstance)
        );
        PlaceholderImpl(address(mmProxy)).upgradeTo(address(mmImpl));

        mm = MembershipManagerForceExitHarness(payable(address(mmProxy)));
        mnft = MembershipNFT(address(mnftProxy));

        vm.startPrank(roleRegistryInstance.owner());
        roleRegistryInstance.grantRole(roleRegistryInstance.OPERATION_MULTISIG_ROLE(), opsMultisig);
        vm.stopPrank();

        // Fund the MembershipManager with eETH the same way the old wrap flow did.
        vm.deal(address(mm), 10 ether);
        vm.prank(address(mm));
        liquidityPoolInstance.deposit{value: 10 ether}();

        // Two NFTs in tier 0 splitting the 10 eETH: A holds 6, B holds 4.
        mm.seedTier();
        mm.seedToken(1, 0, 6 ether, uint128(eETHInstance.shares(address(mm)) * 6 / 10));
        mm.seedToken(2, 0, 4 ether, uint128(eETHInstance.shares(address(mm)) * 4 / 10));
        _giveNft(holderA, 1);
        _giveNft(holderB, 2);
    }

    function _giveNft(address _owner, uint256 _tokenId) internal {
        stdstore.target(address(mnft)).sig("balanceOf(address,uint256)").with_key(_owner).with_key(_tokenId).checked_write(1);
    }

    function _setBurnFee(uint16 _burnFee, uint16 _waiverPeriodInDays) internal {
        uint256 word = uint256(vm.load(address(mm), bytes32(FEE_SLOT)));
        word &= ~(uint256(0xffff) << (14 * 8));
        word &= ~(uint256(0xffff) << (30 * 8));
        word |= uint256(_burnFee) << (14 * 8);
        word |= uint256(_waiverPeriodInDays) << (30 * 8);
        vm.store(address(mm), bytes32(FEE_SLOT), bytes32(word));
    }

    function _exit(uint256 _tokenId, address _owner) internal {
        uint256[] memory ids = new uint256[](1);
        address[] memory owners = new address[](1);
        ids[0] = _tokenId;
        owners[0] = _owner;
        vm.prank(opsMultisig);
        mm.forceExit(ids, owners);
    }

    function test_forceExit_paysOwnerAndBurnsNft() public {
        uint256 value = mnft.valueOf(1);

        _exit(1, holderA);

        assertApproxEqAbs(eETHInstance.balanceOf(holderA), value, 2, "owner did not receive the NFT's eETH");
        assertEq(mnft.balanceOf(holderA, 1), 0, "NFT not burned");
        (,,,,,, uint8 version) = mm.tokenData(1);
        assertEq(version, 0, "tokenData not cleared");
    }

    function test_forceExit_chargesBurnFeeAndKeepsItInContract() public {
        _setBurnFee(500, 10_000); // 0.5 ETH fee, waiver period never met
        (, uint256 burnFeeAmount,) = mm.getFees();
        assertEq(burnFeeAmount, 0.5 ether);
        uint256 value = mnft.valueOf(1);

        _exit(1, holderA);

        assertApproxEqAbs(eETHInstance.balanceOf(holderA), value - 0.5 ether, 2, "fee not deducted");
        assertApproxEqAbs(eETHInstance.balanceOf(address(mm)), 10 ether - value + 0.5 ether, 2, "fee not retained");
    }

    function test_forceExit_capsFeeAtNftValue() public {
        _setBurnFee(type(uint16).max, 10_000); // ~65.5 ETH fee, larger than either NFT

        _exit(2, holderB);

        assertEq(eETHInstance.balanceOf(holderB), 0, "owner should receive nothing when fee exceeds value");
        assertEq(mnft.balanceOf(holderB, 2), 0, "NFT must still be burned");
    }

    function test_forceExit_batch() public {
        uint256[] memory ids = new uint256[](2);
        address[] memory owners = new address[](2);
        (ids[0], ids[1]) = (1, 2);
        (owners[0], owners[1]) = (holderA, holderB);

        vm.prank(opsMultisig);
        mm.forceExit(ids, owners);

        assertEq(mnft.balanceOf(holderA, 1) + mnft.balanceOf(holderB, 2), 0, "NFTs not burned");
        (, uint128 totalVaultShares) = mm.tierVaults(0);
        assertEq(totalVaultShares, 0, "tier vault not emptied");
    }

    function test_forceExit_requiresOperatingMultisig() public {
        uint256[] memory ids = new uint256[](1);
        address[] memory owners = new address[](1);
        (ids[0], owners[0]) = (1, holderA);

        vm.prank(holderA);
        vm.expectRevert(RoleRegistry.OnlyOperatingMultisig.selector);
        mm.forceExit(ids, owners);
    }

    function test_forceExit_revertsForWrongOwner() public {
        uint256[] memory ids = new uint256[](1);
        address[] memory owners = new address[](1);
        (ids[0], owners[0]) = (1, holderB);

        vm.prank(opsMultisig);
        vm.expectRevert(MembershipManager.OnlyTokenOwner.selector);
        mm.forceExit(ids, owners);
    }

    function test_forceExit_revertsOnLengthMismatch() public {
        uint256[] memory ids = new uint256[](2);
        address[] memory owners = new address[](1);

        vm.prank(opsMultisig);
        vm.expectRevert(MembershipManager.LengthMismatch.selector);
        mm.forceExit(ids, owners);
    }

    function test_sweepRemainingFunds_revertsWhileNftsRemain() public {
        _exit(1, holderA);

        vm.prank(opsMultisig);
        vm.expectRevert(MembershipManager.TierVaultsNotEmpty.selector);
        mm.sweepRemainingFunds(treasuryRecipient);
    }

    function test_sweepRemainingFunds_sendsEEthAndEthAfterAllExits() public {
        _setBurnFee(500, 10_000);
        _exit(1, holderA);
        _exit(2, holderB);
        vm.deal(address(mm), 0.1 ether);
        uint256 eEthLeft = eETHInstance.balanceOf(address(mm));
        assertGt(eEthLeft, 0, "expected retained fees");

        vm.prank(opsMultisig);
        mm.sweepRemainingFunds(treasuryRecipient);

        assertApproxEqAbs(eETHInstance.balanceOf(treasuryRecipient), eEthLeft, 1, "eETH not swept");
        assertEq(treasuryRecipient.balance, 0.1 ether, "ETH not swept");
        assertEq(eETHInstance.shares(address(mm)), 0, "eETH left behind");
    }

    function test_sweepRemainingFunds_requiresOperatingMultisig() public {
        vm.prank(holderA);
        vm.expectRevert(RoleRegistry.OnlyOperatingMultisig.selector);
        mm.sweepRemainingFunds(treasuryRecipient);
    }

    function test_userExitsRemoved() public {
        vm.startPrank(holderA);
        (bool ok1, ) = address(mm).call(abi.encodeWithSignature("unwrapForEEthAndBurn(uint256)", 1));
        (bool ok2, ) = address(mm).call(abi.encodeWithSignature("requestWithdraw(uint256,uint256)", 1, 1 ether));
        (bool ok3, ) = address(mm).call(abi.encodeWithSignature("requestWithdrawAndBurn(uint256)", 1));
        (bool ok4, ) = address(mm).call(abi.encodeWithSignature("claim(uint256)", 1));
        vm.stopPrank();
        assertFalse(ok1 || ok2 || ok3 || ok4, "a user exit path still exists");
    }
}
