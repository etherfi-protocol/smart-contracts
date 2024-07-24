// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;


import "./TestSetup.sol";
import "forge-std/Test.sol";


contract TotalValueInLpTest is TestSetup {

    uint constant GWEI = 1e9;

    function setUp() public {
        initializeRealisticFork(MAINNET_FORK);

        // vm.createSelectFork('https://rpc.ankr.com/eth', 19_675_736);
        // liquidityPoolInstance = ILiquidityPool(0x308861A430be4cce5502d0A12724771Fc6DaF216);
        // managerInstance = IEtherFiNodesManager(0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F);
        
    }


    function test_totalValueInLpInCycle() public {
        _upgrade_staking_manager_contract();
        _upgrade_liquidity_pool_contract();

        uint startBalance = address(liquidityPoolInstance).balance;
        uint startValue = liquidityPoolInstance.totalValueInLp();
        
        uint[] memory validatorIds = new uint[](1);
        validatorIds[0] = 61065;

        vm.startPrank(0x5836152812568244760ba356B5f3838Aa5B672e0);

        liquidityPoolInstance.batchDepositWithLiquidityPoolAsBnftHolder(validatorIds, 1);

        // create params for register and approve
        IStakingManager.DepositData[] memory registerValidatorDepositData = new IStakingManager.DepositData[](1);
        bytes32[] memory depositDataRootApproval = new bytes32[](1);
        bytes[] memory pubKey = new bytes[](1);
        bytes[] memory signature = new bytes[](1);
        bytes32 depositDataRoot;

        {
            bytes memory zeroBytes32 = abi.encodePacked(bytes32(0));
            bytes memory zeroBytes48 = abi.encodePacked(bytes32(0), bytes16(0));
            bytes memory zeroBytes64 = abi.encodePacked(bytes32(0), bytes32(0));
            bytes memory zeroBytes96 = abi.encodePacked(bytes32(0), bytes32(0), bytes32(0));
            bytes memory withdrawalCredentials = managerInstance.getWithdrawalCredentials(validatorIds[0]);
            depositDataRoot = generateDepositRoot(zeroBytes48, zeroBytes64, zeroBytes32, withdrawalCredentials, 1 ether);
            depositDataRootApproval[0] = generateDepositRoot(zeroBytes48, zeroBytes64, zeroBytes32, withdrawalCredentials, 31 ether);
            registerValidatorDepositData[0] = IStakingManager.DepositData(zeroBytes48, zeroBytes96, depositDataRoot, '');
            pubKey[0] = zeroBytes48;
            signature[0] = zeroBytes96;
        }

        (address staker,,) = stakingManagerInstance.bidIdToStakerInfo(validatorIds[0]);
        assertEq(staker, 0x5836152812568244760ba356B5f3838Aa5B672e0);

        liquidityPoolInstance.batchRegisterWithLiquidityPoolAsBnftHolder(
            bytes32(0),
            validatorIds,
            registerValidatorDepositData,
            depositDataRootApproval,
            new bytes[](1)
        );

        vm.stopPrank();

        vm.startPrank(0x0EF8fa4760Db8f5Cd4d993f3e3416f30f942D705);
        liquidityPoolInstance.batchApproveRegistration(validatorIds, pubKey, signature);
        vm.stopPrank();

        uint endBalance = address(liquidityPoolInstance).balance;
        uint endValue = liquidityPoolInstance.totalValueInLp();

        console.log('Change in balance %e', startBalance - endBalance);
        console.log('Change in totalValueInLp %e', startValue - endValue);

        assertEq(startBalance - endBalance, startValue - endValue);
    }

    function generateDepositRoot(
        bytes memory pubkey,
        bytes memory signature64,
        bytes memory signature64Plus,
        bytes memory withdrawal_credentials,
        uint256 _amountIn
    ) internal pure returns (bytes32) {
        uint deposit_amount = _amountIn / GWEI;
        bytes memory amount = to_little_endian_64(uint64(deposit_amount));

        bytes32 pubkey_root = sha256(abi.encodePacked(pubkey, bytes16(0)));
        bytes32 signature_root = sha256(
            abi.encodePacked(
                // note this was changed to avoid error about slicing memory
                sha256(abi.encodePacked(signature64)),
                sha256(abi.encodePacked(signature64Plus, bytes32(0)))
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