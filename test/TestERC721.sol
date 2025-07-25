// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract TestERC721 is ERC721 {
    uint256 private _nextTokenId;

    constructor(string memory _name, string memory _symbol)
        ERC721(_name, _symbol)
    {}

    function mint(address _to) public returns (uint256) {
        uint256 tokenId = _nextTokenId++;
        _mint(_to, tokenId);
        return tokenId;
    }

    function mintWithTokenId(address _to, uint256 _tokenId) public {
        _mint(_to, _tokenId);
    }
}