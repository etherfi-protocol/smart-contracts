// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "forge-std/StdJson.sol";

import "../script/Create2Factory.sol";

import "../src/EtherFiNode.sol";
import "../src/RoleRegistry.sol";
import "../src/StakingManager.sol";
import "../src/EtherFiNodesManager.sol";
import "../src/LiquidityPool.sol";
import "../src/WeETH.sol";
import "../src/EETH.sol";
import "../src/EtherFiAdmin.sol";
import "../src/EtherFiOracle.sol";

interface ICreate2Factory {
    function deploy(bytes memory code, bytes32 salt) external payable returns (address);
    function verify(address addr, bytes32 salt, bytes memory code) external view returns (bool);
    function computeAddress(bytes32 salt, bytes memory code) external view returns (address);
}

contract DeployScript is Script {
    using stdJson for string;

    ICreate2Factory constant factory = ICreate2Factory(0x356d1B83970CeF2018F2c9337cDdb67dff5AEF99);

    address constant roleRegistry = 0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9;
    address constant liquidityPool = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    address constant stakingManager = 0x25e821b7197B146F7713C3b89B6A4D83516B912d;
    address constant etherFiNodesManager = 0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F;
    address constant auctionManager = 0x00C452aFFee3a17d9Cecc1Bcd2B8d5C7635C4CB9;
    address constant etherFiNodeBeacon = 0x3c55986Cfee455E2533F4D29006634EcF9B7c03F;
    address constant stakingDepositContract = 0x00000000219ab540356cBB839Cbe05303d7705Fa;

    // eigenlayer
    address constant eigenPodManager = 0x91E677b07F7AF907ec9a428aafA9fc14a0d3A338;
    address constant delegationManager = 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A;

    // TODO: update with final commit
    bytes32 commitHashSalt = bytes32(bytes20(hex"7972bd777a339ca98eff1677484aacc816b24d87"));

    function run() external {
        // -------------------------------------------------------------------------
        // INPUT
        // -------------------------------------------------------------------------
        // 1. contract name
        // 2. constructor args
        // 3. bytecode
        // 4. commithash_salt
        // 5. (if verification is desired) deployed address
        // -------------------------------------------------------------------------

        // EtherFiNode
        vm.startBroadcast();
        {
            string memory contractName = "EtherFiNode";
            bytes memory constructorArgs = abi.encode(
                address(liquidityPool),
                address(etherFiNodesManager),
                address(eigenPodManager),
                address(delegationManager),
                address(roleRegistry)
            );
            bytes memory bytecode = abi.encodePacked(
                type(EtherFiNode).creationCode,
                constructorArgs
            );
            address deployedAddress = deploy(contractName, constructorArgs, bytecode, commitHashSalt, true);
            verify(deployedAddress, bytecode, commitHashSalt);
        }

        // StakingManager
        {
            string memory contractName = "StakingManager";
            bytes memory constructorArgs = abi.encode(
                address(liquidityPool),
                address(etherFiNodesManager),
                address(stakingDepositContract),
                address(auctionManager),
                address(etherFiNodeBeacon),
                address(roleRegistry)
            );
            bytes memory bytecode = abi.encodePacked(
                type(StakingManager).creationCode,
                constructorArgs
            );
            address deployedAddress = deploy(contractName, constructorArgs, bytecode, commitHashSalt, true);
            verify(deployedAddress, bytecode, commitHashSalt);
        }

        // EtherFiNodesManager
        {
            string memory contractName = "EtherFiNodesManager";
            bytes memory constructorArgs = abi.encode(
                address(stakingManager),
                address(roleRegistry)
            );
            bytes memory bytecode = abi.encodePacked(
                type(EtherFiNodesManager).creationCode,
                constructorArgs
            );
            address deployedAddress = deploy(contractName, constructorArgs, bytecode, commitHashSalt, true);
            verify(deployedAddress, bytecode, commitHashSalt);
        }

        // LiquidityPool
        {
            string memory contractName = "LiquidityPool";
            bytes memory constructorArgs;
            bytes memory bytecode = abi.encodePacked(
                type(LiquidityPool).creationCode,
                constructorArgs
            );
            address deployedAddress = deploy(contractName, constructorArgs, bytecode, commitHashSalt, true);
            verify(deployedAddress, bytecode, commitHashSalt);
        }

        // WeETH
        {
            string memory contractName = "WeETH";
            bytes memory constructorArgs = abi.encode(
                address(roleRegistry)
            );
            bytes memory bytecode = abi.encodePacked(
                type(WeETH).creationCode,
                constructorArgs
            );
            address deployedAddress = deploy(contractName, constructorArgs, bytecode, commitHashSalt, true);
            verify(deployedAddress, bytecode, commitHashSalt);
        }

        // eETH
        {
            string memory contractName = "EETH";
            bytes memory constructorArgs = abi.encode(
                address(roleRegistry)
            );
            bytes memory bytecode = abi.encodePacked(
                type(EETH).creationCode,
                constructorArgs
            );
            address deployedAddress = deploy(contractName, constructorArgs, bytecode, commitHashSalt, true);
            verify(deployedAddress, bytecode, commitHashSalt);
        }

        // EtherFiOracle
        {
            string memory contractName = "EtherFiOracle";
            bytes memory constructorArgs;
            bytes memory bytecode = abi.encodePacked(
                type(EtherFiOracle).creationCode,
                constructorArgs
            );
            address deployedAddress = deploy(contractName, constructorArgs, bytecode, commitHashSalt, true);
            verify(deployedAddress, bytecode, commitHashSalt);
        }

        // EtherFiAdmin
        {
            string memory contractName = "EtherFiAdmin";
            bytes memory constructorArgs;
            bytes memory bytecode = abi.encodePacked(
                type(EtherFiAdmin).creationCode,
                constructorArgs
            );
            address deployedAddress = deploy(contractName, constructorArgs, bytecode, commitHashSalt, true);
            verify(deployedAddress, bytecode, commitHashSalt);
        }

        vm.stopBroadcast();
    }

    function deploy(string memory contractName, bytes memory constructorArgs, bytes memory bytecode, bytes32 salt, bool logging) internal returns (address) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address predictedAddress = factory.computeAddress(salt, bytecode);
        address deployedAddress = factory.deploy(bytecode, salt);
        require(deployedAddress == predictedAddress, "Deployment address mismatch");

        if (logging) {

            // 5. Create JSON deployment log (exact same format)
            string memory deployLog = string.concat(
                "{\n",
                '  "contractName": "', contractName, '",\n',
                '  "deploymentParameters": {\n',
                '    "factory": "', vm.toString(address(factory)), '",\n',
                '    "salt": "', vm.toString(salt), '",\n',
                formatConstructorArgs(constructorArgs, contractName), '\n',
                '  },\n',
                '  "deployedAddress": "', vm.toString(deployedAddress), '"\n',
                "}"
            );

            // 6. Save deployment log
            string memory root = vm.projectRoot();
            string memory logFileDir = string.concat(root, "/deployment/", contractName);
            vm.createDir(logFileDir, true);

            string memory logFileName = string.concat(
                logFileDir,
                "/",
                getTimestampString(),
                ".json"
            );
            vm.writeFile(logFileName, deployLog);

            // 7. Console output
            console.log("\n=== Deployment Successful ===");
            console.log("Contract:", contractName);
            console.log("Deployed to:", deployedAddress);
            console.log("Deployment log saved to:", logFileName);
            console.log(deployLog);
        }
    }

    function verify(address addr, bytes memory bytecode, bytes32 salt) internal view returns (bool) {
        return factory.verify(addr, salt, bytecode);
    }

    //-------------------------------------------------------------------------
    // Parse and format constructor arguments into JSON
    //-------------------------------------------------------------------------

    function formatConstructorArgs(bytes memory constructorArgs, string memory contractName)
        internal
        view
        returns (string memory)
    {
        // 1. Load artifact JSON
        string memory artifactJson = readArtifact(contractName);

        // 2. Parse ABI inputs for the constructor
        bytes memory inputsArray = vm.parseJson(artifactJson, "$.abi[?(@.type == 'constructor')].inputs");
        if (inputsArray.length == 0) {
            // No constructor, return empty object
            return '    "constructorArgs": {}';
        }

        // 3. Decode to get the number of inputs
        bytes[] memory decodedInputs = abi.decode(inputsArray, (bytes[]));
        uint256 inputCount = decodedInputs.length;

        // 4. Collect param names and types in arrays
        (string[] memory names, string[] memory typesArr) = getConstructorMetadata(artifactJson, inputCount);

        // 5. Build the final JSON
        return decodeParamsJson(constructorArgs, names, typesArr);
    }

    /**
     * @dev Helper to read the contract's compiled artifact
     */
    function readArtifact(string memory contractName) internal view returns (string memory) {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/out/", contractName, ".sol/", contractName, ".json");
        return vm.readFile(path);
    }

    /**
     * @dev Extracts all `name` and `type` fields from the constructor inputs
     */
    function getConstructorMetadata(string memory artifactJson, uint256 inputCount)
        internal
        pure
        returns (string[] memory, string[] memory)
    {
        string[] memory names = new string[](inputCount);
        string[] memory typesArr = new string[](inputCount);

        for (uint256 i = 0; i < inputCount; i++) {
            // We'll build the JSON path e.g. "$.abi[?(@.type == 'constructor')].inputs[0].name"
            string memory baseQuery = string.concat("$.abi[?(@.type == 'constructor')].inputs[", vm.toString(i), "]");

            names[i] = trim(string(vm.parseJson(artifactJson, string.concat(baseQuery, ".name"))));
            typesArr[i] = trim(string(vm.parseJson(artifactJson, string.concat(baseQuery, ".type"))));
        }
        return (names, typesArr);
    }

    /**
     * @dev Decodes each provided constructorArg and builds the JSON lines
     */
    function decodeParamsJson(
        bytes memory constructorArgs,
        string[] memory names,
        string[] memory typesArr
    )
        internal
        pure
        returns (string memory)
    {
        uint256 offset;
        string memory json = '    "constructorArgs": {\n';

        for (uint256 i = 0; i < names.length; i++) {
            (string memory val, uint256 newOffset) = decodeParam(constructorArgs, offset, typesArr[i]);
            offset = newOffset;

            json = string.concat(
                json,
                '      "', names[i], '": "', val, '"',
                (i < names.length - 1) ? ",\n" : "\n"
            );
        }
        return string.concat(json, "    }");
    }

    //-------------------------------------------------------------------------
    // Decoder logic (same as before)
    //-------------------------------------------------------------------------

    function decodeParam(bytes memory data, uint256 offset, string memory t)
        internal
        pure
        returns (string memory, uint256)
    {
        if (!isDynamicType(t)) {
            // For static params, read 32 bytes directly
            bytes memory chunk = slice(data, offset, 32);
            return (formatStaticParam(t, bytes32(chunk)), offset + 32);
        } else {
            // Dynamic param: first 32 bytes is a pointer to the data location
            uint256 dataLoc = uint256(bytes32(slice(data, offset, 32)));
            offset += 32;

            // Next 32 bytes at that location is the length
            uint256 len = uint256(bytes32(slice(data, dataLoc, 32)));
            bytes memory dynData = slice(data, dataLoc + 32, len);

            return (formatDynamicParam(t, dynData), offset);
        }
    }

    function formatStaticParam(string memory t, bytes32 chunk) internal pure returns (string memory) {
        if (compare(t, "address")) {
            return vm.toString(address(uint160(uint256(chunk))));
        } else if (compare(t, "uint256")) {
            return vm.toString(uint256(chunk));
        } else if (compare(t, "bool")) {
            return uint256(chunk) != 0 ? "true" : "false";
        } else if (compare(t, "bytes32")) {
            return vm.toString(chunk);
        }
        revert("Unsupported static type");
    }

    function formatDynamicParam(string memory t, bytes memory dynData) internal pure returns (string memory) {
        if (compare(t, "string")) {
            return string(dynData);
        } else if (compare(t, "bytes")) {
            return vm.toString(dynData);
        } else if (endsWithArray(t)) {
            // e.g. "uint256[]" or "address[]"
            if (startsWith(t, "uint256")) {
                uint256[] memory arr = abi.decode(dynData, (uint256[]));
                return formatUint256Array(arr);
            } else if (startsWith(t, "address")) {
                address[] memory arr = abi.decode(dynData, (address[]));
                return formatAddressArray(arr);
            }
        }
        revert("Unsupported dynamic type");
    }

    //-------------------------------------------------------------------------
    // Array format helpers
    //-------------------------------------------------------------------------

    function formatUint256Array(uint256[] memory arr) internal pure returns (string memory) {
        string memory out = "[";
        for (uint256 i = 0; i < arr.length; i++) {
            out = string.concat(out, (i == 0 ? "" : ","), vm.toString(arr[i]));
        }
        return string.concat(out, "]");
    }

    function formatAddressArray(address[] memory arr) internal pure returns (string memory) {
        string memory out = "[";
        for (uint256 i = 0; i < arr.length; i++) {
            out = string.concat(out, (i == 0 ? "" : ","), vm.toString(arr[i]));
        }
        return string.concat(out, "]");
    }

    //-------------------------------------------------------------------------
    // Type checks
    //-------------------------------------------------------------------------

    function isDynamicType(string memory t) internal pure returns (bool) {
        return startsWith(t, "string") || startsWith(t, "bytes") || endsWithArray(t);
    }

    function endsWithArray(string memory t) internal pure returns (bool) {
        bytes memory b = bytes(t);
        return b.length >= 2 && (b[b.length - 2] == '[' && b[b.length - 1] == ']');
    }

    //-------------------------------------------------------------------------
    // Low-level bytes slicing
    //-------------------------------------------------------------------------

    function slice(bytes memory data, uint256 start, uint256 length) internal pure returns (bytes memory) {
        require(data.length >= start + length, "slice_outOfBounds");
        bytes memory out = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            out[i] = data[start + i];
        }
        return out;
    }

    //-------------------------------------------------------------------------
    // String helpers
    //-------------------------------------------------------------------------

    function trim(string memory str) internal pure returns (string memory) {
        bytes memory b = bytes(str);
        uint256 start;
        uint256 end = b.length;
        while (start < b.length && uint8(b[start]) <= 0x20) start++;
        while (end > start && uint8(b[end - 1]) <= 0x20) end--;
        bytes memory out = new bytes(end - start);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = b[start + i];
        }
        return string(out);
    }

    function compare(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function startsWith(string memory str, string memory prefix) internal pure returns (bool) {
        bytes memory s = bytes(str);
        bytes memory p = bytes(prefix);
        if (s.length < p.length) return false;
        for (uint256 i = 0; i < p.length; i++) {
            if (s[i] != p[i]) return false;
        }
        return true;
    }

    //-------------------------------------------------------------------------
    // Timestamp-based filename
    //-------------------------------------------------------------------------

    // The timestamp is in UTC (Coordinated Universal Time). This is because block.timestamp returns a Unix timestamp, which is always in UTC.
    function getTimestampString() internal view returns (string memory) {
        uint256 ts = block.timestamp;
        string memory year = vm.toString((ts / 31536000) + 1970);
        string memory month = pad(vm.toString(((ts % 31536000) / 2592000) + 1));
        string memory day = pad(vm.toString(((ts % 2592000) / 86400) + 1));
        string memory hour = pad(vm.toString((ts % 86400) / 3600));
        string memory minute = pad(vm.toString((ts % 3600) / 60));
        string memory second = pad(vm.toString(ts % 60));
        return string.concat(year,"-",month,"-",day,"-",hour,"-",minute,"-",second);
    }

    function pad(string memory n) internal pure returns (string memory) {
        return bytes(n).length == 1 ? string.concat("0", n) : n;
    }
}
