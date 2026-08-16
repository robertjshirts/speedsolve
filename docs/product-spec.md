# Speedsolve Product Specification

## Status

This document records the agreed product behavior for the Speedsolve rewrite. It
defines what the product must do without prescribing service boundaries,
databases, deployment topology, or other architectural implementation details.

## Product summary

Speedsolve is a competitive one-on-one speedcubing site with live video and
optional audio. Two players are matched using their recent online solve
performance, receive the same server-generated scramble, synchronize their
starts, complete their solves, and receive a recorded match result.

The site also includes an offline timer. All online and offline solves are
persisted so that users can review their history and, eventually, detailed
statistics.

The initial release supports only the 3x3 cube.

## Terminology

- **Online solve:** A solve performed as part of a competitive online match.
- **Offline solve:** A solve performed with the site's offline timer, including
  an online attempt converted to an offline solve after a match is abandoned.
- **Online average:** The recent online-solve average used for matchmaking.
- **Offline average:** An average calculated from offline solves.
- **Combined average:** An average calculated from both online and offline
  solves.
- **Raw time:** The measured solve duration before a penalty is applied.
- **Adjusted time:** The raw time plus any time penalty.
- **DNF:** A did-not-finish result.

The online average is a performance statistic, not a competitive rating. The
terms `rating` and `rank` should not be used for it.

## MVP scope

The MVP includes:

- Email and password accounts
- Password reset
- Optional TOTP two-factor authentication using authenticator-app QR setup and
  six-digit verification codes
- One-time 2FA recovery codes
- User profiles
- One unnamed public matchmaking queue
- Competitive 1v1 matches for 3x3
- Mandatory WebRTC video and optional WebRTC audio
- Server-generated, WCA-compliant random-state scrambles
- An offline timer
- Persistent online and offline solve history
- Self-reported `+2` and DNF penalties
- An audit trail for penalty corrections
- Reconnection behavior for a single disconnected player

## Matchmaking

### Queue membership

- The MVP has one unnamed queue.
- A user may be in the queue only once.
- A user may have only one active gameplay connection. Attempts to queue or
  play from another tab or device are rejected.
- Private matches and additional queues are not part of the MVP.

### Matchmaking value

Matchmaking uses the user's online average:

- It uses a rolling window of at most the 50 most recent online solves.
- The window size is configurable.
- The best 5% and worst 5% of results are excluded before calculating the
  average.
- The trimming percentage is configurable independently for each side.
- Self-reported penalties are included in the calculation.
- A user with no online solves has an infinite online average.
- Two users with infinite online averages are eligible to match immediately.
- A user with an infinite average and a user with a finite average become
  eligible only when matchmaking reaches its first-available stage.

DNFs are treated as worst results when trimming. If a DNF is excluded by the
worst-result trim, it does not affect the average. If a DNF remains in the set
used to calculate the average, its raw measured time plus four seconds is used
for matchmaking instead of making the entire average a DNF. The four-second
substitution is configurable and affects only the matchmaking calculation; the
persisted solve remains a DNF.

### Search expansion

The initial matchmaking algorithm expands its acceptable online-average range
as a user waits:

| Total time waiting | Eligible difference |
| --- | --- |
| 0-20 seconds | Within 2.5 seconds |
| 20-60 seconds | Within 5 seconds |
| 60-120 seconds | Within 10 seconds |
| 120 seconds or more | First available user |

All waiting periods and difference thresholds are configurable. The
matchmaking algorithm must be replaceable without changing the rest of the
match lifecycle.

## Match lifecycle

The normal match lifecycle is:

```text
QUEUED
  -> MATCHED
  -> SCRAMBLE
  -> COUNTDOWN
  -> SOLVING
  -> RESULTS
  -> COMPLETED
```

Abandonment may occur before completion. When a competitive match is
abandoned, both attempts continue as offline solves.

### Matched and scramble

- The server generates a WCA-compliant random-state 3x3 scramble.
- Both competitors always receive the same scramble.
- The scramble is revealed immediately after the two users are matched.
- There is no separate inspection phase. Players may inspect while viewing the
  scramble.
- A player uses the spacebar to indicate readiness to leave the scramble phase.
- Countdown begins after both players have entered the countdown phase.
- If the configured scramble-phase timeout is exceeded, the competitive match
  is abandoned and both players proceed with the attempt as an offline solve.
  This lets each player finish the physically scrambled cube before queueing
  again.

### Countdown

- During the countdown phase, both players are expected to hold the spacebar.
- Once both players are holding space, the server starts a three-second
  countdown.
- The countdown duration is configurable.
- If either player releases space before the countdown reaches zero, the
  countdown resets for both players.
- If the configurable countdown-phase timeout expires before both players hold
  space, the server starts the countdown automatically.
- When an automatically started countdown reaches zero, a player who is not
  holding space starts solving immediately.
- The server broadcasts countdown state to both clients. It may send individual
  countdown ticks or a start message containing the countdown duration; this is
  an implementation choice.

When the countdown reaches zero, the match enters the solving phase. A player
who is still holding space starts their timer when they release it. This gives
each player up to five seconds after zero to release space. If the player is
still holding space when that configurable grace period expires, their timer is
started automatically.

### Solving and timing validation

Each client:

1. Reports when its solve starts.
2. Measures the solve locally for a responsive timer display.
3. Reports when the solve ends and includes its measured duration.

The server independently records when it receives the player's start and end
events and calculates a server-observed duration. If the client-reported and
server-observed durations differ by five seconds or more, the solve is marked
DNF. This validation threshold is configurable.

The comparison is deliberately approximate because network delay affects the
server-observed duration. Client wall-clock timestamps are not assumed to be
synchronized with server time.

