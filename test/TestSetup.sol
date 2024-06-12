pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console.sol";


import "../src/eigenlayer-interfaces/IDelayedWithdrawalRouter.sol";
import "../src/eigenlayer-interfaces/IEigenPodManager.sol";
import "../src/eigenlayer-interfaces/IBeaconChainOracle.sol";
import "../src/eigenlayer-interfaces/IDelegationManager.sol";
import "./eigenlayer-mocks/BeaconChainOracleMock.sol";
import "../src/eigenlayer-interfaces/ITimelock.sol";

import "../src/interfaces/IStakingManager.sol";
import "../src/interfaces/IEtherFiNode.sol";
import "../src/interfaces/ILiquidityPool.sol";
import "../src/interfaces/ILiquifier.sol";
import "../src/interfaces/IPausable.sol";
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
import "../src/RoleRegistry.sol";
import "../src/TVLOracle.sol";
import "../src/UUPSProxy.sol";
import "../src/WithdrawRequestNFT.sol";
import "../src/NFTExchange.sol";
import "../src/helpers/AddressProvider.sol";
import "./DepositDataGeneration.sol";
import "./DepositContract.sol";
import "./Attacker.sol";
import "./TestERC20.sol";

import "../src/archive/MembershipManagerV0.sol";
import "../src/EtherFiOracle.sol";
import "../src/EtherFiAdmin.sol";
import "../src/EtherFiTimelock.sol";
import "../src/BucketRateLimiter.sol";
import "../src/Pauser.sol";

