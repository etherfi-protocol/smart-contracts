pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console.sol";

// import "@openzeppelin-upgradeable/contracts/interfaces/IERC20.sol";

import "../src/eigenlayer-interfaces/IDelayedWithdrawalRouter.sol";
import "../src/eigenlayer-interfaces/IEigenPodManager.sol";
import "../src/eigenlayer-interfaces/IBeaconChainOracle.sol";
import "./eigenlayer-mocks/BeaconChainOracleMock.sol";

import "../src/interfaces/IStakingManager.sol";
import "../src/interfaces/IEtherFiNode.sol";
import "../src/interfaces/ILiquidityPool.sol";
import "../src/interfaces/ILiquifier.sol";
import "../src/EtherFiNodesManager.sol";
import "../src/StakingManager.sol";
import "../src/NodeOperatorManager.sol";
import "../src/archive/RegulationsManager.sol";
import "../src/AuctionManager.sol";
import "../src/archive/ProtocolRevenueManager.sol";
import "../src/BNFT.sol";
import "../src/TNFT.sol";
import "../src/Treasury.sol";
import "../src/EtherFiNode.sol";
import "../src/LiquidityPool.sol";
import "../src/Liquifier.sol";
import "../src/EETH.sol";
import "../src/WeETH.sol";
import "../src/MembershipManager.sol";
import "../src/MembershipNFT.sol";
import "../src/EarlyAdopterPool.sol";
import "../src/TVLOracle.sol";
import "../src/UUPSProxy.sol";
import "../src/WithdrawRequestNFT.sol";
import "../src/NFTExchange.sol";
import "../src/helpers/AddressProvider.sol";
import "./DepositDataGeneration.sol";
import "./DepositContract.sol";
import "./Attacker.sol";
import "../lib/murky/src/Merkle.sol";
import "./TestERC20.sol";

import "../src/archive/MembershipManagerV0.sol";
import "../src/EtherFiOracle.sol";
import "../src/EtherFiAdmin.sol";
import "../src/EtherFiTimelock.sol";

