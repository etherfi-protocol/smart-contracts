// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/token/ERC1155/ERC1155Upgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./interfaces/IMembershipManager.sol";
import "./interfaces/IMembershipNFT.sol";
import "./interfaces/ILiquidityPool.sol";

import "forge-std/console.sol";

contract MembershipNFT is Initializable, OwnableUpgradeable, UUPSUpgradeable, ERC1155Upgradeable, IMembershipNFT {

    IMembershipManager membershipManager;
    uint32 public nextMintTokenId;
    uint32 public maxTokenId;
    bool public mintingPaused;
    uint24 __gap0;

    mapping(uint256 => NftData) public nftData;
    mapping (address => bool) public eapDepositProcessed;
    bytes32 public eapMerkleRoot;
    uint64[] public requiredEapPointsPerEapDeposit;

    string private contractMetadataURI; /// @dev opensea contract-level metadata

    address public DEPRECATED_admin;

    mapping(address => bool) public admins;

    ILiquidityPool public liquidityPool;

    event MerkleUpdated(bytes32, bytes32);
    event MintingPaused(bool isPaused);
    event TokenLocked(uint256 indexed _tokenId, uint256 until);
    
    error DisallowZeroAddress();
    error MintingIsPaused();
    error InvalidEAPRollover();
    error RequireTokenUnlocked();
    error OnlyMembershipManagerContract();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(string calldata _metadataURI, address _membershipManagerInstance) external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        __ERC1155_init(_metadataURI);
        nextMintTokenId = 1;
        maxTokenId = 1000;
        membershipManager = IMembershipManager(_membershipManagerInstance);
    }

    function initializeOnUpgrade(address _liquidityPoolAddress) external onlyOwner {
        require(_liquidityPoolAddress != address(0), "No zero addresses");
        liquidityPool = ILiquidityPool(_liquidityPoolAddress);
        admins[DEPRECATED_admin] = true;
        DEPRECATED_admin = address(0);
    }

    function mint(address _to, uint256 _amount) external onlyMembershipManagerContract returns (uint256) {
        if (mintingPaused || nextMintTokenId > maxTokenId) revert MintingIsPaused();

        uint32 tokenId = nextMintTokenId++;
        _mint(_to, tokenId, _amount, "");
        return tokenId;
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

    function processDepositFromEapUser(address _user, uint32  _eapDepositBlockNumber, uint256 _snapshotEthAmount, uint256 _points, bytes32[] calldata _merkleProof) onlyMembershipManagerContract external {
        if (eapDepositProcessed[_user] == true) revert InvalidEAPRollover();
        bytes32 leaf = keccak256(abi.encodePacked(_user,_snapshotEthAmount, _points, _eapDepositBlockNumber));
        if (!MerkleProof.verify(_merkleProof, eapMerkleRoot, leaf)) revert InvalidEAPRollover(); 

        eapDepositProcessed[_user] = true;
    }

    //--------------------------------------------------------------------------------------
    //--------------------------------------  SETTER  --------------------------------------
    //--------------------------------------------------------------------------------------

    function setMaxTokenId(uint32 _maxTokenId) external onlyAdmin() {
        maxTokenId = _maxTokenId;
    }

    /// @notice Set up for EAP migration; Updates the merkle root, Set the required loyalty points per tier
    /// @param _newMerkleRoot new merkle root used to verify the EAP user data (deposits, points)
    /// @param _requiredEapPointsPerEapDeposit required EAP points per deposit for each tier
    function setUpForEap(bytes32 _newMerkleRoot, uint64[] calldata _requiredEapPointsPerEapDeposit) external onlyAdmin {
        bytes32 oldMerkleRoot = eapMerkleRoot;
        eapMerkleRoot = _newMerkleRoot;
        requiredEapPointsPerEapDeposit = _requiredEapPointsPerEapDeposit;
        emit MerkleUpdated(oldMerkleRoot, _newMerkleRoot);
    }

    /// @notice Updates the address of the admin
    /// @param _address the new address to set as admin
    function updateAdmin(address _address, bool _isAdmin) external onlyOwner {
        require(_address != address(0), "Cannot be address zero");
        admins[_address] = _isAdmin;
    }
    
    function setMintingPaused(bool _paused) external onlyAdmin {
        mintingPaused = _paused;
        emit MintingPaused(_paused);
    }

    //--------------------------------------------------------------------------------------
    //---------------------------------  INTERNAL FUNCTIONS  -------------------------------
    //--------------------------------------------------------------------------------------

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}


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

    function canTopUp(uint256 _tokenId, uint256 _totalAmount, uint128 _amount, uint128 _amountForPoints) public view returns (bool) {
        return membershipManager.canTopUp(_tokenId, _totalAmount, _amount, _amountForPoints);
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
        uint256 earning = effectiveBalanceForEarningPoints * elapsed * pointsGrowthRate / 10000;

        // 0.001         ether   earns 1     wei   points per day
        // == 1          ether   earns 1     kwei  points per day
        // == 1  Million ether   earns 1     gwei  points per day
        // type(uint40).max == 2^40 - 1 ~= 4 * (10 ** 12) == 1000 gwei
        // - A user with 1 Million ether can earn points for 1000 days
        earning = _min((earning / 1 days) / 0.001 ether, type(uint40).max);
        return uint40(earning);
    }

    function computeTierPointsForEap(uint32 _eapDepositBlockNumber) public view returns (uint40) {
        uint8 numTiers = membershipManager.numberOfTiers();
        uint32[] memory lastBlockNumbers = new uint32[](numTiers);
        uint32 eapCloseBlockNumber = 17664247; // https://etherscan.io/tx/0x1ff2ade678bea8b4e5633841ff21390283e57bc50fced4dea54b11ebc929b10c
        
        lastBlockNumbers[0] = 0;
        lastBlockNumbers[1] = eapCloseBlockNumber;
        lastBlockNumbers[2] = 16970393; // https://etherscan.io/tx/0x65bc8e0e5c038fc1569c3b7d9663438696a1e261451a6a57d44373266eda5a19
        lastBlockNumbers[3] = 16755015; // https://etherscan.io/tx/0xe579a56c6c1b1878b368836b682b8fa7c39fe54d6f07750158b570844597e5b4
        
        uint8 tierId;
        if (_eapDepositBlockNumber <= lastBlockNumbers[3]) {
            tierId = 3; // PLATINUM
        } else if (_eapDepositBlockNumber <= lastBlockNumbers[2]) {
            tierId = 2; // GOLD
        } else if (_eapDepositBlockNumber <= lastBlockNumbers[1]) {
            tierId = 1; // SILVER
        } else {
            tierId = 0; // BRONZE
        }
        uint8 nextTierId = (tierId < numTiers - 1) ? tierId + 1 : tierId;

        (,uint40 current,, ) = membershipManager.tierData(tierId);
        (,uint40 next,, ) = membershipManager.tierData(nextTierId);

        // Minimum tierPoints for the current tier
        uint40 tierPoints = current;

        // Linear projection of TierPoints within the tier
        // so that the days in EAP is taken into account for the days remaining for the next tier
        if (tierId != nextTierId) {
            tierPoints += (next - current) * (lastBlockNumbers[tierId] - _eapDepositBlockNumber) / (lastBlockNumbers[tierId] - lastBlockNumbers[nextTierId]);
        }

        // They kept staking with us after the EAP ended
        // One tier point per hour
        // While the actual block generation time is slightly larger than 12 seconds
        // we use 13 seconds to compenstae our users pain during the days after the EAP
        tierPoints += (13 * (uint40(block.number) - eapCloseBlockNumber)) / 3600;

        return tierPoints;
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
    function setContractMetadataURI(string calldata _newURI) external onlyAdmin {
        contractMetadataURI = _newURI;
    }

    /// @dev erc1155 metadata extension
    function setMetadataURI(string calldata _newURI) external onlyAdmin {
        _setURI(_newURI);
    }

    /// @dev alert opensea to a metadata update
    function alertMetadataUpdate(uint256 id) public onlyAdmin {
        emit MetadataUpdate(id);
    }

    /// @dev alert opensea to a metadata update
    function alertBatchMetadataUpdate(uint256 startID, uint256 endID) public onlyAdmin {
        emit BatchMetadataUpdate(startID, endID);
    }

    //--------------------------------------------------------------------------------------
    //------------------------------------  MODIFIER  --------------------------------------
    //--------------------------------------------------------------------------------------

    modifier onlyAdmin() {
        require(admins[msg.sender], "Caller is not the admin");
        _;
    }

    modifier onlyMembershipManagerContract() {
        if (msg.sender != address(membershipManager)) revert OnlyMembershipManagerContract();
        _;
    }
}
