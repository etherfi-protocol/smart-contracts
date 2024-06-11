// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// @dev careful here, older OZ version doesn't deploy the ProxyAdmin contract by default and the send would be
// the direct owner of the proxy contract (he won't be able to call any function of the implementation contract)
import "forge-std/Script.sol";

import "../../test/NativeMintingConfigs.t.sol";
import "../../test/NativeMintingL1.t.sol";

contract Deploy is Script, NativeMintingL1Suite {
    
    constructor() {
        IS_TEST = false;
    }

    function run() public {
        pk = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(pk);

        _setUp();

        _go();
    }

}