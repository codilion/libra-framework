/**
 * This is the general Voting module that can be used as part of a DAO Governance. Voting is designed to be used by
 * standalone governance modules, who has full control over the voting flow and is responsible for voting power
 * calculation and including proper capabilities when creating the proposal so resolution can go through.
 * On-chain governance of the Diem network also uses Voting.
 *
 * The voting flow:
 * 1. The Voting module can be deployed at a known address (e.g. 0x1 for Diem on-chain governance)
 * 2. The governance module, e.g. DiemGovernance, can be deployed later and define a GovernanceProposal resource type
 * that can also contain other information such as Capability resource for authorization.
 * 3. The governance module's owner can then register the ProposalType with Voting. This also hosts the proposal list
 * (forum) on the calling account.
 * 4. A proposer, through the governance module, can call Voting::create_proposal to create a proposal. create_proposal
 * cannot be called directly not through the governance module. A script hash of the resolution script that can later
 * be called to execute the proposal is required.
 * 5. A voter, through the governance module, can call Voting::vote on a proposal. vote requires passing a &ProposalType
 * and thus only the governance module that registers ProposalType can call vote.
 * 6. Once the proposal's expiration time has passed and more than the defined threshold has voted yes on the proposal,
 * anyone can call resolve which returns the content of the proposal (of type ProposalType) that can be used to execute.
 * 7. Only the resolution script with the same script hash specified in the proposal can call Voting::resolve as part of
 * the resolution process.
 */
module diem_framework::voting {
    use std::bcs::to_bytes;
    use std::error;
    use std::option::{Self, Option};
    use std::signer;
    use std::string::{String, utf8};
    use std::vector;

    use diem_std::from_bcs::to_u64;
    use diem_std::simple_map::{Self, SimpleMap};
    use diem_std::table::{Self, Table};
    use diem_std::type_info::{Self, TypeInfo};

    use diem_framework::account;
    use diem_framework::event::{Self, EventHandle};
    use diem_framework::timestamp;
    use diem_framework::transaction_context;
    use diem_std::from_bcs;



    friend diem_framework::diem_governance;

    /// Current script's execution hash does not match the specified proposal's
    const EPROPOSAL_EXECUTION_HASH_NOT_MATCHING: u64 = 1;
    /// Proposal cannot be resolved. Either voting duration has not passed, not enough votes, or fewer yes than no votes
    const EPROPOSAL_CANNOT_BE_RESOLVED: u64 = 2;
    /// Proposal cannot be resolved more than once
    const EPROPOSAL_ALREADY_RESOLVED: u64 = 3;
    /// Proposal cannot contain an empty execution script hash
    const EPROPOSAL_EMPTY_EXECUTION_HASH: u64 = 4;
    /// Proposal's voting period has already ended.
    const EPROPOSAL_VOTING_ALREADY_ENDED: u64 = 5;
    /// Voting forum has already been registered.
    const EVOTING_FORUM_ALREADY_REGISTERED: u64 = 6;
    /// Minimum vote threshold cannot be higher than early resolution threshold.
    const EINVALID_MIN_VOTE_THRESHOLD: u64 = 7;
    /// Resolution of a proposal cannot happen atomically in the same transaction as the last vote.
    const ERESOLUTION_CANNOT_BE_ATOMIC: u64 = 8;
    /// Cannot vote if the specified multi-step proposal is in execution.
    const EMULTI_STEP_PROPOSAL_IN_EXECUTION: u64 = 9;
    /// If a proposal is multi-step, we need to use `resolve_proposal_v2()` to resolve it.
    /// If we use `resolve()` to resolve a multi-step proposal, it will fail with EMULTI_STEP_PROPOSAL_CANNOT_USE_SINGLE_STEP_RESOLVE_FUNCTION.
    const EMULTI_STEP_PROPOSAL_CANNOT_USE_SINGLE_STEP_RESOLVE_FUNCTION: u64 = 10;
    /// If we call `resolve_proposal_v2()` to resolve a single-step proposal, the `next_execution_hash` parameter should be an empty vector.
    const ESINGLE_STEP_PROPOSAL_CANNOT_HAVE_NEXT_EXECUTION_HASH: u64 = 11;
    /// Cannot call `is_multi_step_proposal_in_execution()` on single-step proposals.
    const EPROPOSAL_IS_SINGLE_STEP: u64 = 12;


    /// Proposal is pending
    const EPROPOSAL_IS_PENDING: u64 = 13;
    /// Proposal is failed
    const EPROPOSAL_IS_FAILED: u64 = 14;


    /// ProposalStateEnum representing proposal state.
    const PROPOSAL_STATE_PENDING: u64 = 0;
    const PROPOSAL_STATE_SUCCEEDED: u64 = 1;
    /// Proposal has failed because either the min vote threshold is not met or majority voted no.
    const PROPOSAL_STATE_FAILED: u64 = 3;

    /// Key used to track the resolvable time in the proposal's metadata.
    const RESOLVABLE_TIME_METADATA_KEY: vector<u8> = b"RESOLVABLE_TIME_METADATA_KEY";
    /// Key used to track if the proposal is multi-step
    const IS_MULTI_STEP_PROPOSAL_KEY: vector<u8> = b"IS_MULTI_STEP_PROPOSAL_KEY";
    /// Key used to track if the multi-step proposal is in execution / resolving in progress.
    const IS_MULTI_STEP_PROPOSAL_IN_EXECUTION_KEY: vector<u8> = b"IS_MULTI_STEP_PROPOSAL_IN_EXECUTION";

    /// Extra metadata (e.g. description, code url) can be part of the ProposalType struct.
    struct Proposal<ProposalType: store> has store {
        /// Required. The address of the proposer.
        proposer: address,

        /// Required. Should contain enough information to execute later, for example the required capability.
        /// This is stored as an option so we can return it to governance when the proposal is resolved.
        execution_content: Option<ProposalType>,

        /// Optional. Value is serialized value of an attribute.
        /// Currently, we have three attributes that are used by the voting flow.
        /// 1. RESOLVABLE_TIME_METADATA_KEY: this is uesed to record the resolvable time to ensure that resolution has to be done non-atomically.
        /// 2. IS_MULTI_STEP_PROPOSAL_KEY: this is used to track if a proposal is single-step or multi-step.
        /// 3. IS_MULTI_STEP_PROPOSAL_IN_EXECUTION_KEY: this attribute only applies to multi-step proposals. A single-step proposal will not have
        /// this field in its metadata map. The value is used to indicate if a multi-step proposal is in execution. If yes, we will disable further
        /// voting for this multi-step proposal.
        metadata: SimpleMap<String, vector<u8>>,

        /// Timestamp when the proposal was created.
        creation_time_secs: u64,

