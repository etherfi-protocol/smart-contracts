// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "forge-std/console.sol";
import "../src/EtherFiAdmin.sol";

contract EtherFiAdminUpgradeTest is TestSetup {
    bytes[] pubKeys;
    bytes[] signatures;
    IEtherFiOracle.OracleReport report;
    uint16 batchSize;
    uint16 alternativeBatchSize;
    bytes32 reportHash;
    uint256[] batchValidatorsToApprove;
    uint32[] emptyTimestamps;
    bytes32 approvalHash;
    uint256 accruedRewards; 
    uint256 protocolFees;

    function setUp() public {
        pubKeys = _getImperialPubkey();
        signatures = _getImperialSignature();
        report = _generateImperialReport();
        batchSize = 10;
        alternativeBatchSize = 5;
        accruedRewards = 12865299762487754752;
        protocolFees = 1438401262268165688;
        setUpTests();
        initializeRealisticForkWithBlock(MAINNET_FORK, 21796450);
        (uint32 slotFrom, uint32 slotTo, uint32 blockFrom) = etherFiOracleInstance.blockStampForNextReport();

        // upgrade the contact
        upgradeContract();
        vm.startPrank(address(0x1a9AC2a6fC85A7234f9E21697C75D06B2b350864));
        etherFiOracleInstance.submitReport(report);
        vm.startPrank(address(0x6d850af8e7AB3361CfF28b31C701647414b9C92b));
        etherFiOracleInstance.submitReport(report);

        reportHash = etherFiOracleInstance.generateReportHash(report);
        batchValidatorsToApprove = _getValidatorToApprove(80920, batchSize); //52835 based on transaction
        emptyTimestamps = new uint32[](0);
        approvalHash = keccak256(abi.encode(reportHash, batchValidatorsToApprove, emptyTimestamps));
    }

    function upgradeContract() public {
        
        vm.startPrank(roleRegistryInstance.owner());
        
        roleRegistryInstance.grantRole(liquidityPoolInstance.LIQUIDITY_POOL_ADMIN_ROLE(), address(etherFiAdminInstance));
        roleRegistryInstance.grantRole(etherFiAdminInstance.ETHERFI_ADMIN_ADMIN_ROLE(), committeeMember);
        roleRegistryInstance.grantRole(etherFiAdminInstance.ETHERFI_ADMIN_TASK_EXECUTOR_ROLE(), committeeMember);
        vm.startPrank(committeeMember);
        etherFiAdminInstance.setValidatorTaskBatchSize(batchSize);
        vm.stopPrank();
    }

    // example transactions for submitting and executing report (recreate with the same block number)
    //0xc30a309d02917ae5edf27e441ca029c54b069336919439d342c2f4b7889c623d etherfioracle
    //0x8b9a2df2b0df2c25d9e96dece8c3e473ba1797a9e764b90eea32e9839f6caa10 etheradmin
    function _generateImperialReport()
        internal
        returns (IEtherFiOracle.OracleReport memory)
    {
        IEtherFiOracle.OracleReport memory report = IEtherFiOracle.OracleReport(
            { 
                consensusVersion: 1,
                refSlotFrom: 11009824,
                refSlotTo: 11010463,
                refBlockFrom: 21795511,
                refBlockTo: 21796145,
                accruedRewards: 12865299762487754752,
                protocolFees: 1438401262268165688,
                validatorsToApprove: new uint256[](100),
                liquidityPoolValidatorsToExit: new uint256[](0),
                exitedValidators: new uint256[](0),
                exitedValidatorsExitTimestamps: new uint32[](0),
                slashedValidators: new uint256[](0),
                withdrawalRequestsToInvalidate: new uint256[](0),
                lastFinalizedWithdrawalRequestId: 57907,
                eEthTargetAllocationWeight: 0,
                etherFanTargetAllocationWeight: 0,
                finalizedWithdrawalAmount: 608440514420670619423,
                numValidatorsToSpinUp: 100
            });
        uint256 startId = 80920;
        for (uint i = 0; i < 10; i++) {
            report.validatorsToApprove[i] = startId + i;
        }
        return report;
    }

    function _getValidatorToApprove(uint256 firstValidatorIndex, uint16 batchSize) internal returns (uint256[] memory) {
        uint256[] memory batchValidatorsToApprove = new uint256[](batchSize);
        for (uint i = 0; i < batchSize; i++) {
            batchValidatorsToApprove[i] = firstValidatorIndex + i;
        }
        return batchValidatorsToApprove;
    }

    function _getImperialSignature() internal returns (bytes[] memory) {
        bytes[] memory _signature = new bytes[](10);
        _signature[0] = hex"b5da060d1e9da3c9e7b2a9edfae5346caddf0e9fb03fa56ba5648b871b8c8cf23bcaa2a1e8e60992376c6a0cda8189841081fa27b0a0068d2c46de1fe0ab57c31dfcd76f11c31fe19e8b82cb3500aa0161bc879ae3fa2e188b81686aea1c3318";
        _signature[1] = hex"8cdb0f14e7003c0b14147e07a465bc0b9d4acdc3ae6f2b811d509b5f8d0fad15339d464abc2adf7936a287ff242598e80b947c54a5e10f926fd1d5b9865dfb505fd446d8c949fbaebd5651aa81cbf5589a79d9b5f9bc180cddf8e0e8ae4c81e5";
        _signature[2] = hex"a946bf00a561aa8152ec9ea9d04dc2caf1d88e568e0542f305062f9b1e49dbe42f6aec53686cfd00b096d82a698eca8c02f0c0de631868c1a5e24c34fc5b6c0254ee89588e02394ef073327f5d2115ec82b70f0d3baa9c931462cd5dbf864886";
        _signature[3] = hex"b9eedda7ac2c6949d1bb057b8d638c7d7b6179c15b8f9a987de0be65c697ba6d93659d1af41fbfc01aba616fb0af1fc7178d0ccd548ac42c7b92b26378cb698982797817eafe724845eda0886ce22bc94d02a248037cb26808eabec8ec1e9813";
        _signature[4] = hex"8c1745ecfa4d078361064b8a57801d20741ea39003cc761961c0464c8761fa8fbaab42abe613ee94c997997203f00a140e8fd28eb8da5fb0916cc6fa7da42005dfba2236c9aff471ab6373b0c96d18c4e384c539dc94aef60a7fc1b6bfb0bd16";
        _signature[5] = hex"ad907827693b0f144eae43964907c7da750043c9c4b255db0aa531520868d0fd02cce09850324ef55556250221998711045af33b6cb2d6a7fc3b7ed7a9618fbc5e8f5cc495d4859bf2e5701d2eda4571b2319389a24bbc4a75671b85aff589fb";
        _signature[6] = hex"88122a7a43402d719abd82bc8facf6dc7f1683d109b87546f7f61d8ef8e8777637d73110bd9879bf29b6b482c816592c1259a2e34aab179cc33baa8722a6b5c16d5a27b7bf151c01219bda0c6b702b2d59ee344129085891862a669ef5d84726";
        _signature[7] = hex"ac8d1e9691b4242b5e9b6029e732e86dff7acef34ba66dd6638956852f80b27b43c1cd081ac34b8cb337142750a5ba84109e91c514c5174d7b597229b076ab7d3960b9d2fe7aa7a7e567f01b398ecd67b7c646bcca1a7565b5a005f7b50d6bbd";
        _signature[8] = hex"b8c7fc64ce0fbd4b8ea6a089d0113a51fb477e48fda434e022e2f16f4474dfdbc5add06772fd0b50d537127aacea3de50510da621f9856c31c4f55ed3df91102bdf218404f12d4f5cfefb7f14a01a3eeb3f77f658b6aa6a3bbafdab0482bb362";
        _signature[9] = hex"88a22b55edd9be44cd27b25457751cd42241322ce24d63f55cc1d57d59841d2030944f5ebf762b177dc234c6768d6ad3108342ec02466f877649c5c94579598107cacfdbe0164311af06ea9adfcc9c48da9f3d680fbc75f2d278d6d6551bccbb";
        return _signature;
    }

    function _getImperialPubkey() internal returns (bytes[] memory) {
        bytes[] memory _pubKey = new bytes[](10);
        _pubKey[0] = hex"acccb5d1ee2c39c67184c7a5b830fcbd157792c1bc9225ad007100cb83005723807f6ff53c70ae1bfd750167f29df2a7";
        _pubKey[1] = hex"94afd93f86ae1c4c3209a7d4917a2f9d3c50211e85499c5bc20340c6655bc2dfa16673e2afbd79eb98c64f4f690b8c73";
        _pubKey[2] = hex"8e3f9f0d20c570bc2175f7e00a1593ff5a344916eb96af3307cc8899ab592f4e2d96eafdd8083f426440bd687f9d591f";
        _pubKey[3] = hex"b36f0e692767d3d899125c8ff8507e08a06944d61121ec111a1ccd06fd15f7f6fde1a96a51924110946ead1528aaa32f";
        _pubKey[4] = hex"aa18b9aedc1600cfa86f98eeaf3e1472959af1e54dbcad9b26d1ef2496364e53d27cdc2c5c869df541f357f42141538d";
        _pubKey[5] = hex"817e3bf994a05442d7f4fb1ab1177cb2838f375a9492105e416a40a08f3296d75a9d35f414fb8a84097ace74a2a555c0";
        _pubKey[6] = hex"8a8c717dcc4e8bcf6c2ca5da7e86784f8ba1311bb8a2bd4a88a8fb456f7d0542ae1dbfb4f6b247c668273fedff8c6875";
        _pubKey[7] = hex"8a07585715b3917059b50228a5e81b62e9b0b0f2ea53d71afaf5dd2b60d3d9cdd0a404071dfd50d5427877464d377312";
        _pubKey[8] = hex"ae91a0fd59d85db3b1cd8ffdff8b0692fe1cd20bbc1ac09ee863c52d8cccb6c140f681c7b1659a08a818ac9e01c49194";
        _pubKey[9] = hex"a482419c3b9f5102e3281d96ce60b8699ee946c19348ed7202a6d293e496619c08b3812384029759d8ed4228cbb91bfc";
        return _pubKey;
    }

    function test_executeTask() public {
        skip(1800);
        (bool preExecuteCompleted, bool preExecuteExists, ) = etherFiAdminInstance.validatorManagementTaskStatus(approvalHash);
        assertFalse(preExecuteCompleted);
        assertFalse(preExecuteExists);
        vm.startPrank(committeeMember);
        etherFiAdminInstance.executeTasks(report);
    }

    function test_changingBatchSize() public {
        vm.startPrank(alice);
        vm.expectRevert();
        etherFiAdminInstance.setValidatorTaskBatchSize(alternativeBatchSize);
        vm.startPrank(committeeMember);
        etherFiAdminInstance.setValidatorTaskBatchSize(alternativeBatchSize);
        vm.stopPrank();
    }

    function test_invalidateReport() public {
        test_executeTask();
        etherFiAdminInstance.invalidateValidatorManagementTask(reportHash, batchValidatorsToApprove, emptyTimestamps);
        (bool postCompleted, bool postExists, ) = etherFiAdminInstance.validatorManagementTaskStatus(approvalHash);
        assertFalse(postCompleted);
        assertFalse(postExists);
        vm.expectRevert();
        etherFiAdminInstance.executeValidatorManagementTask(reportHash, batchValidatorsToApprove, emptyTimestamps, pubKeys, signatures);
    }

    function test_validatorApprovalTasks() public {
        test_executeTask();
        (bool preCompleted, bool preExists, ) = etherFiAdminInstance.validatorManagementTaskStatus(approvalHash);
        assertTrue(preExists);
        assertFalse(preCompleted);
        vm.startPrank(committeeMember);
        etherFiAdminInstance.executeValidatorManagementTask(reportHash, batchValidatorsToApprove, emptyTimestamps, pubKeys, signatures);
        (bool postCompleted, bool postExists, ) = etherFiAdminInstance.validatorManagementTaskStatus(approvalHash);
        assertTrue(postCompleted);
        assertTrue(postExists);
        vm.stopPrank();
    }

    function test_anotherBatchSize() public {
        bytes[] memory newPubKeys = new bytes[](alternativeBatchSize);
        bytes[] memory newSignatures = new bytes[](alternativeBatchSize);
        uint32[] memory emptyTimestamps = new uint32[](0);   
        uint256[] memory alternativeBatchValidatorsToApprove = _getValidatorToApprove(80920, alternativeBatchSize);
        bytes32 alternativeApprovalHash = keccak256(abi.encode(reportHash, alternativeBatchValidatorsToApprove, emptyTimestamps));

        for (uint i = 0; i < alternativeBatchSize; i++) {
            newPubKeys[i] = pubKeys[i];
            newSignatures[i] = signatures[i];
        }
        test_changingBatchSize(); //
        test_executeTask();
        (bool preCompleted, bool preExists, ) = etherFiAdminInstance.validatorManagementTaskStatus(alternativeApprovalHash);
        etherFiAdminInstance.executeValidatorManagementTask(reportHash, alternativeBatchValidatorsToApprove, emptyTimestamps, newPubKeys, newSignatures);
        (bool postCompleted, bool postExists, ) = etherFiAdminInstance.validatorManagementTaskStatus(alternativeApprovalHash);
        assertTrue(postCompleted);
        assertTrue(postExists);
        vm.stopPrank();
    }

    function test_rebase_admin() public {
        skip(3600);
        uint256 preTotalPooledEth = liquidityPoolInstance.getTotalPooledEther();
        vm.startPrank(committeeMember);
        etherFiAdminInstance.executeTasks(report);
        (bool preExecuteCompleted, bool preExecuteExists, ) = etherFiAdminInstance.validatorManagementTaskStatus(approvalHash);
        uint256 postTotalPooledEth = liquidityPoolInstance.getTotalPooledEther();
        uint256 rebaseAmount = preTotalPooledEth + accruedRewards + 6 ether / 100;
        assert(postTotalPooledEth == (preTotalPooledEth + accruedRewards + protocolFees + 6 ether / 100));
    }
}
