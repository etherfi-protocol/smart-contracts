// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../src/StakingManager.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract DeployPatchV3 is Script {
    using Strings for string;

    struct UpgradeAddresses {
        address stakingManager;
    }

    UpgradeAddresses upgradeAddressesStruct;


    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address stakingManagerProxyAddress = vm.envAddress("STAKING_MANAGER_PROXY_ADDRESS");

        //mainnet
        require(stakingManagerProxyAddress == 0x44F5759C47e052E5Cf6495ce236aB0601F1f98fF, "stakingManagerProxyAddress incorrect see .env");

        vm.startBroadcast(deployerPrivateKey);

        StakingManager stakingManagerInstance = StakingManager(stakingManagerProxyAddress);
        StakingManager stakingManagerV3Implementation = new StakingManager();

        stakingManagerInstance.upgradeTo(address(stakingManagerV3Implementation));
        vm.stopBroadcast();

        upgradeAddressesStruct = UpgradeAddresses({
            stakingManager: address(stakingManagerV3Implementation)
        });
    }

    function _stringToUint(
        string memory numString
    ) internal pure returns (uint256) {
        uint256 val = 0;
        bytes memory stringBytes = bytes(numString);
        for (uint256 i = 0; i < stringBytes.length; i++) {
            uint256 exp = stringBytes.length - i;
            bytes1 ival = stringBytes[i];
            uint8 uval = uint8(ival);
            uint256 jval = uval - uint256(0x30);

            val += (uint256(jval) * (10 ** (exp - 1)));
        }
        return val;
    }

    function writeUpgradeToFile() internal {
        // Read Current version
        string memory versionString = vm.readLine("release/logs/Upgrades/version.txt");

        // Cast string to uint256
        uint256 version = _stringToUint(versionString);

        version++;

        // Overwrites the version.txt file with incremented version
        vm.writeFile(
            "release/logs/Upgrades/version.txt",
            string(abi.encodePacked(Strings.toString(version)))
        );

        // Writes the data to .release file
        vm.writeFile(
            string(
                abi.encodePacked(
                    "release/logs/Upgrades/",
                    Strings.toString(version),
                    ".release"
                )
            ),
            string(
                abi.encodePacked(
                    Strings.toString(version),
                    "\nNew Staking Manager Implementation: ",
                    Strings.toHexString(upgradeAddressesStruct.stakingManager)
                )
            )
        );
    }
}