        /// Required. The hash for the execution script module. Only the same exact script module can resolve this
        /// proposal.
        execution_hash: vector<u8>,

        /// A proposal is only resolved if expiration has passed and the number of votes is above threshold.
        min_vote_threshold: u128,
        expiration_secs: u64,

        /// Optional. Early resolution threshold. If specified, the proposal can be resolved early if the total
        /// number of yes or no votes passes this threshold.
        /// For example, this can be set to 50% of the total supply of the voting token, so if > 50% vote yes or no,
        /// the proposal can be resolved before expiration.
        early_resolution_vote_threshold: Option<u128>,

        /// Number of votes for each outcome.
        /// u128 since the voting power is already u64 and can add up to more than u64 can hold.
        yes_votes: u128,
        no_votes: u128,

        /// Whether the proposal has been resolved.
        is_resolved: bool,
        /// Resolution timestamp if the proposal has been resolved. 0 otherwise.
        resolution_time_secs: u64,
    }

    struct VotingForum<ProposalType: store> has key {
        /// Use Table for execution optimization instead of Vector for gas cost since Vector is read entirely into memory
        /// during execution while only relevant Table entries are.
        proposals: Table<u64, Proposal<ProposalType>>,
        events: VotingEvents,
        /// Unique identifier for a proposal. This allows for 2 * 10**19 proposals.
        next_proposal_id: u64,
    }

    struct VotingEvents has store {
        create_proposal_events: EventHandle<CreateProposalEvent>,
        register_forum_events: EventHandle<RegisterForumEvent>,
        resolve_proposal_events: EventHandle<ResolveProposal>,
        vote_events: EventHandle<VoteEvent>,
    }

    struct CreateProposalEvent has drop, store {
        proposal_id: u64,
        early_resolution_vote_threshold: Option<u128>,
        execution_hash: vector<u8>,
        expiration_secs: u64,
        metadata: SimpleMap<String, vector<u8>>,
        min_vote_threshold: u128,
    }

    struct RegisterForumEvent has drop, store {
        hosting_account: address,
        proposal_type_info: TypeInfo,
    }

    struct VoteEvent has drop, store {
        proposal_id: u64,
        num_votes: u64,
    }

    struct ResolveProposal has drop, store {
        proposal_id: u64,
        yes_votes: u128,
        no_votes: u128,
        resolved_early: bool
    }

    public(friend) fun register<ProposalType: store>(account: &signer) {
        let addr = signer::address_of(account);
        assert!(!exists<VotingForum<ProposalType>>(addr), error::already_exists(EVOTING_FORUM_ALREADY_REGISTERED));

        let voting_forum = VotingForum<ProposalType> {
            next_proposal_id: 0,
            proposals: table::new<u64, Proposal<ProposalType>>(),
            events: VotingEvents {
                create_proposal_events: account::new_event_handle<CreateProposalEvent>(account),
                register_forum_events: account::new_event_handle<RegisterForumEvent>(account),
                resolve_proposal_events: account::new_event_handle<ResolveProposal>(account),
                vote_events: account::new_event_handle<VoteEvent>(account),
            }
        };

        event::emit_event<RegisterForumEvent>(
            &mut voting_forum.events.register_forum_events,
            RegisterForumEvent {
                hosting_account: addr,
                proposal_type_info: type_info::type_of<ProposalType>(),
            },
        );

        move_to(account, voting_forum);
    }

    /// Create a single-step proposal with the given parameters
    ///
    /// @param voting_forum_address The forum's address where the proposal will be stored.
    /// @param execution_content The execution content that will be given back at resolution time. This can contain
    /// data such as a capability resource used to scope the execution.
    /// @param execution_hash The hash for the execution script module. Only the same exact script module can resolve
    /// this proposal.
    /// @param min_vote_threshold The minimum number of votes needed to consider this proposal successful.
    /// @param expiration_secs The time in seconds at which the proposal expires and can potentially be resolved.
    /// @param early_resolution_vote_threshold The vote threshold for early resolution of this proposal.
    /// @param metadata A simple_map that stores information about this proposal.
    /// @return The proposal id.
    public(friend) fun create_proposal<ProposalType: store>(
        proposer: address,
        voting_forum_address: address,
        execution_content: ProposalType,
        execution_hash: vector<u8>,
        min_vote_threshold: u128,
        expiration_secs: u64,
        early_resolution_vote_threshold: Option<u128>,
        metadata: SimpleMap<String, vector<u8>>,
    ): u64 acquires VotingForum {
        create_proposal_v2(
            proposer,
            voting_forum_address,
            execution_content,
            execution_hash,
            min_vote_threshold,
            expiration_secs,
            early_resolution_vote_threshold,
            metadata,
            false
        )
    }

    /// Create a single-step or a multi-step proposal with the given parameters
    ///
    /// @param voting_forum_address The forum's address where the proposal will be stored.
    /// @param execution_content The execution content that will be given back at resolution time. This can contain
    /// data such as a capability resource used to scope the execution.
    /// @param execution_hash The sha-256 hash for the execution script module. Only the same exact script module can
    /// resolve this proposal.
    /// @param min_vote_threshold The minimum number of votes needed to consider this proposal successful.
    /// @param expiration_secs The time in seconds at which the proposal expires and can potentially be resolved.
    /// @param early_resolution_vote_threshold The vote threshold for early resolution of this proposal.
    /// @param metadata A simple_map that stores information about this proposal.
    /// @param is_multi_step_proposal A bool value that indicates if the proposal is single-step or multi-step.
    /// @return The proposal id.
    public(friend) fun create_proposal_v2<ProposalType: store>(
        proposer: address,
        voting_forum_address: address,
        execution_content: ProposalType,
        execution_hash: vector<u8>,
        min_vote_threshold: u128,
        expiration_secs: u64,
        early_resolution_vote_threshold: Option<u128>,
        metadata: SimpleMap<String, vector<u8>>,
        is_multi_step_proposal: bool,
    ): u64 acquires VotingForum {
        if (option::is_some(&early_resolution_vote_threshold)) {
            assert!(
                min_vote_threshold <= *option::borrow(&early_resolution_vote_threshold),
                error::invalid_argument(EINVALID_MIN_VOTE_THRESHOLD),
            );
        };
        // Make sure the execution script's hash is not empty.
        assert!(vector::length(&execution_hash) > 0, error::invalid_argument(EPROPOSAL_EMPTY_EXECUTION_HASH));

        let voting_forum = borrow_global_mut<VotingForum<ProposalType>>(voting_forum_address);
        let proposal_id = voting_forum.next_proposal_id;
        voting_forum.next_proposal_id = voting_forum.next_proposal_id + 1;

        // Add a flag to indicate if this proposal is single-step or multi-step.
        simple_map::add(&mut metadata, utf8(IS_MULTI_STEP_PROPOSAL_KEY), to_bytes(&is_multi_step_proposal));

        let is_multi_step_in_execution_key = utf8(IS_MULTI_STEP_PROPOSAL_IN_EXECUTION_KEY);
        if (is_multi_step_proposal) {
            // If the given proposal is a multi-step proposal, we will add a flag to indicate if this multi-step proposal is in execution.
            // This value is by default false. We turn this value to true when we start executing the multi-step proposal. This value
            // will be used to disable further voting after we started executing the multi-step proposal.
            simple_map::add(&mut metadata, is_multi_step_in_execution_key, to_bytes(&false));
        // If the proposal is a single-step proposal, we check if the metadata passed by the client has the IS_MULTI_STEP_PROPOSAL_IN_EXECUTION_KEY key.
        // If they have the key, we will remove it, because a single-step proposal that doesn't need this key.
        } else if (simple_map::contains_key(&mut metadata, &is_multi_step_in_execution_key)) {
            simple_map::remove(&mut metadata, &is_multi_step_in_execution_key);
        };

        table::add(&mut voting_forum.proposals, proposal_id, Proposal {
            proposer,
            creation_time_secs: timestamp::now_seconds(),
            execution_content: option::some<ProposalType>(execution_content),
            execution_hash,
            metadata,
            min_vote_threshold,
            expiration_secs,
            early_resolution_vote_threshold,
            yes_votes: 0,
            no_votes: 0,
            is_resolved: false,
            resolution_time_secs: 0,
        });

        event::emit_event<CreateProposalEvent>(
            &mut voting_forum.events.create_proposal_events,
            CreateProposalEvent {
                proposal_id,
                early_resolution_vote_threshold,
                execution_hash,
                expiration_secs,
                metadata,
                min_vote_threshold,
            },
        );

        proposal_id
    }

