// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface IeETH {
    function name() external pure returns (string memory);
    function symbol() external pure returns (string memory);
    function decimals() external pure returns (uint8);
    function totalShares() external view returns (uint256);

    function shares(address _user) external view returns (uint256);
    function balanceOf(address _user) external view returns (uint256);

    function initialize(address _liquidityPool) external;
    function mintShares(address _user, uint256 _share) external;
    function burnShares(address _user, uint256 _share) external;
    function transferFrom(address _sender, address _recipient, uint256 _amount) external returns (bool);
    function transfer(address _recipient, uint256 _amount) external returns (bool);
    function approve(address _spender, uint256 _amount) external returns (bool);
    function increaseAllowance(address _spender, uint256 _increaseAmount) external returns (bool);
    function decreaseAllowance(address _spender, uint256 _decreaseAmount) external returns (bool);

    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;
}
