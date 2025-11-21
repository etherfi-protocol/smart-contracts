/*
┌─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Summarize looping methods (to prevent unexpected side effects from unverified functions)                              │
└─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
*/
methods {
    // Defines the implementation for the report hash generation function.
    function generateReportHash(IEtherFiOracle.OracleReport calldata) internal returns (bytes32) => to_bytes32(0x1234);
    function generateReportHash(IEtherFiOracle.OracleReport) external returns (bytes32) => to_bytes32(0x1234);
}

/*
┌─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Ghost & hooks: Count committee members and active members                                                             │
└─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
*/
// Ghost variable tracking the total number of registered committee members.
ghost mathint sumMembers {
    init_state axiom sumMembers == 0;
}

// Ghost variable tracking the total number of active/enabled committee members.
ghost mathint sumActive {
    init_state axiom sumActive == 0;
}

// Hook to update sumMembers when a member's registered status changes.
hook Sstore committeeMemberStates[KEY address user].registered bool newValue (bool oldValue) {
    if (newValue && !oldValue) {
        sumMembers = sumMembers + 1;
    } else if (!newValue && oldValue) {
        sumMembers = sumMembers - 1;
    }
}

// Hook to update sumActive when a member's enabled status changes.
hook Sstore committeeMemberStates[KEY address user].enabled bool newValue (bool oldValue) {
    if (newValue && !oldValue) {
        sumActive = sumActive + 1;
    } else if (!newValue && oldValue) {
        sumActive = sumActive - 1;
    }
}

/*
┌─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Invariants (Properties that must always hold true)                                                                    │
└─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
*/

// A committee member can only be enabled if they are first registered.
invariant testActiveCommitteeMembersEnabled(address _user)
    currentContract.committeeMemberStates[_user].enabled => currentContract.committeeMemberStates[_user].registered
        filtered {
            // Exclude administrative upgrade function from invariant check
            f -> f.selector != (sig:upgradeToAndCall(address,bytes).selector)
        }

// The contract's internal member count must match the ghost count.
invariant numMembersIsSumMembers()
    to_mathint(currentContract.numCommitteeMembers) == sumMembers
        filtered {
            f -> f.selector != (sig:upgradeToAndCall(address,bytes).selector)
        }

// The contract's internal active member count must match the ghost count.
invariant numActiveIsSumActive()
    to_mathint(currentContract.numActiveCommitteeMembers) == sumActive
        filtered {
            f -> f.selector != (sig:upgradeToAndCall(address,bytes).selector)
        }
    {
        // Require prerequisite invariant for the specific action 'addCommitteeMember'
        preserved addCommitteeMember(address _address) with (env e) {
            requireInvariant testActiveCommitteeMembersEnabled(_address);
        }
    }
    
// The number of active members must always be less than or equal to the total registered members.
// This is critical and should be proved once foundational invariants are established.
invariant invariantTotalMoreThanActive()
    currentContract.numActiveCommitteeMembers <= currentContract.numCommitteeMembers
        filtered {
            f -> f.selector != (sig:upgradeToAndCall(address,bytes).selector)
        }

// Consensus can only be reached if the report's support is greater than or equal to the quorum size.
invariant invariantConsensusNotReached(bytes32 _reportHash)
    currentContract.consensusStates[_reportHash].support < currentContract.quorumSize => !currentContract.consensusStates[_reportHash].consensusReached
        filtered {
            // Exclude functions that can change the quorum size or initialize the contract state
            f -> f.selector != (sig:upgradeToAndCall(address,bytes).selector) &&
            f.selector != (sig:initialize(uint32, uint32, uint32, uint32, uint32, uint32).selector) && 
            f.selector != (sig:setQuorumSize(uint32).selector) 
        }

/*
┌─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Rules (Properties that hold across one or more specific transactions)                                                 │
└─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
*/

// Rule that proves the contract logic correctly links consensusReached status 
// to the quorum size and support count, excluding functions that change quorum size.
rule ConsensusReachedOnlyQuorumSupport(method f, bytes32 _reportHash) filtered {
    f -> f.selector != (sig:upgradeToAndCall(address,bytes).selector) &&
    f.selector != (sig:initialize(uint32, uint32, uint32, uint32, uint32, uint32).selector) && 
    f.selector != (sig:setQuorumSize(uint32).selector) 
}
{
    env e;
    calldataarg args;
    // Assume invariant holds before the action (standard rule verification flow)
    
    // Action
    f(e,args);
    
    // Assert that the property holds after the action
    assert(currentContract.consensusStates[_reportHash].consensusReached <=> (currentContract.quorumSize <= currentContract.consensusStates[_reportHash].support));
