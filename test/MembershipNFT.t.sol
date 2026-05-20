// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "forge-std/console2.sol";
import "../src/helpers/Blacklister.sol";

contract MembershipNFTTest is TestSetup {

    event MintingPaused(bool isPaused);

    function setUp() public {
        setUpTests();
        vm.startPrank(alice);
        eETHInstance.approve(address(membershipManagerInstance), 1_000_000_000 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        eETHInstance.approve(address(membershipManagerInstance), 1_000_000_000 ether);
        vm.stopPrank();
    }

    function test_metadata() public {

        // Setters now gate on OPERATION_MULTISIG_ROLE — test contract holds no roles.
        vm.expectRevert(RoleRegistry.OnlyOperatingMultisig.selector);
        membershipNftInstance.setMetadataURI("badURI.com");
        vm.expectRevert(RoleRegistry.OnlyOperatingMultisig.selector);
        membershipNftInstance.setContractMetadataURI("badURI2.com");

        vm.startPrank(alice);
        membershipNftInstance.setMetadataURI("http://ether-fi/{id}");
        assertEq(membershipNftInstance.uri(5), "http://ether-fi/{id}");

        membershipNftInstance.setContractMetadataURI("http://ether-fi/contract-metadata");
        assertEq(membershipNftInstance.contractURI(), "http://ether-fi/contract-metadata");

        vm.stopPrank();
    }

    function test_setLimit() public {
        vm.startPrank(alice);
        membershipNftInstance.setMaxTokenId(1);
        vm.stopPrank();

        // 1st mint should work
        vm.startPrank(address(membershipManagerInstance));
        membershipNftInstance.mint(alice, 1);
        vm.stopPrank();

        // 2nd mint should fail
        vm.startPrank(address(membershipManagerInstance));
        vm.expectRevert(MembershipNFT.MintingIsPaused.selector);
        membershipNftInstance.mint(alice, 1);
        vm.stopPrank();

        // Increase the cap
        vm.startPrank(alice);
        membershipNftInstance.setMaxTokenId(2);
        vm.stopPrank();

        // 3rd mint should work
        vm.startPrank(address(membershipManagerInstance));
        membershipNftInstance.mint(alice, 1);
        vm.stopPrank();

        // 4th mint should fail
        vm.startPrank(address(membershipManagerInstance));
        vm.expectRevert(MembershipNFT.MintingIsPaused.selector);
        membershipNftInstance.mint(alice, 1);
        vm.stopPrank();
    }

    function test_pauseMinting() public {

        // setMintingPaused now requires OPERATION_MULTISIG_ROLE; bob holds no roles.
        vm.startPrank(bob);
        vm.expectRevert(RoleRegistry.OnlyOperatingMultisig.selector);
        membershipNftInstance.setMintingPaused(true);
        vm.stopPrank();

        // mint a token
        vm.prank(address(membershipManagerInstance));
        membershipNftInstance.mint(alice, 1);

        // pause the minting
        vm.prank(alice);
        vm.expectEmit(false, false, false, true);
        emit MintingPaused(true);
        membershipNftInstance.setMintingPaused(true);
        assertEq(membershipNftInstance.mintingPaused(), true);

        // mint should fail
        vm.startPrank(address(membershipManagerInstance));
        vm.expectRevert(MembershipNFT.MintingIsPaused.selector);
        membershipNftInstance.mint(alice, 1);
        vm.stopPrank();

        // unpause
        vm.prank(alice);
        vm.expectEmit(false, false, false, true);
        emit MintingPaused(false);
        membershipNftInstance.setMintingPaused(false);
        assertEq(membershipNftInstance.mintingPaused(), false);

        // mint should succeed again
        vm.startPrank(address(membershipManagerInstance));
        membershipNftInstance.mint(alice, 1);


    }

    function test_permissions() public {

        // only membership manager can update call
        vm.startPrank(alice);
        vm.expectRevert(MembershipNFT.OnlyMembershipManagerContract.selector);
        membershipNftInstance.mint(alice, 1);
        vm.expectRevert(MembershipNFT.OnlyMembershipManagerContract.selector);
        membershipNftInstance.burn(alice, 0, 1);
        vm.stopPrank();

        vm.startPrank(owner);
        vm.expectRevert(MembershipNFT.OnlyMembershipManagerContract.selector);
        membershipNftInstance.mint(alice, 1);
        vm.expectRevert(MembershipNFT.OnlyMembershipManagerContract.selector);
        membershipNftInstance.burn(alice, 0, 1);
        vm.stopPrank();

        // should succeed
        vm.startPrank(address(membershipManagerInstance));
        membershipNftInstance.mint(alice, 1);
        membershipNftInstance.burn(alice, 1, 1);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Blacklist on _beforeTokenTransfer (ERC1155)
    //
    // The hook short-circuits when `_from == 0` (mint) or `_to == 0` (burn),
    // so mint/burn must remain callable for blacklisted holders. For real
    // transfers, the blacklist gate fires for any of `operator`, `from`, or
    // `to`. A time-bounded blacklist auto-opens at its expiry.
    // -------------------------------------------------------------------------

    function _expectBlacklistedRevert(address user) internal {
        vm.expectRevert(abi.encodeWithSelector(Blacklister.BlacklistedUser.selector, user));
    }

    /// @dev Mint a single NFT to `recipient` via the membership manager and
    /// return the token id. Pulled out because the existing tests inline this
    /// boilerplate.
    function _mintNftTo(address recipient) internal returns (uint256 tokenId) {
        vm.prank(address(membershipManagerInstance));
        tokenId = membershipNftInstance.mint(recipient, 1);
    }

    // ---- mint / burn bypass the blacklist gate (early return on zero side) -

    function test_MembershipNFT_mint_skipsBlacklistForRecipient() public {
        vm.prank(owner);
        blacklisterInstance.blacklistUser(alice);

        // mint is `from = address(0)` → hook returns early, so this succeeds
        // even though alice is blacklisted.
        uint256 tokenId = _mintNftTo(alice);
        assertEq(membershipNftInstance.balanceOf(alice, tokenId), 1);
    }

    function test_MembershipNFT_burn_skipsBlacklistForHolder() public {
        uint256 tokenId = _mintNftTo(alice);

        vm.prank(owner);
        blacklisterInstance.blacklistUser(alice);

        // burn is `to = address(0)` → hook returns early.
        vm.prank(address(membershipManagerInstance));
        membershipNftInstance.burn(alice, tokenId, 1);
        assertEq(membershipNftInstance.balanceOf(alice, tokenId), 0);
    }

    // ---- real transfers respect the gate ------------------------------------

    function test_MembershipNFT_transfer_revertsWhenSenderBlacklisted() public {
        uint256 tokenId = _mintNftTo(alice);

        vm.prank(owner);
        blacklisterInstance.blacklistUser(alice);

        vm.prank(alice);
        _expectBlacklistedRevert(alice);
        membershipNftInstance.safeTransferFrom(alice, bob, tokenId, 1, "");
    }

    function test_MembershipNFT_transfer_revertsWhenRecipientBlacklisted() public {
        uint256 tokenId = _mintNftTo(alice);

        vm.prank(owner);
        blacklisterInstance.blacklistUser(bob);

        vm.prank(alice);
        _expectBlacklistedRevert(bob);
        membershipNftInstance.safeTransferFrom(alice, bob, tokenId, 1, "");
    }

    function test_MembershipNFT_transfer_revertsWhenOperatorBlacklisted() public {
        // Operator-distinct path: chad pulls alice's token after approval.
        uint256 tokenId = _mintNftTo(alice);

        vm.prank(alice);
        membershipNftInstance.setApprovalForAll(chad, true);

        vm.prank(owner);
        blacklisterInstance.blacklistUser(chad);

        vm.prank(chad);
        _expectBlacklistedRevert(chad);
        membershipNftInstance.safeTransferFrom(alice, bob, tokenId, 1, "");
    }

    function test_MembershipNFT_transfer_succeedsAfterBlacklistExpires() public {
        uint256 tokenId = _mintNftTo(alice);

        vm.prank(owner);
        blacklisterInstance.setBlacklistUntil(alice, 1 days);

        vm.prank(alice);
        _expectBlacklistedRevert(alice);
        membershipNftInstance.safeTransferFrom(alice, bob, tokenId, 1, "");

        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        membershipNftInstance.safeTransferFrom(alice, bob, tokenId, 1, "");
        assertEq(membershipNftInstance.balanceOf(bob, tokenId), 1);
    }

    function test_MembershipNFT_transfer_succeedsAfterUnblacklist() public {
        uint256 tokenId = _mintNftTo(alice);

        vm.prank(owner);
        blacklisterInstance.blacklistUser(alice);
        vm.prank(owner);
        blacklisterInstance.unblacklistUser(alice);

        vm.prank(alice);
        membershipNftInstance.safeTransferFrom(alice, bob, tokenId, 1, "");
        assertEq(membershipNftInstance.balanceOf(bob, tokenId), 1);
    }
}
