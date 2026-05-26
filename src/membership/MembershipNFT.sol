// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/token/ERC1155/ERC1155Upgradeable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "@etherfi/membership/interfaces/IMembershipManager.sol";
import "@etherfi/membership/interfaces/IMembershipNFT.sol";
import "@etherfi/core/interfaces/ILiquidityPool.sol";
import "@etherfi/governance/interfaces/IBlacklister.sol";
import "@etherfi/governance/utils/RolesLibrary.sol";

import "forge-std/console.sol";

contract MembershipNFT is Initializable, OwnableUpgradeable, UUPSUpgradeable, ERC1155Upgradeable, IMembershipNFT, RolesLibrary {

    IMembershipManager private DEPRECATED_membershipManager;
    uint32 public nextMintTokenId;
    uint32 public maxTokenId;
    bool public mintingPaused;
    uint24 __gap0;

    mapping(uint256 => NftData) public nftData;
    mapping (address => bool) public eapDepositProcessed;
    bytes32 public eapMerkleRoot;
    uint64[] public requiredEapPointsPerEapDeposit;

    string private contractMetadataURI; /// @dev opensea contract-level metadata

    address private DEPRECATED_admin;

    mapping(address => bool) private DEPRECATED_admins;

    ILiquidityPool private DEPRECATED_liquidityPool;

    ILiquidityPool public immutable liquidityPool;
    IMembershipManager public immutable membershipManager;
    IBlacklister public immutable blacklister;

    uint256 public constant BASIS_POINTS_DENOMINATOR = 10000;

    event TokenLocked(uint256 indexed _tokenId, uint256 until);

    error RequireTokenUnlocked();
    error OnlyMembershipManagerContract();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _liquidityPool, address _membershipManager, address _roleRegistry, address _blacklister) RolesLibrary(_roleRegistry) {
        liquidityPool = ILiquidityPool(_liquidityPool);
        membershipManager = IMembershipManager(_membershipManager);
        blacklister = IBlacklister(_blacklister);
        _disableInitializers();
    }

    function initialize(string calldata _metadataURI, address _membershipManagerInstance) external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        __ERC1155_init(_metadataURI);
        nextMintTokenId = 1;
        maxTokenId = 1000;
    }

    function burn(address _from, uint256 _tokenId, uint256 _amount) onlyMembershipManagerContract external {
        _burn(_from, _tokenId, _amount);
    }

    /// @dev locks a token from being transferred for a number of blocks
    function incrementLock(uint256 _tokenId, uint32 _blocks) onlyMembershipManagerContract external {
        uint32 target = uint32(block.number) + _blocks;

        // don't accidentally shorten an existing lock
        if (nftData[_tokenId].transferLockedUntil < target) {
            nftData[_tokenId].transferLockedUntil = target;
            emit TokenLocked(_tokenId, target);
        }
    }

    //--------------------------------------------------------------------------------------
    //---------------------------------  INTERNAL FUNCTIONS  -------------------------------
    //--------------------------------------------------------------------------------------

    function _authorizeUpgrade(address newImplementation) internal override onlyUpgradeTimelock {}


    function _beforeTokenTransfer(
        address _operator,
        address _from,
        address _to,
        uint256[] memory _ids,
        uint256[] memory _amounts,
        bytes memory _data
    ) internal view override {

        // empty mints and burns from checks
        if (_from == address(0x00) || _to == address(0x00)) {
            return;
        }

        // check if the operator, from, and to are not blacklisted
        blacklister.nonBlacklisted(_operator);
        blacklister.nonBlacklisted(_from);
        blacklister.nonBlacklisted(_to);

        // prevent transfers if token is locked
        for (uint256 x; x < _ids.length; ++x) {
            if (block.number < nftData[_ids[x]].transferLockedUntil) revert RequireTokenUnlocked();
        }
    }

    //--------------------------------------------------------------------------------------
    //--------------------------------------  GETTER  --------------------------------------
    //--------------------------------------------------------------------------------------

    function balanceOfUser(address _user, uint256 _id) public view returns (uint256) {
        return balanceOf(_user, _id);
    }

    error InvalidVersion();
    function valueOf(uint256 _tokenId) public view returns (uint256) {
        (uint96 rewardsLocalIndex,,,,, uint8 tier, uint8 version) = membershipManager.tokenData(_tokenId);
        if (version == 0) {
            return _V0_valueOf(_tokenId);
        } else if (version == 1) {
            return _V1_valueOf(_tokenId);
        } else {
            revert InvalidVersion();
        }
        return 0;
    }

    function accruedStakingRewardsOf(uint256 _tokenId) public view returns (uint256) {
        (uint96 rewardsLocalIndex,,,,, uint8 tier, uint8 version) = membershipManager.tokenData(_tokenId);
        if (version == 0) {
            return _V0_accruedStakingRewardsOf(_tokenId);
        } else {
            revert InvalidVersion();
        }
        return 0;
    }

    function _V0_valueOf(uint256 _tokenId) internal view returns (uint256) {
        (uint96 rewardsLocalIndex,,,,, uint8 tier, uint8 version) = membershipManager.tokenData(_tokenId);
        (uint128 amounts,) = membershipManager.tokenDeposits(_tokenId);
        (uint96 rewardsGlobalIndex,,, ) = membershipManager.tierData(tier);
        uint256 rewards = accruedStakingRewardsOf(_tokenId);
        return amounts + rewards;
    }

    function _V0_accruedStakingRewardsOf(uint256 _tokenId) internal view returns (uint256) {
        (uint96 rewardsLocalIndex,,,,, uint8 tier, uint8 version) = membershipManager.tokenData(_tokenId);
        (uint128 amounts, uint128 shares) = membershipManager.tokenDeposits(_tokenId);
        (uint96 rewardsGlobalIndex,,, ) = membershipManager.tierData(tier);
        uint256 rewards = 0;
        if (rewardsGlobalIndex > rewardsLocalIndex) {        
            rewards = uint256(rewardsGlobalIndex - rewardsLocalIndex) * shares / 1 ether;
        }
        return rewards;
    }

    function _V1_valueOf(uint256 _tokenId) internal view returns (uint256) {
        (uint96 share,,,,, uint8 tier,) = membershipManager.tokenData(_tokenId);
        return membershipManager.ethAmountForVaultShare(tier, share);
    }

    function loyaltyPointsOf(uint256 _tokenId) public view returns (uint40) {
        (, uint40 baseLoyaltyPoints,,,,,) = membershipManager.tokenData(_tokenId);
        uint256 pointsEarning = accruedLoyaltyPointsOf(_tokenId);
        uint256 total = _min(baseLoyaltyPoints + pointsEarning, type(uint40).max);
        return uint40(total);
    }

    function tierPointsOf(uint256 _tokenId) public view returns (uint40) {
        (,, uint40 baseTierPoints,,,,) = membershipManager.tokenData(_tokenId);
        uint256 pointsEarning = accruedTierPointsOf(_tokenId);
        uint256 total = _min(baseTierPoints + pointsEarning, type(uint40).max);
        return uint40(total);
    }

    function tierOf(uint256 _tokenId) public view returns (uint8) {
        (,,,,, uint8 tier,) = membershipManager.tokenData(_tokenId);
        return tier;
    }

    function claimableTier(uint256 _tokenId) public view returns (uint8) {
        uint40 tierPoints = tierPointsOf(_tokenId);
        return membershipManager.tierForPoints(tierPoints);
    }

    function accruedLoyaltyPointsOf(uint256 _tokenId) public view returns (uint40) {
        (,,, uint32 prevPointsAccrualTimestamp,,,) = membershipManager.tokenData(_tokenId);
        return membershipPointsEarning(_tokenId, prevPointsAccrualTimestamp, block.timestamp);
    }

    function accruedTierPointsOf(uint256 _tokenId) public view returns (uint40) {
        uint256 amounts = valueOf(_tokenId);
        if (amounts == 0) {
            return 0;
        }
        (,,, uint32 prevPointsAccrualTimestamp,,,) = membershipManager.tokenData(_tokenId);
        uint256 tierPointsPerDay = 24; // 1 per an hour
        uint256 earnedPoints = (uint32(block.timestamp) - prevPointsAccrualTimestamp) * tierPointsPerDay / 1 days;
        return uint40(earnedPoints);
    }

    function isWithdrawable(uint256 _tokenId, uint256 _withdrawalAmount) public view returns (bool) {
        // cap withdrawals to 50% of lifetime max balance. Otherwise need to fully withdraw and burn NFT
        uint256 totalDeposit = valueOf(_tokenId);
        uint256 highestDeposit = allTimeHighDepositOf(_tokenId);
        return (totalDeposit >= _withdrawalAmount && totalDeposit - _withdrawalAmount >= highestDeposit / 2);
    }

    function allTimeHighDepositOf(uint256 _tokenId) public view returns (uint256) {
        uint256 totalDeposit = valueOf(_tokenId);
        return _max(totalDeposit, membershipManager.allTimeHighDepositAmount(_tokenId));        
    }

    function transferLockedUntil(uint256 _tokenId) external view returns (uint32) {
        return nftData[_tokenId].transferLockedUntil;
    }

    // Compute the points earnings of a user between [since, until) 
    // Assuming the user's balance didn't change in between [since, until)
    function membershipPointsEarning(uint256 _tokenId, uint256 _since, uint256 _until) public view returns (uint40) {
        uint256 amounts = valueOf(_tokenId);
        uint256 shares = liquidityPool.sharesForAmount(amounts);
        if (amounts == 0 || shares == 0) {
            return 0;
        }
        
        uint16 pointsGrowthRate = membershipManager.pointsGrowthRate();

        uint256 elapsed = _until - _since;
        uint256 effectiveBalanceForEarningPoints = shares;
        uint256 earning = effectiveBalanceForEarningPoints * elapsed * pointsGrowthRate / BASIS_POINTS_DENOMINATOR;

        // 0.001         ether   earns 1     wei   points per day
        // == 1          ether   earns 1     kwei  points per day
        // == 1  Million ether   earns 1     gwei  points per day
        // type(uint40).max == 2^40 - 1 ~= 4 * (10 ** 12) == 1000 gwei
        // - A user with 1 Million ether can earn points for 1000 days
        earning = _min((earning / 1 days) / 0.001 ether, type(uint40).max);
        return uint40(earning);
    }

    function _min(uint256 _a, uint256 _b) internal pure returns (uint256) {
        return (_a > _b) ? _b : _a;
    }

    function _max(uint256 _a, uint256 _b) internal pure returns (uint256) {
        return (_a > _b) ? _a : _b;
    }

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    //--------------------------------------------------------------------------------------
    //---------------------------------- NFT METADATA --------------------------------------
    //--------------------------------------------------------------------------------------

    /// @dev ERC-4906 This event emits when the metadata of a token is changed.
    /// So that the third-party platforms such as NFT market could
    /// timely update the images and related attributes of the NFT.
    event MetadataUpdate(uint256 _tokenId);

    /// @dev ERC-4906 This event emits when the metadata of a range of tokens is changed.
    /// So that the third-party platforms such as NFT market could
    /// timely update the images and related attributes of the NFTs.    
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    /// @notice OpenSea contract-level metadata
    function contractURI() public view returns (string memory) {
        return contractMetadataURI;
    }

    /// @dev opensea contract-level metadata
    function setContractMetadataURI(string calldata _newURI) external onlyOperatingMultisig {
        contractMetadataURI = _newURI;
    }

    /// @dev erc1155 metadata extension
    function setMetadataURI(string calldata _newURI) external onlyOperatingMultisig {
        _setURI(_newURI);
    }

    /// @dev alert opensea to a metadata update
    function alertMetadataUpdate(uint256 id) public onlyOperatingMultisig {
        emit MetadataUpdate(id);
    }

    /// @dev alert opensea to a metadata update
    function alertBatchMetadataUpdate(uint256 startID, uint256 endID) public onlyOperatingMultisig {
        emit BatchMetadataUpdate(startID, endID);
    }

    //--------------------------------------------------------------------------------------
    //------------------------------------  MODIFIER  --------------------------------------
    //--------------------------------------------------------------------------------------

    modifier onlyMembershipManagerContract() {
        if (msg.sender != address(membershipManager)) revert OnlyMembershipManagerContract();
        _;
    }
}
