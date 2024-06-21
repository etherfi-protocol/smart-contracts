
/*
┌─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Summarize looping methods                                                                                           │
└─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
*/
methods {
    function generateReportHash(IEtherFiOracle.OracleReport calldata) internal returns (bytes32) => CONSTANT;
    function generateReportHash(IEtherFiOracle.OracleReport) external returns (bytes32) => CONSTANT;
}

/*
┌─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Ghost & hooks: count committee members                                                                              │
└─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
*/
ghost mathint sumMembers {
    init_state axiom sumMembers == 0;
}

ghost mathint sumActive {
    init_state axiom sumActive == 0;
}

hook Sstore committeeMemberStates[KEY address user].registered bool newValue (bool oldValue) {
    if (newValue && !oldValue) {
        sumMembers = sumMembers + 1;
    } else if (!newValue && oldValue) {
        sumMembers = sumMembers - 1;
    }
}

hook Sstore committeeMemberStates[KEY address user].enabled bool newValue (bool oldValue) {
    if (newValue && !oldValue) {
        sumActive = sumActive + 1;
    } else if (!newValue && oldValue) {
        sumActive = sumActive - 1;
    }
}
/*
┌─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Invariants                                                                                                          │
└─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
*/

//
invariant testActiveCommitteeMembersEnabled(address _user)
    currentContract.committeeMemberStates[_user].enabled => currentContract.committeeMemberStates[_user].registered
        filtered {
            f -> f.selector != (sig:upgradeToAndCall(address,bytes).selector) 
        }

invariant numMembersIsSumMembers()
    to_mathint(currentContract.numCommitteeMembers) == sumMembers
    filtered {
        f -> f.selector != (sig:upgradeToAndCall(address,bytes).selector) 
    }

invariant numActiveIsSumActive()
    to_mathint(currentContract.numActiveCommitteeMembers) == sumActive
    filtered {
        f -> f.selector != (sig:upgradeToAndCall(address,bytes).selector) 
    }
    {
        preserved addCommitteeMember(address _address) with (env e) {
            requireInvariant testActiveCommitteeMembersEnabled(_address);
        }
    }

// active members <= total members
invariant invariantTotalMoreThanActive(address _user) 
    currentContract.numActiveCommitteeMembers <= currentContract.numCommitteeMembers
        filtered {
            f -> f.selector != (sig:upgradeToAndCall(address,bytes).selector)
        }
    {
        preserved {
            requireInvariant testActiveCommitteeMembersEnabled(_user);
            requireInvariant numMembersIsSumMembers();
            requireInvariant numActiveIsSumActive();
        }
    }

//consensus can only be reach if report is agreed by quorum size
invariant invariantConsensusNotReached(bytes32 _reportHash) 
    currentContract.consensusStates[_reportHash].support < currentContract.quorumSize => !currentContract.consensusStates[_reportHash].consensusReached 
    filtered {
        f -> f.selector != (sig:upgradeToAndCall(address,bytes).selector) &&
        f.selector != (sig:initialize(uint32, uint32, uint32, uint32, uint32, uint32).selector) && 
        f.selector != (sig:setQuorumSize(uint32).selector) 
    }

    //consensus can only be reach if consenState.support == quorum size
invariant invariantConsensusReached(bytes32 _reportHash) 
    currentContract.consensusStates[_reportHash].consensusReached => (currentContract.quorumSize == currentContract.consensusStates[_reportHash].support)
    filtered {
        f -> f.selector != (sig:upgradeToAndCall(address,bytes).selector)
    }
/*
┌─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Rules                                                                                                               │
└─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
*/

//test the functionality of adding removing and managing committee members
rule testAddingCommitteeMembers(address _user)  {
    uint64 totalMembersPre = currentContract.numCommitteeMembers;
    env e;
    addCommitteeMember(e, _user);
    uint64 totalMembersPost = currentContract.numCommitteeMembers;
    assert (totalMembersPre+1 == to_mathint(totalMembersPost) &&
    currentContract.committeeMemberStates[_user].registered == true && 
    currentContract.committeeMemberStates[_user].enabled == true);
}

/// @title Check adding member increases committee size by 1
rule testRemovingCommitteeMembers(address _user)  {
    uint64 totalMembersPre = currentContract.numCommitteeMembers;
    env e;
    removeCommitteeMember(e, _user);
    uint64 totalMembersPost = currentContract.numCommitteeMembers;
    assert (to_mathint(totalMembersPre) == totalMembersPost+1 &&
    currentContract.committeeMemberStates[_user].registered == false && 
    currentContract.committeeMemberStates[_user].enabled == false);
}

//test that you cannot submit report twice
rule testMemberCannotSubmitTwice() {
    env e;
    address _user = e.msg.sender;
    IEtherFiOracle.OracleReport report;
    submitReport(e, report);
    submitReport@withrevert(e, report);
    assert lastReverted;
}


//When publishing a report the count only increases 1
rule testHashUpdatedCorrectly(IEtherFiOracle.OracleReport _report) {
    env e;
    bytes32 reportHash = generateReportHash(e, _report);
    uint32 preSupport = currentContract.consensusStates[reportHash].support;
    address _user = e.msg.sender;
    submitReport(e, _report);
    mathint postSupport = currentContract.consensusStates[reportHash].support;
    assert (postSupport == preSupport + 1) && postSupport < to_mathint(currentContract.quorumSize) => currentContract.consensusStates[reportHash].consensusReached;
}

//test that you cannot submit report if you are not a committee member
rule testNotCommitteeMemberCannotSubmitReport(IEtherFiOracle.OracleReport report) {
    env e;
    address _user = e.msg.sender;
    require (currentContract.committeeMemberStates[_user].registered == false || currentContract.committeeMemberStates[_user].enabled == false);
    submitReport@withrevert(e, report);
    assert lastReverted;
}


// if submitReport does not revert, then the committee member is enabled and registered 
rule testingPublishingReport(IEtherFiOracle.OracleReport report) {
    env e;
    submitReport(e, report);
    assert (currentContract.committeeMemberStates[e.msg.sender].enabled == true) && (currentContract.committeeMemberStates[e.msg.sender].registered == true);
}

/*notes from rules
-what happens if we decrease quorum size submit next report 
-logic is funky when we change quorum size
*/
