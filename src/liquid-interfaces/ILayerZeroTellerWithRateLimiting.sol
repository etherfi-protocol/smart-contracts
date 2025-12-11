// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;
//Fetched via cast interface 0x4DE413a26fC24c3FC27Cc983be70aA9c5C299387 -e ETHERSCAN_API_KEY > ILayerZeroTellerWithRateLimiting.sol

library PairwiseRateLimiter {
    struct RateLimitConfig {
        uint32 peerEid;
        uint256 limit;
        uint256 window;
    }
}

interface ILayerZeroTellerWithRateLimiting {
    struct Origin {
        uint32 srcEid;
        bytes32 sender;
        uint64 nonce;
    }

    error CrossChainTellerWithGenericBridge__UnsafeCastToUint96();
    error InboundRateLimitExceeded();
    error InvalidDelegate();
    error InvalidEndpointCall();
    error InvalidOptionType(uint16 optionType);
    error LayerZeroTeller__BadFeeToken();
    error LayerZeroTeller__FeeExceedsMax(uint256 chainSelector, uint256 fee, uint256 maxFee);
    error LayerZeroTeller__MessagesNotAllowedFrom(uint256 chainSelector);
    error LayerZeroTeller__MessagesNotAllowedFromSender(uint256 chainSelector, address sender);
    error LayerZeroTeller__MessagesNotAllowedTo(uint256 chainSelector);
    error LayerZeroTeller__ZeroMessageGasLimit();
    error LzTokenUnavailable();
    error MessageLib__ShareAmountOverflow();
    error NoPeer(uint32 eid);
    error NotEnoughNative(uint256 msgValue);
    error OnlyEndpoint(address addr);
    error OnlyPeer(uint32 eid, bytes32 sender);
    error OutboundRateLimitExceeded();
    error SafeCastOverflowedUintDowncast(uint8 bits, uint256 value);
    error TellerWithMultiAssetSupport__AssetNotSupported();
    error TellerWithMultiAssetSupport__BadDepositHash();
    error TellerWithMultiAssetSupport__CannotDepositNative();
    error TellerWithMultiAssetSupport__DualDeposit();
    error TellerWithMultiAssetSupport__MinimumAssetsNotMet();
    error TellerWithMultiAssetSupport__MinimumMintNotMet();
    error TellerWithMultiAssetSupport__Paused();
    error TellerWithMultiAssetSupport__PermitFailedAndAllowanceTooLow();
    error TellerWithMultiAssetSupport__ShareLockPeriodTooLong();
    error TellerWithMultiAssetSupport__SharePremiumTooLarge();
    error TellerWithMultiAssetSupport__SharesAreLocked();
    error TellerWithMultiAssetSupport__SharesAreUnLocked();
    error TellerWithMultiAssetSupport__TransferDenied(address from, address to, address operator);
    error TellerWithMultiAssetSupport__ZeroAssets();
    error TellerWithMultiAssetSupport__ZeroShares();

    event AllowFrom(address indexed user);
    event AllowOperator(address indexed user);
    event AllowTo(address indexed user);
    event AssetDataUpdated(address indexed asset, bool allowDeposits, bool allowWithdraws, uint16 sharePremium);
    event AuthorityUpdated(address indexed user, address indexed newAuthority);
    event BulkDeposit(address indexed asset, uint256 depositAmount);
    event BulkWithdraw(address indexed asset, uint256 shareAmount);
    event ChainAdded(uint256 chainId, bool allowMessagesFrom, bool allowMessagesTo, address targetTeller);
    event ChainAllowMessagesFrom(uint256 chainId, address targetTeller);
    event ChainAllowMessagesTo(uint256 chainId, address targetTeller);
    event ChainRemoved(uint256 chainId);
    event ChainSetGasLimit(uint256 chainId, uint128 messageGasLimit);
    event ChainStopMessagesFrom(uint256 chainId);
    event ChainStopMessagesTo(uint256 chainId);
    event DenyFrom(address indexed user);
    event DenyOperator(address indexed user);
    event DenyTo(address indexed user);
    event Deposit(
        uint256 indexed nonce,
        address indexed receiver,
        address indexed depositAsset,
        uint256 depositAmount,
        uint256 shareAmount,
        uint256 depositTimestamp,
        uint256 shareLockPeriodAtTimeOfDeposit
    );
    event DepositRefunded(uint256 indexed nonce, bytes32 depositHash, address indexed user);
    event InboundRateLimitsChanged(PairwiseRateLimiter.RateLimitConfig[] rateLimitConfigs);
    event MessageReceived(bytes32 indexed messageId, uint256 shareAmount, address indexed to);
    event MessageSent(bytes32 indexed messageId, uint256 shareAmount, address indexed to);
    event OutboundRateLimitsChanged(PairwiseRateLimiter.RateLimitConfig[] rateLimitConfigs);
    event OwnershipTransferred(address indexed user, address indexed newOwner);
    event Paused();
    event PeerSet(uint32 eid, bytes32 peer);
    event Unpaused();