    /// Vote on the given proposal.
    ///
    /// @param _proof Required so only the governance module that defines ProposalType can initiate voting.
    ///               This guarantees that voting eligibility and voting power are controlled by the right governance.
    /// @param voting_forum_address The address of the forum where the proposals are stored.
    /// @param proposal_id The proposal id.
    /// @param num_votes Number of votes. Voting power should be calculated by governance.
    /// @param should_pass Whether the votes are for yes or no.
    public(friend) fun vote<ProposalType: store>(
        _proof: &ProposalType,
        voting_forum_address: address,
        proposal_id: u64,
        num_votes: u64,
        should_pass: bool,
    ) acquires VotingForum {
        let voting_forum = borrow_global_mut<VotingForum<ProposalType>>(voting_forum_address);
        let proposal = table::borrow_mut(&mut voting_forum.proposals, proposal_id);
        // Voting might still be possible after the proposal has enough yes votes to be resolved early. This would only
        // lead to possible proposal resolution failure if the resolve early threshold is not definitive (e.g. < 50% + 1
        // of the total voting token's supply). In this case, more voting might actually still be desirable.
        // Governance mechanisms built on this voting module can apply additional rules on when voting is closed as
        // appropriate.
        assert!(!is_voting_period_over(proposal), error::invalid_state(EPROPOSAL_VOTING_ALREADY_ENDED));
        assert!(!proposal.is_resolved, error::invalid_state(EPROPOSAL_ALREADY_RESOLVED));
        // Assert this proposal is single-step, or if the proposal is multi-step, it is not in execution yet.
        assert!(!simple_map::contains_key(&proposal.metadata, &utf8(IS_MULTI_STEP_PROPOSAL_IN_EXECUTION_KEY))
                || *simple_map::borrow(&proposal.metadata, &utf8(IS_MULTI_STEP_PROPOSAL_IN_EXECUTION_KEY)) == to_bytes(&false),
                error::invalid_state(EMULTI_STEP_PROPOSAL_IN_EXECUTION));

        if (should_pass) {
            proposal.yes_votes = proposal.yes_votes + (num_votes as u128);
        } else {
            proposal.no_votes = proposal.no_votes + (num_votes as u128);
        };

        // Record the resolvable time to ensure that resolution has to be done non-atomically.
        let timestamp_secs_bytes = to_bytes(&timestamp::now_seconds());
        let key = utf8(RESOLVABLE_TIME_METADATA_KEY);
        if (simple_map::contains_key(&proposal.metadata, &key)) {
            *simple_map::borrow_mut(&mut proposal.metadata, &key) = timestamp_secs_bytes;
        } else {
            simple_map::add(&mut proposal.metadata, key, timestamp_secs_bytes);
        };

        event::emit_event<VoteEvent>(
            &mut voting_forum.events.vote_events,
            VoteEvent { proposal_id, num_votes },
        );
    }

