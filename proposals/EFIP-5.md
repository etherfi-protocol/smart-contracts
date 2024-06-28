# [EFIP-5] Security Improvements for eETH/weETH: Whitelist on `spender` of `permit`, blacklist on `transfer`, and rescue mechanism

**Author**: syko (seongyun@ether.fi)

**Date**: 2024-06-28

## Summary

This EFIP aims to improve the security of ether.fi eETH/weETH by introducing a whitelist on `spender` of `permit` and a blacklist on `transfer`.


## Motivation

While ERC20's extension on `Permit` brings convenience by using off-chain signatures for authorization, it is a well-known vulnerability that can lead to [phishing attacks](https://cointelegraph.com/magazine/phishing-crypto-erc-20-bait-scammers/). We have also been seeing growing incidents of incidents, where eETH/weETH users are tricked into signing a permit for a malicious contract or address.

In addition, the funds can be sent to the malicious contracts or addresses by the owner or the malicious contracts can lock the funds by transferring them to the malicious addresses. This can lead to the loss of funds or the funds being locked forever.


## Proposal

The below are PoC implementations. The actual implementation may vary.

### Whitelist on `spender` of `permit`

It introduces a whitelist mechanism on `spender` of `permit`. It will only allow the permit to be signed only for the whitelisted addresses to be the `spender` such as the well-known DEXes or lending protocols.

```
contract EETH {
    ...

    mapping(address => bool) public whitelistedSpender;

    function permit(
            address owner,
            address spender,
            uint256 value,
            uint256 deadline,
            uint8 v,
            bytes32 r,
            bytes32 s
    ) public virtual override(IeETH, IERC20PermitUpgradeable) {
        require(whitelistedSpender[spender], "EETH: spender not whitelisted"); 

        ...
    }
}
```


### Blacklist on `transfer`

It introduces a blacklist mechanism on `transfer`. It will prevent the transfer of tokens to the blacklisted addresses. This will help to prevent the funds from being sent to the malicious contracts or addresses.

Note that [USDCv2](https://etherscan.io/address/0x43506849d7c04f9138d1a2050bbf3a0c054402dd#code) by Circle implements the blacklist.

```
contract EETH {
    ...
    
    mapping(address => bool) public blacklisted;

    function _transfer(address _sender, address _recipient, uint256 _amount) internal {
        require(!blacklisted[_sender] || !blacklisted[_recipient], "EETH: blacklisted address");

        ...
    }
}
```

## References

- Ethereum’s ERC-20 design flaws are a crypto scammer’s best friend [link](https://cointelegraph.com/magazine/phishing-crypto-erc-20-bait-scammers/)
- USDCv2 [link](https://etherscan.io/address/0x43506849d7c04f9138d1a2050bbf3a0c054402dd)

## Copyright

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/).