contract TestSetup is Test {
    uint256 public constant kwei = 10 ** 3;
    uint256 public slippageLimit = 50;

    TestERC20 public rETH;
    TestERC20 public wstETH;
    TestERC20 public sfrxEth;
    TestERC20 public cbEthTestERC;

    ICurvePool public cbEth_Eth_Pool;
    ICurvePool public wbEth_Eth_Pool;
    ICurvePool public stEth_Eth_Pool;

    IcbETH public cbEth;
    IwBETH public wbEth;
    ILido public stEth;
    IStrategy public cbEthStrategy;
    IStrategy public wbEthStrategy;
    IStrategy public stEthStrategy;
    IEigenLayerStrategyManager public eigenLayerStrategyManager;
    IDelayedWithdrawalRouter public eigenLayerDelayedWithdrawalRouter;
    IBeaconChainOracle public beaconChainOracle;
    BeaconChainOracleMock public beaconChainOracleMock;
    IEigenPodManager public eigenLayerEigenPodManager;

    ILidoWithdrawalQueue public lidoWithdrawalQueue;

    UUPSProxy public auctionManagerProxy;
    UUPSProxy public stakingManagerProxy;
    UUPSProxy public etherFiNodeManagerProxy;
    UUPSProxy public protocolRevenueManagerProxy;
    UUPSProxy public TNFTProxy;
    UUPSProxy public BNFTProxy;
    UUPSProxy public liquidityPoolProxy;
    UUPSProxy public liquifierProxy;
    UUPSProxy public eETHProxy;
    UUPSProxy public regulationsManagerProxy;
    UUPSProxy public weETHProxy;
    UUPSProxy public nodeOperatorManagerProxy;
    UUPSProxy public membershipManagerProxy;
    UUPSProxy public membershipNftProxy;
    UUPSProxy public nftExchangeProxy;
    UUPSProxy public withdrawRequestNFTProxy;
    UUPSProxy public etherFiOracleProxy;
    UUPSProxy public etherFiAdminProxy;

    DepositDataGeneration public depGen;
    IDepositContract public depositContractEth2;

    DepositContract public mockDepositContractEth2;

    StakingManager public stakingManagerInstance;
    StakingManager public stakingManagerImplementation;

    AuctionManager public auctionImplementation;
    AuctionManager public auctionInstance;

    ProtocolRevenueManager public protocolRevenueManagerInstance;
    ProtocolRevenueManager public protocolRevenueManagerImplementation;

    EtherFiNodesManager public managerInstance;
    EtherFiNodesManager public managerImplementation;

    RegulationsManager public regulationsManagerInstance;
    RegulationsManager public regulationsManagerImplementation;

    EarlyAdopterPool public earlyAdopterPoolInstance;
    AddressProvider public addressProviderInstance;

    TNFT public TNFTImplementation;
    TNFT public TNFTInstance;

    BNFT public BNFTImplementation;
    BNFT public BNFTInstance;

    LiquidityPool public liquidityPoolImplementation;
    LiquidityPool public liquidityPoolInstance;

    Liquifier public liquifierImplementation;
    Liquifier public liquifierInstance;

    EETH public eETHImplementation;
    EETH public eETHInstance;

    WeETH public weEthImplementation;
    WeETH public weEthInstance;

    MembershipManagerV0 public membershipManagerImplementation;
    MembershipManagerV0 public membershipManagerInstance;

    MembershipManager public membershipManagerV1Implementation;
    MembershipManager public membershipManagerV1Instance;

    MembershipNFT public membershipNftImplementation;
    MembershipNFT public membershipNftInstance;

    WithdrawRequestNFT public withdrawRequestNFTImplementation;
    WithdrawRequestNFT public withdrawRequestNFTInstance;

    NFTExchange public nftExchangeImplementation;
    NFTExchange public nftExchangeInstance;

    NodeOperatorManager public nodeOperatorManagerImplementation;
    NodeOperatorManager public nodeOperatorManagerInstance;

    EtherFiOracle public etherFiOracleImplementation;
    EtherFiOracle public etherFiOracleInstance;

    EtherFiAdmin public etherFiAdminImplementation;
    EtherFiAdmin public etherFiAdminInstance;

    EtherFiNode public node;
    Treasury public treasuryInstance;

    Attacker public attacker;
    RevertAttacker public revertAttacker;
    GasDrainAttacker public gasDrainAttacker;
    NoAttacker public noAttacker;

    TVLOracle tvlOracle;

    EtherFiTimelock public etherFiTimelockInstance;

    Merkle merkle;
    bytes32 root;

    Merkle merkleMigration;
    bytes32 rootMigration;

    Merkle merkleMigration2;
    bytes32 rootMigration2;

    uint64[] public requiredEapPointsPerEapDeposit;

    bytes32 termsAndConditionsHash = keccak256("TERMS AND CONDITIONS");

    bytes32[] public whiteListedAddresses;
    bytes32[] public dataForVerification;
    bytes32[] public dataForVerification2;

    IStakingManager.DepositData public test_data;
    IStakingManager.DepositData public test_data_2;

    address owner = vm.addr(1);
    address alice = vm.addr(2);
    address bob = vm.addr(3);
    address chad = vm.addr(4);
    address dan = vm.addr(5);
    address elvis = vm.addr(6);
    address greg = vm.addr(7);
    address henry = vm.addr(8);
    address liquidityPool = vm.addr(9);
    address shonee = vm.addr(1200);
    address jess = vm.addr(1201);

    address admin;

    address[] public actors;
    address[] public bnftHoldersArray;
    uint256[] public whitelistIndices;

    bytes aliceIPFSHash = "AliceIPFS";
    bytes _ipfsHash = "ipfsHash";

    bytes32 zeroRoot = 0x0000000000000000000000000000000000000000000000000000000000000000;
    bytes32[] zeroProof;

    IEtherFiOracle.OracleReport reportAtPeriod2A;
    IEtherFiOracle.OracleReport reportAtPeriod2B;
    IEtherFiOracle.OracleReport reportAtPeriod2C;
    IEtherFiOracle.OracleReport reportAtPeriod3;
    IEtherFiOracle.OracleReport reportAtPeriod3A;
    IEtherFiOracle.OracleReport reportAtPeriod3B;
    IEtherFiOracle.OracleReport reportAtPeriod4;
    IEtherFiOracle.OracleReport reportAtSlot3071;
    IEtherFiOracle.OracleReport reportAtSlot4287;

    int256 slotsPerEpoch = 32;
    int256 secondsPerSlot = 12;
    uint32 genesisSlotTimestamp;

    // enum for fork options
    uint8 TESTNET_FORK = 1;
    uint8 MAINNET_FORK = 2;

    struct TimelockTransactionInput {
        address target;
        uint256 value;
        bytes data;
        bytes32 predecessor;
        bytes32 salt;
        uint256 delay;
    }


    // initialize a fork in which fresh contracts are deployed
    // and initialized to the same state as the unit tests.
    function initializeTestingFork(uint8 forkEnum) public {

        if (forkEnum == MAINNET_FORK) {
            vm.selectFork(vm.createFork(vm.envString("MAINNET_RPC_URL")));
        } else if (forkEnum == TESTNET_FORK) {
            vm.selectFork(vm.createFork(vm.envString("TESTNET_RPC_URL")));
        } else {
            revert("Unimplemented fork");
        }

        setUpTests();
    }

    // initialize a fork which inherits the exact contracts, addresses, and state of
    // the associated network. This allows you to realistically test new transactions against
    // testnet or mainnet.
    function initializeRealisticFork(uint8 forkEnum) public {

        if (forkEnum == MAINNET_FORK) {
            vm.selectFork(vm.createFork(vm.envString("MAINNET_RPC_URL")));
            addressProviderInstance = AddressProvider(address(0x8487c5F8550E3C3e7734Fe7DCF77DB2B72E4A848));
            owner = addressProviderInstance.owner();
            admin = 0x2aCA71020De61bb532008049e1Bd41E451aE8AdC;
        } else if (forkEnum == TESTNET_FORK) {
            vm.selectFork(vm.createFork(vm.envString("TESTNET_RPC_URL")));
            addressProviderInstance = AddressProvider(address(0x6E429db4E1a77bCe9B6F9EDCC4e84ea689c1C97e));
            owner = 0xD0d7F8a5a86d8271ff87ff24145Cf40CEa9F7A39;
            admin = 0xD0d7F8a5a86d8271ff87ff24145Cf40CEa9F7A39;
        } else {
            revert("Unimplemented fork");
        }

        depGen = new DepositDataGeneration();

        //  grab all addresses from address manager and override global testing variables
        regulationsManagerInstance = RegulationsManager(addressProviderInstance.getContractAddress("RegulationsManager"));
        managerInstance = EtherFiNodesManager(payable(addressProviderInstance.getContractAddress("EtherFiNodesManager")));
        liquidityPoolInstance = LiquidityPool(payable(addressProviderInstance.getContractAddress("LiquidityPool")));
        eETHInstance = EETH(addressProviderInstance.getContractAddress("EETH"));
        weEthInstance = WeETH(addressProviderInstance.getContractAddress("WeETH"));
        membershipManagerV1Instance = MembershipManager(payable(addressProviderInstance.getContractAddress("MembershipManager")));
        membershipNftInstance = MembershipNFT(addressProviderInstance.getContractAddress("MembershipNFT"));
        nftExchangeInstance = NFTExchange(addressProviderInstance.getContractAddress("NFTExchange"));
        auctionInstance = AuctionManager(addressProviderInstance.getContractAddress("AuctionManager"));
        stakingManagerInstance = StakingManager(addressProviderInstance.getContractAddress("StakingManager"));
        TNFTInstance = TNFT(addressProviderInstance.getContractAddress("TNFT"));
        BNFTInstance = BNFT(addressProviderInstance.getContractAddress("BNFT"));
        treasuryInstance = Treasury(payable(addressProviderInstance.getContractAddress("Treasury")));
        nodeOperatorManagerInstance = NodeOperatorManager(addressProviderInstance.getContractAddress("NodeOperatorManager"));
        node = EtherFiNode(payable(addressProviderInstance.getContractAddress("EtherFiNode")));
        earlyAdopterPoolInstance = EarlyAdopterPool(payable(addressProviderInstance.getContractAddress("EarlyAdopterPool")));
        withdrawRequestNFTInstance = WithdrawRequestNFT(addressProviderInstance.getContractAddress("WithdrawRequestNFT"));
        etherFiTimelockInstance = EtherFiTimelock(payable(addressProviderInstance.getContractAddress("EtherFiTimelock")));
        liquifierInstance = Liquifier(payable(addressProviderInstance.getContractAddress("Liquifier")));

        assert(address(regulationsManagerInstance) != address(0x0));
        assert(address(managerInstance) != address(0x0));
        assert(address(liquidityPoolInstance) != address(0x0));
        assert(address(eETHInstance) != address(0x0));
        assert(address(weEthInstance) != address(0x0));
        assert(address(membershipManagerV1Instance) != address(0x0));
        assert(address(membershipNftInstance) != address(0x0));
        assert(address(nftExchangeInstance) != address(0x0));
        assert(address(auctionInstance) != address(0x0));
        assert(address(stakingManagerInstance) != address(0x0));
        assert(address(TNFTInstance) != address(0x0));
        assert(address(BNFTInstance) != address(0x0));
        assert(address(treasuryInstance) != address(0x0));
        assert(address(nodeOperatorManagerInstance) != address(0x0));
        assert(address(node) != address(0x0));
        assert(address(earlyAdopterPoolInstance) != address(0x0));
        assert(address(etherFiTimelockInstance) != address(0x0));

     // TODO: doesn't currently exist on mainnet. But re-add this check after deploy
     //   assert(address(withdrawRequestNFTInstance) != address(0x0));
    }

    function setUpLiquifier(uint8 forkEnum) internal {
        
        vm.startPrank(owner);
            
        if (forkEnum == MAINNET_FORK) {
            liquifierImplementation = new Liquifier();
            liquifierProxy = new UUPSProxy(address(liquifierImplementation), "");
            liquifierInstance = Liquifier(payable(liquifierProxy));

            cbEth_Eth_Pool = ICurvePool(0x5FAE7E604FC3e24fd43A72867ceBaC94c65b404A);
            wbEth_Eth_Pool = ICurvePool(0xBfAb6FA95E0091ed66058ad493189D2cB29385E6);
            stEth_Eth_Pool = ICurvePool(0xDC24316b9AE028F1497c275EB9192a3Ea0f67022);
            cbEth = IcbETH(0xBe9895146f7AF43049ca1c1AE358B0541Ea49704);
            wbEth = IwBETH(0xa2E3356610840701BDf5611a53974510Ae27E2e1);
            stEth = ILido(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
            cbEthStrategy = IStrategy(0x54945180dB7943c0ed0FEE7EdaB2Bd24620256bc);
            wbEthStrategy = IStrategy(0x7CA911E83dabf90C90dD3De5411a10F1A6112184);
            stEthStrategy = IStrategy(0x93c4b944D05dfe6df7645A86cd2206016c51564D);
            eigenLayerStrategyManager = IEigenLayerStrategyManager(0x858646372CC42E1A627fcE94aa7A7033e7CF075A);
            eigenLayerDelayedWithdrawalRouter = IDelayedWithdrawalRouter(0x7Fe7E9CC0F274d2435AD5d56D5fa73E47F6A23D8);
            lidoWithdrawalQueue = ILidoWithdrawalQueue(0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1);
            
            liquifierInstance.initialize(
                address(treasuryInstance),
                address(liquidityPoolInstance),
                address(eigenLayerStrategyManager),
                address(lidoWithdrawalQueue),
                address(stEth),
                address(cbEth),
                address(wbEth),
                address(cbEth_Eth_Pool),
                address(wbEth_Eth_Pool),
                address(stEth_Eth_Pool),
                3600
            );

            liquifierInstance.updateAdmin(alice, true);
            liquifierInstance.registerToken(address(stEth), address(stEthStrategy), true, 0, 50, 1000); // 50 ether timeBoundCap, 1000 ether total cap
            liquifierInstance.registerToken(address(cbEth), address(cbEthStrategy), true, 0, 50, 1000);
            liquifierInstance.registerToken(address(wbEth), address(wbEthStrategy), true, 0, 50, 1000);

            liquidityPoolInstance.upgradeTo(address(new LiquidityPool()));
            liquidityPoolInstance.initializeOnUpgrade(address(auctionInstance), address(liquifierInstance));
        } else if (forkEnum == TESTNET_FORK) {

        }

        vm.stopPrank();
    }

    function setUpTests() internal {
        vm.startPrank(owner);

        mockDepositContractEth2 = new DepositContract();
        depositContractEth2 = IDepositContract(address(mockDepositContractEth2));

        // Deploy Contracts and Proxies
        treasuryInstance = new Treasury();

        nodeOperatorManagerImplementation = new NodeOperatorManager();
        nodeOperatorManagerProxy = new UUPSProxy(address(nodeOperatorManagerImplementation), "");
        nodeOperatorManagerInstance = NodeOperatorManager(address(nodeOperatorManagerProxy));
        nodeOperatorManagerInstance.initialize();
        nodeOperatorManagerInstance.updateAdmin(alice, true);

        auctionImplementation = new AuctionManager();
        auctionManagerProxy = new UUPSProxy(address(auctionImplementation), "");
        auctionInstance = AuctionManager(address(auctionManagerProxy));
        auctionInstance.initialize(address(nodeOperatorManagerInstance));
        auctionInstance.updateAdmin(alice, true);

        stakingManagerImplementation = new StakingManager();
        stakingManagerProxy = new UUPSProxy(address(stakingManagerImplementation), "");
        stakingManagerInstance = StakingManager(address(stakingManagerProxy));
        stakingManagerInstance.initialize(address(auctionInstance), address(mockDepositContractEth2));
        stakingManagerInstance.updateAdmin(alice, true);

        TNFTImplementation = new TNFT();
        TNFTProxy = new UUPSProxy(address(TNFTImplementation), "");
        TNFTInstance = TNFT(address(TNFTProxy));
        TNFTInstance.initialize(address(stakingManagerInstance));

        BNFTImplementation = new BNFT();
        BNFTProxy = new UUPSProxy(address(BNFTImplementation), "");
        BNFTInstance = BNFT(address(BNFTProxy));
        BNFTInstance.initialize(address(stakingManagerInstance));

        protocolRevenueManagerImplementation = new ProtocolRevenueManager();
        protocolRevenueManagerProxy = new UUPSProxy(address(protocolRevenueManagerImplementation), "");
        protocolRevenueManagerInstance = ProtocolRevenueManager(payable(address(protocolRevenueManagerProxy)));
        protocolRevenueManagerInstance.initialize();
        protocolRevenueManagerInstance.updateAdmin(alice);

        managerImplementation = new EtherFiNodesManager();
        etherFiNodeManagerProxy = new UUPSProxy(address(managerImplementation), "");
        managerInstance = EtherFiNodesManager(payable(address(etherFiNodeManagerProxy)));
        managerInstance.initialize(
            address(treasuryInstance),
            address(auctionInstance),
            address(stakingManagerInstance),
            address(TNFTInstance),
            address(BNFTInstance)
        );
        managerInstance.updateAdmin(alice, true);

        TNFTInstance.initializeOnUpgrade(address(managerInstance));
        BNFTInstance.initializeOnUpgrade(address(managerInstance));

        regulationsManagerImplementation = new RegulationsManager();
        vm.expectRevert("Initializable: contract is already initialized");
        regulationsManagerImplementation.initialize();

        regulationsManagerProxy = new UUPSProxy(address(regulationsManagerImplementation), "");
        regulationsManagerInstance = RegulationsManager(address(regulationsManagerProxy));
        regulationsManagerInstance.initialize();
        regulationsManagerInstance.updateAdmin(alice, true);

        node = new EtherFiNode();

        rETH = new TestERC20("Rocket Pool ETH", "rETH");
        rETH.mint(alice, 10e18);
        rETH.mint(bob, 10e18);
        cbEthTestERC = new TestERC20("Staked ETH", "wstETH");
        cbEthTestERC.mint(alice, 10e18);
        cbEthTestERC.mint(bob, 10e18);
        wstETH = new TestERC20("Coinbase ETH", "cbEthTestERC");
        wstETH.mint(alice, 10e18);
        wstETH.mint(bob, 10e18);
        sfrxEth = new TestERC20("Frax ETH", "sfrxEth");
        sfrxEth.mint(alice, 10e18);
        sfrxEth.mint(bob, 10e18);

        earlyAdopterPoolInstance = new EarlyAdopterPool(
            address(rETH),
            address(wstETH),
            address(sfrxEth),
            address(cbEthTestERC)
        );

        addressProviderInstance = new AddressProvider(address(owner));

        liquidityPoolImplementation = new LiquidityPool();
        liquidityPoolProxy = new UUPSProxy(address(liquidityPoolImplementation),"");
        liquidityPoolInstance = LiquidityPool(payable(address(liquidityPoolProxy)));

        liquifierImplementation = new Liquifier();
        liquifierProxy = new UUPSProxy(address(liquifierImplementation), "");
        liquifierInstance = Liquifier(payable(liquifierProxy));

        // TODO - not sure what `name` and `versiona` are for
        eETHImplementation = new EETH();
        vm.expectRevert("Initializable: contract is already initialized");
        eETHImplementation.initialize(payable(address(liquidityPoolInstance)));

        eETHProxy = new UUPSProxy(address(eETHImplementation), "");
        eETHInstance = EETH(address(eETHProxy));

        vm.expectRevert("No zero addresses");
        eETHInstance.initialize(payable(address(0)));
        eETHInstance.initialize(payable(address(liquidityPoolInstance)));

        weEthImplementation = new WeETH();
        vm.expectRevert("Initializable: contract is already initialized");
        weEthImplementation.initialize(payable(address(liquidityPoolInstance)), address(eETHInstance));

        weETHProxy = new UUPSProxy(address(weEthImplementation), "");
        weEthInstance = WeETH(address(weETHProxy));
        vm.expectRevert("No zero addresses");
        weEthInstance.initialize(address(0), address(eETHInstance));
        vm.expectRevert("No zero addresses");
        weEthInstance.initialize(payable(address(liquidityPoolInstance)), address(0));
        weEthInstance.initialize(payable(address(liquidityPoolInstance)), address(eETHInstance));
        vm.stopPrank();

        vm.prank(alice);
        regulationsManagerInstance.initializeNewWhitelist(termsAndConditionsHash);
        vm.startPrank(owner);

        membershipNftImplementation = new MembershipNFT();
        membershipNftProxy = new UUPSProxy(address(membershipNftImplementation), "");
        membershipNftInstance = MembershipNFT(payable(membershipNftProxy));

        withdrawRequestNFTImplementation = new WithdrawRequestNFT();
        withdrawRequestNFTProxy = new UUPSProxy(address(withdrawRequestNFTImplementation), "");
        withdrawRequestNFTInstance = WithdrawRequestNFT(payable(withdrawRequestNFTProxy));


        membershipManagerImplementation = new MembershipManagerV0();
        membershipManagerProxy = new UUPSProxy(address(membershipManagerImplementation), "");
        membershipManagerInstance = MembershipManagerV0(payable(membershipManagerProxy));

        etherFiAdminImplementation = new EtherFiAdmin();
        etherFiAdminProxy = new UUPSProxy(address(etherFiAdminImplementation), "");
        etherFiAdminInstance = EtherFiAdmin(payable(etherFiAdminProxy));

        etherFiOracleImplementation = new EtherFiOracle();
        etherFiOracleProxy = new UUPSProxy(address(etherFiOracleImplementation), "");
        etherFiOracleInstance = EtherFiOracle(payable(etherFiOracleProxy));


        liquidityPoolInstance.initialize(address(eETHInstance), address(stakingManagerInstance), address(etherFiNodeManagerProxy), address(membershipManagerInstance), address(TNFTInstance), address(etherFiAdminProxy), address(withdrawRequestNFTInstance));
        membershipNftInstance.initialize("https://etherfi-cdn/{id}.json", address(membershipManagerInstance));
        withdrawRequestNFTInstance.initialize(payable(address(liquidityPoolInstance)), payable(address(eETHInstance)), payable(address(membershipManagerInstance)));
        membershipManagerInstance.initialize(
            address(eETHInstance),
            address(liquidityPoolInstance),
            address(membershipNftInstance),
            address(treasuryInstance),
            address(protocolRevenueManagerInstance)
        );
        liquifierInstance.initialize(
            address(treasuryInstance),
            address(liquidityPoolInstance),
            address(0),
            address(0),
            address(0),
            address(0),
            address(0),
            address(0),
            address(0),
            address(0),
            0
        );

        membershipManagerInstance.updateAdmin(alice, true);
        membershipNftInstance.updateAdmin(alice, true);
        withdrawRequestNFTInstance.updateAdmin(alice, true);
        liquidityPoolInstance.updateAdmin(alice, true);
        liquifierInstance.updateAdmin(alice, true);

        // special case for forked tests utilizing oracle
        // can't use env variable because then it would apply to all tests including non-forked ones
        if (block.chainid == 1) {
            genesisSlotTimestamp = 1606824023;
        } else if (block.chainid == 5) {
            // goerli
            genesisSlotTimestamp = uint32(1616508000);
        } else if (block.chainid == 17000) {
            // holesky
            genesisSlotTimestamp = 1695902400;
            beaconChainOracle = IBeaconChainOracle(0x4C116BB629bff7A8373c2378bBd919f8349B8f25);
        } else {
            genesisSlotTimestamp = 0;
        }
        etherFiOracleInstance.initialize(2, 1024, 0, 32, 12, genesisSlotTimestamp);

        etherFiOracleInstance.addCommitteeMember(alice);
        etherFiOracleInstance.addCommitteeMember(bob);

        vm.stopPrank();

        vm.startPrank(alice);
        managerInstance.setStakingRewardsSplit(50_000, 50_000, 815_625, 84_375);
        managerInstance.setNonExitPenalty(300, 1 ether);
        membershipManagerInstance.setTopUpCooltimePeriod(28 days);
        vm.stopPrank();
        
        vm.startPrank(owner);

        tvlOracle = new TVLOracle(alice);

        nftExchangeImplementation = new NFTExchange();
        nftExchangeProxy = new UUPSProxy(address(nftExchangeImplementation), "");
        nftExchangeInstance = NFTExchange(payable(nftExchangeProxy));
        nftExchangeInstance.initialize(address(TNFTInstance), address(membershipNftInstance), address(managerInstance));
        nftExchangeInstance.updateAdmin(alice);

        etherFiAdminInstance.initialize(
            address(etherFiOracleInstance),
            address(stakingManagerInstance),
            address(auctionInstance),
            address(managerInstance),
            address(liquidityPoolInstance),
            address(membershipManagerInstance),
            address(withdrawRequestNFTInstance),
            10000,
            0
        );

        etherFiOracleInstance.setEtherFiAdmin(address(etherFiAdminInstance));
        liquidityPoolInstance.initializeOnUpgrade(address(auctionManagerProxy), address(liquifierInstance));
        stakingManagerInstance.initializeOnUpgrade(address(nodeOperatorManagerInstance), address(etherFiAdminInstance));
        auctionInstance.initializeOnUpgrade(address(membershipManagerInstance), 1 ether, address(etherFiAdminInstance), address(nodeOperatorManagerInstance));
        membershipNftInstance.initializeOnUpgrade(address(liquidityPoolInstance));


        // configure eigenlayer dependency differently for mainnet vs testnet because we rely
        // on the contracts already deployed by eigenlayer on those chains
        bool restakingBnftDeposits;
        if (block.chainid == 1) {
            restakingBnftDeposits = true;
            managerInstance.initializeOnUpgrade(address(etherFiAdminInstance), 0x91E677b07F7AF907ec9a428aafA9fc14a0d3A338, 0x7Fe7E9CC0F274d2435AD5d56D5fa73E47F6A23D8, 5);
            managerInstance.initializeOnUpgrade2(0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A);
        } else if (block.chainid == 17000) {
            restakingBnftDeposits = false;
            eigenLayerEigenPodManager = IEigenPodManager(0x30770d7E3e71112d7A6b7259542D1f680a70e315);
            managerInstance.initializeOnUpgrade(address(etherFiAdminInstance), 0x30770d7E3e71112d7A6b7259542D1f680a70e315, 0x642c646053eaf2254f088e9019ACD73d9AE0FA32, 5);
            managerInstance.initializeOnUpgrade2(0xA44151489861Fe9e3055d95adC98FbD462B948e7);
        } else {
            restakingBnftDeposits = false;
            managerInstance.initializeOnUpgrade(address(etherFiAdminInstance), address(0), address(0), 5);
            managerInstance.initializeOnUpgrade2(address(0));
        }

        _initOracleReportsforTesting();
        vm.stopPrank();

        vm.startPrank(alice);
        liquidityPoolInstance.unPauseContract();
        liquidityPoolInstance.updateWhitelistStatus(false);
        liquidityPoolInstance.setRestakeBnftDeposits(restakingBnftDeposits);
        vm.stopPrank();

        // Setup dependencies
        vm.startPrank(alice);
        _approveNodeOperators();
        _setUpNodeOperatorWhitelist();
        vm.stopPrank();

        _merkleSetup();

        vm.startPrank(owner);
        _merkleSetupMigration();

        vm.startPrank(owner);
        _merkleSetupMigration2();

        nodeOperatorManagerInstance.setAuctionContractAddress(address(auctionInstance));

        auctionInstance.setStakingManagerContractAddress(address(stakingManagerInstance));

        protocolRevenueManagerInstance.setAuctionManagerAddress(address(auctionInstance));
        protocolRevenueManagerInstance.setEtherFiNodesManagerAddress(address(managerInstance));

        stakingManagerInstance.setEtherFiNodesManagerAddress(address(managerInstance));
        stakingManagerInstance.setLiquidityPoolAddress(address(liquidityPoolInstance));
        stakingManagerInstance.registerEtherFiNodeImplementationContract(address(node));
        stakingManagerInstance.registerTNFTContract(address(TNFTInstance));
        stakingManagerInstance.registerBNFTContract(address(BNFTInstance));

        vm.stopPrank();

        vm.startPrank(owner);

        depGen = new DepositDataGeneration();

        attacker = new Attacker(address(liquidityPoolInstance));
        revertAttacker = new RevertAttacker();
        gasDrainAttacker = new GasDrainAttacker();
        noAttacker = new NoAttacker();

        vm.stopPrank();

        vm.prank(alice);
        managerInstance.setEnableNodeRecycling(true);

        _initializeMembershipTiers();
        _initializePeople();
        _initializeEtherFiAdmin();

        admin = alice;
    }

    function _initOracleReportsforTesting() internal {
        uint256[] memory validatorsToApprove = new uint256[](0);
        uint256[] memory validatorsToExit = new uint256[](0);
        uint256[] memory exitedValidators = new uint256[](0);
        uint32[] memory  exitTimestamps = new uint32[](0);
        uint256[] memory slashedValidators = new uint256[](0);
        uint256[] memory withdrawalRequestsToInvalidate = new uint256[](0);
        reportAtPeriod2A = IEtherFiOracle.OracleReport(1, 0, 1024 - 1, 0, 1024 - 1, 1, validatorsToApprove, validatorsToExit, exitedValidators, exitTimestamps, slashedValidators, withdrawalRequestsToInvalidate, 1, 80, 20, 0, 0);
        reportAtPeriod2B = IEtherFiOracle.OracleReport(1, 0, 1024 - 1, 0, 1024 - 1, 1, validatorsToApprove, validatorsToExit, exitedValidators, exitTimestamps, slashedValidators, withdrawalRequestsToInvalidate, 1, 81, 19, 0, 0);
        reportAtPeriod2C = IEtherFiOracle.OracleReport(2, 0, 1024 - 1, 0, 1024 - 1, 1, validatorsToApprove, validatorsToExit, exitedValidators, exitTimestamps, slashedValidators, withdrawalRequestsToInvalidate, 1, 79, 21, 0, 0);
        reportAtPeriod3 = IEtherFiOracle.OracleReport(1, 0, 2048 - 1, 0, 2048 - 1, 1, validatorsToApprove, validatorsToExit, exitedValidators, exitTimestamps, slashedValidators, withdrawalRequestsToInvalidate, 1, 80, 20, 0, 0);
        reportAtPeriod3A = IEtherFiOracle.OracleReport(1, 0, 2048 - 1, 0, 3 * 1024 - 1, 1, validatorsToApprove, validatorsToExit, exitedValidators, exitTimestamps, slashedValidators, withdrawalRequestsToInvalidate, 1, 80, 20, 0, 0);
        reportAtPeriod3B = IEtherFiOracle.OracleReport(1, 0, 2048 - 1, 1, 2 * 1024 - 1, 1, validatorsToApprove, validatorsToExit, exitedValidators, exitTimestamps, slashedValidators, withdrawalRequestsToInvalidate, 1, 80, 20, 0, 0);
        reportAtPeriod4 = IEtherFiOracle.OracleReport(1, 2 * 1024, 1024 * 3 - 1, 2 * 1024, 3 * 1024 - 1, 0, validatorsToApprove, validatorsToExit, exitedValidators, exitTimestamps, slashedValidators, withdrawalRequestsToInvalidate, 1, 80, 20, 0, 0);
        reportAtSlot3071 = IEtherFiOracle.OracleReport(1, 2048, 3072 - 1, 2048, 3072 - 1, 1, validatorsToApprove, validatorsToExit, exitedValidators, exitTimestamps, slashedValidators, withdrawalRequestsToInvalidate, 1, 80, 20, 0, 0);
        reportAtSlot4287 = IEtherFiOracle.OracleReport(1, 3264, 4288 - 1, 3264, 4288 - 1, 1, validatorsToApprove, validatorsToExit, exitedValidators, exitTimestamps, slashedValidators, withdrawalRequestsToInvalidate, 1, 80, 20, 0, 0);
    }

    function _merkleSetup() internal {
        merkle = new Merkle();

        whiteListedAddresses.push(keccak256(abi.encodePacked(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931)));
        whiteListedAddresses.push(keccak256(abi.encodePacked(0x9154a74AAfF2F586FB0a884AeAb7A64521c64bCf)));
        whiteListedAddresses.push(keccak256(abi.encodePacked(0xCDca97f61d8EE53878cf602FF6BC2f260f10240B)));

        whiteListedAddresses.push(keccak256(abi.encodePacked(alice)));

        whiteListedAddresses.push(keccak256(abi.encodePacked(bob)));

        whiteListedAddresses.push(keccak256(abi.encodePacked(chad)));

        whiteListedAddresses.push(keccak256(abi.encodePacked(dan)));

        whiteListedAddresses.push(keccak256(abi.encodePacked(elvis)));

        whiteListedAddresses.push(keccak256(abi.encodePacked(greg)));

        whiteListedAddresses.push(keccak256(abi.encodePacked(address(liquidityPoolInstance))));

        whiteListedAddresses.push(keccak256(abi.encodePacked(owner)));
        //Needed a whitelisted address that hasn't been registered as a node operator
        whiteListedAddresses.push(keccak256(abi.encodePacked(shonee)));

        root = merkle.getRoot(whiteListedAddresses);
    }

    function getWhitelistMerkleProof(uint256 index) internal view returns (bytes32[] memory) {
        return merkle.getProof(whiteListedAddresses, index);
    }

    function _initializeMembershipTiers() internal {
        uint40 requiredPointsForTier = 0;
        vm.startPrank(alice);
        for (uint256 i = 0; i < 5; i++) {
            requiredPointsForTier += uint40(28 * 24 * i);
            uint24 weight = uint24(i + 1);
            membershipManagerInstance.addNewTier(requiredPointsForTier, weight);
        }
        vm.stopPrank();
    }

    function _initializePeople() internal {
        for (uint256 i = 1000; i < 1000 + 36; i++) {
            address actor = vm.addr(i);
            actors.push(actor);
            whitelistIndices.push(whiteListedAddresses.length);
            whiteListedAddresses.push(keccak256(abi.encodePacked(actor)));
        }
    }

    function _setUpNodeOperatorWhitelist() internal {
        nodeOperatorManagerInstance.addToWhitelist(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.addToWhitelist(0x9154a74AAfF2F586FB0a884AeAb7A64521c64bCf);
        nodeOperatorManagerInstance.addToWhitelist(0xCDca97f61d8EE53878cf602FF6BC2f260f10240B);
        nodeOperatorManagerInstance.addToWhitelist(alice);
        nodeOperatorManagerInstance.addToWhitelist(bob);
        nodeOperatorManagerInstance.addToWhitelist(chad);
        nodeOperatorManagerInstance.addToWhitelist(dan);
        nodeOperatorManagerInstance.addToWhitelist(elvis);
        nodeOperatorManagerInstance.addToWhitelist(greg);
        nodeOperatorManagerInstance.addToWhitelist(address(liquidityPoolInstance));
        nodeOperatorManagerInstance.addToWhitelist(owner);
        nodeOperatorManagerInstance.addToWhitelist(henry);
    }

    function _merkleSetupMigration() internal {
        merkleMigration = new Merkle();
        dataForVerification.push(
            keccak256(
                abi.encodePacked(alice, uint256(0), uint256(10), uint256(0), uint256(0), uint256(0), uint256(400))
            )
        );
        dataForVerification.push(
            keccak256(
                abi.encodePacked(
                    0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931,
                    uint256(0.2 ether),
                    uint256(0),
                    uint256(0),
                    uint256(0),
                    uint256(0),
                    uint256(652_000_000_000)
                )
            )
        );
        dataForVerification.push(
            keccak256(
                abi.encodePacked(chad, uint256(0), uint256(10), uint256(0), uint256(50), uint256(0), uint256(9464))
            )
        );
        dataForVerification.push(
            keccak256(
                abi.encodePacked(bob, uint256(0.1 ether), uint256(0), uint256(0), uint256(0), uint256(0), uint256(400))
            )
        );
        dataForVerification.push(
            keccak256(
                abi.encodePacked(dan, uint256(0.1 ether), uint256(0), uint256(0), uint256(0), uint256(0), uint256(800))
            )
        );
        rootMigration = merkleMigration.getRoot(dataForVerification);
        requiredEapPointsPerEapDeposit.push(0);
        requiredEapPointsPerEapDeposit.push(0); // we want all EAP users to be at least Silver
        requiredEapPointsPerEapDeposit.push(100);
        requiredEapPointsPerEapDeposit.push(400);
        vm.stopPrank();

        vm.prank(alice);
        membershipNftInstance.setUpForEap(rootMigration, requiredEapPointsPerEapDeposit);
    }

    function _merkleSetupMigration2() internal {
        merkleMigration2 = new Merkle();
        dataForVerification2.push(
            keccak256(
                abi.encodePacked(
                    alice,
                    uint256(1 ether),
                    uint256(103680),
                    uint32(16970393 - 10) // 10 blocks before the last gold
                )
            )
        );
        dataForVerification2.push(keccak256(abi.encodePacked(bob, uint256(2 ether), uint256(141738), uint32(0))));
        dataForVerification2.push(keccak256(abi.encodePacked(chad, uint256(2 ether), uint256(139294), uint32(0))));
        dataForVerification2.push(keccak256(abi.encodePacked(dan, uint256(1 ether), uint256(96768), uint32(0))));

        rootMigration2 = merkleMigration2.getRoot(dataForVerification2);
    }

    function _upgradeMembershipManagerFromV0ToV1() internal {
        assertEq(membershipManagerInstance.getImplementation(), address(membershipManagerImplementation));
        membershipManagerV1Implementation = new MembershipManager();
        vm.startPrank(owner);
        membershipManagerInstance.upgradeTo(address(membershipManagerV1Implementation));
        membershipManagerV1Instance = MembershipManager(payable(membershipManagerProxy));
        assertEq(membershipManagerV1Instance.getImplementation(), address(membershipManagerV1Implementation));

        membershipManagerV1Instance.initializeOnUpgrade(address(etherFiAdminInstance), 0.3 ether, 30);
        vm.stopPrank();
    }

    function _getDepositRoot() internal view returns (bytes32) {
        bytes32 onchainDepositRoot = depositContractEth2.get_deposit_root();
        return onchainDepositRoot;
    }

    function _transferTo(address _recipient, uint256 _amount) internal {
        vm.deal(owner, address(owner).balance + _amount);
        vm.prank(owner);
        (bool sent,) = payable(_recipient).call{value: _amount}("");
        assertEq(sent, true);
    }

    // effect: current slot x, moveClock y slots, you are at x + y
    function _moveClock(int256 numSlots) internal {
        assertEq(numSlots >= 0, true);
        vm.roll(block.number + uint256(numSlots));
        vm.warp(genesisSlotTimestamp + 12 * block.number);
    }

    function _initializeEtherFiAdmin() internal {
        vm.startPrank(owner);

        etherFiAdminInstance.updatePauser(alice, true);
        etherFiAdminInstance.updateAdmin(alice, true);
        etherFiOracleInstance.updateAdmin(alice, true);

        address admin = address(etherFiAdminInstance);
        stakingManagerInstance.updateAdmin(admin, true); 
        liquidityPoolInstance.updateAdmin(admin, true);
        membershipManagerInstance.updateAdmin(admin, true);
        withdrawRequestNFTInstance.updateAdmin(admin, true);
        etherFiOracleInstance.updateAdmin(admin, true);

        vm.stopPrank();
    }

    function _approveNodeOperators() internal {
        address[] memory users = new address[](4);
        users[0] = address(alice);
        users[1] = address(bob);
        users[2] = address(bob);
        users[3] = address(owner);

        ILiquidityPool.SourceOfFunds[] memory approvedTags = new ILiquidityPool.SourceOfFunds[](4);
        approvedTags[0] = ILiquidityPool.SourceOfFunds.EETH;
        approvedTags[1] = ILiquidityPool.SourceOfFunds.ETHER_FAN;
        approvedTags[2] = ILiquidityPool.SourceOfFunds.EETH;
        approvedTags[3] = ILiquidityPool.SourceOfFunds.EETH;

        bool[] memory approvals = new bool[](4);
        approvals[0] = true;
        approvals[1] = true;
        approvals[2] = true;
        approvals[3] = true;

        nodeOperatorManagerInstance.batchUpdateOperatorsApprovedTags(users, approvedTags, approvals);

        address[] memory aliceUser = new address[](1);
        aliceUser[0] = address(alice);

        ILiquidityPool.SourceOfFunds[] memory aliceApprovedTags = new ILiquidityPool.SourceOfFunds[](1);
        aliceApprovedTags[0] = ILiquidityPool.SourceOfFunds.ETHER_FAN;

        bool[] memory aliceApprovals = new bool[](1);
        aliceApprovals[0] = true;
        nodeOperatorManagerInstance.batchUpdateOperatorsApprovedTags(aliceUser, aliceApprovedTags, aliceApprovals);

    }

    function _initReportBlockStamp(IEtherFiOracle.OracleReport memory _report) internal view {
        (uint32 slotFrom, uint32 slotTo, uint32 blockFrom) = etherFiOracleInstance.blockStampForNextReport();
        _report.refSlotFrom = slotFrom;
        _report.refSlotTo = slotTo;
        _report.refBlockFrom = blockFrom;
        _report.refBlockTo = slotTo; //
    }

    function _executeAdminTasks(IEtherFiOracle.OracleReport memory _report) internal {
        _executeAdminTasks(_report, "");
    }

    function _executeAdminTasks(IEtherFiOracle.OracleReport memory _report, string memory _revertMessage) internal {
        bytes[] memory emptyBytes = new bytes[](0);
        _executeAdminTasks(_report, emptyBytes, emptyBytes, _revertMessage);
    }

    function _executeAdminTasks(IEtherFiOracle.OracleReport memory _report, bytes[] memory _pubKey, bytes[] memory /*_signature*/, string memory _revertMessage) internal {        
        _initReportBlockStamp(_report);
        
        uint32 currentSlot = etherFiOracleInstance.computeSlotAtTimestamp(block.timestamp);
        uint32 currentEpoch = (currentSlot / 32);
        uint32 reportEpoch = (_report.refSlotTo / 32) + 3;
        if (currentEpoch < reportEpoch) { // ensure report is finalized
            uint32 numSlotsToMove = 32 * (reportEpoch - currentEpoch);
            _moveClock(int256(int32(numSlotsToMove)));
        }

        etherFiOracleInstance.verifyReport(_report);

        vm.prank(alice);
        etherFiOracleInstance.submitReport(_report);
        vm.prank(bob);
        etherFiOracleInstance.submitReport(_report);

        int256 offset = int256(int16(etherFiAdminInstance.postReportWaitTimeInSlots()));
        if (offset > 2 * 32) {
            offset -= 2 * 32;
        }
        if (offset > 0) {
            _moveClock(offset);
        }

        if (bytes(_revertMessage).length > 0) {
            vm.expectRevert(bytes(_revertMessage));
        }

        vm.prank(alice);
        etherFiAdminInstance.executeTasks(_report, _pubKey, _pubKey);
    }

    function _emptyOracleReport() internal view returns (IEtherFiOracle.OracleReport memory report) {
        uint256[] memory emptyVals = new uint256[](0);
        uint32[] memory emptyVals32 = new uint32[](0);
        uint32 consensusVersion = etherFiOracleInstance.consensusVersion();
        report = IEtherFiOracle.OracleReport(consensusVersion, 0, 0, 0, 0, 0, emptyVals, emptyVals, emptyVals, emptyVals32, emptyVals, emptyVals, 0, 0, 0, 0, 0);
    }

    function calculatePermitDigest(address _owner, address spender, uint256 value, uint256 nonce, uint256 deadline, bytes32 domainSeparator) public pure returns (bytes32) {
        bytes32 permitTypehash = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 digest = keccak256(
            abi.encodePacked(
                hex"1901",
                domainSeparator,
                keccak256(abi.encode(permitTypehash, _owner, spender, value, nonce, deadline))
            )
        );
        return digest;
    }

    function createPermitInput(uint256 privKey, address spender, uint256 value, uint256 nonce, uint256 deadline, bytes32 domianSeparator) public returns (ILiquidityPool.PermitInput memory) {
        address _owner = vm.addr(privKey);
        bytes32 digest = calculatePermitDigest(_owner, spender, value, nonce, deadline, domianSeparator);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, digest);
        ILiquidityPool.PermitInput memory permitInput = ILiquidityPool.PermitInput({
            value: value,
            deadline: deadline,
            v: v,
            r: r,
            s: s
        });
        return permitInput;
    }

    function registerAsBnftHolder(address _user) internal {
        (bool registered, uint32 index) = liquidityPoolInstance.bnftHoldersIndexes(_user);
        if (!registered) liquidityPoolInstance.registerAsBnftHolder(_user);
    }

    function setUpBnftHolders() internal {
        vm.startPrank(alice);
        registerAsBnftHolder(alice);
        registerAsBnftHolder(greg);
        registerAsBnftHolder(bob);
        registerAsBnftHolder(owner);
        registerAsBnftHolder(shonee);
        registerAsBnftHolder(dan);
        registerAsBnftHolder(elvis);
        registerAsBnftHolder(henry);
        vm.stopPrank();

        vm.deal(alice, 100000 ether);
        vm.deal(greg, 100000 ether);
        vm.deal(bob, 100000 ether);
        vm.deal(owner, 100000 ether);
        vm.deal(shonee, 100000 ether);
        vm.deal(dan, 100000 ether);
        vm.deal(elvis, 100000 ether);
        vm.deal(henry, 100000 ether);
        vm.deal(chad, 100000 ether);

        (bool registered, uint32 index) = liquidityPoolInstance.bnftHoldersIndexes(alice);
        assertEq(registered, true);
        assertEq(index, 0);

        (registered, index) = liquidityPoolInstance.bnftHoldersIndexes(henry);
        assertEq(registered, true);
        assertEq(index, 7);
    }

    function depositAndRegisterValidator(bool restaked) public returns (uint256) {
        vm.deal(alice, 33 ether);
        vm.startPrank(alice);

        // if we call this multiple times in a test, don't blow up
        try  nodeOperatorManagerInstance.registerNodeOperator("fake_ipfs_hash", 10) {
        } catch {}

        // create a new bid
        uint256[] memory createdBids = auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);

        // deposit against that bid with restaking enabled
        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether * createdBids.length}(createdBids, restaked);

        // Register the validator and send deposited eth to depositContract/Beaconchain
        // signatures are not checked but roots need to match
        bytes32 depositRoot = depGen.generateDepositRoot(
            hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
            hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
            managerInstance.getWithdrawalCredentials(createdBids[0]),
            32 ether
        );
        IStakingManager.DepositData memory depositData = IStakingManager
            .DepositData({
                publicKey: hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                signature: hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                depositDataRoot: depositRoot,
                ipfsHashForEncryptedValidatorKey: "validator_unit_tests"
        });
        IStakingManager.DepositData[] memory depositDatas = new IStakingManager.DepositData[](1);
        depositDatas[0] = depositData;
        stakingManagerInstance.batchRegisterValidators(zeroRoot, createdBids, depositDatas);

        vm.stopPrank();
        return createdBids[0];
    }

    function launch_validator() internal returns (uint256[] memory) {
        return launch_validator(2, 0, false, alice);
    }

    function launch_validator(uint256 _numValidators, uint256 _validatorIdToCoUseWithdrawalSafe, bool _isLpBnftHolder) internal returns (uint256[] memory) {
        return launch_validator(_numValidators, _validatorIdToCoUseWithdrawalSafe, _isLpBnftHolder, alice, alice);
    }

    function launch_validator(uint256 _numValidators, uint256 _validatorIdToCoUseWithdrawalSafe, bool _isLpBnftHolder, address _bnftStaker) internal returns (uint256[] memory) {
        return launch_validator(_numValidators, _validatorIdToCoUseWithdrawalSafe, _isLpBnftHolder, _bnftStaker, alice);
    }

    function launch_validator(uint256 _numValidators, uint256 _validatorIdToCoUseWithdrawalSafe, bool _isLpBnftHolder, address _bnftStaker, address _nodeOperator) internal returns (uint256[] memory) {
        bytes32 rootForApproval;

        // IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        // report.numValidatorsToSpinUp = uint32(_numValidators);
        // _executeAdminTasks(report);

        vm.deal(owner, 10000 ether);
        vm.deal(alice, 10000 ether);
        vm.deal(bob, 10000 ether);
        vm.deal(_bnftStaker, 10000 ether);

        address admin;
        if (block.chainid == 1) {
            admin = 0x2aCA71020De61bb532008049e1Bd41E451aE8AdC;
        } else {
            admin = alice;
        }
        vm.startPrank(admin);
        registerAsBnftHolder(_nodeOperator);
        liquidityPoolInstance.updateBnftMode(_isLpBnftHolder);
        vm.stopPrank();

        vm.prank(admin);
        auctionInstance.disableWhitelist();

        vm.startPrank(_nodeOperator);
        if (!nodeOperatorManagerInstance.registered(_nodeOperator)) {
            nodeOperatorManagerInstance.registerNodeOperator(
                _ipfsHash,
                10000
            );
        }
        vm.stopPrank();

        vm.startPrank(admin);
        {
            address[] memory users = new address[](2);
            ILiquidityPool.SourceOfFunds[] memory approvedTags = new ILiquidityPool.SourceOfFunds[](2);
            bool[] memory approvals = new bool[](2);
            users[0] = _nodeOperator;
            users[1] = _nodeOperator;
            approvedTags[0] = ILiquidityPool.SourceOfFunds.EETH;
            approvedTags[1] = ILiquidityPool.SourceOfFunds.ETHER_FAN;
            approvals[0] = true;
            approvals[1] = true;
            nodeOperatorManagerInstance.batchUpdateOperatorsApprovedTags(users, approvedTags, approvals);
        }
        vm.stopPrank();

        vm.startPrank(_nodeOperator);
        uint256[] memory bidIds = auctionInstance.createBid{value: 0.1 ether * _numValidators}(_numValidators, 0.1 ether);
        vm.stopPrank();

        startHoax(bob);
        if (_isLpBnftHolder) {
            liquidityPoolInstance.deposit{value: 32 ether * _numValidators}();
        } else {
            liquidityPoolInstance.deposit{value: 30 ether * _numValidators}();
        }
        vm.stopPrank();

        vm.prank(_bnftStaker);
        uint256[] memory newValidators;
        if (_isLpBnftHolder) {
            newValidators = liquidityPoolInstance.batchDepositWithLiquidityPoolAsBnftHolder(bidIds, _numValidators, _validatorIdToCoUseWithdrawalSafe);
        } else {
            newValidators = liquidityPoolInstance.batchDepositAsBnftHolder{value: 2 ether * _numValidators}(bidIds, _numValidators, _validatorIdToCoUseWithdrawalSafe);
        }

        IStakingManager.DepositData[] memory depositDataArray = new IStakingManager.DepositData[](_numValidators);

        bytes32[] memory depositDataRootsForApproval = new bytes32[](_numValidators);
        bytes[] memory pubKey = new bytes[](_numValidators);
        bytes[] memory sig = new bytes[](_numValidators);

        for (uint256 i = 0; i < newValidators.length; i++) {
            address safe = managerInstance.getWithdrawalSafeAddress(
                newValidators[i]
            );
            root = depGen.generateDepositRoot(
                hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                managerInstance.generateWithdrawalCredentials(safe),
                1 ether
            );

            rootForApproval = depGen.generateDepositRoot(
                hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                hex"ad899d85dcfcc2506a8749020752f81353dd87e623b2982b7bbfbbdd7964790eab4e06e226917cba1253f063d64a7e5407d8542776631b96c4cea78e0968833b36d4e0ae0b94de46718f905ca6d9b8279e1044a41875640f8cb34dc3f6e4de65",
                managerInstance.generateWithdrawalCredentials(safe),
                31 ether
            );

            depositDataRootsForApproval[i] = rootForApproval;

            depositDataArray[i] = IStakingManager.DepositData({
                publicKey: hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                signature: hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                depositDataRoot: root,
                ipfsHashForEncryptedValidatorKey: "test_ipfs"
            });

            sig[i] = hex"ad899d85dcfcc2506a8749020752f81353dd87e623b2982b7bbfbbdd7964790eab4e06e226917cba1253f063d64a7e5407d8542776631b96c4cea78e0968833b36d4e0ae0b94de46718f905ca6d9b8279e1044a41875640f8cb34dc3f6e4de65";
            pubKey[i] = hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c";
        }

        vm.startPrank(_bnftStaker);
        bytes32 depositRoot = zeroRoot;
        if (_isLpBnftHolder) {
            liquidityPoolInstance.batchRegisterWithLiquidityPoolAsBnftHolder(depositRoot, newValidators, depositDataArray, depositDataRootsForApproval, sig);
        } else {
            liquidityPoolInstance.batchRegisterAsBnftHolder(depositRoot, newValidators, depositDataArray, depositDataRootsForApproval, sig);
        }
        vm.stopPrank();

        vm.startPrank(admin);
        liquidityPoolInstance.batchApproveRegistration(newValidators, pubKey, sig);
        vm.stopPrank();
    
        return newValidators;
    }

    function _finalizeWithdrawalRequest(uint256 _requestId) internal {
        vm.startPrank(alice);
        withdrawRequestNFTInstance.finalizeRequests(_requestId);
        uint128 amount = withdrawRequestNFTInstance.getRequest(_requestId).amountOfEEth;
        vm.stopPrank();

        vm.prank(address(etherFiAdminInstance));
        liquidityPoolInstance.addEthAmountLockedForWithdrawal(amount);
    }

    function _upgrade_multiple_validators_per_safe() internal {
        vm.warp(block.timestamp + 3 days);

        vm.startPrank(0xcdd57D11476c22d265722F68390b036f3DA48c21);
        // ├─ emit TimelockTransaction(target: 0x308861A430be4cce5502d0A12724771Fc6DaF216, value: 0, data: 0x3659cfe6000000000000000000000000d27a57bb8f9b7ec7862df87f5143146c161f5a8b, predecessor: 0x0000000000000000000000000000000000000000000000000000000000000000, salt: 0x0000000000000000000000000000000000000000000000000000000000000000, delay: 259200 [2.592e5])
        {
            etherFiTimelockInstance.execute(
                address(0x308861A430be4cce5502d0A12724771Fc6DaF216),
                0,
                hex"3659cfe6000000000000000000000000605f17e88027e25e18c95be0d8011ac969426399",
                0x0,
                0x0
            );
        }

        // ├─ emit TimelockTransaction(target: 0x25e821b7197B146F7713C3b89B6A4D83516B912d, value: 0, data: 0x3659cfe6000000000000000000000000b27d4e7b8ff1ef21751b50f3821d99719ad5868f, predecessor: 0x0000000000000000000000000000000000000000000000000000000000000000, salt: 0x0000000000000000000000000000000000000000000000000000000000000000, delay: 259200 [2.592e5])
        {
            etherFiTimelockInstance.execute(
                address(0x25e821b7197B146F7713C3b89B6A4D83516B912d),
                0,
                hex"3659cfe6000000000000000000000000b27d4e7b8ff1ef21751b50f3821d99719ad5868f",
                0x0,
                0x0
            );
        }
        
        // ├─ emit TimelockTransaction(target: 0x7B5ae07E2AF1C861BcC4736D23f5f66A61E0cA5e, value: 0, data: 0x3659cfe6000000000000000000000000afb82ce44fd8a3431a64742bcd3547eeda1afea7, predecessor: 0x0000000000000000000000000000000000000000000000000000000000000000, salt: 0x0000000000000000000000000000000000000000000000000000000000000000, delay: 259200 [2.592e5])
        {
            etherFiTimelockInstance.execute(
                address(0x7B5ae07E2AF1C861BcC4736D23f5f66A61E0cA5e),
                0,
                hex"3659cfe6000000000000000000000000afb82ce44fd8a3431a64742bcd3547eeda1afea7",
                0x0,
                0x0
            );
        }
        
        // ├─ emit TimelockTransaction(target: 0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F, value: 0, data: 0x3659cfe6000000000000000000000000d90c5624a52a3bd4ad006d578b00c3ecf8725fda, predecessor: 0x0000000000000000000000000000000000000000000000000000000000000000, salt: 0x0000000000000000000000000000000000000000000000000000000000000000, delay: 259200 [2.592e5])
        {
            etherFiTimelockInstance.execute(
                address(0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F),
                0,
                hex"3659cfe6000000000000000000000000d90c5624a52a3bd4ad006d578b00c3ecf8725fda",
                0x0,
                0x0
            );
        }

        // ├─ emit TimelockTransaction(target: 0x25e821b7197B146F7713C3b89B6A4D83516B912d, value: 0, data: 0x4937097400000000000000000000000052bbf281fbcfa7cf3e9101a52af5dcb32754e3c0, predecessor: 0x0000000000000000000000000000000000000000000000000000000000000000, salt: 0x0000000000000000000000000000000000000000000000000000000000000000, delay: 259200 [2.592e5])
        {
            etherFiTimelockInstance.execute(
                address(0x25e821b7197B146F7713C3b89B6A4D83516B912d),
                0,
                hex"4937097400000000000000000000000052bbf281fbcfa7cf3e9101a52af5dcb32754e3c0",
                0x0,
                0x0
            );
        }
        
        // ├─ emit TimelockTransaction(target: 0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F, value: 0, data: 0xde5faecc00000000000000000000000039053d51b77dc0d36036fc1fcc8cb819df8ef37a, predecessor: 0x0000000000000000000000000000000000000000000000000000000000000000, salt: 0x0000000000000000000000000000000000000000000000000000000000000000, delay: 259200 [2.592e5])
        {
            etherFiTimelockInstance.execute(
                address(0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F),
                0,
                hex"de5faecc00000000000000000000000039053d51b77dc0d36036fc1fcc8cb819df8ef37a",
                0x0,
                0x0
            );
        }
        vm.stopPrank();
    }

    function _upgrade_etherfi_node_contract() internal {
        EtherFiNode etherFiNode = new EtherFiNode();
        address newImpl = address(etherFiNode);
        vm.prank(stakingManagerInstance.owner());
        stakingManagerInstance.upgradeEtherFiNode(newImpl);
    }

    function _upgrade_etherfi_nodes_manager_contract() internal {
        address newImpl = address(new EtherFiNodesManager());
        vm.prank(managerInstance.owner());
        managerInstance.upgradeTo(newImpl);
    }

    function _upgrade_staking_manager_contract() internal {
        address newImpl = address(new StakingManager());
        vm.prank(stakingManagerInstance.owner());
        stakingManagerInstance.upgradeTo(newImpl);

        assert(stakingManagerInstance.isFullStakeEnabled() == false);
    }

    function _upgrade_liquidity_pool_contract() internal {
        address newImpl = address(new LiquidityPool());
        vm.prank(liquidityPoolInstance.owner());
        liquidityPoolInstance.upgradeTo(newImpl);
    }

    function _to_uint256_array(uint256 _value) internal pure returns (uint256[] memory) {
        uint256[] memory array = new uint256[](1);
        array[0] = _value;
        return array;
    }

    // Given two uint256 params (a, b, c),
    // Check if |a-b| <= c
    function _assertWithinRange(uint256 a, uint256 b, uint256 c) internal pure returns (bool) {
        if (a > b) {
            return a - b <= c;
        } else {
            return b - a <= c;
        }
    }

    function _finalizeLidoWithdrawals(uint256[] memory reqIds) internal {
        bytes32 FINALIZE_ROLE = liquifierInstance.lidoWithdrawalQueue().FINALIZE_ROLE();
        address finalize_role = liquifierInstance.lidoWithdrawalQueue().getRoleMember(FINALIZE_ROLE, 0);

        // The redemption is approved by the Lido
        vm.startPrank(finalize_role);
        uint256 currentRate = stEth.getTotalPooledEther() * 1e27 / stEth.getTotalShares();
        (uint256 ethToLock, uint256 sharesToBurn) = liquifierInstance.lidoWithdrawalQueue().prefinalize(reqIds, currentRate);
        liquifierInstance.lidoWithdrawalQueue().finalize(reqIds[reqIds.length-1], currentRate);
        vm.stopPrank();

        // The ether.fi admin claims the finalized withdrawal, which sends the ETH to the liquifier contract
        vm.startPrank(alice);
        uint256 lastCheckPointIndex = liquifierInstance.lidoWithdrawalQueue().getLastCheckpointIndex();
        uint256[] memory hints = liquifierInstance.lidoWithdrawalQueue().findCheckpointHints(reqIds, 1, lastCheckPointIndex);
        liquifierInstance.stEthClaimWithdrawals(reqIds, hints);

        // The ether.fi admin withdraws the ETH from the liquifier contract to the liquidity pool contract
        liquifierInstance.withdrawEther();
        vm.stopPrank();
    }

    function _prepareForDepositData(uint256[] memory _validatorIds, uint256 _depositAmount) internal returns (IStakingManager.DepositData[] memory) {
        IStakingManager.DepositData[] memory depositDataArray = new IStakingManager.DepositData[](_validatorIds.length);
        bytes[] memory pubKey = new bytes[](_validatorIds.length);

        for (uint256 i = 0; i < _validatorIds.length; i++) {
            address etherFiNode = managerInstance.etherfiNodeAddress(_validatorIds[i]);
            pubKey[i] = hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c";
            bytes32 root = depGen.generateDepositRoot(
                pubKey[i],
                hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                managerInstance.generateWithdrawalCredentials(etherFiNode),
                _depositAmount
            );

            depositDataArray[i] = IStakingManager.DepositData({
                publicKey: pubKey[i],
                signature: hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                depositDataRoot: root,
                ipfsHashForEncryptedValidatorKey: "test_ipfs"
            });
        }

        return depositDataArray;
    }

    function _prepareForValidatorRegistration(uint256[] memory _validatorIds) internal returns (IStakingManager.DepositData[] memory, bytes32[] memory, bytes[] memory, bytes[] memory pubKey) {
        IStakingManager.DepositData[] memory depositDataArray = new IStakingManager.DepositData[](_validatorIds.length);
        bytes32[] memory depositDataRootsForApproval = new bytes32[](_validatorIds.length);
        bytes[] memory sig = new bytes[](_validatorIds.length);
        bytes[] memory pubKey = new bytes[](_validatorIds.length);

        for (uint256 i = 0; i < _validatorIds.length; i++) {
            address etherFiNode = managerInstance.etherfiNodeAddress(_validatorIds[i]);
            pubKey[i] = hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c";
            bytes32 root = depGen.generateDepositRoot(
                pubKey[i],
                hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                managerInstance.generateWithdrawalCredentials(etherFiNode),
                1 ether
            );
            depositDataArray[i] = IStakingManager.DepositData({
                publicKey: pubKey[i],
                signature: hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                depositDataRoot: root,
                ipfsHashForEncryptedValidatorKey: "test_ipfs"
            });

            depositDataRootsForApproval[i] = depGen.generateDepositRoot(
                pubKey[i],
                hex"ad899d85dcfcc2506a8749020752f81353dd87e623b2982b7bbfbbdd7964790eab4e06e226917cba1253f063d64a7e5407d8542776631b96c4cea78e0968833b36d4e0ae0b94de46718f905ca6d9b8279e1044a41875640f8cb34dc3f6e4de65",
                managerInstance.generateWithdrawalCredentials(etherFiNode),
                31 ether
            );

            sig[i] = hex"ad899d85dcfcc2506a8749020752f81353dd87e623b2982b7bbfbbdd7964790eab4e06e226917cba1253f063d64a7e5407d8542776631b96c4cea78e0968833b36d4e0ae0b94de46718f905ca6d9b8279e1044a41875640f8cb34dc3f6e4de65";
        
        }

        return (depositDataArray, depositDataRootsForApproval, sig, pubKey);
    }
}
