// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// @dev careful here, older OZ version doesn't deploy the ProxyAdmin contract by default and the send would be
// the direct owner of the proxy contract (he won't be able to call any function of the implementation contract)
import "forge-std/Script.sol";

import "../../test/NativeMintingConfigs.t.sol";
import "../../test/NativeMintingL2.t.sol";

contract Deploy is Script, NativeMintingL2 {
 
    function run() public {
        pk = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(pk);
        
        targetL2Params = prod;
        
        // _init();
        // for (uint256 i = 0; i < l2s.length; i++) {
        //     vm.createSelectFork(l2s[i].rpc_url);
        //     _setUp();
        //     _go();
        //     // _verify_oft_wired();
        // }
        
        _setUp();
        // _verify_L2_OFT_configuratinos();

        _go();
        // _go_oft();
    }

}