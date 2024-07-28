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

    function setUp() public {
        setUpTests();
        initializeRealisticForkWithBlock(MAINNET_FORK, 20157483);
        pubKeys = _getImperialPubkey();
        signatures = _getImperialSignature();
        report = _generateImperialReport();
        batchSize = 25;
        alternativeBatchSize = 10;
        accruedRewards = 8729224130452426342;
        //upgrade the contact
        upgradeContract();
        reportHash = etherFiOracleInstance.generateReportHash(report);
        batchValidatorsToApprove = _getValidatorToApprove(52835, batchSize); //52835 based on transaction
        emptyTimestamps = new uint32[](0);
        approvalHash = keccak256(abi.encode(reportHash, batchValidatorsToApprove, emptyTimestamps));
    }

    function upgradeContract() public {
        EtherFiAdmin v2Implementation = new EtherFiAdmin();
        EtherFiOracle v2ImplementationOracle = new EtherFiOracle();
        vm.startPrank(etherFiAdminInstance.owner());
        etherFiAdminInstance.upgradeTo(address(v2Implementation));
        etherFiOracleInstance.upgradeTo(address(v2ImplementationOracle));
        etherFiAdminInstance.initializeV2dot5(address(roleRegistry));
        vm.startPrank(superAdmin);
        roleRegistry.grantRole(etherFiAdminInstance.ETHERFI_ADMIN_ADMIN_ROLE(), committeeMember);
        vm.startPrank(etherFiAdminInstance.owner());
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
                refSlotFrom: 9362464,
                refSlotTo: 9362943,
                refBlockFrom: 20156700,
                refBlockTo: 20157172,
                accruedRewards: 8729224130452426342,
                protocolFees: 0,
                validatorsToApprove: new uint256[](100),
                liquidityPoolValidatorsToExit: new uint256[](0),
                exitedValidators: new uint256[](0),
                exitedValidatorsExitTimestamps: new uint32[](0),
                slashedValidators: new uint256[](0),
                withdrawalRequestsToInvalidate: new uint256[](0),
                lastFinalizedWithdrawalRequestId: 21696,
                eEthTargetAllocationWeight: 0,
                etherFanTargetAllocationWeight: 0,
                finalizedWithdrawalAmount: 1137171105616126724,
                numValidatorsToSpinUp: 100
            });
        uint256 startId = 52835;
        for (uint i = 0; i < 100; i++) {
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
        bytes[] memory _signature = new bytes[](25);
        _signature[0] = hex"b294fa958aabc6480cfa8d81cb6b0fe81d34cee13923d95885221a7ebee2a910f6b3ceb7b1b8e8dd84b9a008c22c386303d27537d0d1c93cc37393a39579ab0129ca5ed1a04e92b213794cbaa346fab9e26f38c5f0d8ebab3b197060897b8b4c";
        _signature[1] = hex"a0bf526ae1220422608c578a792278f72e2f9a1b7ba905ead0429dbae0993a9dceda00a701afa7a5825f587b149c50ec09227c7babbe4be8151643c51ff80e492ab9ca91f4afe8c1520495ba3c6a3a46aee33aecb4ee02d3bb1ab22168d82be4";
        _signature[2] = hex"b27e7824df83f908b535310b629ee68a261cc2a4ae849f6ab50b1ae90a65399aef81c58076baecf1110324d0b2b7d17f158aedbcfaa303d184358265b7e96177023c10900122242c90f2a8f221d87404979bf15ae04f34b8cbaa06865cf20628";
        _signature[3] = hex"8af91b61d04b9df4a0eb602c06dd833201e5ad306b12b023ade121fef17888608e88170c95aba66434e34957b9a63c3a09f7e0f02c0bd2039b507f6ef4fccb54ef1ae0dd4db09e306c35680718351e11b5ea23341d8ef25ac1f0964ec3587a86";
        _signature[4] = hex"ac9788dd32c3f72f01671cd02b87b4ddf495865b19646a13d6e2d29a532a5155a1783e8654abaa08ce77759bb823c56f13f55ec64a50e20335e5fc40d9e38508367669dad76b0b93b51729a8ca9e4d7a824b43f656aabf17b9a4a25216fdce33";
        _signature[5] = hex"a3baa08b99b7096e4e7bd2ec7565e934271642e1e532beb43f1325e7de391614cd341115b0fd63df9eb4186009ba3e300e1df6898be497211105b38ff7ac848f5d9fd0d7496d14298f787f158c08f32644f552002f10076c6ab070592226aca5";
        _signature[6] = hex"b03b2c4ddbea3483d95bc61b98db6254ec89cfb90f544e70f0c03d533360728f747e6a1afececb003ea3bde13a5eee3915f56e093f3679bfce6251a3ea975385afbfad58478ee670d54bce964109bb301210fb6fb14dfe3b709f26b6c8027555";
        _signature[7] = hex"b49fc5c1cecd67af9a4d029b2896535e54e72e71b7cce16ee169bb4e89d52d159ded993789f731031073a91f196c1e690aa8ef7850d10711c9da7851936ae4a029fef08ce0068a19442757bd25b6694f2d1777dd560b83fb90b0557977611a65";
        _signature[8] = hex"833c1059ff48408a2154a35b4db91b261fed525d67e6378bbda8cfa5b6016f8b17573568dff16f6a7f7c4835d615bddf0d56bca662f1e96c294b07574b44851bd6226b3654e0c28f50e8b5f954bca22ba98512666db269d1530f7f29cf305011";
        _signature[9] = hex"a13de25e8c7448e59bfdfcc948166e83d69b4241e9cd2bf9242307ea0c036ccccc99eb685b08b0766f43124cc05b0812083704bd0604c026302dd8b26e2c8c53514ab55dab048c53f67f0922a4b7f29e34ef03cdf5c50712622db8674466d166";
        _signature[10] = hex"95ea2eef8e67561f384a1e1275f2dcceff8659da9121bfc2539b8c85f2245974ab02b234cfec91666e6a2a0a96c15fd9037623ff14fb31ca94d949caeffd428d78ac6afb09cff42298cf7517d78372ca0a0d345efc701c41b826d6262bbbe2cd";
        _signature[11] = hex"96c7e49974727a5f3926627fbfb9c50d3bf3231f2ad7d410fc78a5bc69f2c48210e8cf9c874947cc6f9939b8a89d244a0de877b431eae8b410744777985971ed52d58bf9e586183f2edcaad52540aac5303b0e680d561eef3c248d1b0f902ad1";
        _signature[12] = hex"8b71de6d47ae4e1392caa054086179e0d230518515ca15ee8ff45cdf851868d587451d4e9dc36d52dd6618d03bcddec80330fc9b767a4084019a77a18358a882ebbf0f1daeb76907d2b4eb988f80f8c70f64e6b2f28736aaf613e38c82ef4bdf";
        _signature[13] = hex"b2474d80290da393b6fef2f73b85614842564cf1ad0e59c845530d1be9405e2208723aa6cfcd339808f1976f4544160710076f916a4e7df0714004d8ac583b81f546e0f2451561583854198ff7f7ad2e26f1df4e670e2f0d0587057cd97fdb04";
        _signature[14] = hex"ad3ab548ab95a7291fcccd2c195ebff32b7fd5f6c033c70fba69f9388d2877c2c29f814386216546ceef64d0462229f8141b25b07a2575c71a9cf503bb7de361b54111d37c936e6216823af38f29c5f504cf942d0f48922bdb9da22d51f55e74";
        _signature[15] = hex"88d6af3f70b87868f8596c59b5a7cff9047fbde018ed672cbf06f36e6a10208784e6b03f43812aa646335628ce48e04312bb2664ec74e2859802fbc74657882da718aa8b3e0ae5f45e4dc9ecec7050d2ae23b378b0be6fa9ac699fd04d2987c0";
        _signature[16] = hex"b581e4b59fef57b952f253624b17a087eedcb43b42ed54d2b16038542a8aee8d8f0de40b41834fd2d267b4722c3cfe730b5906f59afc7ed74c6d2805f93f3678c1f829216615bb87425189802359fb28bf015fe511e7dbed685cea96a43c2aae";
        _signature[17] = hex"988fec296584ceed34b603537d66165ee34109f3c1aa2e1152622d18f7425d9ca25471fee268e04c9c412bc87ee6d67c03f4ea5cf537c39370ccdd36df09c1046a71b36c053c1cea58a8f8a9a2858c0a5c1326b5719cc82d720c61cc7d915526";
        _signature[18] = hex"b61ba8d6c03f1c38cce346b8653b4e0a052b26d5b775506f1db944908262a51ec49303bd4c40d4ce5a53403d72482d2615d49662e0847393e13084c4a0210a1748598cc1cf089a19f2919ae6c5e572530206aa454ed9d24042390169f3849b18";
        _signature[19] = hex"a185f4bea0d0f04be088bd580d1b8c7cec5e6c4dc6b7d1c7c51b3abee54994e56615260120000bd08f64acc42b96acef0eba1b562ea58c8a4aaabcc02fc0e6f78234b45feedcc1906580b405c8a358842bff5a6ccd15e9cb55a3f18c28d53d0e";
        _signature[20] = hex"937c637488230cdaa13b8b7c1bebc77ab970d25be715584bd758798b4cd2f3fe681077d29d949449fdd0c063959783c10da730bc8707fe8ac2711976ea6650288d0e5e28491ffeb82b7476ac473f838b15234827b726a6380af06a831ff8889d";
        _signature[21] = hex"a44a25451bcdcff2612c362afc79fef7bb05aebab28d5c40acd68c7d5aff4f63015c68fe9e186acb10eb27865d7c847a09f85d449c8b28e8b7ddd96fdf1b12a37900fe5abc2e24b5a9d250ca4fbfb6e1ab5fef4aad726367b4ea8591c536c2cf";
        _signature[22] = hex"81efb7148934a9c37646678f063bbf982faaa4ca0d0cf8aac396a3661a65da074273ebd0cd163164b0d7ee60e67da6eb15dc126af9edef2062954b2c21075f848ac599347231a95a788157d22e498ae2a70260caee473492b3dcc367ba51d2e3";
        _signature[23] = hex"b2b024013ad8e18b3373dc12f71ea6db26997371f7eaefd5a86d03976573dc449c7051ffc8d0a56be4755d80237ef80e01f91eac7820f602de42024f350fb246f6d149bb267b669aa4c4be3113f0e8c1bd8ee06b925d040e09f33d8c0fadb955";
        _signature[24] = hex"8ae7af7fa32bc5c4542cacdf386e24f94c1196da6fa50dc5ac6bcc6fffacb4361bbc3466b1dba2beeac78aca5e52328a18cd708326c9c924f70fcbf9278ba3fe71160f52c7e6d0b91a054c80442732dbcc913da2658bcdda21c14773b384ec82";
        return _signature;
    }

    function _getImperialPubkey() internal returns (bytes[] memory) {
        bytes[] memory _pubKey = new bytes[](25);
        _pubKey[0] = hex"b224aa083a5c8d20a65880b863c2867e27be39fc33c2d9e515211a438bc3b69ae1efa4714b711ff4983e46d30f5032eb";
        _pubKey[1] = hex"a595fc34bc29e6655358c76b5728d6f5dcffcf6c56449a13b677fa0c8fdfa44a9c0095da877aab3a5b7b57085355d44a";
        _pubKey[2] = hex"94ab75720528b666fc06c4c7dcb7c6fc442baba61d0c71b8bef4376ddb46182f5dd18bc1f901971509d1b536b2178727";
        _pubKey[3] = hex"b2ac9209280ac9d882569849be0ba22a62ec5143bb2eabbd00fcbc3b3ecc4d1b05ef5a1b6d5d2dade34786f8ffe6aff7";
        _pubKey[4] = hex"a118cd50c16cb163c59560c50b844e51fd46a007ceff96a48dd259ee3bc86c04f9885bc1c0a6c99289925fd88d172a9a";
        _pubKey[5] = hex"99645abecfc96cbaf74acc8e9ca25b3185f702d9f63ac147bdd10337768aa958d1fd7d2227d6e980112605b552b368dc";
        _pubKey[6] = hex"a6b048a5167ea73f4ff8ab147945b9c2259015b44ed3af12fe82bca48c75f6ccaf45e46bc18210a79698c6b4a3d6f660";
        _pubKey[7] = hex"9230cef2772c2fc46c2a13d84f8312fa63441d4fa6728d7b7e6da62eb5fbba510ea07922059259ebb4dc7af881ba1cb6";
        _pubKey[8] = hex"a7ba9e2b5daeaaa68ccc8da8b75994dcbb504d9720d011e6190fc86bedf69812050dfa71fd46ba3492a5e2ad68a639b6";
        _pubKey[9] = hex"87843de270c37a30d4245fcaadc38155469ac066a1f2bafcfe1192998be5ae5151b8fca6d17998c7730120ee06879cd4";
        _pubKey[10] = hex"90558c9ed2e6875e34a2f0fe8cb48955336bae90fb846d0bb82ced5769c143d675a15a9396039a1025f8ed6e0e980af0";
        _pubKey[11] = hex"ad79f00e6e0e066acf90bd5570efdee22cb02177fdeda5e1519970ce59e477133d63ccfccf59d3e5181f6d7fcd0c96ed";
        _pubKey[12] = hex"a6c36df930f45b4c48057ae329519b6fa0d2a5ca78aaaa14781e2b5f36489c7c4385160a38b536ccb7c89278b11f38ef";
        _pubKey[13] = hex"b8a9afe415e6facbc61c826a756e40c356343ccff993e95214699af3990d1df2effb984d7b7bfeb88a8df8403f5e846a";
        _pubKey[14] = hex"a83049af5ac2c32be4134654177cd62d9c66f4aa4197499c6b5575946a4e91566649a224b5bf0fe0be5375767daa66cd";
        _pubKey[15] = hex"b7ba13ed7b0590407b855e49bd3cb26b75959d140521a83750f7c5b71f93f4414eb47ebd625ee9ca56a5c097d550233e";
        _pubKey[16] = hex"b293da30d0f4940dcf688dfa43bf7616b35c77269e7a08deaf91571a2c5ba604ca312f106fab51b538b114f59c6c9ca8";
        _pubKey[17] = hex"918e73d0545f35c27c03c7da70cf26b1ffad545febeb0d9f2260c2b984389dd1c37c2c2a2481f62aae98bde55dcf3321";
        _pubKey[18] = hex"86b7f539e7313987d67788cd7ed67d469ab98172dbab133144ba0bf8833be40747513a99e0b2f6530e521d4de114767b";
        _pubKey[19] = hex"b758e8123dd22d2b534707d627a41d5e20a4eeef49b5a764f3770cbe4e3e66d16940350ce94f6d7c98e95ecbecdb156f";
        _pubKey[20] = hex"9248a998630095a2373ea124dc358b5bfa7143373b22f043683f393a9ee553e1c9d6632d7da5be1f6699484087652875";
        _pubKey[21] = hex"854c069f2437184ef0170aa6fd607489f3229f010d4fc647fc419ea4b5d062d2857d745bc3d9e1365e046c28e4099d65";
        _pubKey[22] = hex"920f978f7aa95bae09ec450409083af9b6e8e8817a84b71763e72e568d0ff0e247b61eb01b60f32eb823969cfe720103";
        _pubKey[23] = hex"a98772501ec0405f42e0b5b2b166b65b850c7c39a861946c5b6dc77c2caa5a34ac4fc8af8d2fdeac8991819e3db7fa93";
        _pubKey[24] = hex"a5570902fea39478fbbbbac62862214d86fb87a7f51e5b690ddb97f230d89613100f2817894324cb09a09d259044f0ed";
        return _pubKey;
    }

    function test_executeTask() public {
        vm.startPrank(committeeMember);
        etherFiOracleInstance.submitReport(report);
        skip(1800);
        (bool preExecuteCompleted, bool preExecuteExists, ) = etherFiAdminInstance.validatorManagementTaskStatus(approvalHash);
        assertFalse(preExecuteCompleted);
        assertFalse(preExecuteExists);
        etherFiAdminInstance.executeTasks(report);
    }

    function test_changingBatchSize() public {
        vm.startPrank(alice);
        vm.expectRevert();
        etherFiAdminInstance.setValidatorTaskBatchSize(alternativeBatchSize);
        vm.stopPrank();
        vm.startPrank(owner);
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
        uint256[] memory alternativeBatchValidatorsToApprove = _getValidatorToApprove(52835, alternativeBatchSize);
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

    function test_rebase() public {
        vm.startPrank(committeeMember);
        etherFiOracleInstance.submitReport(report);
        skip(3600);
        uint256 preTotalPooledEth = liquidityPoolInstance.getTotalPooledEther();
        etherFiAdminInstance.executeTasks(report);
        (bool preExecuteCompleted, bool preExecuteExists, ) = etherFiAdminInstance.validatorManagementTaskStatus(approvalHash);
        skip(1);
        uint256 postTotalPooledEth = liquidityPoolInstance.getTotalPooledEther();
        uint256 boost = membershipManagerV1Instance.fanBoostThresholdEthAmount();

        assert(preTotalPooledEth + accruedRewards + boost == postTotalPooledEth);
    }

    //0xab30d861d075d595fdff4dc100568722047230ceea4916e4d7eceff3804c50c4 admin
    //0xd89636ce38de66a2b0bd42448d896fcb5e90688edc443b3145c402067650f6d7 oracle
    function test_exitValidators() public {
        initializeRealisticForkWithBlock(MAINNET_FORK, 20245813);
        upgradeContract();  
        report.refSlotFrom =  9448384;
        report.refSlotTo = 9451743;
        report.refBlockFrom = 20242141;
        report.refBlockTo = 20245485;
        report.accruedRewards = 62905531321344003821;
        report.validatorsToApprove = new uint256[](0);
        report.exitedValidators = new uint256[](20);
        report.exitedValidatorsExitTimestamps = new uint32[](20);
        report.lastFinalizedWithdrawalRequestId = 23682;
        report.finalizedWithdrawalAmount = 5695197386208801146906;
        uint256 startId = 813;
        for (uint i = 0; i < 20; i++) {
            report.exitedValidators[i] = startId + i;
            report.exitedValidatorsExitTimestamps[i] = 1713702359;
            if(i < 8) {
            report.exitedValidatorsExitTimestamps[i] = 1713701975;
            }
        }
        reportHash = etherFiOracleInstance.generateReportHash(report);
        approvalHash = keccak256(abi.encode(reportHash, report.exitedValidators, report.exitedValidatorsExitTimestamps));
        test_executeTask();
        (bool postCompleted, bool postExists, ) = etherFiAdminInstance.validatorManagementTaskStatus(approvalHash);
        assertFalse(postCompleted);
        assertTrue(postExists);
        bytes[] memory emptySignatures = new bytes[](0);
        bytes[] memory emptyPubKeys = new bytes[](0);
        etherFiAdminInstance.executeValidatorManagementTask(reportHash, report.exitedValidators, report.exitedValidatorsExitTimestamps, emptyPubKeys, emptySignatures);
        (bool finalCompleted, bool finalExists, ) = etherFiAdminInstance.validatorManagementTaskStatus(approvalHash);
        assertTrue(finalCompleted);
        assertTrue(finalExists);
    }
}

