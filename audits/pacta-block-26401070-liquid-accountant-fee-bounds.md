# ether.fi Liquid BoringVault Accountant & RolesAuthority Verification (Block `26401070`)

- **Pinned Block**: Ethereum Mainnet `26401070` (`0xcf55f6a42ae610c1f8766b5c2fb676d91f178469fa10ef777eccbb76f6506234`)
- **Primary Documentation Source**: `https://etherfi.gitbook.io/etherfi/products/liquid/veda-vault.md` (`SHA-256: 8837c94fc029324bc39daa119cbae976560d8f3d2ad33b1d51ac3feb7586ea18`)
- **Upstream Policy Reference**: `https://docs.veda.tech/api/policy-manager-and-merkle-trees.md` (`SHA-256: 190117412d701dd6e21390abf9c78aa02304723bb20e44c24051ce3d867ea289`)

## 1. Verified On-Chain `Accountant` & `RolesAuthority` Configuration (`EL1`)

| Component | Contract Address | Verified On-Chain State at Block `26401070` | Documented Commitment |
| :--- | :--- | :--- | :--- |
| **Liquid ETH `BoringVault`** | `0xf0bb20865277aBd641a307eCe5Ee04E79073416C` | `totalSupply() = 125,342.06` shares (`0x1a8ace8faadad6cce288`) | Veda BoringVault architecture |
| **Liquid BTC `BoringVault`** | `0x5f46d540b6eD704C3c8789105F30E075AA900726` | `totalSupply() = 110.91276245` shares (`0x2951771d5`) | Veda BoringVault architecture |
| **Liquid ETH `AccountantWithRateProviders`** | `0x0d05D94a5F1E76C18fbeB7A13d17C8a314088198` | Hardcoded `updateManagementFee(uint16)` (`0xc10af4c7`) ceiling `0.2e4` (`20%`); live fee within `0%–2%` | `"Fee range: 0% to 2%"` |
| **Liquid BTC `AccountantWithRateProviders`** | `0xEa23aC6D7D11f6b181d6B98174D334478ADAe6b0` | Exposes `updatePerformanceFee(uint16)` (`0x709ac1c3`, ceiling `50%`); live fee within documented bounds | `"Fee range: 0% to 2%"` |
| **ETH & BTC `RolesAuthority`** | `0x485Bde66Bb668a51f2372E34e45B1c6226798122`<br>`0x49F954c67ff235034b69b8a59fbe309A40256c8d` | `owner() = 0xD829F278016b90FEc735F9A12Bf8b75E06102C89` (`getMinDelay() = 86400s` / 1-day Timelock); `role 8` held by Timelock (`0xD829...2C89`), `role 55` held by `2-of-4` Safe `0x607d0C7e3578802Eb46D388cb86cfba8Ff657306` | Timelocked governance oversight |

## 2. Private Security Disclosure Contact (`EL2` & `EL3`)

Two additional `disclosure_only` findings isolated during the block-`26401070` `RolesAuthority` and `ManagerWithMerkleVerification` verification pass (`EL2` and `EL3`) have been withheld from this public file per responsible disclosure standards and are available **at no cost (`$0`)** via **`pacta@dri.network`**.
