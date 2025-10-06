// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "forge-std/Vm.sol";
import "forge-std/StdJson.sol";
import "forge-std/console.sol";
import "forge-std/console2.sol";

interface ICreate2Factory {
    function deploy(bytes memory code, bytes32 salt) external payable returns (address);
    function verify(address addr, bytes32 salt, bytes memory code) external view returns (bool);
    function computeAddress(bytes32 salt, bytes memory code) external view returns (address);
}

interface IUpgrade {
    function upgradeTo(address) external;

    function roleRegistry() external returns (address);
}

interface IERC1822ProxiableUpgradeable {
    function proxiableUUID() external view returns (bytes32);
}

contract Utils is Script {
    // Create2 factory
    // ICreate2Factory constant factory = ICreate2Factory(0x356d1B83970CeF2018F2c9337cDdb67dff5AEF99);
    // ERC1967 storage slot for implementation address
    bytes32 constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;


    function deploy(string memory contractName, bytes memory constructorArgs, bytes memory bytecode, bytes32 salt, bool logging, ICreate2Factory factory) internal returns (address) {
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

    function verify(address addr, bytes memory bytecode, bytes32 salt, ICreate2Factory factory) internal view returns (bool) {
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