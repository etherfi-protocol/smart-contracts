
import {TestSetup} from "./TestSetup.sol";
import "forge-std/StdCheats.sol";
import "forge-std/console2.sol";


contract RewardsManagerTest is TestSetup {

    address earner1 = address(1);
    address earner2 = address(2);
    address earner3 = address(3);
    address rewardsManagerAdmin = alice;

    function setUp() public {
        setUpTests();
        vm.deal(address(rewardsManagerInstance), 2000 ether);
        vm.prank(address(rewardsManagerInstance));
        liquidityPoolInstance.deposit{value: 1000 ether}();
    }

    // 1. processRewards
    function test_basicProcessRewards() public {
        address token = address(eETHInstance);
        address[] memory earners = new address[](3);
        earners[0] = earner1;
        earners[1] = earner2;
        earners[2] = earner3;
        uint256[] memory rewards = new uint256[](3);
        rewards[0] = 100 ether;
        rewards[1] = 100 ether;
        rewards[2] = 300 ether;
        vm.roll(block.number + rewardsManagerInstance.CLAIM_DELAY() + 1);
        vm.prank(rewardsManagerAdmin);
        rewardsManagerInstance.processRewards(token, earners, rewards, block.number - 100);
        // check that pending rewards are set correctly
        assertEq(rewardsManagerInstance.totalPendingRewards(token, earners[0]), rewards[0]);
        assertEq(rewardsManagerInstance.totalPendingRewards(token, earners[1]), rewards[1]);
        assertEq(rewardsManagerInstance.totalPendingRewards(token, earners[2]), rewards[2]);
        // check that claimable rewards are 0
        assertEq(rewardsManagerInstance.totalClaimableRewards(token, earners[0]), 0);
        assertEq(rewardsManagerInstance.totalClaimableRewards(token, earners[1]), 0);
        assertEq(rewardsManagerInstance.totalClaimableRewards(token, earners[2]), 0);
        vm.roll(block.number + rewardsManagerInstance.CLAIM_DELAY() + 1);
        vm.prank(rewardsManagerAdmin);
        rewardsManagerInstance.processRewards(token, earners, rewards, block.number - 100);
        // check that pending rewards are set correctly
        assertEq(rewardsManagerInstance.totalPendingRewards(token, earners[0]), 100 ether);
        assertEq(rewardsManagerInstance.totalPendingRewards(token, earners[1]), 100 ether);
        assertEq(rewardsManagerInstance.totalPendingRewards(token, earners[2]), 300 ether);
        // check that claimable rewards now claimable
        assertEq(rewardsManagerInstance.totalClaimableRewards(token, earners[0]), 100 ether);
        assertEq(rewardsManagerInstance.totalClaimableRewards(token, earners[1]), 100 ether);
        assertEq(rewardsManagerInstance.totalClaimableRewards(token, earners[2]), 300 ether);
    }

    // 2. claimRewards
    function test_basicClaimRewards() public {
        test_basicProcessRewards(); 
        vm.prank(earner1);
        rewardsManagerInstance.claimRewards(earner1, address(eETHInstance));
        assertEq(eETHInstance.balanceOf(earner1), 100 ether);
        assertEq(rewardsManagerInstance.totalClaimableRewards(address(eETHInstance), earner1), 0);
    }

     // 3. updatePendingRewards
     function test_basicUpdatePendingRewards() public {
        address token = address(eETHInstance);
        address[] memory earners = new address[](3);
        earners[0] = earner1;
        earners[1] = earner2;
        earners[2] = earner3;
        uint256[] memory rewards = new uint256[](3);
        rewards[0] = 100 ether;
        rewards[1] = 100 ether;
        rewards[2] = 200 ether;
        vm.roll(block.number + rewardsManagerInstance.CLAIM_DELAY() + 1);
        vm.prank(rewardsManagerAdmin);
        rewardsManagerInstance.processRewards(token, earners, rewards, block.number - 100);
        assertEq(rewardsManagerInstance.totalPendingRewards(token, earners[0]), rewards[0]);
        assertEq(rewardsManagerInstance.totalPendingRewards(token, earners[1]), rewards[1]);
        assertEq(rewardsManagerInstance.totalPendingRewards(token, earners[2]), rewards[2]);
        vm.roll(block.number + 10);
        rewards[0] = 900 ether;
        rewards[1] = 10 ether;
        rewards[2] = 10 ether;
        vm.prank(rewardsManagerAdmin);
        rewardsManagerInstance.updatePendingRewards(token, earners, rewards, block.number);
        assertEq(rewardsManagerInstance.totalPendingRewards(token, earners[0]), 900 ether);
        assertEq(rewardsManagerInstance.totalPendingRewards(token, earners[1]), 10 ether);
        assertEq(rewardsManagerInstance.totalPendingRewards(token, earners[2]), 10 ether);
        assertEq(rewardsManagerInstance.totalClaimableRewards(token, earners[0]), 0 ether);
        assertEq(rewardsManagerInstance.totalClaimableRewards(token, earners[1]), 0 ether);
        assertEq(rewardsManagerInstance.totalClaimableRewards(token, earners[2]), 0 ether);

     }

    // 4. updateRewardsRecipient
    function test_basicUpdateRewardsRecipient() public {
        test_basicProcessRewards();
        vm.prank(address(1));
        rewardsManagerInstance.updateRewardsRecipient(earner1, earner2);
        assertEq(rewardsManagerInstance.earnerToRecipient(earner1), earner2);
        vm.prank(earner2);
        rewardsManagerInstance.claimRewards(earner2, address(eETHInstance));
        assertEq(eETHInstance.balanceOf(earner2), 100 ether);
        assertEq(eETHInstance.balanceOf(earner1), 0);
        assertEq(rewardsManagerInstance.totalClaimableRewards(address(eETHInstance), earner2), 0);

    }

    /// @dev Tests that processRewards reverts when arrays have different lengths
    function test_processRewardsArrayLengthMismatch() public {
        address[] memory earners = new address[](2);
        uint256[] memory rewards = new uint256[](3);
        vm.prank(rewardsManagerAdmin);
        vm.expectRevert("Array lengths must match");
        rewardsManagerInstance.processRewards(address(eETHInstance), earners, rewards, block.number);
    }

    /// @dev Tests that non-admin cannot process rewards
    function test_processRewardsNonAdmin() public {
        address[] memory earners = new address[](1);
        uint256[] memory rewards = new uint256[](1);
        vm.prank(earner1);
        vm.expectRevert("Caller must be admin");
        rewardsManagerInstance.processRewards(address(eETHInstance), earners, rewards, block.number);
    }

        /// @dev Tests that rewards cannot be processed before claim delay
    function test_processRewardsClaimDelay() public {
        address[] memory earners = new address[](1);
        uint256[] memory rewards = new uint256[](1);
        vm.prank(rewardsManagerAdmin);
        vm.expectRevert("Claim delay not met");
        rewardsManagerInstance.processRewards(address(eETHInstance), earners, rewards, block.number);
    }

        /// @dev Tests that rewards cannot be processed with invalid block numbers
    function test_processRewardsInvalidBlockNumber() public {
        address[] memory earners = new address[](1);
        uint256[] memory rewards = new uint256[](1);
        
        // Process rewards first time
        vm.roll(block.number + rewardsManagerInstance.CLAIM_DELAY() + 1);
        vm.prank(rewardsManagerAdmin);
        rewardsManagerInstance.processRewards(address(eETHInstance), earners, rewards, block.number - 100);
        uint256 rewardsCalculatedToBlock = block.number - 100;
        
        // Try to process with old block number
        vm.roll(block.number + rewardsManagerInstance.CLAIM_DELAY() + 1);
        vm.prank(rewardsManagerAdmin);
        vm.expectRevert("Invalid block number");
        rewardsManagerInstance.processRewards(address(eETHInstance), earners, rewards, rewardsCalculatedToBlock);
    }

    function test_claimAllRewards() public {
        test_basicClaimRewards();
        rewardsManagerInstance.claimRewards(earner2, address(eETHInstance));
        rewardsManagerInstance.claimRewards(earner3, address(eETHInstance));
        assertEq(rewardsManagerInstance.totalClaimableRewards(address(eETHInstance), earner2), 0);
        assertEq(rewardsManagerInstance.totalClaimableRewards(address(eETHInstance), earner3), 0);
        address[] memory earners = new address[](3);
        uint256[] memory rewards = new uint256[](3);
        rewards[0] = rewards[1] = rewards[2] = 0 ether;
        earners[0] = earner1;
        earners[1] = earner2;
        earners[2] = earner3; 
        vm.roll(rewardsManagerInstance.rewardsCalculatedToBlock(address(eETHInstance))+ rewardsManagerInstance.CLAIM_DELAY() * 2);
        vm.startPrank(rewardsManagerAdmin);
        rewardsManagerInstance.processRewards(address(eETHInstance), earners, rewards, block.number - 5);
        rewardsManagerInstance.claimRewards(earner1, address(eETHInstance));
        rewardsManagerInstance.claimRewards(earner2, address(eETHInstance));
        rewardsManagerInstance.claimRewards(earner3, address(eETHInstance));
        assertEq(eETHInstance.balanceOf(earner1), 200 ether);
        assertEq(eETHInstance.balanceOf(earner2), 200 ether);
        assertEq(eETHInstance.balanceOf(earner3), 600 ether);

    }
}