If neither player finishes before the configured maximum solve duration, each
unfinished player receives a DNF and the match proceeds to results. When one
player finishes first, the other player has up to 15 additional seconds to
finish. If that configurable finishing window expires, the remaining player
receives a DNF and the match proceeds to results.

### Results and penalties

Players may self-report a `+2` or DNF after a solve. They may later apply or
remove those penalties, but may never replace or edit the raw time.

- There is currently no deadline for correcting a penalty.
- Every application and removal of a penalty is retained in an audit trail.
- Corrected penalties affect online, offline, and combined averages as
  applicable.
- A DNF remains associated with its original raw measured time so that the
  matchmaking substitution rule can be calculated without changing the
  recorded result.

The winner is determined as follows:

1. A valid result beats a DNF.
2. Two DNFs produce a draw.
3. Otherwise, the lower adjusted time wins.
4. If adjusted times are equal and only one result has a `+2`, the result
   without the penalty wins.
5. If adjusted times and penalty statuses are equal, the match is a draw.

Examples of the last rule include equal raw times with no penalties and equal
raw times where both players have a `+2`.

## Disconnection and reconnection

- A disconnected player has five seconds to reconnect. This period is
  configurable.
- The connected player may continue solving while the opponent is disconnected.
- If the opponent reconnects within the grace period, the competitive match
  resumes.
- If the opponent does not reconnect in time, the competitive match is
  abandoned.
- After abandonment, both players may continue and save their attempts as
  offline solves.
- An abandoned match has no competitive winner, and its attempts do not affect
  the online average.

Recovery of a live match after a full backend restart or deployment is a future
goal. The MVP reconnection rule covers a single disconnected player while the
match remains live on the backend.

## Audio and video

- A WebRTC connection carrying video must be established before the scramble
  phase begins.
- Video is mandatory; audio is optional.
- Video is a social feature in the MVP, not an enforced anti-cheat mechanism.
- If media stops working after the match begins, the match continues without an
  automatic penalty or cancellation.
- Audio and video are not recorded in the MVP.

## Persistence and event history

All online and offline solves are persisted. Only eligible online solves are
used for the matchmaking online average.

Every meaningful match event and its relevant timestamps must be recorded,
including:

- Queue entry and exit
- Match creation
- Scramble generation and delivery
- Scramble acknowledgement and readiness
- Countdown readiness changes
- Countdown start, reset, and completion
- Forced countdown and forced solve starts
- Solve start and submission
- Client-reported and server-observed durations
- Timing-validation outcome
- Penalty selection and correction
- Disconnection and reconnection
- Match completion or abandonment
- Conversion of an online attempt into an offline solve

Audio and video content are excluded from this event history.

Historical events and original results are append-only from the product's
perspective. Corrections add audit records and update the effective result; they
do not overwrite the original raw time or erase prior penalty choices.

## Configuration

MVP configuration is supplied through deployment, environment, or configuration
files. It is not edited through a live administration interface.

| Setting | Initial value |
| --- | --- |
| Online-average window | 50 solves |
| Best-result trim | 5% |
| Worst-result trim | 5% |
| DNF matchmaking substitution | Raw time + 4 seconds |
| Initial matchmaking range | 2.5 seconds |
| First expansion time/range | 20 seconds / 5 seconds |
| Second expansion time/range | 60 seconds / 10 seconds |
| First-available time | 120 seconds |
| Countdown duration | 3 seconds |
| Post-countdown release grace | 5 seconds |
| Client/server duration discrepancy limit | 5 seconds |
| Reconnection grace | 5 seconds |
| Second-player finishing window | 15 seconds |
| Scramble-phase timeout | To be selected |
| Countdown-phase timeout | To be selected |
| Maximum solve duration | To be selected |

For a window size where a trim percentage produces a fractional result count,
the rounding rule remains to be selected before implementation.

## Technical and operational constraints

These are inputs to the later architecture design, not service-boundary
decisions:

- Backend: Python and FastAPI
- Frontend: Next.js in a separate repository
- Live media: WebRTC
- Matches must work when the backend runs multiple instances.
- Expected initial peak concurrency is fewer than 10 matches.
- The desired longer-term capacity is approximately 1,000 concurrent matches.
- The project is currently operated by one person.
- The initial hosting budget is approximately $20 per month.
- Infrastructure must be provisioned with Terraform.
- GitHub Actions must test changes before building, build deployable images, and
  deploy them.
- Declarative, reproducible infrastructure is preferred even where it creates
  more initial engineering work than the expected MVP traffic requires.

Scrambles may eventually be pre-generated into a buffer and replenished in the
background, but whether that buffer uses Redis or another mechanism is an
architecture decision.

## Explicitly deferred goals

The following are not part of the MVP:

- Additional puzzle sizes or events
- Multiple or named matchmaking queues
- Private matches
- Leaderboards, as the first planned stretch goal
- Reporting and blocking, as an early stretch goal separate from match flagging
- Opponent or match flagging
- Friends
- Direct challenges
- Google OAuth
- Spectators
- Tournaments
- Audio/video recording
- Automated video-based anti-cheat checks
- Moderation tooling
- A deadline or restriction policy for historical penalty corrections
- Alternative behavior for multiple tabs or devices
- Full live-match recovery after backend restarts or deployments
- Machine-learning analysis of user turns or completed matches

The event history should preserve useful product data, but the MVP must not be
designed around the distant machine-learning goal.

## Outstanding product decisions

The following values or rules must be selected before their features are
implemented:

- Rounding fractional trim counts for configurable average sizes and percentages
- Scramble-phase timeout duration
- Countdown-phase timeout duration
- Maximum solve duration
- Exact definition of which persisted offline solves contribute to the offline
  and combined averages, if filtering becomes necessary
