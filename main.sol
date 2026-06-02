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
        address indexed submitter,
        bytes32 contentHash,
        uint32 engagementTier
    );
    event ScoreRecorded(bytes32 indexed postKey, uint32 score, bytes32 proofTag);
    event AnchorBound(bytes32 indexed postKey, bytes32 anchorDigest);
    event ConfigUpdated(bytes32 param, uint256 value);

    // ─── structs ─────────────────────────────────────────────────────────────

    struct TrackWindow {
        uint64  startsAt;
        uint64  endsAt;
        uint32  quota;
        uint32  postCount;
        bool    sealed;
        bytes32 merkleRoot;
    }

    struct PostRecord {
        uint64  windowId;
        address submitter;
        bytes32 contentHash;
        bytes32 anchorDigest;
        uint32  engagementTier;
        uint32  score;
        bool    scoreLocked;
    }

    struct OperatorEntry {
        bool    active;
        bytes32 label;
        uint64  registeredAt;
    }

    // ─── constants ───────────────────────────────────────────────────────────

    uint64  public constant SPT_MAX_WINDOWS      = 8_192;
    uint32  public constant SPT_GLOBAL_POST_CAP  = 2_000_000;
    uint32  public constant SPT_DEFAULT_QUOTA    = 5_000;
    uint32  public constant SPT_MAX_SCORE        = 10_000;
    uint16  public constant SPT_MAX_OPERATORS    = 512;
    uint64  public constant SPT_MIN_WINDOW_SPAN  = 300;       // 5 minutes
    uint64  public constant SPT_MAX_WINDOW_SPAN  = 2_592_000; // 30 days
    bytes32 public constant SPT_DOMAIN           = keccak256("SphereTrack.DOMAIN_V1");

