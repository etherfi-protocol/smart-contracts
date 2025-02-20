
import {TestSetup} from "./TestSetup.sol";
import "forge-std/StdCheats.sol";
import "forge-std/console.sol";


contract RewardsManagerTest is TestSetup {

    function setUp() public {
        console.log("rewardsManagerInstance");
        setUpTests();
        console.log("rewardsManagerInstance");
        vm.deal(address(rewardsManagerInstance), 1000 ether);
        deal(address(eETHInstance), address(rewardsManagerInstance), 1000 ether);
        console.log("rewardsManagerInstance");
    }

    // 1. processRewards
    function test_basicProcessRewards() public {
        address token = address(eETHInstance);
        //address[] memory earners = new address[](3);
        //earners[0] = address(0);
        ///earners[1] = address(1);
        //earners[2] = address(2);
        //uint256[] memory rewards = new uint256[](3);
        //rewards[0] = rewards[1] = rewards[2] = 100 ether;
        //vm.startPrank(superAdmin);
        //rewardsManagerInstance.processRewards(token, earners, rewards);
        //vm.stopPrank();
        //assertEq(rewardsManagerInstance.totalPendingRewards(token, earners[0]), rewards[0]);
        //assertEq(rewardsManagerInstance.totalPendingRewards(token, earners[1]), rewards[1]);
        //assertEq(rewardsManagerInstance.totalPendingRewards(token, earners[2]), rewards[2]);
    }

    // 2. claimRewards
    function test_basicClaimRewards() public {

    }

    // 3. updatePendingRewards
    function test_basicUpdatePendingRewards() public {

    }

    // 4. updateRewardsRecipient
    function test_basicUpdateRewardsRecipient() public {
        
    }
}