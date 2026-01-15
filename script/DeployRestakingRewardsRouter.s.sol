// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/RestakingRewardsRouter.sol";
import "../src/UUPSProxy.sol";

interface ICreate2Factory {
    function deploy(
        bytes memory code,
        bytes32 salt
    ) external payable returns (address);
    function verify(
        address addr,
        bytes32 salt,
        bytes memory code
    ) external view returns (bool);
    function computeAddress(
        bytes32 salt,
        bytes memory code
    ) external view returns (address);
}

contract DeployRestakingRewardsRouter is Script {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    ICreate2Factory constant factory =
        ICreate2Factory(0x356d1B83970CeF2018F2c9337cDdb67dff5AEF99);

    address routerImpl;
    address routerProxy;
    bytes32 commitHashSalt =
        bytes32(bytes20(hex"7212da1d56a6d252e00fbce224fa93588631e719"));

    // === MAINNET CONTRACT ADDRESSES ===
    address constant ROLE_REGISTRY = 0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9;
    address constant LIQUIDITY_POOL =
        0x308861A430be4cce5502d0A12724771Fc6DaF216;
    address constant REWARD_TOKEN_ADDRESS =
        0xec53bF9167f50cDEB3Ae105f56099aaaB9061F83;

    function run() public {
        console2.log("================================================");
        console2.log(
            "======== Running Deploy Restaking Rewards Router ========"
        );
        console2.log("================================================");
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy RestakingRewardsRouter implementation
        {
            string memory contractName = "RestakingRewardsRouter";
            bytes memory constructorArgs = abi.encode(
                ROLE_REGISTRY,
                REWARD_TOKEN_ADDRESS,
                LIQUIDITY_POOL
            );
            bytes memory bytecode = abi.encodePacked(
                type(RestakingRewardsRouter).creationCode,
                constructorArgs
            );
            routerImpl = deployCreate2(
                contractName,
                constructorArgs,
                bytecode,
                commitHashSalt,
                true
            );
        }

        // Deploy UUPSProxy
        {
            string memory contractName = "UUPSProxy";

            // Prepare initialization data (initialize takes no parameters)
            bytes memory initializerData = abi.encodeWithSelector(
                RestakingRewardsRouter.initialize.selector
            );

            bytes memory constructorArgs = abi.encode(
                routerImpl,
                initializerData
            );
            bytes memory bytecode = abi.encodePacked(
                type(UUPSProxy).creationCode,
                constructorArgs
            );
            routerProxy = deployCreate2(
                contractName,
                constructorArgs,
                bytecode,
                commitHashSalt,
                true
            );
        }

        vm.stopBroadcast();
    }

    // === CREATE2 DEPLOYMENT HELPER ===

    function deployCreate2(
        string memory contractName,
        bytes memory constructorArgs,
        bytes memory bytecode,
        bytes32 salt,
        bool logging
    ) internal returns (address) {
        address predictedAddress = factory.computeAddress(salt, bytecode);
        address deployedAddress = factory.deploy(bytecode, salt);
        require(
            deployedAddress == predictedAddress,
            "Deployment address mismatch"
        );

        if (logging) {
            // Create JSON deployment log
            string memory deployLog = string.concat(
                "{\n",
                '  "contractName": "',
                contractName,
                '",\n',
                '  "deploymentParameters": {\n',
                '    "factory": "',
                vm.toString(address(factory)),
                '",\n',
                '    "salt": "',
                vm.toString(salt),
                '",\n',
                formatConstructorArgs(constructorArgs, contractName),
                "\n",
                "  },\n",
                '  "deployedAddress": "',
                vm.toString(deployedAddress),
                '"\n',
                "}"
            );

            // Save deployment log
            string memory root = vm.projectRoot();
            string memory logFileDir = string.concat(
                root,
                "/deployment/",
                contractName
            );
            vm.createDir(logFileDir, true);

            string memory logFileName = string.concat(
                logFileDir,
                "/",
                getTimestampString(),
                ".json"
            );
            vm.writeFile(logFileName, deployLog);

            // Console output
            console2.log("=== Deployment Successful ===");
            console2.log("Contract:", contractName);
            console2.log("Deployed to:", deployedAddress);
            console2.log("Deployment log saved to:", logFileName);
        }

        return deployedAddress;
    }

    function verify(
        address addr,
        bytes memory bytecode,
        bytes32 salt
    ) internal view returns (bool) {
        return factory.verify(addr, salt, bytecode);
    }

    //-------------------------------------------------------------------------
    // Constructor args formatting
    //-------------------------------------------------------------------------

    function formatConstructorArgs(
        bytes memory constructorArgs,
        string memory contractName
    ) internal view returns (string memory) {
        // Load artifact JSON
        string memory artifactJson = readArtifact(contractName);

        // Parse ABI inputs for the constructor
        bytes memory inputsArray = vm.parseJson(
            artifactJson,
            "$.abi[?(@.type == 'constructor')].inputs"
        );
        if (inputsArray.length == 0) {
            // No constructor, return empty object
            return '    "constructorArgs": {}';
        }

        // Decode to get the number of inputs
        bytes[] memory decodedInputs = abi.decode(inputsArray, (bytes[]));
        uint256 inputCount = decodedInputs.length;

        // Collect param names and types in arrays
        (
            string[] memory names,
            string[] memory typesArr
        ) = getConstructorMetadata(artifactJson, inputCount);

        // Build the final JSON
        return decodeParamsJson(constructorArgs, names, typesArr);
    }

    function readArtifact(
        string memory contractName
    ) internal view returns (string memory) {
        string memory root = vm.projectRoot();
        string memory path = string.concat(
            root,
            "/out/",
            contractName,
            ".sol/",
            contractName,
            ".json"
        );
        return vm.readFile(path);
    }

    function getConstructorMetadata(
        string memory artifactJson,
        uint256 inputCount
    ) internal pure returns (string[] memory, string[] memory) {
        string[] memory names = new string[](inputCount);
        string[] memory typesArr = new string[](inputCount);

        for (uint256 i = 0; i < inputCount; i++) {
            string memory baseQuery = string.concat(
                "$.abi[?(@.type == 'constructor')].inputs[",
                vm.toString(i),
                "]"
            );
            names[i] = trim(
                string(
                    vm.parseJson(
                        artifactJson,
                        string.concat(baseQuery, ".name")
                    )
                )
            );
            typesArr[i] = trim(
                string(
                    vm.parseJson(
                        artifactJson,
                        string.concat(baseQuery, ".type")
                    )
                )
            );
        }
        return (names, typesArr);
    }

    function decodeParamsJson(
        bytes memory constructorArgs,
        string[] memory names,
        string[] memory typesArr
    ) internal pure returns (string memory) {
        uint256 offset;
        string memory json = '    "constructorArgs": {\n';

        for (uint256 i = 0; i < names.length; i++) {
            (string memory val, uint256 newOffset) = decodeParam(
                constructorArgs,
                offset,
                typesArr[i]
            );
            offset = newOffset;

            json = string.concat(
                json,
                '      "',
                names[i],
                '": "',
                val,
                '"',
                (i < names.length - 1) ? ",\n" : "\n"
            );
        }
        return string.concat(json, "    }");
    }

    //-------------------------------------------------------------------------
    // Parameter decoding helpers
    //-------------------------------------------------------------------------

    function decodeParam(
        bytes memory data,
        uint256 offset,
        string memory t
    ) internal pure returns (string memory, uint256) {
        if (!isDynamicType(t)) {
            bytes memory chunk = slice(data, offset, 32);
            return (formatStaticParam(t, bytes32(chunk)), offset + 32);
        } else {
            uint256 dataLoc = uint256(bytes32(slice(data, offset, 32)));
            offset += 32;
            uint256 len = uint256(bytes32(slice(data, dataLoc, 32)));
            bytes memory dynData = slice(data, dataLoc + 32, len);
            return (formatDynamicParam(t, dynData), offset);
        }
    }

    function formatStaticParam(
        string memory t,
        bytes32 chunk
    ) internal pure returns (string memory) {
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

    function formatDynamicParam(
        string memory t,
        bytes memory dynData
    ) internal pure returns (string memory) {
        if (compare(t, "string")) {
            return string(dynData);
        } else if (compare(t, "bytes")) {
            return vm.toString(dynData);
        }
        revert("Unsupported dynamic type");
    }

    function isDynamicType(string memory t) internal pure returns (bool) {
        return startsWith(t, "string") || startsWith(t, "bytes");
    }

    function slice(
        bytes memory data,
        uint256 start,
        uint256 length
    ) internal pure returns (bytes memory) {
        require(data.length >= start + length, "slice_outOfBounds");
        bytes memory out = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            out[i] = data[start + i];
        }
        return out;
    }

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

    function compare(
        string memory a,
        string memory b
    ) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function startsWith(
        string memory str,
        string memory prefix
    ) internal pure returns (bool) {
        bytes memory s = bytes(str);
        bytes memory p = bytes(prefix);
        if (s.length < p.length) return false;
        for (uint256 i = 0; i < p.length; i++) {
            if (s[i] != p[i]) return false;
        }
        return true;
    }

    function getTimestampString() internal view returns (string memory) {
        uint256 ts = block.timestamp;
        string memory year = vm.toString((ts / 31536000) + 1970);
        string memory month = pad(vm.toString(((ts % 31536000) / 2592000) + 1));
        string memory day = pad(vm.toString(((ts % 2592000) / 86400) + 1));
        string memory hour = pad(vm.toString((ts % 86400) / 3600));
        string memory minute = pad(vm.toString((ts % 3600) / 60));
        string memory second = pad(vm.toString(ts % 60));
        return
            string.concat(
                year,
                "-",
                month,
                "-",
                day,
                "-",
                hour,
                "-",
                minute,
                "-",
                second
            );
    }

    function pad(string memory n) internal pure returns (string memory) {
        return bytes(n).length == 1 ? string.concat("0", n) : n;
    }
}
