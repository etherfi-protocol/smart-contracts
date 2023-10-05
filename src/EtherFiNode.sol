// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./interfaces/IEtherFiNode.sol";
import "./interfaces/IEtherFiNodesManager.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import "@eigenlayer/contracts/interfaces/IEigenPodManager.sol";
import "@eigenlayer/contracts/interfaces/IDelayedWithdrawalRouter.sol";

contract EtherFiNode is IEtherFiNode {
    address public etherFiNodesManager;

    uint256 public DEPRECATED_localRevenueIndex;
    uint256 public DEPRECATED_vestedAuctionRewards;
    string public ipfsHashForEncryptedValidatorKey;
    uint32 public exitRequestTimestamp;
    uint32 public exitTimestamp;
    uint32 public stakingStartTimestamp;
    VALIDATOR_PHASE public phase;

    uint32 public restakingObservedExitBlock; 
    address public eigenPod;
    bool public isRestakingEnabled;

    //--------------------------------------------------------------------------------------
    //----------------------------------  CONSTRUCTOR   ------------------------------------
    //--------------------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        stakingStartTimestamp = type(uint32).max;
    }

    /// @notice Based on the sources where they come from, the staking rewards are split into
    ///  - those from the execution layer: transaction fees and MEV
    ///  - those from the consensus layer: staking rewards for attesting the state of the chain, 
    ///    proposing a new block, or being selected in a validator sync committee
    ///  To receive the rewards from the execution layer, it should have 'receive()' function.
    receive() external payable {}

    /// @dev called once immediately after creating a new instance of a EtheriNode beacon proxy
    function initialize(address _etherFiNodesManager) external {
        require(phase == VALIDATOR_PHASE.NOT_INITIALIZED, "already initialized");
        require(etherFiNodesManager == address(0), "already initialized");
        require(_etherFiNodesManager != address(0), "No zero addresses");
        etherFiNodesManager = _etherFiNodesManager;

        _setPhase(VALIDATOR_PHASE.READY_FOR_DEPOSIT);
    }

    /// @dev record a succesfull deposit. The stake can still be cancelled until the validator is formally registered
    function recordStakingStart(bool _enableRestaking) external onlyEtherFiNodeManagerContract {
        require(stakingStartTimestamp == 0, "already recorded");
        stakingStartTimestamp = uint32(block.timestamp);

        if (_enableRestaking) {
            isRestakingEnabled = true;
            createEigenPod(); // NOOP if already exists
        }

        _setPhase(VALIDATOR_PHASE.STAKE_DEPOSITED);
    }

    /// @dev reset this validator safe so it can be used again in the withdrawal safe pool
    function resetWithdrawalSafe() external onlyEtherFiNodeManagerContract {
        require(phase == VALIDATOR_PHASE.CANCELLED || phase == VALIDATOR_PHASE.FULLY_WITHDRAWN, "withdrawal safe still in use");
        ipfsHashForEncryptedValidatorKey = "";
        exitRequestTimestamp = 0;
        exitTimestamp = 0;
        stakingStartTimestamp = 0;
        phase = VALIDATOR_PHASE.READY_FOR_DEPOSIT;
        restakingObservedExitBlock = 0;
        isRestakingEnabled = false;
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------------  SETTER   --------------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Set the validator phase
    /// @param _phase the new phase
    function setPhase(VALIDATOR_PHASE _phase) external onlyEtherFiNodeManagerContract {
        _setPhase(_phase);
    }

    function _setPhase(VALIDATOR_PHASE _phase) internal {
        _validatePhaseTransition(_phase);
        phase = _phase;
    }

    /// @notice Set the deposit data
    /// @param _ipfsHash the deposit data
    function setIpfsHashForEncryptedValidatorKey(
        string calldata _ipfsHash
    ) external onlyEtherFiNodeManagerContract {
        ipfsHashForEncryptedValidatorKey = _ipfsHash;
    }

    /// @notice Sets the exit request timestamp
    /// @dev Called when a TNFT holder submits an exit request
    function setExitRequestTimestamp() external onlyEtherFiNodeManagerContract {
        require(exitRequestTimestamp == 0, "Exit request was already sent.");
        exitRequestTimestamp = uint32(block.timestamp);
    }

    /// @notice Set the validators phase to exited
    /// @param _exitTimestamp the time the exit was complete
    function markExited(uint32 _exitTimestamp) external onlyEtherFiNodeManagerContract {
        require(_exitTimestamp <= block.timestamp, "Invalid exit timestamp");
        _validatePhaseTransition(VALIDATOR_PHASE.EXITED);
        phase = VALIDATOR_PHASE.EXITED;
        exitTimestamp = _exitTimestamp;

        if (isRestakingEnabled) {
            // eigenLayer bookeeping
            // we need to mark a block from which we know all beaconchain eth has been moved to the eigenPod
            // so that we can properly calculate exit payouts and ensure queued withdrawals have been resolved
            // (eigenLayer withdrawals are tied to blocknumber instead of timestamp)
            restakingObservedExitBlock = uint32(block.number);
            queueRestakedWithdrawal();
        }
    }

    /// @notice Set the validators phase to EVICTED
    function markEvicted() external onlyEtherFiNodeManagerContract {
        _validatePhaseTransition(VALIDATOR_PHASE.EVICTED);
        phase = VALIDATOR_PHASE.EVICTED;
        exitTimestamp = uint32(block.timestamp);
    }

    /// @dev unused by protocol. Simplifies test setup
    function setIsRestakingEnabled(bool _enabled) external onlyEtherFiNodeManagerContract {
        isRestakingEnabled = _enabled;
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  STATE-CHANGING FUNCTIONS  ------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Sends funds to the rewards manager
    /// @param _amount The value calculated in the etherfi node manager to send to the rewards manager
    function moveRewardsToManager(
        uint256 _amount
    ) external onlyEtherFiNodeManagerContract {
        (bool sent, ) = payable(etherFiNodesManager).call{value: _amount}("");
        require(sent, "Failed to send Ether");
    }

    /// @dev transfer funds from the withdrawal safe to the 4 associated parties (bNFT, tNFT, treasury, nodeOperator)
    function withdrawFunds(
        address _treasury,
        uint256 _treasuryAmount,
        address _operator,
        uint256 _operatorAmount,
        address _tnftHolder,
        uint256 _tnftAmount,
        address _bnftHolder,
        uint256 _bnftAmount
    ) external onlyEtherFiNodeManagerContract {

        // the recipients of the funds must be able to receive the fund
        // For example, if it is a smart contract, 
        // they should implement either receive() or fallback() properly
        // It's designed to prevent malicious actors from pausing the withdrawals
        bool sent;
        (sent, ) = payable(_operator).call{value: _operatorAmount, gas: 2300}("");
        _treasuryAmount += (!sent) ? _operatorAmount : 0;
        (sent, ) = payable(_bnftHolder).call{value: _bnftAmount, gas: 2300}("");
        _treasuryAmount += (!sent) ? _bnftAmount : 0;
        (sent, ) = payable(_tnftHolder).call{value: _tnftAmount, gas: 12000}(""); // to support 'receive' of LP
        _treasuryAmount += (!sent) ? _tnftAmount : 0;
        (sent, ) = _treasury.call{value: _treasuryAmount, gas: 2300}("");
        require(sent, "Failed to send Ether");
    }

    //--------------------------------------------------------------------------------------
    //--------------------------------------  GETTER  --------------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Fetch the accrued staking rewards payouts to (toNodeOperator, toTnft, toBnft, toTreasury)
    /// @param _balance the balance
    /// @param _splits the splits for the staking rewards
    /// @param _scale the scale = SUM(_splits)
    ///
    /// @return toNodeOperator  the payout to the Node Operator
    /// @return toTnft          the payout to the T-NFT holder
    /// @return toBnft          the payout to the B-NFT holder
    /// @return toTreasury      the payout to the Treasury
    function getStakingRewardsPayouts(
        uint256 _balance,
        IEtherFiNodesManager.RewardsSplit memory _splits,
        uint256 _scale
    )
        public
        view
        returns (
            uint256 toNodeOperator,
            uint256 toTnft,
            uint256 toBnft,
            uint256 toTreasury
        )
    {
        uint256 rewards;

        // If (Staking Principal + Staking Rewards >= 32 ether), the validator is running in a normal state
        // Else, the validator is getting slashed
        if (_balance >= 32 ether) {
            rewards = _balance - 32 ether;
        } else {
            // Without the Oracle, the exact staking rewards cannot be computed
            // Assume that there is no staking rewards.
            return (0, 0, 0, 0);
        }

        (
            uint256 operator,
            uint256 tnft,
            uint256 bnft,
            uint256 treasury
        ) = calculatePayouts(rewards, _splits, _scale);


        // If there was the exit request from the T-NFT holder,
        // but the B-NFT holder did not serve it by sending the voluntary exit message for more than 14 days
        // it incentivize's the node operator to do so instead
        // by
        //  - not sharing the staking rewards anymore with the node operator (see the below logic)
        //  - sharing the non-exit penalty with the node operator instead (~ 0.2 eth)
        if (exitRequestTimestamp > 0) {
            uint256 daysPassedSinceExitRequest = _getDaysPassedSince(
                exitRequestTimestamp,
                uint32(block.timestamp)
            );
            if (daysPassedSinceExitRequest >= 14) {
                treasury += operator;
                operator = 0;
            }
        }

        return (operator, tnft, bnft, treasury);
    }

    /// @notice Compute the non exit penalty for the b-nft holder
    /// @param _tNftExitRequestTimestamp the timestamp when the T-NFT holder asked the B-NFT holder to exit the node
    /// @param _bNftExitRequestTimestamp the timestamp when the B-NFT holder submitted the exit request to the beacon network
    function getNonExitPenalty(
        uint32 _tNftExitRequestTimestamp, 
        uint32 _bNftExitRequestTimestamp
    ) public view returns (uint256) {
        if (_tNftExitRequestTimestamp == 0) {
            return 0;
        }
        uint128 _principal = IEtherFiNodesManager(etherFiNodesManager).nonExitPenaltyPrincipal();
        uint64 _dailyPenalty = IEtherFiNodesManager(etherFiNodesManager).nonExitPenaltyDailyRate();
        uint256 daysElapsed = _getDaysPassedSince(
            _tNftExitRequestTimestamp,
            _bNftExitRequestTimestamp
        );

        // full penalty
        if (daysElapsed > 365) {
            return _principal;
        }

        uint256 remaining = _principal;
        while (daysElapsed > 0) {
            uint256 exponent = Math.min(7, daysElapsed);
            remaining = (remaining * (100 - uint256(_dailyPenalty)) ** exponent) / (100 ** exponent);
            daysElapsed -= Math.min(7, daysElapsed);
        }

        return _principal - remaining;
    }

    /// @notice total balance of this withdrawal safe in the execution layer split into its component parts. Includes restaked funds
    /// @dev funds can be split across
    ///   1. the withdrawal safe
    ///   2. the EigenPod (eigenLayer)
    ///   3. the delayedWithdrawalRouter (eigenLayer)
    function splitBalanceInExecutionLayer() public view returns (uint256 _withdrawalSafe, uint256 _eigenPod, uint256 _delayedWithdrawalRouter) {

        _withdrawalSafe = address(this).balance;

        if (isRestakingEnabled) {
            _eigenPod = eigenPod.balance;

            IDelayedWithdrawalRouter delayedWithdrawalRouter = IDelayedWithdrawalRouter(IEtherFiNodesManager(etherFiNodesManager).delayedWithdrawalRouter());
            IDelayedWithdrawalRouter.DelayedWithdrawal[] memory delayedWithdrawals = delayedWithdrawalRouter.getUserDelayedWithdrawals(address(this));
            for (uint256 x = 0; x < delayedWithdrawals.length; x++) {
                _delayedWithdrawalRouter += delayedWithdrawals[x].amount;
            }
        }
        return (_withdrawalSafe, _eigenPod, _delayedWithdrawalRouter);
    }

    /// @notice total balance (wei) of this safe currently in the execution layer. Includes restaked funds
    function totalBalanceInExecutionLayer() public view returns (uint256) {
        (uint256 _safe, uint256 _pod, uint256 _router) = splitBalanceInExecutionLayer();
        return _safe + _pod + _router;
    }

    /// @notice Given
    ///         - the current balance of the validator in Consensus Layer
    ///         - the current balance of the ether fi node,
    ///         Compute the TVLs for {node operator, t-nft holder, b-nft holder, treasury}
    /// @param _beaconBalance the balance of the validator in Consensus Layer
    /// @param _SRsplits the splits for the Staking Rewards
    /// @param _scale the scale
    ///
    /// @return toNodeOperator  the payout to the Node Operator
    /// @return toTnft          the payout to the T-NFT holder
    /// @return toBnft          `the payout to the B-NFT holder
    /// @return toTreasury      the payout to the Treasury
    function calculateTVL(
        uint256 _beaconBalance,
        IEtherFiNodesManager.RewardsSplit memory _SRsplits,
        uint256 _scale
    ) public view returns (uint256 toNodeOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury) {

        uint256 balance = _beaconBalance + totalBalanceInExecutionLayer();

        // Compute the payouts for the rewards = (staking rewards)
        // the protocol rewards must be paid off already in 'processNodeExit'
        uint256[] memory payouts = new uint256[](4); // (toNodeOperator, toTnft, toBnft, toTreasury)
        (payouts[0], payouts[1], payouts[2], payouts[3]) = getStakingRewardsPayouts(balance, _SRsplits, _scale);
        uint256 principal = balance - (payouts[0] + payouts[1] + payouts[2] + payouts[3]);

        // Compute the payouts for the principals to {B, T}-NFTs
        {
            (uint256 toBnftPrincipal, uint256 toTnftPrincipal) = calculatePrincipals(principal);
            payouts[1] += toTnftPrincipal;
            payouts[2] += toBnftPrincipal;
        }

        // Apply the non-exit penalty to the B-NFT
        {
            uint256 bnftNonExitPenalty = getNonExitPenalty(exitRequestTimestamp, exitTimestamp);
            uint256 appliedPenalty = Math.min(payouts[2], bnftNonExitPenalty);
            payouts[2] -= appliedPenalty;

            // While the NonExitPenalty keeps growing till 1 ether,
            //  the incentive to the node operator stops growing at 0.2 ether
            //  the rest goes to the treasury
            // - Cap the incentive to the operator under 0.2 ether.
            if (appliedPenalty > 0.2 ether) {
                payouts[0] += 0.2 ether;
                payouts[3] += appliedPenalty - 0.2 ether;
            } else {
                payouts[0] += appliedPenalty;
            }
        }

        require(payouts[0] + payouts[1] + payouts[2] + payouts[3] == balance, "Incorrect Amount");
        return (payouts[0], payouts[1], payouts[2], payouts[3]);
    }

    /// @notice Calculates values for payouts based on certain parameters
    /// @param _totalAmount The total amount to split
    /// @param _splits The splits for the staking rewards
    /// @param _scale The scale = SUM(_splits)
    ///
    /// @return toNodeOperator  the payout to the Node Operator
    /// @return toTnft          the payout to the T-NFT holder
    /// @return toBnft          the payout to the B-NFT holder
    /// @return toTreasury      the payout to the Treasury
    function calculatePayouts(
        uint256 _totalAmount,
        IEtherFiNodesManager.RewardsSplit memory _splits,
        uint256 _scale
    ) public pure returns (uint256 toNodeOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury) {
        require(
            _splits.nodeOperator +
                _splits.tnft +
                _splits.bnft +
                _splits.treasury ==
                _scale,
            "Incorrect Splits"
        );
        toNodeOperator = (_totalAmount * _splits.nodeOperator) / _scale;
        toTnft = (_totalAmount * _splits.tnft) / _scale;
        toBnft = (_totalAmount * _splits.bnft) / _scale;
        toTreasury = _totalAmount - (toBnft + toTnft + toNodeOperator);
        return (toNodeOperator, toTnft, toBnft, toTreasury);
    }

    /// @notice Calculate the principal for the T-NFT and B-NFT holders based on the balance
    /// @param _balance The balance of the node
    /// @return toBnftPrincipal the principal for the B-NFT holder
    /// @return toTnftPrincipal the principal for the T-NFT holder
    function calculatePrincipals(
        uint256 _balance
    ) public pure returns (uint256 , uint256) {
        require(_balance <= 32 ether, "the total principal must be lower than 32 ether");
        uint256 toBnftPrincipal;
        uint256 toTnftPrincipal;
        if (_balance > 31.5 ether) {
            // 31.5 ether < balance <= 32 ether
            toBnftPrincipal = _balance - 30 ether;
        } else if (_balance > 26 ether) {
            // 26 ether < balance <= 31.5 ether
            toBnftPrincipal = 1.5 ether;
        } else if (_balance > 25.5 ether) {
            // 25.5 ether < balance <= 26 ether
            toBnftPrincipal = 1.5 ether - (26 ether - _balance);
        } else if (_balance > 16 ether) {
            // 16 ether <= balance <= 25.5 ether
            toBnftPrincipal = 1 ether;
        } else {
            // balance < 16 ether
            // The T-NFT and B-NFT holder's principals decrease 
            // starting from 15 ether and 1 ether respectively.
            toBnftPrincipal = 625 * _balance / 10_000;
        }
        toTnftPrincipal = _balance - toBnftPrincipal;
        return (toBnftPrincipal, toTnftPrincipal);
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------  INTERNAL FUNCTIONS  ---------------------------------
    //--------------------------------------------------------------------------------------

    function _validatePhaseTransition(VALIDATOR_PHASE _newPhase) internal view returns (bool) {
        VALIDATOR_PHASE currentPhase = phase;
        bool pass = true;

        // Transition rules
        if (currentPhase == VALIDATOR_PHASE.NOT_INITIALIZED) {
            pass = (_newPhase == VALIDATOR_PHASE.READY_FOR_DEPOSIT);
        } else if (currentPhase == VALIDATOR_PHASE.READY_FOR_DEPOSIT) {
            pass = (_newPhase == VALIDATOR_PHASE.STAKE_DEPOSITED);
        } else if (currentPhase == VALIDATOR_PHASE.STAKE_DEPOSITED) {
            pass = (_newPhase == VALIDATOR_PHASE.LIVE || _newPhase == VALIDATOR_PHASE.CANCELLED || _newPhase == VALIDATOR_PHASE.WAITING_FOR_APPROVAL);
        } else if (currentPhase == VALIDATOR_PHASE.WAITING_FOR_APPROVAL) {
            pass = (_newPhase == VALIDATOR_PHASE.LIVE || _newPhase == VALIDATOR_PHASE.CANCELLED);
        } else if (currentPhase == VALIDATOR_PHASE.LIVE) {
            pass = (_newPhase == VALIDATOR_PHASE.EXITED || _newPhase == VALIDATOR_PHASE.BEING_SLASHED || _newPhase == VALIDATOR_PHASE.EVICTED);
        } else if (currentPhase == VALIDATOR_PHASE.BEING_SLASHED) {
            pass = (_newPhase == VALIDATOR_PHASE.EXITED);
        } else if (currentPhase == VALIDATOR_PHASE.EXITED) {
            pass = (_newPhase == VALIDATOR_PHASE.FULLY_WITHDRAWN);
        } else {
            pass = false;
        }

        require(pass, "Invalid phase transition");
        return pass;
    }

    function _getDaysPassedSince(
        uint32 _startTimestamp,
        uint32 _endTimestamp
    ) public pure returns (uint256) {
        if (_endTimestamp <= _startTimestamp) {
            return 0;
        }
        uint256 timeElapsed = _endTimestamp - _startTimestamp;
        return uint256(timeElapsed / (24 * 3_600));
    }

    /// @dev implementation address for beacon proxy.
    ///      https://docs.openzeppelin.com/contracts/3.x/api/proxy#beacon
    function implementation() external view returns (address) {
        bytes32 slot = bytes32(uint256(keccak256('eip1967.proxy.beacon')) - 1);
        address implementationVariable;
        assembly {
            implementationVariable := sload(slot)
        }

        IBeacon beacon = IBeacon(implementationVariable);
        return beacon.implementation();
    }


    //--------------------------------------------------------------------------------------
    //-----------------------------------  RESTAKING  --------------------------------------
    //--------------------------------------------------------------------------------------

    event EigenPodCreated(address indexed nodeAddress, address indexed podAddress);

    /// @notice create a new eigenPod associated with this withdrawal safe
    /// @dev to take advantage of restaking via eigenlayer the validator associated with this
    ///      withdrawal safe must set their withdrawalCredentials to point to this eigenPod
    ///      and not to the withdrawal safe itself
    function createEigenPod() public {
        if (eigenPod != address(0x0)) return; // already have pod

        IEigenPodManager eigenPodManager = IEigenPodManager(IEtherFiNodesManager(etherFiNodesManager).eigenPodManager());
        eigenPodManager.createPod();
        eigenPod = address(eigenPodManager.getPod(address(this)));
        emit EigenPodCreated(address(this), eigenPod);
    }

    // Check that all withdrawals initiated before the observed exit of the node have been claimed.
    // This check ignores withdrawals queued after the observed exit of a node to prevent a denial of serviec
    // in which an attacker keeps sending small amounts of eth to the eigenPod and queuing more withdrawals
    //
    // We don't need to worry about unbounded array length because anyone can call claimQueuedWithdrawals()
    // with a variable number of withdrawals to process if the queue ever became to large.
    // This function can go away once we have a proof based withdrawal system.
    function hasOutstandingEigenLayerWithdrawals() external view returns (bool) {

        IDelayedWithdrawalRouter delayedWithdrawalRouter = IDelayedWithdrawalRouter(IEtherFiNodesManager(etherFiNodesManager).delayedWithdrawalRouter());
        IDelayedWithdrawalRouter.DelayedWithdrawal[] memory unclaimedWithdrawals = delayedWithdrawalRouter.getUserDelayedWithdrawals(address(this));
        for (uint256 i = 0; i < unclaimedWithdrawals.length; i++) {
            if (unclaimedWithdrawals[i].blockCreated <= restakingObservedExitBlock) {
                // unclaimed withdrawal from before oracle observed exit
                return true;
            }
        }

        return false;
    }

    /// @notice Queue a withdrawal of the current balance of the eigenPod to this withdrawalSafe.
    /// @dev You must call claimQueuedWithdrawals at a later time once the time required by EigenLayer's
    ///     DelayedWithdrawalRouter has elapsed. Once queued the funds live in the DelayedWithdrawalRouter
    function queueRestakedWithdrawal() public {
        if (!isRestakingEnabled) return;

        // EigenLayer has not enabled "true" restaking yet so we use this temporary mechanism
        IEigenPod(eigenPod).withdrawBeforeRestaking();
    }

    /// @notice claim queued withdrawals from the EigenPod to this withdrawal safe.
    /// @param maxNumWithdrawals maximum number of queued withdrawals to claim in this tx.
    /// @dev usually you will want to call with "maxNumWithdrawals == unclaimedWithdrawals.length
    ///      but if this queue grows too large to process in your target tx you can pass less
    function claimQueuedWithdrawals(uint256 maxNumWithdrawals) public {
        if (!isRestakingEnabled) return;

        // only claim if we have active unclaimed withdrawals
        IDelayedWithdrawalRouter delayedWithdrawalRouter = IDelayedWithdrawalRouter(IEtherFiNodesManager(etherFiNodesManager).delayedWithdrawalRouter());
        if (delayedWithdrawalRouter.getUserDelayedWithdrawals(address(this)).length > 0) {
            delayedWithdrawalRouter.claimDelayedWithdrawals(address(this), maxNumWithdrawals);
        }
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  MODIFIERS  --------------------------------------
    //--------------------------------------------------------------------------------------

    modifier onlyEtherFiNodeManagerContract() {
        require(
            msg.sender == etherFiNodesManager,
            "Only EtherFiNodeManager Contract"
        );
        _;
    }

}