    function accountant() external view returns (address);
    function addChain(
        uint32 chainId,
        bool allowMessagesFrom,
        bool allowMessagesTo,
        address targetTeller,
        uint128 messageGasLimit
    ) external;
    function allowAll(address user) external;
    function allowFrom(address user) external;
    function allowInitializePath(Origin memory origin) external view returns (bool);
    function allowMessagesFromChain(uint32 chainId, address targetTeller) external;
    function allowMessagesToChain(uint32 chainId, address targetTeller, uint128 messageGasLimit) external;
    function allowOperator(address user) external;
    function allowTo(address user) external;
    function assetData(address) external view returns (bool allowDeposits, bool allowWithdraws, uint16 sharePremium);
    function authority() external view returns (address);
    function beforeTransfer(address from, address to, address operator) external view;
    function beforeTransfer(address from) external view;
    function bridge(uint96 shareAmount, address to, bytes memory bridgeWildCard, address feeToken, uint256 maxFee)
        external
        payable;
    function bulkDeposit(address depositAsset, uint256 depositAmount, uint256 minimumMint, address to)
        external
        returns (uint256 shares);
    function bulkWithdraw(address withdrawAsset, uint256 shareAmount, uint256 minimumAssets, address to)
        external
        returns (uint256 assetsOut);
    function composeMsgSender() external view returns (address sender);
    function denyAll(address user) external;
    function denyFrom(address user) external;
    function denyOperator(address user) external;
    function denyTo(address user) external;
    function deposit(address depositAsset, uint256 depositAmount, uint256 minimumMint)
        external
        payable
        returns (uint256 shares);
    function depositAndBridge(
        address depositAsset,
        uint256 depositAmount,
        uint256 minimumMint,
        address to,
        bytes memory bridgeWildCard,
        address feeToken,
        uint256 maxFee
    ) external payable returns (uint256 sharesBridged);
    function depositAndBridgeWithPermit(
        address depositAsset,
        uint256 depositAmount,
        uint256 minimumMint,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s,
        address to,
        bytes memory bridgeWildCard,
        address feeToken,
        uint256 maxFee
    ) external payable returns (uint256 sharesBridged);
    function depositNonce() external view returns (uint96);
    function depositWithPermit(
        address depositAsset,
        uint256 depositAmount,
        uint256 minimumMint,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 shares);
    function endpoint() external view returns (address);
    function fromDenyList(address) external view returns (bool);
    function getAmountCanBeReceived(uint32 _srcEid)
        external
        view
        returns (uint256 inboundAmountInFlight, uint256 amountCanBeReceived);
    function getAmountCanBeSent(uint32 _dstEid)
        external
        view
        returns (uint256 outboundAmountInFlight, uint256 amountCanBeSent);
    function idToChains(uint32)
        external
        view
        returns (bool allowMessagesFrom, bool allowMessagesTo, uint128 messageGasLimit);
    function inboundRateLimits(uint32 srcEid)
        external
        view
        returns (uint256 amountInFlight, uint256 lastUpdated, uint256 limit, uint256 window);
    function isPaused() external view returns (bool);
    function lzReceive(
        Origin memory _origin,
        bytes32 _guid,
        bytes memory _message,
        address _executor,
        bytes memory _extraData
    ) external payable;
    function nativeWrapper() external view returns (address);
    function nextNonce(uint32, bytes32) external view returns (uint64 nonce);
    function oAppVersion() external pure returns (uint64 senderVersion, uint64 receiverVersion);
    function operatorDenyList(address) external view returns (bool);
    function outboundRateLimits(uint32 dstEid)
        external
        view
        returns (uint256 amountInFlight, uint256 lastUpdated, uint256 limit, uint256 window);
    function owner() external view returns (address);
    function pause() external;
    function peers(uint32 eid) external view returns (bytes32 peer);
    function previewFee(uint96 shareAmount, address to, bytes memory bridgeWildCard, address feeToken)
        external
        view
        returns (uint256 fee);
    function publicDepositHistory(uint256) external view returns (bytes32);
    function refundDeposit(
        uint256 nonce,
        address receiver,
        address depositAsset,
        uint256 depositAmount,
        uint256 shareAmount,
        uint256 depositTimestamp,
        uint256 shareLockUpPeriodAtTimeOfDeposit
    ) external;
    function removeChain(uint32 chainId) external;
    function setAuthority(address newAuthority) external;
    function setChainGasLimit(uint32 chainId, uint128 messageGasLimit) external;
    function setDelegate(address _delegate) external;
    function setInboundRateLimits(PairwiseRateLimiter.RateLimitConfig[] memory _rateLimitConfigs) external;
    function setOutboundRateLimits(PairwiseRateLimiter.RateLimitConfig[] memory _rateLimitConfigs) external;
    function setPeer(uint32 _eid, bytes32 _peer) external;
    function setShareLockPeriod(uint64 _shareLockPeriod) external;
    function shareLockPeriod() external view returns (uint64);
    function shareUnlockTime(address) external view returns (uint256);
    function stopMessagesFromChain(uint32 chainId) external;
    function stopMessagesToChain(uint32 chainId) external;
    function toDenyList(address) external view returns (bool);
    function transferOwnership(address newOwner) external;
    function unpause() external;
    function updateAssetData(address asset, bool allowDeposits, bool allowWithdraws, uint16 sharePremium) external;
    function vault() external view returns (address);
}
