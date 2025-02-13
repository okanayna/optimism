// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { IDisputeGame } from "./interfaces/IDisputeGame.sol";
import { IVersioned } from "./interfaces/IVersioned.sol";
import { IFaultDisputeGame } from "./interfaces/IFaultDisputeGame.sol";
import { IInitializable } from "./interfaces/IInitializable.sol";
import { IBondManager } from "./interfaces/IBondManager.sol";

import { Clone } from "../libraries/Clone.sol";
import { LibHashing } from "./lib/LibHashing.sol";
import { LibPosition } from "./lib/LibPosition.sol";
import { LibClock } from "./lib/LibClock.sol";

import "../libraries/DisputeTypes.sol";
import "../libraries/DisputeErrors.sol";

/**
 * @title FaultDisputeGame
 * @notice An implementation of the `IFaultDisputeGame` interface.
 */
contract FaultDisputeGame is IFaultDisputeGame, Clone {
    ////////////////////////////////////////////////////////////////
    //                         State Vars                         //
    ////////////////////////////////////////////////////////////////

    /**
     * @notice The current Semver of the FaultDisputeGame implementation.
     */
    string internal constant VERSION = "0.0.1";

    /**
     * @notice The max depth of the game.
     */
    uint256 internal constant MAX_GAME_DEPTH = 63;

    /**
     * @notice The duration of the game.
     * @dev TODO: Account for resolution buffer. (?)
     */
    Duration internal constant GAME_DURATION = Duration.wrap(7 days);

    /**
     * @notice The root claim's position is always at gindex 1.
     */
    Position internal constant ROOT_POSITION = Position.wrap(1);

    /**
     * @notice The starting timestamp of the game
     */
    Timestamp public gameStart;

    /**
     * @inheritdoc IDisputeGame
     */
    GameStatus public status;

    /**
     * @inheritdoc IDisputeGame
     */
    IBondManager public bondManager;

    /**
     * @notice An append-only array of all claims made during the dispute game.
     */
    ClaimData[] public claimData;

    /**
     * @notice An internal mapping to allow for constant-time lookups of existing claims.
     */
    mapping(ClaimHash => bool) internal claims;

    ////////////////////////////////////////////////////////////////
    //                       External Logic                       //
    ////////////////////////////////////////////////////////////////

    /**
     * @inheritdoc IFaultDisputeGame
     */
    function attack(uint256 _parentIndex, Claim _pivot) external payable {
        _move(_parentIndex, _pivot, true);
    }

    /**
     * @inheritdoc IFaultDisputeGame
     */
    function defend(uint256 _parentIndex, Claim _pivot) external payable {
        _move(_parentIndex, _pivot, false);
    }

    /**
     * @inheritdoc IFaultDisputeGame
     */
    function step(
        uint256 _prestateIndex,
        uint256 _parentIndex,
        bytes calldata _stateData,
        bytes calldata _proof
    ) external {
        // TODO - Call the VM to perform the execution step.
    }

    ////////////////////////////////////////////////////////////////
    //                       Internal Logic                       //
    ////////////////////////////////////////////////////////////////

    /**
     * @notice Internal move function, used by both `attack` and `defend`.
     * @param _challengeIndex The index of the claim being moved against.
     * @param _pivot The claim at the next logical position in the game.
     * @param _isAttack Whether or not the move is an attack or defense.
     */
    function _move(
        uint256 _challengeIndex,
        Claim _pivot,
        bool _isAttack
    ) internal {
        // Moves cannot be made unless the game is currently in progress.
        if (status != GameStatus.IN_PROGRESS) {
            revert GameNotInProgress();
        }

        // The only move that can be made against a root claim is an attack. This is because the
        // root claim commits to the entire state; Therefore, the only valid defense is to do
        // nothing if it is agreed with.
        if (_challengeIndex == 0 && !_isAttack) {
            revert CannotDefendRootClaim();
        }

        // Get the parent. If it does not exist, the call will revert with OOB.
        ClaimData memory parent = claimData[_challengeIndex];

        // Set the parent claim as countered.
        claimData[_challengeIndex].countered = true;

        // Compute the position that the claim commits to. Because the parent's position is already
        // known, we can compute the next position by moving left or right depending on whether
        // or not the move is an attack or defense.
        Position nextPosition = _isAttack ? parent.position.attack() : parent.position.defend();

        // At the leaf nodes of the game, the only option is to run a step to prove or disprove
        // the above claim. At this depth, the parent claim commits to the state after a single
        // instruction step.
        if (nextPosition.depth() >= MAX_GAME_DEPTH) {
            revert GameDepthExceeded();
        }

        // Fetch the grandparent clock, if it exists.
        // The grandparent clock should always exist unless the parent is the root claim.
        Clock grandparentClock;
        if (parent.parentIndex != type(uint32).max) {
            grandparentClock = claimData[parent.parentIndex].clock;
        }

        // Compute the duration of the next clock. This is done by adding the duration of the
        // grandparent claim to the difference between the current block timestamp and the
        // parent's clock timestamp.
        Duration nextDuration = Duration.wrap(
            uint64(
                // First, fetch the duration of the grandparent claim.
                Duration.unwrap(grandparentClock.duration()) +
                    // Second, add the difference between the current block timestamp and the
                    // parent's clock timestamp.
                    block.timestamp -
                    Timestamp.unwrap(parent.clock.timestamp())
            )
        );

        // Enforce the clock time rules. If the new clock duration is greater than half of the game
        // duration, then the move is invalid and cannot be made.
        if (Duration.unwrap(nextDuration) > Duration.unwrap(GAME_DURATION) >> 1) {
            revert ClockTimeExceeded();
        }

        // Construct the next clock with the new duration and the current block timestamp.
        Clock nextClock = LibClock.wrap(nextDuration, Timestamp.wrap(uint64(block.timestamp)));

        // Do not allow for a duplicate claim to be made.
        ClaimHash claimHash = _pivot.hashClaimPos(nextPosition);
        if (claims[claimHash]) {
            revert ClaimAlreadyExists();
        }
        claims[claimHash] = true;

        // Create the new claim.
        claimData.push(
            ClaimData({
                parentIndex: uint32(_challengeIndex),
                claim: _pivot,
                position: nextPosition,
                clock: nextClock,
                countered: false
            })
        );

        // Emit the appropriate event for the attack or defense.
        emit Move(_challengeIndex, _pivot, msg.sender);
    }

    ////////////////////////////////////////////////////////////////
    //                    `IDisputeGame` impl                     //
    ////////////////////////////////////////////////////////////////

    /**
     * @inheritdoc IDisputeGame
     */
    function gameType() public pure override returns (GameType gameType_) {
        gameType_ = GameTypes.FAULT;
    }

    /**
     * @inheritdoc IDisputeGame
     */
    function createdAt() external view returns (Timestamp createdAt_) {
        createdAt_ = gameStart;
    }

    /**
     * @inheritdoc IDisputeGame
     */
    function resolve() external returns (GameStatus status_) {
        if (status != GameStatus.IN_PROGRESS) {
            revert GameNotInProgress();
        }

        // Search for the left-most dangling non-bottom node
        // The most recent claim is always a dangling, non-bottom node so we start with that
        uint256 leftMostIndex = claimData.length - 1;
        uint256 leftMostTraceIndex = LibPosition.rightIndex(
            claimData[leftMostIndex].position,
            MAX_GAME_DEPTH
        );
        for (uint256 i = leftMostIndex; i < type(uint64).max; ) {
            // Fetch the claim at the current index.
            ClaimData storage claim = claimData[i];

            // Decrement the loop counter; If it underflows, we've reached the root
            // claim and can stop searching.
            unchecked {
                --i;
            }

            // If the claim is not a dangling node above the bottom of the tree,
            // we can skip over it. These nodes are not relevant to the game resolution.
            Position claimPos = claim.position;
            if (LibPosition.depth(claimPos) == MAX_GAME_DEPTH || claim.countered) {
                continue;
            }

            // If the claim is a dangling node, we can check if it is the left-most
            // dangling node we've come across so far. If it is, we can update the
            // left-most trace index.
            uint256 traceIndex = LibPosition.rightIndex(claimPos, MAX_GAME_DEPTH);
            if (traceIndex < leftMostTraceIndex) {
                leftMostTraceIndex = traceIndex;
                leftMostIndex = i + 1;
            }
        }

        // If the left-most dangling node is at an even depth, the defender wins.
        // Otherwise, the challenger wins and the root claim is deemed invalid.
        // slither-disable-next-line weak-prng
        if (LibPosition.depth(claimData[leftMostIndex].position) % 2 == 0) {
            status_ = GameStatus.DEFENDER_WINS;
        } else {
            status_ = GameStatus.CHALLENGER_WINS;
        }

        // Update the game status
        status = status_;
        emit Resolved(status_);
    }

    /**
     * @inheritdoc IDisputeGame
     */
    function rootClaim() public pure returns (Claim rootClaim_) {
        rootClaim_ = Claim.wrap(_getArgFixedBytes(0x00));
    }

    /**
     * @inheritdoc IDisputeGame
     */
    function extraData() public pure returns (bytes memory extraData_) {
        // The extra data starts at the second word within the cwia calldata.
        // TODO: What data do we need to pass along to this contract from the factory?
        //       Block hash, preimage data, etc.?
        extraData_ = _getArgDynBytes(0x20, 0x20);
    }

    /**
     * @inheritdoc IDisputeGame
     */
    function gameData()
        external
        pure
        returns (
            GameType gameType_,
            Claim rootClaim_,
            bytes memory extraData_
        )
    {
        gameType_ = gameType();
        rootClaim_ = rootClaim();
        extraData_ = extraData();
    }

    /**
     * @inheritdoc IInitializable
     */
    function initialize() external {
        // Set the game start
        gameStart = Timestamp.wrap(uint64(block.timestamp));
        // Set the game status
        status = GameStatus.IN_PROGRESS;

        // Set the root claim
        claimData.push(
            ClaimData({
                parentIndex: type(uint32).max,
                claim: rootClaim(),
                position: ROOT_POSITION,
                clock: LibClock.wrap(Duration.wrap(0), Timestamp.wrap(uint64(block.timestamp))),
                countered: false
            })
        );
    }

    /**
     * @inheritdoc IVersioned
     */
    function version() external pure override returns (string memory version_) {
        version_ = VERSION;
    }
}
