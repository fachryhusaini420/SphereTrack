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

    // ─── immutables ──────────────────────────────────────────────────────────

    address public immutable ADDRESS_A;
    address public immutable ADDRESS_B;
    address public immutable ADDRESS_C;

    // ─── state ───────────────────────────────────────────────────────────────

    address public curator;
    address public pendingCurator;
    bool    public deskFrozen;

    uint64  public windowCounter;
    uint32  public totalPostCount;
    uint16  public operatorCount;

    mapping(uint64  => TrackWindow)   public windows;
    mapping(bytes32 => PostRecord)    public posts;
    mapping(address => OperatorEntry) public operators;
    mapping(bytes32 => bool)          private _postKeyExists;
    mapping(bytes32 => bytes32[])     private _windowPostIndex;

    uint256 private _reentrancyFlag;

    // ─── modifiers ───────────────────────────────────────────────────────────

    modifier onlyCurator() {
        if (msg.sender != curator) revert SPT_NotCurator();
        _;
    }

    modifier onlyOperator() {
        if (!operators[msg.sender].active) revert SPT_NotOperator();
        _;
    }

    modifier whenLive() {
        if (deskFrozen) revert SPT_DeskFrozen();
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyFlag == 1) revert SPT_Reentrancy();
        _reentrancyFlag = 1;
        _;
        _reentrancyFlag = 0;
    }

    // ─── receive / fallback ──────────────────────────────────────────────────

    receive() external payable {
        emit ConfigUpdated(keccak256("receive.triggered"), msg.value);
        revert SPT_BadContent();
    }

    // ─── constructor ─────────────────────────────────────────────────────────

    /// @param _curator  Initial curator address
    /// @param _addrA    Immutable reference address A
    /// @param _addrB    Immutable reference address B
    /// @param _addrC    Immutable reference address C
    constructor(
        address _curator,
        address _addrA,
        address _addrB,
        address _addrC
    ) {
        if (_curator == address(0)) revert SPT_ZeroAddress();
        if (_addrA   == address(0)) revert SPT_ZeroAddress();
        if (_addrB   == address(0)) revert SPT_ZeroAddress();
        if (_addrC   == address(0)) revert SPT_ZeroAddress();

        curator    = _curator;
        ADDRESS_A  = _addrA;
        ADDRESS_B  = _addrB;
        ADDRESS_C  = _addrC;

        _reentrancyFlag = 0;
    }

    // ─── curator handoff ─────────────────────────────────────────────────────

    /// @notice Queue a new curator. Nominee must call acceptCurator().
    function queueCurator(address nominee) external onlyCurator {
        if (nominee == address(0)) revert SPT_ZeroAddress();
        pendingCurator = nominee;
        emit CuratorQueued(nominee);
    }

    /// @notice Accept the queued curator role.
    function acceptCurator() external {
        if (msg.sender != pendingCurator) revert SPT_PendingMismatch();
        if (pendingCurator == address(0)) revert SPT_NoPendingCurator();
        address prev   = curator;
        curator        = pendingCurator;
        pendingCurator = address(0);
        emit CuratorTransferred(prev, curator);
    }

    // ─── freeze control ──────────────────────────────────────────────────────

    /// @notice Toggle desk freeze. Only curator.
    function setDeskFrozen(bool freeze) external onlyCurator {
        deskFrozen = freeze;
        emit Frozen(freeze);
    }

    // ─── operator management ─────────────────────────────────────────────────

    /// @notice Register an operator with a label tag.
    function addOperator(address op, bytes32 label) external onlyCurator whenLive {
        if (op == address(0))          revert SPT_ZeroAddress();
        if (operators[op].active)      revert SPT_OperatorActive();
        if (operatorCount >= SPT_MAX_OPERATORS) revert SPT_QuotaExceeded();

        operators[op] = OperatorEntry({
            active:       true,
            label:        label,
            registeredAt: uint64(block.timestamp)
        });
        operatorCount++;
        emit OperatorAdded(op, label);
    }

    /// @notice Revoke an operator.
    function revokeOperator(address op) external onlyCurator {
        if (!operators[op].active) revert SPT_OperatorMissing();
        operators[op].active = false;
        operatorCount--;
        emit OperatorRevoked(op);
    }

    // ─── window management ───────────────────────────────────────────────────

    /// @notice Open a new tracking window.
    /// @param startsAt  Unix timestamp window opens
    /// @param endsAt    Unix timestamp window closes
    /// @param quota     Max posts ingested in this window (0 = default cap)
    function openWindow(
        uint64 startsAt,
        uint64 endsAt,
        uint32 quota
    ) external onlyCurator whenLive returns (uint64 windowId) {
        if (windowCounter >= SPT_MAX_WINDOWS) revert SPT_QuotaExceeded();
        if (endsAt <= startsAt)               revert SPT_BadWindow();
        uint64 span = endsAt - startsAt;
        if (span < SPT_MIN_WINDOW_SPAN)       revert SPT_BadWindow();
        if (span > SPT_MAX_WINDOW_SPAN)       revert SPT_BadWindow();

        uint32 effectiveQuota = quota == 0 ? SPT_DEFAULT_QUOTA : quota;
        windowId = ++windowCounter;

        windows[windowId] = TrackWindow({
            startsAt:   startsAt,
            endsAt:     endsAt,
            quota:      effectiveQuota,
            postCount:  0,
            sealed:     false,
            merkleRoot: bytes32(0)
        });

        emit WindowOpened(windowId, startsAt, endsAt, effectiveQuota);
    }

    /// @notice Seal a window and commit a merkle root of ingested posts.
    function sealWindow(uint64 windowId, bytes32 merkleRoot) external onlyCurator {
        TrackWindow storage w = _requireWindow(windowId);
        if (w.sealed)                    revert SPT_WindowClosed();
        if (block.timestamp < w.endsAt)  revert SPT_WindowOpen();

        w.sealed     = true;
        w.merkleRoot = merkleRoot;
        emit WindowSealed(windowId, merkleRoot, w.postCount);
    }

    // ─── post ingestion ──────────────────────────────────────────────────────

    /// @notice Ingest a tracked post into an open window.
    /// @param windowId       Target window
    /// @param postKey        Unique identifier (e.g. keccak256 of platform post ID)
    /// @param contentHash    Hash of post content snapshot
    /// @param engagementTier Tier classification (0–255 = low to viral)
    function ingestPost(
        uint64  windowId,
        bytes32 postKey,
        bytes32 contentHash,
        uint32  engagementTier
    ) external onlyOperator whenLive nonReentrant {
        if (postKey     == bytes32(0)) revert SPT_BadContent();
        if (contentHash == bytes32(0)) revert SPT_BadContent();
        if (_postKeyExists[postKey])   revert SPT_PostExists();
        if (totalPostCount >= SPT_GLOBAL_POST_CAP) revert SPT_QuotaExceeded();

        TrackWindow storage w = _requireWindow(windowId);
        if (w.sealed)                                   revert SPT_WindowClosed();
        if (block.timestamp < w.startsAt)               revert SPT_WindowMissing();
        if (block.timestamp > w.endsAt)                 revert SPT_WindowClosed();
        if (w.postCount >= w.quota)                     revert SPT_QuotaExceeded();

        posts[postKey] = PostRecord({
            windowId:       windowId,
            submitter:      msg.sender,
            contentHash:    contentHash,
            anchorDigest:   bytes32(0),
            engagementTier: engagementTier,
            score:          0,
            scoreLocked:    false
        });

        _postKeyExists[postKey] = true;
        w.postCount++;
        totalPostCount++;

        bytes32 idxKey = bytes32(uint256(windowId));
        _windowPostIndex[idxKey].push(postKey);

        emit PostIngested(windowId, postKey, msg.sender, contentHash, engagementTier);
    }

    // ─── score ledger ────────────────────────────────────────────────────────

    /// @notice Record a computed score for an ingested post.
    /// @param postKey  Target post key
    /// @param score    Score value (0–SPT_MAX_SCORE)
    /// @param proofTag Opaque proof or model tag hash
    function recordScore(
        bytes32 postKey,
        uint32  score,
        bytes32 proofTag
    ) external onlyOperator whenLive {
