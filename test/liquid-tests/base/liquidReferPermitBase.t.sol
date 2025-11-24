// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20Permit} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/draft-IERC20Permit.sol";
import {LiquidReferBaseTest} from "./liquidReferBaseTest.t.sol";
import {LiquidRefer} from "src/LiquidRefer.sol";

abstract contract LiquidReferPermitFuzzBaseTest is LiquidReferBaseTest {
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    struct DepositWithPermitParams {
        address referral;
        uint256 amount;
    }

    //Permit
    function _buildPermit(uint256 deadline) internal view returns (uint8 v, bytes32 r, bytes32 s) {
    uint256 nonce = IERC20Permit(asset.asset).nonces(user);
    (string memory name, string memory version) = _permitDetails();

    bytes32 domainSeparator = keccak256(
        abi.encode(
            EIP712_DOMAIN_TYPEHASH, keccak256(bytes(name)), keccak256(bytes(version)), block.chainid, asset.asset
        )
    );

    bytes32 structHash =
        keccak256(abi.encode(PERMIT_TYPEHASH, user, address(liquidRefer), asset.depositAmount, nonce, deadline));
    bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    (v, r, s) = vm.sign(userPrivateKey, digest);
    }


    function _permitDetails() internal pure virtual returns (string memory name, string memory version);

    function test_DepositWithPermit() public {
        _fund(user);
        uint256 deadline = block.timestamp + 1 days;

        (uint8 v, bytes32 r, bytes32 s) = _buildPermit(deadline);
        address vault = asset.teller.vault();

        vm.expectEmit(true, true, false, true);
        emit LiquidRefer.Referral(vault, referrer, asset.depositAmount);

        vm.prank(user);
        uint256 shares = liquidRefer.depositWithPermit(
            asset.teller, asset.asset, asset.depositAmount, 0, deadline, v, r, s, referrer
        );

        _assertDepositResults(user, shares, vault);
    }

    //Fuzz
    function testFuzz_DepositWithPermit(address referral, uint256 amount) public {
        amount = _boundAmount(amount);
        _fundWithAmount(user, amount);

        (uint256 shares, address vault) = _depositWithPermitAmount(
            DepositWithPermitParams({referral: referral, amount: amount})
        );
        _assertDepositResultsForAmount(user, shares, vault, amount);
    }

    function _depositWithPermitAmount(DepositWithPermitParams memory params)
        internal
        returns (uint256 shares, address vault)
    {
        address referral = params.referral;
        uint256 amount = params.amount;

        vault = asset.teller.vault();

        vm.expectEmit(true, true, false, true);
        emit LiquidRefer.Referral(vault, referral, amount);

        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _buildPermitForAmount(deadline, amount);

        vm.prank(user);
        shares = liquidRefer.depositWithPermit(asset.teller, asset.asset, amount, 0, deadline, v, r, s, referral);
    }

    function _buildPermitForAmount(uint256 deadline, uint256 amount)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        uint256 nonce = IERC20Permit(asset.asset).nonces(user);
        (string memory name, string memory version) = _permitDetails();

        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH, keccak256(bytes(name)), keccak256(bytes(version)), block.chainid, asset.asset
            )
        );

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, user, address(liquidRefer), amount, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (v, r, s) = vm.sign(userPrivateKey, digest);
    }
}
