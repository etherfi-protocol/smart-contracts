// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "forge-std/Vm.sol";
import "forge-std/StdJson.sol";
import "forge-std/console.sol";
import "forge-std/console2.sol";
import "openzeppelin-contracts-upgradeable/contracts/interfaces/draft-IERC1822Upgradeable.sol";
import {Deployed} from "../deploys/Deployed.s.sol";
import {EtherFiTimelock} from "../../src/EtherFiTimelock.sol";

interface ICreate2Factory {
    function deploy(bytes memory code, bytes32 salt) external payable returns (address);
    function verify(address addr, bytes32 salt, bytes memory code) external view returns (bool);
    function computeAddress(bytes32 salt, bytes memory code) external view returns (address);
}

interface IUpgrade {
    function upgradeTo(address) external;

    function roleRegistry() external returns (address);
}

contract Utils is Script, Deployed {
    // ERC1967 storage slot for implementation address
    bytes32 constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    uint256 constant MIN_DELAY_OPERATING_TIMELOCK = 28800; // 8 hours
    uint256 constant MIN_DELAY_TIMELOCK = 259200; // 72 hours

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
        
        return deployedAddress;
    }

    function verify(address addr, bytes memory bytecode, bytes32 salt, ICreate2Factory factory) internal view returns (bool) {
        return factory.verify(addr, salt, bytecode);
    }

    function getImplementation(address proxy) internal view returns (address) {
        bytes32 slot = IMPLEMENTATION_SLOT;
        bytes32 value = vm.load(proxy, slot);
        return address(uint160(uint256(value)));
    }

    function checkCondition(bool condition, string memory message) internal pure {
        require(condition, message);
    }

    function verifyProxyUpgradeability(
        address proxy,
        string memory name
    ) internal {
        console2.log(string.concat("Checking ", name, " upgradeability..."));

        // 1. Proxy really points to an implementation
        address impl = getImplementation(proxy);
        console.log("Implementation:", impl);
        checkCondition(
            impl != address(0) && impl != proxy,
            string.concat(name, " is a proxy with an implementation")
        );

        // 2. Implementation exposes correct proxiableUUID()
        try IERC1822ProxiableUpgradeable(impl).proxiableUUID() returns (
            bytes32 slot
        ) {
            checkCondition(
                slot == IMPLEMENTATION_SLOT,
                string.concat(name, " implementation returns correct UUID")
            );
        } catch {
            checkCondition(
                false,
                string.concat(name, " implementation missing proxiableUUID()")
            );
        }

        (bool ok, bytes memory data) = proxy.staticcall(
            abi.encodeWithSignature("upgradeTo(address)", impl)
        );

        checkCondition(
            ok || data.length != 0,
            string.concat(name, " proxy exposes upgradeTo()")
        );
        vm.prank(address(0xcaffe));
        try IUpgrade(proxy).upgradeTo(address(0xbeef)) {
            checkCondition(
                false,
                string.concat(name, " allows a random to upgrade")
            );
        } catch {
            checkCondition(
                true,
                string.concat(name, " does not allows a random to upgrade")
            );
        }
    }

    // Helper function to verify Create2 address    
    function verifyCreate2Address(
        string memory contractName, 
        bytes memory constructorArgs, 
        bytes memory bytecode, 
        bytes32 salt, 
        bool logging,
        ICreate2Factory factory
    ) internal view returns (address) {
        address predictedAddress = factory.computeAddress(salt, bytecode);
        return predictedAddress;
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
        
        // Calculate year accounting for leap years
        uint256 year = 1970;
        uint256 remainingSeconds = ts;
        
        while (remainingSeconds >= secondsInYear(year)) {
            remainingSeconds -= secondsInYear(year);
            year++;
        }
        
        // Calculate month accounting for varying month lengths
        uint256 month = 1;
        while (remainingSeconds >= secondsInMonth(year, month)) {
            remainingSeconds -= secondsInMonth(year, month);
            month++;
        }
        
        // Calculate day (1-based)
        uint256 day = (remainingSeconds / 86400) + 1;
        remainingSeconds %= 86400;
        
        // Calculate time components
        uint256 hour = remainingSeconds / 3600;
        remainingSeconds %= 3600;
        uint256 minute = remainingSeconds / 60;
        uint256 second = remainingSeconds % 60;
        
        return string.concat(
            vm.toString(year), "-",
            pad(vm.toString(month)), "-",
            pad(vm.toString(day)), "-",
            pad(vm.toString(hour)), "-",
            pad(vm.toString(minute)), "-",
            pad(vm.toString(second))
        );
    }
    
    // Helper function to calculate seconds in a given year (accounting for leap years)
    function secondsInYear(uint256 year) internal pure returns (uint256) {
        if (isLeapYear(year)) {
            return 366 * 86400; // 366 days * 24 hours * 3600 seconds
        } else {
            return 365 * 86400; // 365 days * 24 hours * 3600 seconds
        }
    }
    
    // Helper function to calculate seconds in a given month (accounting for varying month lengths)
    function secondsInMonth(uint256 year, uint256 month) internal pure returns (uint256) {
        uint256 daysInMonth;
        
        if (month == 2) {
            daysInMonth = isLeapYear(year) ? 29 : 28;
        } else if (month == 4 || month == 6 || month == 9 || month == 11) {
            daysInMonth = 30;
        } else {
            daysInMonth = 31;
        }
        
        return daysInMonth * 86400; // days * 24 hours * 3600 seconds
    }
    
    // Helper function to determine if a year is a leap year
    function isLeapYear(uint256 year) internal pure returns (bool) {
        return (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
    }

    function pad(string memory n) internal pure returns (string memory) {
        return bytes(n).length == 1 ? string.concat("0", n) : n;
    }

    function _schedule_timelock(address timelock, uint256 minDelay, address target, bytes memory data, bytes32 predecessor, bytes32 salt) internal {
        vm.startPrank(timelockToAdmin[timelock]);
        EtherFiTimelock timelockInstance = EtherFiTimelock(payable(timelock));
        timelockInstance.schedule(target, 0, data, predecessor, salt, minDelay);
        vm.stopPrank();
    }

    function _scheduleBatch_timelock(address timelock, uint256 minDelay, address[] memory targets, bytes[] memory data, bytes32 predecessor, bytes32 salt) internal {
        uint256[] memory values = new uint256[](targets.length);
        for (uint256 i = 0; i < targets.length; i++) {
            values[i] = 0;
        }

        vm.startPrank(timelockToAdmin[timelock]);
        EtherFiTimelock timelockInstance = EtherFiTimelock(payable(timelock));
        timelockInstance.scheduleBatch(targets, values, data, predecessor, salt, minDelay);
        vm.stopPrank();
    }

    function _scheduleBatch_timelock(address timelock, uint256 minDelay, address target, bytes memory data, bytes32 predecessor, bytes32 salt) internal {
        address[] memory targetsArray = new address[](1);
        targetsArray[0] = target;
        bytes[] memory dataArray = new bytes[](1);
        dataArray[0] = data;
        uint256[] memory valuesArray = new uint256[](1);
        valuesArray[0] = 0;
        
        _scheduleBatch_timelock(timelock, minDelay, targetsArray, dataArray, predecessor, salt);
    }

    function _execute_timelock(address timelock, address target, bytes memory data, bytes32 predecessor, bytes32 salt) internal {
        vm.startPrank(timelockToAdmin[timelock]);
        EtherFiTimelock timelockInstance = EtherFiTimelock(payable(timelock));
        timelockInstance.execute(target, 0, data, predecessor, salt);
        vm.stopPrank();
    }

    function _executeBatch_timelock(address timelock, address[] memory targets, bytes[] memory data, bytes32 predecessor, bytes32 salt) internal {
        uint256[] memory values = new uint256[](targets.length);
        for (uint256 i = 0; i < targets.length; i++) {
            values[i] = 0;
        }

        vm.startPrank(timelockToAdmin[timelock]);
        EtherFiTimelock timelockInstance = EtherFiTimelock(payable(timelock));
        timelockInstance.executeBatch(targets, values, data, predecessor, salt);
        vm.stopPrank();
    }

    function _executeBatch_timelock(address timelock, address target, bytes memory data, bytes32 predecessor, bytes32 salt) internal {
        address[] memory targetsArray = new address[](1);
        targetsArray[0] = target;
        bytes[] memory dataArray = new bytes[](1);
        dataArray[0] = data;
        uint256[] memory valuesArray = new uint256[](1);
        valuesArray[0] = 0;
        
        _executeBatch_timelock(timelock, targetsArray, dataArray, predecessor, salt);
    }
}