    /// Common checks on if a proposal is resolvable, regardless if the proposal is single-step or multi-step.
    fun is_proposal_resolvable<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ) acquires VotingForum {
        let proposal_state = get_proposal_state<ProposalType>(voting_forum_address, proposal_id);
        assert!(proposal_state == PROPOSAL_STATE_SUCCEEDED, error::invalid_state(EPROPOSAL_CANNOT_BE_RESOLVED));

        let voting_forum = borrow_global_mut<VotingForum<ProposalType>>(voting_forum_address);
        let proposal = table::borrow_mut(&mut voting_forum.proposals, proposal_id);
        assert!(!proposal.is_resolved, error::invalid_state(EPROPOSAL_ALREADY_RESOLVED));

        // We need to make sure that the resolution is happening in
        // a separate transaction from the last vote to guard against any potential flashloan attacks.
        let resolvable_time = to_u64(*simple_map::borrow(&proposal.metadata, &utf8(RESOLVABLE_TIME_METADATA_KEY)));

        assert!(timestamp::now_seconds() > resolvable_time, error::invalid_state(ERESOLUTION_CANNOT_BE_ATOMIC));

        assert!(
            transaction_context::get_script_hash() == proposal.execution_hash,
            error::invalid_argument(EPROPOSAL_EXECUTION_HASH_NOT_MATCHING),
        );
    }


    //////// 0L ////////
    #[view]
    /// view function to see if the proposal could resolve, and if not return the error
    public fun check_resolvable_ex_hash<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ): (bool, u64) acquires VotingForum {
        let proposal_state = get_proposal_state<ProposalType>(voting_forum_address, proposal_id);
        if (proposal_state == PROPOSAL_STATE_PENDING) {
          return (false, EPROPOSAL_IS_PENDING)
        };
        if (proposal_state == PROPOSAL_STATE_FAILED) {
          return (false, EPROPOSAL_IS_FAILED)
        };

        let voting_forum = borrow_global_mut<VotingForum<ProposalType>>(voting_forum_address);
        let proposal = table::borrow_mut(&mut voting_forum.proposals, proposal_id);
        if(proposal.is_resolved) {
          return (false, EPROPOSAL_ALREADY_RESOLVED)
        };

        // We need to make sure that the resolution is happening in
        // a separate transaction from the last vote to guard against any potential flashloan attacks.
        let resolvable_time = to_u64(*simple_map::borrow(&proposal.metadata, &utf8(RESOLVABLE_TIME_METADATA_KEY)));

        if(timestamp::now_seconds() <= resolvable_time){
          return (false, ERESOLUTION_CANNOT_BE_ATOMIC)
        };

        // if(transaction_context::get_script_hash() != proposal.execution_hash) {
        //   return (false, EPROPOSAL_EXECUTION_HASH_NOT_MATCHING)
        // };

        (true, 0)
    }

    /// Resolve a single-step proposal with given id. Can only be done if there are at least as many votes as min required and
    /// there are more yes votes than no. If either of these conditions is not met, this will revert.
    ///
    /// @param voting_forum_address The address of the forum where the proposals are stored.
    /// @param proposal_id The proposal id.
    public(friend) fun resolve<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ): ProposalType acquires VotingForum {
        is_proposal_resolvable<ProposalType>(voting_forum_address, proposal_id);

        let voting_forum = borrow_global_mut<VotingForum<ProposalType>>(voting_forum_address);
        let proposal = table::borrow_mut(&mut voting_forum.proposals, proposal_id);

        // Assert that the specified proposal is not a multi-step proposal.
        let multi_step_key = utf8(IS_MULTI_STEP_PROPOSAL_KEY);
        let has_multi_step_key = simple_map::contains_key(&proposal.metadata, &multi_step_key);
        if (has_multi_step_key) {
            let is_multi_step_proposal = from_bcs::to_bool(*simple_map::borrow(&proposal.metadata, &multi_step_key));
            assert!(!is_multi_step_proposal, error::permission_denied(EMULTI_STEP_PROPOSAL_CANNOT_USE_SINGLE_STEP_RESOLVE_FUNCTION));
        };

        let resolved_early = can_be_resolved_early(proposal);
        proposal.is_resolved = true;
        proposal.resolution_time_secs = timestamp::now_seconds();

        event::emit_event<ResolveProposal>(
            &mut voting_forum.events.resolve_proposal_events,
            ResolveProposal {
                proposal_id,
                yes_votes: proposal.yes_votes,
                no_votes: proposal.no_votes,
                resolved_early,
            },
        );

        option::extract(&mut proposal.execution_content)
    }

    /// Resolve a single-step or a multi-step proposal with the given id.
    /// Can only be done if there are at least as many votes as min required and
    /// there are more yes votes than no. If either of these conditions is not met, this will revert.
    ///
    ///
    /// @param voting_forum_address The address of the forum where the proposals are stored.
    /// @param proposal_id The proposal id.
    /// @param next_execution_hash The next execution hash if the given proposal is multi-step.
    public(friend) fun resolve_proposal_v2<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
        next_execution_hash: vector<u8>,
    ) acquires VotingForum {
        is_proposal_resolvable<ProposalType>(voting_forum_address, proposal_id);

        let voting_forum = borrow_global_mut<VotingForum<ProposalType>>(voting_forum_address);
        let proposal = table::borrow_mut(&mut voting_forum.proposals, proposal_id);

        // Update the IS_MULTI_STEP_PROPOSAL_IN_EXECUTION_KEY key to indicate that the multi-step proposal is in execution.
        let multi_step_in_execution_key = utf8(IS_MULTI_STEP_PROPOSAL_IN_EXECUTION_KEY);
        if (simple_map::contains_key(&proposal.metadata, &multi_step_in_execution_key)) {
            let is_multi_step_proposal_in_execution_value = simple_map::borrow_mut(&mut proposal.metadata, &multi_step_in_execution_key);
            *is_multi_step_proposal_in_execution_value = to_bytes(&true);
        };

        let multi_step_key = utf8(IS_MULTI_STEP_PROPOSAL_KEY);
        let is_multi_step = simple_map::contains_key(&proposal.metadata, &multi_step_key) && from_bcs::to_bool(*simple_map::borrow(&proposal.metadata, &multi_step_key));
        let next_execution_hash_is_empty = vector::length(&next_execution_hash) == 0;

        // Assert that if this proposal is single-step, the `next_execution_hash` parameter is empty.
        assert!(is_multi_step || next_execution_hash_is_empty, error::invalid_argument(ESINGLE_STEP_PROPOSAL_CANNOT_HAVE_NEXT_EXECUTION_HASH));

        // If the `next_execution_hash` parameter is empty, it means that either
        // - this proposal is a single-step proposal, or
        // - this proposal is multi-step and we're currently resolving the last step in the multi-step proposal.
        // We can mark that this proposal is resolved.
        if (next_execution_hash_is_empty) {
            proposal.is_resolved = true;
            proposal.resolution_time_secs = timestamp::now_seconds();

            // Set the `IS_MULTI_STEP_PROPOSAL_IN_EXECUTION_KEY` value to false upon successful resolution of the last step of a multi-step proposal.
            if (is_multi_step) {
                let is_multi_step_proposal_in_execution_value = simple_map::borrow_mut(&mut proposal.metadata, &multi_step_in_execution_key);
                *is_multi_step_proposal_in_execution_value = to_bytes(&false);
            };
        } else {
            // If the current step is not the last step,
            // update the proposal's execution hash on-chain to the execution hash of the next step.
            proposal.execution_hash = next_execution_hash;
        };

        // For single-step proposals, we emit one `ResolveProposal` event per proposal.
        // For multi-step proposals, we emit one `ResolveProposal` event per step in the multi-step proposal. This means
        // that we emit multiple `ResolveProposal` events for the same multi-step proposal.
        let resolved_early = can_be_resolved_early(proposal);
        event::emit_event<ResolveProposal>(
            &mut voting_forum.events.resolve_proposal_events,
            ResolveProposal {
                proposal_id,
                yes_votes: proposal.yes_votes,
                no_votes: proposal.no_votes,
                resolved_early,
            },
        );
    }

    #[view]
    public fun is_voting_closed<ProposalType: store>(voting_forum_address: address, proposal_id: u64): bool acquires VotingForum {
        let voting_forum = borrow_global<VotingForum<ProposalType>>(voting_forum_address);
        let proposal = table::borrow(&voting_forum.proposals, proposal_id);
        can_be_resolved_early(proposal) || is_voting_period_over(proposal)
    }

    #[view]
    public fun is_early_close_possible<ProposalType: store>(voting_forum_address: address, proposal_id: u64): bool acquires VotingForum {
        let voting_forum = borrow_global<VotingForum<ProposalType>>(voting_forum_address);
        let proposal = table::borrow(&voting_forum.proposals, proposal_id);
        can_be_resolved_early(proposal)
    }

    /// Return true if the proposal has reached early resolution threshold (if specified).
    public(friend) fun can_be_resolved_early<ProposalType: store>(proposal: &Proposal<ProposalType>): bool {
        if (option::is_some(&proposal.early_resolution_vote_threshold)) {
            let early_resolution_threshold = *option::borrow(&proposal.early_resolution_vote_threshold);
            if (proposal.yes_votes >= early_resolution_threshold || proposal.no_votes >= early_resolution_threshold) {
                return true
            };
        };
        false
    }

    //////// 0L ////////
    #[view]
    /// Return true if the governance proposal has already been resolved.
    public fun can_resolve<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ): bool acquires VotingForum {
      is_proposal_resolvable<ProposalType>(voting_forum_address, proposal_id);
      true
    }

    #[view]
    public fun get_next_proposal_id<ProposalType: store>(voting_forum_address: address):u64 acquires VotingForum {
      let voting_forum = borrow_global<VotingForum<ProposalType>>(voting_forum_address);
      voting_forum.next_proposal_id
    }
    //////// end 0L ////////

    #[view]
    /// Return the state of the proposal with given id.
    ///
    /// @param voting_forum_address The address of the forum where the proposals are stored.
    /// @param proposal_id The proposal id.
    /// @return Proposal state as an enum value.
    public fun get_proposal_state<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ): u64 acquires VotingForum {
        if (is_voting_closed<ProposalType>(voting_forum_address, proposal_id)) {
            let voting_forum = borrow_global<VotingForum<ProposalType>>(voting_forum_address);
            let proposal = table::borrow(&voting_forum.proposals, proposal_id);
            let yes_votes = proposal.yes_votes;
            let no_votes = proposal.no_votes;

            if (yes_votes > no_votes && yes_votes + no_votes >= proposal.min_vote_threshold) {
                PROPOSAL_STATE_SUCCEEDED
            } else {
                PROPOSAL_STATE_FAILED
            }
        } else {
            PROPOSAL_STATE_PENDING
        }
    }

    #[view] //////// 0L ////////
    /// Return the proposal's expiration time.
    public fun get_votes<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ): (u128, u128) acquires VotingForum {
        let voting_forum = borrow_global_mut<VotingForum<ProposalType>>(voting_forum_address);
        let proposal = table::borrow_mut(&mut voting_forum.proposals, proposal_id);
        (proposal.yes_votes, proposal.no_votes)
    }

    #[view]
    /// Return the proposal's expiration time.
    public fun get_proposal_expiration_secs<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ): u64 acquires VotingForum {
        let voting_forum = borrow_global_mut<VotingForum<ProposalType>>(voting_forum_address);
        let proposal = table::borrow_mut(&mut voting_forum.proposals, proposal_id);
        proposal.expiration_secs
    }

    #[view]
    /// Return the proposal's execution hash.
    public fun get_execution_hash<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ): vector<u8> acquires VotingForum {
        let voting_forum = borrow_global_mut<VotingForum<ProposalType>>(voting_forum_address);
        let proposal = table::borrow_mut(&mut voting_forum.proposals, proposal_id);
        proposal.execution_hash
    }

    #[view]
    /// Return true if the governance proposal has already been resolved.
    public fun is_resolved<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ): bool acquires VotingForum {
        let voting_forum = borrow_global_mut<VotingForum<ProposalType>>(voting_forum_address);
        let proposal = table::borrow_mut(&mut voting_forum.proposals, proposal_id);
        proposal.is_resolved
    }

    #[view]
    /// Return true if the multi-step governance proposal is in execution.
    public fun is_multi_step_proposal_in_execution<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ): bool acquires VotingForum {
        let voting_forum = borrow_global_mut<VotingForum<ProposalType>>(voting_forum_address);
        let proposal = table::borrow_mut(&mut voting_forum.proposals, proposal_id);
        let is_multi_step_in_execution_key = utf8(IS_MULTI_STEP_PROPOSAL_IN_EXECUTION_KEY);
        assert!(simple_map::contains_key(&proposal.metadata, &is_multi_step_in_execution_key), error::invalid_argument(EPROPOSAL_IS_SINGLE_STEP));
        from_bcs::to_bool(*simple_map::borrow(&proposal.metadata, &is_multi_step_in_execution_key))
    }

    /// Return true if the voting period of the given proposal has already ended.
    fun is_voting_period_over<ProposalType: store>(proposal: &Proposal<ProposalType>): bool {
        timestamp::now_seconds() > proposal.expiration_secs
    }

    #[test_only]
    struct TestProposal has store {}

    #[test_only]
    const VOTING_DURATION_SECS: u64 = 100000;

    #[test_only]
    public fun create_test_proposal_generic(
        governance: &signer,
        early_resolution_threshold: Option<u128>,
        use_generic_create_proposal_function: bool,
    ): u64 acquires VotingForum {
        // Register voting forum and create a proposal.
        register<TestProposal>(governance);
        let governance_address = signer::address_of(governance);
        let proposal = TestProposal {};

        // This works because our Move unit test extensions mock out the execution hash to be [1].
        let execution_hash = vector::empty<u8>();
        vector::push_back(&mut execution_hash, 1);
        let metadata = simple_map::create<String, vector<u8>>();

        if (use_generic_create_proposal_function) {
            create_proposal_v2<TestProposal>(
                governance_address,
                governance_address,
                proposal,
                execution_hash,
                10,
                timestamp::now_seconds() + VOTING_DURATION_SECS,
                early_resolution_threshold,
                metadata,
                use_generic_create_proposal_function
            )
        } else {
            create_proposal<TestProposal>(
                governance_address,
                governance_address,
                proposal,
                execution_hash,
                10,
                timestamp::now_seconds() + VOTING_DURATION_SECS,
                early_resolution_threshold,
                metadata,
            )
        }
    }

    #[test_only]
    public fun resolve_proposal_for_test<ProposalType>(voting_forum_address: address, proposal_id: u64, is_multi_step: bool, finish_multi_step_execution: bool) acquires VotingForum {
        if (is_multi_step) {
            let execution_hash = vector::empty<u8>();
            vector::push_back(&mut execution_hash, 1);
            resolve_proposal_v2<TestProposal>(voting_forum_address, proposal_id, execution_hash);

            if (finish_multi_step_execution) {
                resolve_proposal_v2<TestProposal>(voting_forum_address, proposal_id, vector::empty<u8>());
            };
        } else {
            let proposal = resolve<TestProposal>(voting_forum_address, proposal_id);
            let TestProposal {} = proposal;
        };
    }

    #[test_only]
    public fun create_test_proposal(
        governance: &signer,
        early_resolution_threshold: Option<u128>,
    ): u64 acquires VotingForum {
        create_test_proposal_generic(governance, early_resolution_threshold, false)
    }

    #[test_only]
    public fun create_proposal_with_empty_execution_hash_should_fail_generic(governance: &signer, is_multi_step: bool) acquires VotingForum {
        account::create_account_for_test(@diem_framework);
        let governance_address = signer::address_of(governance);
        account::create_account_for_test(governance_address);
        register<TestProposal>(governance);
        let proposal = TestProposal {};

        // This should fail because execution hash is empty.
        if (is_multi_step) {
            create_proposal_v2<TestProposal>(
                governance_address,
                governance_address,
                proposal,
                b"",
                10,
                100000,
                option::none<u128>(),
                simple_map::create<String, vector<u8>>(),
                is_multi_step
            );
        } else {
            create_proposal<TestProposal>(
                governance_address,
                governance_address,
                proposal,
                b"",
                10,
                100000,
                option::none<u128>(),
                simple_map::create<String, vector<u8>>(),
            );
        };
    }

    #[test(governance = @0x123)]
    #[expected_failure(abort_code = 0x10004, location = Self)]
    public fun create_proposal_with_empty_execution_hash_should_fail(governance: &signer) acquires VotingForum {
        create_proposal_with_empty_execution_hash_should_fail_generic(governance, false);
    }

    #[test(governance = @0x123)]
    #[expected_failure(abort_code = 0x10004, location = Self)]
    public fun create_proposal_with_empty_execution_hash_should_fail_multi_step(governance: &signer) acquires VotingForum {
        create_proposal_with_empty_execution_hash_should_fail_generic(governance, true);
    }

    #[test_only]
    fun test_voting_passed_generic(diem_framework: &signer, governance: &signer, use_create_multi_step: bool, use_resolve_multi_step: bool) acquires VotingForum {
        account::create_account_for_test(@diem_framework);
        timestamp::set_time_has_started_for_testing(diem_framework);

        // Register voting forum and create a proposal.
        let governance_address = signer::address_of(governance);
        account::create_account_for_test(governance_address);
        let proposal_id = create_test_proposal_generic(governance, option::none<u128>(), use_create_multi_step);
        assert!(get_proposal_state<TestProposal>(governance_address, proposal_id) == PROPOSAL_STATE_PENDING, 0);

        // Vote.
        let proof = TestProposal {};
        vote<TestProposal>(&proof, governance_address, proposal_id, 10, true);
        let TestProposal {} = proof;

        // Resolve.
        timestamp::fast_forward_seconds(VOTING_DURATION_SECS + 1);
        assert!(get_proposal_state<TestProposal>(governance_address, proposal_id) == PROPOSAL_STATE_SUCCEEDED, 1);

        // This if statement is specifically for the test `test_voting_passed_single_step_can_use_generic_function()`.
        // It's testing when we have a single-step proposal that was created by the single-step `create_proposal()`,
        // we should be able to successfully resolve it using the generic `resolve_proposal_v2` function.
        if (!use_create_multi_step && use_resolve_multi_step) {
            resolve_proposal_v2<TestProposal>(governance_address, proposal_id, vector::empty<u8>());
        } else {
            resolve_proposal_for_test<TestProposal>(governance_address, proposal_id, use_resolve_multi_step, true);
        };
        let voting_forum = borrow_global<VotingForum<TestProposal>>(governance_address);
        assert!(table::borrow(&voting_forum.proposals, proposal_id).is_resolved, 2);
    }

    #[test(diem_framework = @diem_framework, governance = @0x123)]
    fun test_voting_passed(diem_framework: &signer, governance: &signer) acquires VotingForum {
        test_voting_passed_generic(diem_framework, governance, false, false);
    }

    #[test(diem_framework = @diem_framework, governance = @0x123)]
    fun test_voting_passed_multi_step(diem_framework: &signer, governance: &signer) acquires VotingForum {
        test_voting_passed_generic(diem_framework, governance, true, true);
    }

    #[test(diem_framework = @diem_framework, governance = @0x123)]
    #[expected_failure(abort_code=0x5000a, location = Self)]
    fun test_voting_passed_multi_step_cannot_use_single_step_resolve_function(diem_framework: &signer, governance: &signer) acquires VotingForum {
        test_voting_passed_generic(diem_framework, governance, true, false);
    }

    #[test(diem_framework = @diem_framework, governance = @0x123)]
    fun test_voting_passed_single_step_can_use_generic_function(diem_framework: &signer, governance: &signer) acquires VotingForum {
        test_voting_passed_generic(diem_framework, governance, false, true);
    }

    #[test_only]
    fun test_cannot_resolve_twice_generic(diem_framework: &signer, governance: &signer, is_multi_step: bool) acquires VotingForum {
        account::create_account_for_test(@diem_framework);
        timestamp::set_time_has_started_for_testing(diem_framework);

        // Register voting forum and create a proposal.
        let governance_address = signer::address_of(governance);
        account::create_account_for_test(governance_address);
        let proposal_id = create_test_proposal_generic(governance, option::none<u128>(), is_multi_step);
        assert!(get_proposal_state<TestProposal>(governance_address, proposal_id) == PROPOSAL_STATE_PENDING, 0);

        // Vote.
        let proof = TestProposal {};
        vote<TestProposal>(&proof, governance_address, proposal_id, 10, true);
        let TestProposal {} = proof;

        // Resolve.
        timestamp::fast_forward_seconds(VOTING_DURATION_SECS + 1);
        assert!(get_proposal_state<TestProposal>(governance_address, proposal_id) == PROPOSAL_STATE_SUCCEEDED, 1);
        resolve_proposal_for_test<TestProposal>(governance_address, proposal_id, is_multi_step, true);
        resolve_proposal_for_test<TestProposal>(governance_address, proposal_id, is_multi_step, true);
    }

    #[test(diem_framework = @diem_framework, governance = @0x123)]
    #[expected_failure(abort_code = 0x30003, location = Self)]
    fun test_cannot_resolve_twice(diem_framework: &signer, governance: &signer) acquires VotingForum {
        test_cannot_resolve_twice_generic(diem_framework, governance, false);
    }

    #[test(diem_framework = @diem_framework, governance = @0x123)]
    #[expected_failure(abort_code = 0x30003, location = Self)]
    fun test_cannot_resolve_twice_multi_step(diem_framework: &signer, governance: &signer) acquires VotingForum {
        test_cannot_resolve_twice_generic(diem_framework, governance, true);
    }

    #[test_only]
    fun test_voting_passed_early_generic(diem_framework: &signer, governance: &signer, is_multi_step: bool) acquires VotingForum {
        account::create_account_for_test(@diem_framework);
        timestamp::set_time_has_started_for_testing(diem_framework);

        // Register voting forum and create a proposal.
        let governance_address = signer::address_of(governance);
        account::create_account_for_test(governance_address);
        let proposal_id = create_test_proposal_generic(governance, option::some(100), is_multi_step);
        assert!(get_proposal_state<TestProposal>(governance_address, proposal_id) == PROPOSAL_STATE_PENDING, 0);

        // Assert that IS_MULTI_STEP_PROPOSAL_IN_EXECUTION_KEY has value `false` in proposal.metadata.
        if (is_multi_step) {
            assert!(!is_multi_step_proposal_in_execution<TestProposal>(governance_address, 0), 1);
        };

        // Vote.
        let proof = TestProposal {};
        vote<TestProposal>(&proof, governance_address, proposal_id, 100, true);
        vote<TestProposal>(&proof, governance_address, proposal_id, 10, false);
        let TestProposal {} = proof;

        // Resolve early. Need to increase timestamp as resolution cannot happen in the same tx.
        timestamp::fast_forward_seconds(1);
        assert!(get_proposal_state<TestProposal>(governance_address, proposal_id) == PROPOSAL_STATE_SUCCEEDED, 2);

        if (is_multi_step) {
            // Assert that IS_MULTI_STEP_PROPOSAL_IN_EXECUTION_KEY still has value `false` in proposal.metadata before execution.
            assert!(!is_multi_step_proposal_in_execution<TestProposal>(governance_address, 0), 3);
            resolve_proposal_for_test<TestProposal>(governance_address, proposal_id, is_multi_step, false);

            // Assert that the multi-step proposal is in execution but not resolved yet.
            assert!(is_multi_step_proposal_in_execution<TestProposal>(governance_address, 0), 4);
            let voting_forum = borrow_global_mut<VotingForum<TestProposal>>(governance_address);
            let proposal = table::borrow_mut(&mut voting_forum.proposals, proposal_id);
            assert!(!proposal.is_resolved, 5);
        };

        resolve_proposal_for_test<TestProposal>(governance_address, proposal_id, is_multi_step, true);
        let voting_forum = borrow_global_mut<VotingForum<TestProposal>>(governance_address);
        assert!(table::borrow(&voting_forum.proposals, proposal_id).is_resolved, 6);

        // Assert that the IS_MULTI_STEP_PROPOSAL_IN_EXECUTION_KEY value is set back to `false` upon successful resolution of this multi-step proposal.
        if (is_multi_step) {
            assert!(!is_multi_step_proposal_in_execution<TestProposal>(governance_address, 0), 7);
        };
    }

    #[test(diem_framework = @diem_framework, governance = @0x123)]
    fun test_voting_passed_early(diem_framework: &signer, governance: &signer) acquires VotingForum {
        test_voting_passed_early_generic(diem_framework, governance, false);
    }

    #[test(diem_framework = @diem_framework, governance = @0x123)]
    fun test_voting_passed_early_multi_step(diem_framework: &signer, governance: &signer) acquires VotingForum {
        test_voting_passed_early_generic(diem_framework, governance, true);
    }

    #[test_only]
    fun test_voting_passed_early_in_same_tx_should_fail_generic(
        diem_framework: &signer,
        governance: &signer,
        is_multi_step: bool
    ) acquires VotingForum {
        account::create_account_for_test(@diem_framework);
        timestamp::set_time_has_started_for_testing(diem_framework);
        let governance_address = signer::address_of(governance);
        account::create_account_for_test(governance_address);
        let proposal_id = create_test_proposal_generic(governance, option::some(100), is_multi_step);
        let proof = TestProposal {};
        vote<TestProposal>(&proof, governance_address, proposal_id, 40, true);
        vote<TestProposal>(&proof, governance_address, proposal_id, 60, true);
        let TestProposal {} = proof;

        // Resolving early should fail since timestamp hasn't changed since the last vote.
        resolve_proposal_for_test<TestProposal>(governance_address, proposal_id, is_multi_step, true);
    }

    #[test(diem_framework = @diem_framework, governance = @0x123)]
    #[expected_failure(abort_code = 0x30008, location = Self)]
    fun test_voting_passed_early_in_same_tx_should_fail(
        diem_framework: &signer,
        governance: &signer
    ) acquires VotingForum {
        test_voting_passed_early_in_same_tx_should_fail_generic(diem_framework, governance, false);
    }

    #[test(diem_framework = @diem_framework, governance = @0x123)]
    #[expected_failure(abort_code = 0x30008, location = Self)]
    fun test_voting_passed_early_in_same_tx_should_fail_multi_step(
        diem_framework: &signer,
        governance: &signer
    ) acquires VotingForum {
        test_voting_passed_early_in_same_tx_should_fail_generic(diem_framework, governance, true);
    }

    #[test_only]
    fun test_voting_failed_generic(diem_framework: &signer, governance: &signer, is_multi_step: bool) acquires VotingForum {
        account::create_account_for_test(@diem_framework);
        timestamp::set_time_has_started_for_testing(diem_framework);

        // Register voting forum and create a proposal.
        let governance_address = signer::address_of(governance);
        account::create_account_for_test(governance_address);
        let proposal_id = create_test_proposal_generic(governance, option::none<u128>(), is_multi_step);

        // Vote.
        let proof = TestProposal {};
        vote<TestProposal>(&proof, governance_address, proposal_id, 10, true);
        vote<TestProposal>(&proof, governance_address, proposal_id, 100, false);
        let TestProposal {} = proof;

        // Resolve.
        timestamp::fast_forward_seconds(VOTING_DURATION_SECS + 1);
        assert!(get_proposal_state<TestProposal>(governance_address, proposal_id) == PROPOSAL_STATE_FAILED, 1);
        resolve_proposal_for_test<TestProposal>(governance_address, proposal_id, is_multi_step, true);
    }

    #[test(diem_framework = @diem_framework, governance = @0x123)]
    #[expected_failure(abort_code = 0x30002, location = Self)]
    fun test_voting_failed(diem_framework: &signer, governance: &signer) acquires VotingForum {
        test_voting_failed_generic(diem_framework, governance, false);
    }

    #[test(diem_framework = @diem_framework, governance = @0x123)]
    #[expected_failure(abort_code = 0x30002, location = Self)]
    fun test_voting_failed_multi_step(diem_framework: &signer, governance: &signer) acquires VotingForum {
        test_voting_failed_generic(diem_framework, governance, true);
    }

    #[test(diem_framework = @diem_framework, governance = @0x123)]
    #[expected_failure(abort_code = 0x30005, location = Self)]
    fun test_cannot_vote_after_voting_period_is_over(
        diem_framework: signer,
        governance: signer
    ) acquires VotingForum {
        account::create_account_for_test(@diem_framework);
        timestamp::set_time_has_started_for_testing(&diem_framework);
        let governance_address = signer::address_of(&governance);
        account::create_account_for_test(governance_address);
        let proposal_id = create_test_proposal(&governance, option::none<u128>());
        // Voting period is over. Voting should now fail.
        timestamp::fast_forward_seconds(VOTING_DURATION_SECS + 1);
        let proof = TestProposal {};
        vote<TestProposal>(&proof, governance_address, proposal_id, 10, true);
        let TestProposal {} = proof;
    }

    #[test(diem_framework = @diem_framework, governance = @0x123)]
    #[expected_failure(abort_code=0x30009, location = Self)]
    fun test_cannot_vote_after_multi_step_proposal_starts_executing(
        diem_framework: signer,
        governance: signer
    ) acquires VotingForum {
        account::create_account_for_test(@diem_framework);
        timestamp::set_time_has_started_for_testing(&diem_framework);

        // Register voting forum and create a proposal.
        let governance_address = signer::address_of(&governance);
        account::create_account_for_test(governance_address);
        let proposal_id = create_test_proposal_generic(&governance, option::some(100), true);
        assert!(get_proposal_state<TestProposal>(governance_address, proposal_id) == PROPOSAL_STATE_PENDING, 0);

        // Vote.
        let proof = TestProposal {};
        vote<TestProposal>(&proof, governance_address, proposal_id, 100, true);

        // Resolve early.
        timestamp::fast_forward_seconds(1);
        assert!(get_proposal_state<TestProposal>(governance_address, proposal_id) == PROPOSAL_STATE_SUCCEEDED, 1);
        resolve_proposal_for_test<TestProposal>(governance_address, proposal_id, true, false);
        vote<TestProposal>(&proof, governance_address, proposal_id, 100, false);
        let TestProposal {} = proof;
    }

    #[test_only]
    fun test_voting_failed_early_generic(diem_framework: &signer, governance: &signer, is_multi_step: bool) acquires VotingForum {
        account::create_account_for_test(@diem_framework);
        timestamp::set_time_has_started_for_testing(diem_framework);

        // Register voting forum and create a proposal.
        let governance_address = signer::address_of(governance);
        account::create_account_for_test(governance_address);
        let proposal_id = create_test_proposal_generic(governance, option::some(100), is_multi_step);

        // Vote.
        let proof = TestProposal {};
        vote<TestProposal>(&proof, governance_address, proposal_id, 100, true);
        vote<TestProposal>(&proof, governance_address, proposal_id, 100, false);
        let TestProposal {} = proof;

        // Resolve.
        timestamp::fast_forward_seconds(VOTING_DURATION_SECS + 1);
        assert!(get_proposal_state<TestProposal>(governance_address, proposal_id) == PROPOSAL_STATE_FAILED, 1);
        resolve_proposal_for_test<TestProposal>(governance_address, proposal_id, is_multi_step, true);
    }

    #[test(diem_framework = @diem_framework, governance = @0x123)]
    #[expected_failure(abort_code = 0x30002, location = Self)]
    fun test_voting_failed_early(diem_framework: &signer, governance: &signer) acquires VotingForum {
        test_voting_failed_early_generic(diem_framework, governance, true);
    }

    #[test(diem_framework = @diem_framework, governance = @0x123)]
    #[expected_failure(abort_code = 0x30002, location = Self)]
    fun test_voting_failed_early_multi_step(diem_framework: &signer, governance: &signer) acquires VotingForum {
        test_voting_failed_early_generic(diem_framework, governance, false);
    }

    #[test_only]
    fun test_cannot_set_min_threshold_higher_than_early_resolution_generic(
        diem_framework: &signer,
        governance: &signer,
        is_multi_step: bool,
    ) acquires VotingForum {
        account::create_account_for_test(@diem_framework);
        timestamp::set_time_has_started_for_testing(diem_framework);
        account::create_account_for_test(signer::address_of(governance));
        // This should fail.
        create_test_proposal_generic(governance, option::some(5), is_multi_step);
    }

    #[test(diem_framework = @diem_framework, governance = @0x123)]
    #[expected_failure(abort_code = 0x10007, location = Self)]
    fun test_cannot_set_min_threshold_higher_than_early_resolution(
        diem_framework: &signer,
        governance: &signer,
    ) acquires VotingForum {
        test_cannot_set_min_threshold_higher_than_early_resolution_generic(diem_framework, governance, false);
    }

    #[test(diem_framework = @diem_framework, governance = @0x123)]
    #[expected_failure(abort_code = 0x10007, location = Self)]
    fun test_cannot_set_min_threshold_higher_than_early_resolution_multi_step(
        diem_framework: &signer,
        governance: &signer,
    ) acquires VotingForum {
        test_cannot_set_min_threshold_higher_than_early_resolution_generic(diem_framework, governance, true);
    }

    #[test(diem_framework = @diem_framework, governance = @0x123)]
    fun test_replace_execution_hash(diem_framework: &signer, governance: &signer) acquires VotingForum {
        account::create_account_for_test(@diem_framework);
        timestamp::set_time_has_started_for_testing(diem_framework);

        // Register voting forum and create a proposal.
        let governance_address = signer::address_of(governance);
        account::create_account_for_test(governance_address);
        let proposal_id = create_test_proposal_generic(governance, option::none<u128>(), true);
        assert!(get_proposal_state<TestProposal>(governance_address, proposal_id) == PROPOSAL_STATE_PENDING, 0);

        // Vote.
        let proof = TestProposal {};
        vote<TestProposal>(&proof, governance_address, proposal_id, 10, true);
        let TestProposal {} = proof;

        // Resolve.
        timestamp::fast_forward_seconds(VOTING_DURATION_SECS + 1);
        assert!(get_proposal_state<TestProposal>(governance_address, proposal_id) == PROPOSAL_STATE_SUCCEEDED, 1);

        resolve_proposal_v2<TestProposal>(governance_address, proposal_id, vector[10u8]);
        let voting_forum = borrow_global<VotingForum<TestProposal>>(governance_address);
        let proposal = table::borrow(&voting_forum.proposals, 0);
        assert!(proposal.execution_hash == vector[10u8], 2);
        assert!(!table::borrow(&voting_forum.proposals, proposal_id).is_resolved, 3);
    }
}
