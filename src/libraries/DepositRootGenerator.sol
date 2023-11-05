// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "../MembershipManager.sol";
import "../LiquidityPool.sol";

library depositRootGenerator {
    uint constant GWEI = 1e9;

    function generateDepositRoot(
        bytes calldata pubkey,
        bytes calldata signature,
        bytes calldata withdrawal_credentials,
        uint256 _amountIn
    ) public pure returns (bytes32) {

        uint deposit_amount = _amountIn / GWEI;
        bytes memory amount = to_little_endian_64(uint64(deposit_amount));

        bytes32 pubkey_root = sha256(abi.encodePacked(pubkey, bytes16(0)));
        bytes32 signature_root = sha256(
            abi.encodePacked(
                sha256(abi.encodePacked(signature[:64])),
                sha256(abi.encodePacked(signature[64:], bytes32(0)))
            )
        );
        return
            sha256(
                abi.encodePacked(
                    sha256(
                        abi.encodePacked(pubkey_root, withdrawal_credentials)
                    ),
                    sha256(abi.encodePacked(amount, bytes24(0), signature_root))
                )
            );
    }

    function to_little_endian_64(
        uint64 value
    ) internal pure returns (bytes memory ret) {
        ret = new bytes(8);
        bytes8 bytesValue = bytes8(value);
        // Byteswapping during copying to bytes.
        ret[0] = bytesValue[7];
        ret[1] = bytesValue[6];
        ret[2] = bytesValue[5];
        ret[3] = bytesValue[4];
        ret[4] = bytesValue[3];
        ret[5] = bytesValue[2];
        ret[6] = bytesValue[1];
        ret[7] = bytesValue[0];
    }
}