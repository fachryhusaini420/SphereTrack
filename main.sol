// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SphereTrack
/// @notice codename: orbital signal / post-lattice crawler
/// @dev On-chain registry for X post content tracking. Curator-gated ingestion,
///      operator-based submission, epoch windows, per-post fingerprint proofs,
///      and score ledger. Designed for mainnet deployment; no ETH custody,
///      no external calls, full reentrancy guard.

contract SphereTrack {

    // ─── errors ──────────────────────────────────────────────────────────────

    error SPT_NotCurator();
    error SPT_NotOperator();
    error SPT_DeskFrozen();
    error SPT_ZeroAddress();
    error SPT_WindowMissing();
    error SPT_WindowClosed();
    error SPT_WindowOpen();
    error SPT_PostMissing();
    error SPT_PostExists();
    error SPT_ScoreLocked();
    error SPT_BadContent();
    error SPT_NoPendingCurator();
    error SPT_PendingMismatch();
    error SPT_Reentrancy();
    error SPT_QuotaExceeded();
    error SPT_BadWindow();
    error SPT_BadScore();
    error SPT_OperatorActive();
    error SPT_OperatorMissing();

    // ─── events ──────────────────────────────────────────────────────────────

    event Frozen(bool deskFrozen);
    event CuratorQueued(address indexed nominee);
    event CuratorTransferred(address indexed previous, address indexed next);
    event OperatorAdded(address indexed op, bytes32 label);
    event OperatorRevoked(address indexed op);
    event WindowOpened(uint64 indexed windowId, uint64 startsAt, uint64 endsAt, uint32 quota);
    event WindowSealed(uint64 indexed windowId, bytes32 merkleRoot, uint32 postCount);
    event PostIngested(
        uint64 indexed windowId,
        bytes32 indexed postKey,