contract TestSetup is Test {

    event Schedule(address target, uint256 value, bytes data, bytes32 predecessor, bytes32 salt, uint256 delay);
    event Execute(address target, uint256 value, bytes data, bytes32 predecessor, bytes32 salt);
    event Transaction(address to, uint256 value, bytes data);


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
    IDelegationManager public eigenLayerDelegationManager;
    ITimelock public eigenLayerTimelock;

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

    RoleRegistry public roleRegistry;
    RoleRegistry public roleRegistryImplementation;

    Attacker public attacker;
    RevertAttacker public revertAttacker;
    GasDrainAttacker public gasDrainAttacker;
    NoAttacker public noAttacker;

    TVLOracle tvlOracle;

    EtherFiTimelock public etherFiTimelockInstance;

    Pauser public pauserInstance;
    BucketRateLimiter public bucketRateLimiter;

    bytes32 root;
    bytes32 rootMigration;
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
    address committeeMember = address(0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F);

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

            cbEth_Eth_Pool = ICurvePool(0x5FAE7E604FC3e24fd43A72867ceBaC94c65b404A);
            wbEth_Eth_Pool = ICurvePool(0xBfAb6FA95E0091ed66058ad493189D2cB29385E6);
            stEth_Eth_Pool = ICurvePool(0xDC24316b9AE028F1497c275EB9192a3Ea0f67022);
            cbEth = IcbETH(0xBe9895146f7AF43049ca1c1AE358B0541Ea49704);
            wbEth = IwBETH(0xa2E3356610840701BDf5611a53974510Ae27E2e1);
            stEth = ILido(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
            cbEthStrategy = IStrategy(0x54945180dB7943c0ed0FEE7EdaB2Bd24620256bc);
            wbEthStrategy = IStrategy(0x7CA911E83dabf90C90dD3De5411a10F1A6112184);
            stEthStrategy = IStrategy(0x93c4b944D05dfe6df7645A86cd2206016c51564D);
            lidoWithdrawalQueue = ILidoWithdrawalQueue(0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1);

            eigenLayerStrategyManager = IEigenLayerStrategyManager(0x858646372CC42E1A627fcE94aa7A7033e7CF075A);
            eigenLayerEigenPodManager = IEigenPodManager(0x91E677b07F7AF907ec9a428aafA9fc14a0d3A338);
            eigenLayerDelegationManager = IDelegationManager(0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A);
            eigenLayerDelayedWithdrawalRouter = IDelayedWithdrawalRouter(0x7Fe7E9CC0F274d2435AD5d56D5fa73E47F6A23D8);
            eigenLayerTimelock = ITimelock(0xA6Db1A8C5a981d1536266D2a393c5F8dDb210EAF);

        } else if (forkEnum == TESTNET_FORK) {
            vm.selectFork(vm.createFork(vm.envString("TESTNET_RPC_URL")));

            // cbEth_Eth_Pool = ICurvePool(0x5FAE7E604FC3e24fd43A72867ceBaC94c65b404A);
            // wbEth_Eth_Pool = ICurvePool(0xBfAb6FA95E0091ed66058ad493189D2cB29385E6);
            stEth_Eth_Pool = ICurvePool(0xDC24316b9AE028F1497c275EB9192a3Ea0f67022);
            // cbEth = IcbETH(0xBe9895146f7AF43049ca1c1AE358B0541Ea49704);
            // wbEth = IwBETH(0xa2E3356610840701BDf5611a53974510Ae27E2e1);
            stEth = ILido(0x3F1c547b21f65e10480dE3ad8E19fAAC46C95034 );
            // cbEthStrategy = IStrategy(0x54945180dB7943c0ed0FEE7EdaB2Bd24620256bc);
            // wbEthStrategy = IStrategy(0x7CA911E83dabf90C90dD3De5411a10F1A6112184);
            stEthStrategy = IStrategy(0x7D704507b76571a51d9caE8AdDAbBFd0ba0e63d3);
            lidoWithdrawalQueue = ILidoWithdrawalQueue(0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1);

            eigenLayerStrategyManager = IEigenLayerStrategyManager(0xdfB5f6CE42aAA7830E94ECFCcAd411beF4d4D5b6);
            eigenLayerEigenPodManager = IEigenPodManager(0x30770d7E3e71112d7A6b7259542D1f680a70e315);
            eigenLayerDelegationManager = IDelegationManager(0xA44151489861Fe9e3055d95adC98FbD462B948e7);
            eigenLayerTimelock = ITimelock(0xcF19CE0561052a7A7Ff21156730285997B350A7D);
        } else {
            revert("Unimplemented fork");
        }

        setUpTests();
    }

    function initializeRealisticFork(uint8 forkEnum) public {
        initializeRealisticForkWithBlock(forkEnum, block.number);
    }

    // initialize a fork which inherits the exact contracts, addresses, and state of
    // the associated network. This allows you to realistically test new transactions against
    // testnet or mainnet.
    function initializeRealisticForkWithBlock(uint8 forkEnum, uint256 blockNo) public {

        if (forkEnum == MAINNET_FORK) {
            vm.selectFork(vm.createFork(vm.envString("MAINNET_RPC_URL"), blockNo));
            addressProviderInstance = AddressProvider(address(0x8487c5F8550E3C3e7734Fe7DCF77DB2B72E4A848));
            owner = addressProviderInstance.getContractAddress("EtherFiTimelock");
            admin = 0x2aCA71020De61bb532008049e1Bd41E451aE8AdC;

            cbEth_Eth_Pool = ICurvePool(0x5FAE7E604FC3e24fd43A72867ceBaC94c65b404A);
            wbEth_Eth_Pool = ICurvePool(0xBfAb6FA95E0091ed66058ad493189D2cB29385E6);
            stEth_Eth_Pool = ICurvePool(0xDC24316b9AE028F1497c275EB9192a3Ea0f67022);
            cbEth = IcbETH(0xBe9895146f7AF43049ca1c1AE358B0541Ea49704);
            wbEth = IwBETH(0xa2E3356610840701BDf5611a53974510Ae27E2e1);
            stEth = ILido(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
            cbEthStrategy = IStrategy(0x54945180dB7943c0ed0FEE7EdaB2Bd24620256bc);
            wbEthStrategy = IStrategy(0x7CA911E83dabf90C90dD3De5411a10F1A6112184);
            stEthStrategy = IStrategy(0x93c4b944D05dfe6df7645A86cd2206016c51564D);
            lidoWithdrawalQueue = ILidoWithdrawalQueue(0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1);

            eigenLayerStrategyManager = IEigenLayerStrategyManager(0x858646372CC42E1A627fcE94aa7A7033e7CF075A);
            eigenLayerEigenPodManager = IEigenPodManager(0x91E677b07F7AF907ec9a428aafA9fc14a0d3A338);
            eigenLayerDelegationManager = IDelegationManager(0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A);
            eigenLayerTimelock = ITimelock(0xA6Db1A8C5a981d1536266D2a393c5F8dDb210EAF);

        } else if (forkEnum == TESTNET_FORK) {
            vm.selectFork(vm.createFork(vm.envString("TESTNET_RPC_URL")));
            addressProviderInstance = AddressProvider(address(0x7c5EB0bE8af2eDB7461DfFa0Fd2856b3af63123e));
            owner = 0xD0d7F8a5a86d8271ff87ff24145Cf40CEa9F7A39;
            admin = 0xD0d7F8a5a86d8271ff87ff24145Cf40CEa9F7A39;

            // cbEth_Eth_Pool = ICurvePool(0x5FAE7E604FC3e24fd43A72867ceBaC94c65b404A);
            // wbEth_Eth_Pool = ICurvePool(0xBfAb6FA95E0091ed66058ad493189D2cB29385E6);
            stEth_Eth_Pool = ICurvePool(0xDC24316b9AE028F1497c275EB9192a3Ea0f67022);
            // cbEth = IcbETH(0xBe9895146f7AF43049ca1c1AE358B0541Ea49704);
            // wbEth = IwBETH(0xa2E3356610840701BDf5611a53974510Ae27E2e1);
            stEth = ILido(0x3F1c547b21f65e10480dE3ad8E19fAAC46C95034 );
            // cbEthStrategy = IStrategy(0x54945180dB7943c0ed0FEE7EdaB2Bd24620256bc);
            // wbEthStrategy = IStrategy(0x7CA911E83dabf90C90dD3De5411a10F1A6112184);
            stEthStrategy = IStrategy(0x7D704507b76571a51d9caE8AdDAbBFd0ba0e63d3);
            lidoWithdrawalQueue = ILidoWithdrawalQueue(0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1);

            eigenLayerStrategyManager = IEigenLayerStrategyManager(0xdfB5f6CE42aAA7830E94ECFCcAd411beF4d4D5b6);
            eigenLayerEigenPodManager = IEigenPodManager(0x30770d7E3e71112d7A6b7259542D1f680a70e315);
            eigenLayerDelegationManager = IDelegationManager(0xA44151489861Fe9e3055d95adC98FbD462B948e7);
            eigenLayerTimelock = ITimelock(0xcF19CE0561052a7A7Ff21156730285997B350A7D);

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
        liquifierInstance = Liquifier(payable(addressProviderInstance.getContractAddress("Liquifier")));
        etherFiTimelockInstance = EtherFiTimelock(payable(addressProviderInstance.getContractAddress("EtherFiTimelock")));
        etherFiAdminInstance = EtherFiAdmin(payable(addressProviderInstance.getContractAddress("EtherFiAdmin")));
        etherFiOracleInstance = EtherFiOracle(payable(addressProviderInstance.getContractAddress("EtherFiOracle")));
    }

    function setUpLiquifier(uint8 forkEnum) internal {
        vm.startPrank(owner);
            
        if (forkEnum == MAINNET_FORK) {            
            liquifierInstance.upgradeTo(address(new Liquifier()));
            liquifierInstance.updateAdmin(alice, true);
        } else if (forkEnum == TESTNET_FORK) {
            liquifierInstance.upgradeTo(address(new Liquifier()));
            liquifierInstance.updateAdmin(alice, true);
        }

        address impl = address(new BucketRateLimiter());
        bucketRateLimiter = BucketRateLimiter(address(new UUPSProxy(impl, "")));
        bucketRateLimiter.initialize();
        bucketRateLimiter.updateConsumer(address(liquifierInstance));

        bucketRateLimiter.setCapacity(40 ether);
        bucketRateLimiter.setRefillRatePerSecond(1 ether);

        vm.warp(block.timestamp + 1 days);

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

        managerInstance.initialize(
            address(treasuryInstance),
            address(auctionInstance),
            address(stakingManagerInstance),
            address(TNFTInstance),
            address(BNFTInstance),
            address(eigenLayerEigenPodManager),
            address(eigenLayerDelayedWithdrawalRouter),
            address(eigenLayerDelegationManager)
        );
        vm.stopPrank();

        // configure starting roles
        admin = alice;
        setupRoleRegistry();

        vm.startPrank(owner);
        membershipManagerInstance.updateAdmin(alice, true);
        membershipNftInstance.updateAdmin(alice, true);
        withdrawRequestNFTInstance.updateAdmin(alice, true);
        liquidityPoolInstance.updateAdmin(alice, true);
        // liquifierInstance.updateAdmin(alice, true);

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
        etherFiAdminInstance.setValidatorTaskBatchSize(20);
        etherFiAdminInstance.updateAdmin(alice, true);

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
            eigenLayerStrategyManager = IEigenLayerStrategyManager(0x858646372CC42E1A627fcE94aa7A7033e7CF075A);
            eigenLayerEigenPodManager = IEigenPodManager(0x91E677b07F7AF907ec9a428aafA9fc14a0d3A338);
            eigenLayerDelegationManager = IDelegationManager(0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A);
            eigenLayerTimelock = ITimelock(0xA6Db1A8C5a981d1536266D2a393c5F8dDb210EAF);
        } else if (block.chainid == 17000) {
            restakingBnftDeposits = false;
            eigenLayerEigenPodManager = IEigenPodManager(0x30770d7E3e71112d7A6b7259542D1f680a70e315);
        } else {
            restakingBnftDeposits = false;
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

        vm.startPrank(owner);
        nodeOperatorManagerInstance.setAuctionContractAddress(address(auctionInstance));

        auctionInstance.setStakingManagerContractAddress(address(stakingManagerInstance));

        protocolRevenueManagerInstance.setAuctionManagerAddress(address(auctionInstance));
        protocolRevenueManagerInstance.setEtherFiNodesManagerAddress(address(managerInstance));

        stakingManagerInstance.setEtherFiNodesManagerAddress(address(managerInstance));
        stakingManagerInstance.setLiquidityPoolAddress(address(liquidityPoolInstance));
        stakingManagerInstance.registerEtherFiNodeImplementationContract(address(node));
        stakingManagerInstance.registerTNFTContract(address(TNFTInstance));
        stakingManagerInstance.registerBNFTContract(address(BNFTInstance));


        depGen = new DepositDataGeneration();

        attacker = new Attacker(address(liquidityPoolInstance));
        revertAttacker = new RevertAttacker();
        gasDrainAttacker = new GasDrainAttacker();
        noAttacker = new NoAttacker();

        vm.stopPrank();

        _initializeMembershipTiers();
        _initializePeople();
        _initializeEtherFiAdmin();

        // weETH and Liquidity Pool must be on eETH to function as expected
        vm.prank(owner);
        address[] memory whitelist = new address[](2);
        whitelist[0] = address(weEthInstance);
        whitelist[1] = address(liquidityPoolInstance);
        eETHInstance.setWhitelistedSpender(whitelist, true);
    }

    function setupRoleRegistry() public {

        // TODO: I don't love the coupling here but it was too easy to make tests
        // where the roleRegistry global var diverged from the one set in the manager instance.
        // We should work toward a better system that for each contract, will deploy+initialize
        // proxy if it doesn't exist, or upgrade to the latest version otherwise
        if (address(managerInstance.roleRegistry()) == address(0x0)) {

            // deploy new versions of role registry
            roleRegistryImplementation = new RoleRegistry();
            bytes memory initializerData =  abi.encodeWithSelector(RoleRegistry.initialize.selector, admin);
            roleRegistry = RoleRegistry(address(new UUPSProxy(address(roleRegistryImplementation), initializerData)));

            vm.startPrank(owner);
            managerInstance.initializeV2dot5(address(roleRegistry));
            liquidityPoolInstance.initializeV2dot5(address(roleRegistry));
            auctionInstance.initializeV2dot5(address(roleRegistry));
            stakingManagerInstance.initializeV2dot5(address(roleRegistry));
            nodeOperatorManagerInstance.initializeV2dot5(address(roleRegistry));
            vm.stopPrank();
            vm.startPrank(etherFiOracleInstance.owner());
            etherFiOracleInstance.initializeV2dot5(address(roleRegistry));
        }

        // TODO: along with the role registry, the pauser should be uncoupled in the future
        Pauser pauserImplementation = new Pauser();
        IPausable[] memory initialPausables = new IPausable[](2);
        initialPausables[0] = IPausable(address(liquidityPoolInstance));
        initialPausables[1] = IPausable(address(etherFiOracleInstance));
        bytes memory initializerData = abi.encodeWithSelector(Pauser.initialize.selector, initialPausables, address(roleRegistry));
        pauserInstance = Pauser(address(new UUPSProxy(address(pauserImplementation), initializerData)));

        vm.startPrank(admin);
        roleRegistry.grantRole(managerInstance.NODE_ADMIN_ROLE(), admin);
        roleRegistry.grantRole(managerInstance.EIGENPOD_CALLER_ROLE(), admin);
        roleRegistry.grantRole(managerInstance.EXTERNAL_CALLER_ROLE(), admin);
        roleRegistry.grantRole(managerInstance.WHITELIST_UPDATER(), admin);
        roleRegistry.grantRole(roleRegistry.PROTOCOL_PAUSER(), admin);
        roleRegistry.grantRole(roleRegistry.PROTOCOL_UNPAUSER(), admin);
        roleRegistry.grantRole(managerInstance.NODE_ADMIN_ROLE(), owner);
        roleRegistry.grantRole(managerInstance.EIGENPOD_CALLER_ROLE(), owner);
        roleRegistry.grantRole(managerInstance.EXTERNAL_CALLER_ROLE(), owner);
        roleRegistry.grantRole(managerInstance.WHITELIST_UPDATER(), owner);
        roleRegistry.grantRole(roleRegistry.PROTOCOL_PAUSER(), owner);
        roleRegistry.grantRole(roleRegistry.PROTOCOL_UNPAUSER(), owner);
        roleRegistry.grantRole(roleRegistry.PROTOCOL_PAUSER(), address(pauserInstance));
        roleRegistry.grantRole(roleRegistry.PROTOCOL_UNPAUSER(), address(pauserInstance));
        vm.stopPrank();

        vm.startPrank(owner);
        eETHImplementation = new EETH();
        eETHInstance.upgradeTo(address(eETHImplementation));

        // weETH and Liquidity Pool must be on eETH to function as expected
        address[] memory whitelist = new address[](2);
        whitelist[0] = address(weEthInstance);
        whitelist[1] = address(liquidityPoolInstance);
        eETHInstance.setWhitelistedSpender(whitelist, true);
        vm.stopPrank();
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
    }

    function _perform_eigenlayer_upgrade() public {
        vm.warp(block.timestamp + 12 days);

        vm.prank(eigenLayerTimelock.admin());
        eigenLayerTimelock.executeTransaction(
            0x369e6F597e22EaB55fFb173C6d9cD234BD699111,
            0,
            "",
            hex"6a76120200000000000000000000000040a2accbd92bca938b02010e17a5b8929b49130d0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000014000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000007a000000000000000000000000000000000000000000000000000000000000006248d80ff0a000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000005d3008b9566ada63b64d1e1dcf1418b43fd1433b724440000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004499a88ec400000000000000000000000039053d51b77dc0d36036fc1fcc8cb819df8ef37a0000000000000000000000001784be6401339fc0fedf7e9379409f5c1bfe9dda008b9566ada63b64d1e1dcf1418b43fd1433b724440000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004499a88ec4000000000000000000000000d92145c07f8ed1d392c1b88017934e301cc1c3cd000000000000000000000000f3234220163a757edf1e11a8a085638d9b236614008b9566ada63b64d1e1dcf1418b43fd1433b724440000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004499a88ec4000000000000000000000000858646372cc42e1a627fce94aa7a7033e7cf075a00000000000000000000000070f44c13944d49a236e3cd7a94f48f5dab6c619b008b9566ada63b64d1e1dcf1418b43fd1433b724440000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004499a88ec40000000000000000000000007fe7e9cc0f274d2435ad5d56d5fa73e47f6a23d80000000000000000000000004bb6731b02314d40abbffbc4540f508874014226008b9566ada63b64d1e1dcf1418b43fd1433b724440000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004499a88ec400000000000000000000000091e677b07f7af907ec9a428aafa9fc14a0d3a338000000000000000000000000e4297e3dadbc7d99e26a2954820f514cb50c5762005a2a4f2f3c18f09179b6703e63d9edd165909073000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000243659cfe60000000000000000000000008ba40da60f0827d027f029acee62609f0527a2550039053d51b77dc0d36036fc1fcc8cb819df8ef37a00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000024635bbd10000000000000000000000000000000000000000000000000000000000000c4e00091e677b07f7af907ec9a428aafa9fc14a0d3a33800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000024c1de3aef000000000000000000000000343907185b71adf0eba9567538314396aa9854420091e677b07f7af907ec9a428aafa9fc14a0d3a33800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000024463db0380000000000000000000000000000000000000000000000000000000065f1b0570039053d51b77dc0d36036fc1fcc8cb819df8ef37a00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000024fabc1cbc00000000000000000000000000000000000000000000000000000000000000000091e677b07f7af907ec9a428aafa9fc14a0d3a33800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000024fabc1cbc000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000041000000000000000000000000a6db1a8c5a981d1536266d2a393c5f8ddb210eaf00000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000",
            1712559600
        );
    }

    function _perform_etherfi_upgrade() public {
        vm.warp(block.timestamp + 4 days);

        vm.startPrank(0xcdd57D11476c22d265722F68390b036f3DA48c21);

        // Liquifier, initialize, register dummy

        address[] memory targets = new address[](4);
        targets[0] = 0x9FFDF407cDe9a93c47611799DA23924Af3EF764F;
        targets[1] = 0x9FFDF407cDe9a93c47611799DA23924Af3EF764F;
        targets[2] = 0x9FFDF407cDe9a93c47611799DA23924Af3EF764F;
        targets[3] = 0x9FFDF407cDe9a93c47611799DA23924Af3EF764F;
        // targets[4] = 0x9FFDF407cDe9a93c47611799DA23924Af3EF764F;

        bytes[] memory payloads = new bytes[](4);
        payloads[0] = hex"3659CFE600000000000000000000000061E2CA79CA3D90FD1440976A6C9641431B3F296A";
        payloads[1] = hex"B218FF8F000000000000000000000000D789870BEA40D056A4D26055D0BEFCC8755DA146";
        payloads[2] = hex"F3820F2700000000000000000000000083998E169026136760BE6AF93E776C2F352D4B28000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001";
        payloads[3] = hex"F3820F270000000000000000000000000295E0CE709723FB25A28B8F67C54A488BA5AE46000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001";
        // LINEA // payloads[3] = hex"F3820F2700000000000000000000000061FF310AC15A517A846DA08AC9F9ABF2A0F9A2BF000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001";

        uint256[] memory values = new uint256[](4);
        values[0] = 0;
        values[1] = 0;
        values[2] = 0;
        values[3] = 0;
        // values[4] = 0;

        for (uint256 i = 0; i < targets.length; i++) {
            etherFiTimelockInstance.execute(
                targets[i],
                values[i],
                payloads[i],
                0x0,
                0x0
            );
        }
        vm.stopPrank();
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
        address[] memory users = new address[](5);
        users[0] = address(alice);
        users[1] = address(bob);
        users[2] = address(bob);
        users[3] = address(owner);
        users[4] = address(elvis);

        ILiquidityPool.SourceOfFunds[] memory approvedTags = new ILiquidityPool.SourceOfFunds[](5);
        approvedTags[0] = ILiquidityPool.SourceOfFunds.EETH;
        approvedTags[1] = ILiquidityPool.SourceOfFunds.ETHER_FAN;
        approvedTags[2] = ILiquidityPool.SourceOfFunds.EETH;
        approvedTags[3] = ILiquidityPool.SourceOfFunds.EETH;
        approvedTags[4] = ILiquidityPool.SourceOfFunds.EETH;

        bool[] memory approvals = new bool[](5);
        approvals[0] = true;
        approvals[1] = true;
        approvals[2] = true;
        approvals[3] = true;
        approvals[4] = true;

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
        etherFiAdminInstance.executeTasks(_report);
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
        _transferTo(elvis, 0.1 ether);

        vm.startPrank(elvis);
        // if we call this multiple times in a test, don't blow up
        try  nodeOperatorManagerInstance.registerNodeOperator("fake_ipfs_hash", 10) {
        } catch {}

        // create a new bid
        uint256[] memory createdBids = auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);
        vm.stopPrank();

        return _depositAndRegisterValidator(createdBids[0], restaked);
    }

    function _depositAndRegisterValidator(uint256 bidId, bool restaked) internal returns (uint256) {
        vm.deal(alice, 33 ether);
        uint256[] memory createdBids = new uint256[](1);
        createdBids[0] = bidId;

        // deposit against that bid with restaking enabled
        vm.prank(address(liquidityPoolInstance));
        stakingManagerInstance.batchDepositWithBidIds(createdBids, 1, alice, alice, alice, ILiquidityPool.SourceOfFunds.EETH, restaked, 0);

        (IStakingManager.DepositData[] memory depositDataArray,,,) = _prepareForValidatorRegistration(createdBids);
        vm.deal(address(liquidityPoolInstance), 1 ether);
        vm.prank(address(liquidityPoolInstance));
        stakingManagerInstance.batchRegisterValidators{value: 1 ether}(zeroRoot, createdBids, alice, alice, depositDataArray, alice);

        return bidId;
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
        } else if (block.chainid == 17000) {
            admin = 0xD0d7F8a5a86d8271ff87ff24145Cf40CEa9F7A39;
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

        if (withdrawRequestNFTInstance.isValid(_requestId)) {
            vm.prank(address(etherFiAdminInstance));
            liquidityPoolInstance.addEthAmountLockedForWithdrawal(amount);
        }
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
    }

    function _upgrade_liquidity_pool_contract() internal {
        address newImpl = address(new LiquidityPool());
        vm.prank(liquidityPoolInstance.owner());
        liquidityPoolInstance.upgradeTo(newImpl);
    }

    function _upgrade_liquifier() internal {
        address newImpl = address(new Liquifier());
        vm.prank(liquifierInstance.owner());
        liquifierInstance.upgradeTo(newImpl);
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
            pubKey[i] = hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c";
            bytes32 root = depGen.generateDepositRoot(
                pubKey[i],
                hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                managerInstance.getWithdrawalCredentials(_validatorIds[i]),
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
                managerInstance.getWithdrawalCredentials(_validatorIds[i]),
                31 ether
            );

            sig[i] = hex"ad899d85dcfcc2506a8749020752f81353dd87e623b2982b7bbfbbdd7964790eab4e06e226917cba1253f063d64a7e5407d8542776631b96c4cea78e0968833b36d4e0ae0b94de46718f905ca6d9b8279e1044a41875640f8cb34dc3f6e4de65";
        
        }

        return (depositDataArray, depositDataRootsForApproval, sig, pubKey);
    }

    function _execute_timelock(address target, bytes memory data, bool _schedule, bool _log_schedule, bool _execute, bool _log_execute) internal {
        vm.startPrank(0xcdd57D11476c22d265722F68390b036f3DA48c21);
        
        if (_schedule) etherFiTimelockInstance.schedule(target, 0, data, bytes32(0), bytes32(0), etherFiTimelockInstance.getMinDelay());
        if (_log_schedule) _output_schedule_txn(target, data, bytes32(0), bytes32(0), etherFiTimelockInstance.getMinDelay());

        vm.warp(block.timestamp + etherFiTimelockInstance.getMinDelay());

        if (_execute) etherFiTimelockInstance.execute(target, 0, data, bytes32(0), bytes32(0));
        if (_log_execute) _output_execute_timelock_txn(target, data, bytes32(0), bytes32(0));

        vm.warp(block.timestamp + 1);
        vm.stopPrank();
    }

    function _20240428_updateDepositCap() internal {
        {
            _execute_timelock(
                0x9FFDF407cDe9a93c47611799DA23924Af3EF764F, 
                hex"3BEB551700000000000000000000000083998E169026136760BE6AF93E776C2F352D4B280000000000000000000000000000000000000000000000000000000000000FA00000000000000000000000000000000000000000000000000000000000004E20", 
                false,
                false,
                true,
                false
            );
        }
        {
            _execute_timelock(
                0x9FFDF407cDe9a93c47611799DA23924Af3EF764F, 
                hex"3BEB5517000000000000000000000000DC400F3DA3EA5DF0B7B6C127AE2E54CE55644CF30000000000000000000000000000000000000000000000000000000000000FA00000000000000000000000000000000000000000000000000000000000004E20", 
                false,
                false,
                true,
                false
            );
        }
    }


    function _output_schedule_txn(address target, bytes memory data, bytes32 predecessor, bytes32 salt, uint256 delay) internal {
        bytes memory txn_data = abi.encodeWithSelector(TimelockController.schedule.selector, target, 0, data, predecessor, salt, delay);
        emit Transaction(address(etherFiTimelockInstance), 0, txn_data);

        string memory obj_k = "timelock_txn";
        stdJson.serialize(obj_k, "to", address(etherFiTimelockInstance));
        stdJson.serialize(obj_k, "value", uint256(0));
        string memory output = stdJson.serialize(obj_k, "data", txn_data);

        string memory prefix = string.concat(vm.toString(block.number), string.concat(".", vm.toString(block.timestamp)));
        string memory output_path = string.concat(string("./release/logs/txns/"), string.concat(prefix, string(".json"))); // releast/logs/$(block_number)_{$(block_timestamp)}json
        stdJson.write(output, output_path);
    }

    function _output_execute_timelock_txn(address target, bytes memory data, bytes32 predecessor, bytes32 salt) internal {
        bytes memory txn_data = abi.encodeWithSelector(TimelockController.execute.selector, target, 0, data, predecessor, salt);
        emit Transaction(address(etherFiTimelockInstance), 0, txn_data);

        string memory obj_k = "timelock_txn";
        stdJson.serialize(obj_k, "to", address(etherFiTimelockInstance));
        stdJson.serialize(obj_k, "value", uint256(0));
        string memory output = stdJson.serialize(obj_k, "data", txn_data);

        string memory prefix = string.concat(vm.toString(block.number), string.concat(".", vm.toString(block.timestamp)));
        string memory output_path = string.concat(string("./release/logs/txns/"), string.concat(prefix, string(".json"))); // releast/logs/$(block_number)_{$(block_timestamp)}json
        stdJson.write(output, output_path);
    }
}
