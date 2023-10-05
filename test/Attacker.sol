pragma solidity 0.8.13;


contract Attacker {
    address receiver;

    receive() external payable {
    }

    constructor(address _receiver) {
        receiver = _receiver;
    }

    function attack() public payable {
        // cast address to payable
        address payable addr = payable(address(receiver));
        selfdestruct(addr);
    }
}

contract RevertAttacker {

    error REVERT();
    receive() external payable {
        revert REVERT();
    }

    constructor() {
    }
}


contract GasDrainAttacker {

    uint256 a;
    uint256 b;
    uint256 c;

    receive() external payable {
        a += 1;
        b += 2;
        c += 3;
    }

    constructor() {
        a = 1;
        b = 2;
        c = 3;
    }
}

contract NoAttacker {
    uint128 a;
    uint128 b;

    receive() external payable {
        a += uint128(msg.value);
        b += uint128(msg.value);
    }

    constructor() {
        a = 1;
        b = 2;
    }
}