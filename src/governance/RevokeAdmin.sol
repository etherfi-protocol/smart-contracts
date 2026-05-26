// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;


import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import "@etherfi/governance/utils/RolesLibrary.sol";
import "@etherfi/governance/interfaces/IRevokeAdmin.sol";

contract RevokeAdmin is Initializable, UUPSUpgradeable, RolesLibrary, IRevokeAdmin {

    constructor(address _roleRegistry) RolesLibrary(_roleRegistry) {
        _disableInitializers();
    }

    function initialize() external initializer {
        __UUPSUpgradeable_init();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyUpgradeTimelock {}

    function revokeGuardianRole(address account) external onlyOperatingMultisig {
        _revokeFast(roleRegistry.GUARDIAN_ROLE(), account);
    }

    function revokeOracleOperationsRole(address account) external onlyOperatingMultisig {
        _revokeFast(roleRegistry.ORACLE_OPERATIONS_ROLE(), account);
    }

    function revokeHousekeepingOperationsRole(address account) external onlyOperatingMultisig {
        _revokeFast(roleRegistry.HOUSEKEEPING_OPERATIONS_ROLE(), account);
    }

    function revokeExecutorOperationsRole(address account) external onlyOperatingMultisig {
        _revokeFast(roleRegistry.EXECUTOR_OPERATIONS_ROLE(), account);
    }

    function revokeEigenpodOperationsRole(address account) external onlyOperatingMultisig {
        _revokeFast(roleRegistry.EIGENPOD_OPERATIONS_ROLE(), account);
    }

    function _revokeFast(bytes32 role, address account) internal {
        roleRegistry.revokeFast(role, account);
    }
}