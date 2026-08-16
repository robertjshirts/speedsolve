# Speedsolve Architecture

## Status

This document defines the initial architecture for the Speedsolve rewrite. It
is based on the behavior in [product-spec.md](product-spec.md) and intentionally
separates logical domain boundaries from independently deployed services.

The selected architecture is a **modular monolith** with multiple runtime
processes. PostgreSQL is the authoritative store, while Redis provides
ephemeral coordination and acceleration. The design supports multiple backend
instances without requiring each business domain to become a network service.

## Architectural goals

The architecture must:

- Keep the match lifecycle correct under concurrent commands and multiple API
  instances.
- Record the complete application-level history of matches and solves.
- Recover authoritative state without depending on Redis contents.
- Allow the matchmaking algorithm to be replaced independently.
- Provide responsive WebSocket updates and WebRTC signaling.
- Support fewer than 10 initial concurrent matches without preventing growth
  toward approximately 1,000 concurrent matches.
- Remain operable by one person on an initial hosting budget of approximately
  $20 per month.
- Use Terraform for infrastructure and GitHub Actions for testing, image builds,
  and deployment.
- Preserve clean extraction points for components that later develop different
  scaling or runtime requirements.

The architecture does not optimize for the distant machine-learning goal. A
future analysis service may consume completed-match data without affecting the
current service boundaries.

## Architectural decisions

### Modular monolith

Accounts, users, solves, matchmaking, matches, and statistics are modules in
one Python application and one repository. They communicate through explicit
application interfaces rather than network APIs.

This avoids distributed transactions in the core lifecycle. Creating a match,
recording results, applying penalties, and updating matchmaking inputs all
cross several domains and benefit from a shared database transaction.

Module boundaries must still be enforced:

- Domain code must not import HTTP, WebSocket, PostgreSQL, or Redis adapters.
- One domain must not query another domain's tables directly.
- Cross-domain work goes through an application interface or a recorded domain
  event.
- Infrastructure implementations depend on domain interfaces, not the reverse.
- Public interfaces and event schemas are tested as contracts.

### Multiple processes from one backend codebase

The backend produces one primary container image with different entry points:

1. **API process:** HTTP endpoints, authenticated WebSockets, realtime delivery,
   and WebRTC signaling.
2. **Worker process:** deadlines, outbox publication, email delivery, scramble
   buffer replenishment, and repair jobs.
3. **Migration job:** runs database migrations once during deployment.

The scramble generator may use a separate Java-based image or executable
because the WCA's current official TNoodle generator requires Java. The
[WCA scramble documentation](https://www.worldcubeassociation.org/regulations/scrambles/)
currently lists TNoodle-WCA as its official generator.

### Single-node K3s for the initial deployment

The initial production environment runs on one higher-capacity VPS using K3s.
The target starting size is approximately two or more shared vCPUs, 8 GB of
memory, and SSD-backed local storage. The exact provider and instance type
remain deployment decisions.

K3s runs the API, worker, PostgreSQL, Redis, TNoodle jobs, and coturn on that
node. Its bundled ingress exposes HTTP and WebSocket traffic directly through
the VPS public address, avoiding a separate managed load balancer.

This is intentionally a single failure domain. Multiple pod replicas on the
node provide process-level recovery and rolling deployment behavior, but not
host-level high availability. Durable backups must therefore leave the VPS.

### PostgreSQL is authoritative

PostgreSQL owns durable application state, including:

- Accounts, credentials, sessions, and profiles
- Online and offline solves
- Penalty changes and audit records
- Matchmaking queue membership
- Current match and participant state
- Assigned scrambles
- Match events and timestamps
- Current deadlines
- Transactional outbox records

Redis may cache or index these records, but losing Redis must not corrupt or
permanently lose an active match, solve, or account.

### Redis coordinates and accelerates

Redis is used for:

- Matchmaking search indexes
- Cross-instance publish/subscribe
- WebSocket presence and connection leases
- Enforcing one active gameplay connection per account
- Deadline acceleration
- The unassigned scramble buffer
- Rate limiting
- Short-lived idempotency or deduplication data where durable deduplication is
  unnecessary
- A background-job queue if the selected worker library requires one

Redis is not the sole source of truth for match phase, results, assigned
scrambles, or active queue membership.

## System context

```text
                         HTTPS / WebSocket
┌───────────────┐       ┌───────────────────┐
│ Next.js client├──────►│ FastAPI instances │
└───────┬───────┘       └─────┬────────┬────┘
        │                     │        │
        │ WebRTC media        │        │
        ▼                     ▼        ▼
┌───────────────┐       ┌──────────┐ ┌──────────┐
│ Other player  │       │PostgreSQL│ │  Redis   │
└───────┬───────┘       └────┬─────┘ └────┬─────┘
        │                     │            │
        │ TURN when required  └──────┬─────┘
        ▼                            ▼
┌───────────────┐             ┌──────────────┐
│ STUN / TURN   │             │Worker process│
└───────────────┘             └──────┬───────┘
                                     ▼
                              ┌──────────────┐
                              │TNoodle runner│
                              └──────────────┘
```

The Next.js frontend lives in a separate repository. The backend repository
contains the FastAPI application, workers, migrations, container definitions,
documentation, and Terraform.

## Domain modules

### Accounts

Owns:

- Email and password authentication
- Password reset
- Opaque login sessions
- TOTP enrollment and verification
- One-time recovery codes
- Authentication-related security events

### Users

Owns public and private profile information. Authentication secrets remain in
the accounts module.

### Solves

Owns:

- Raw solve records
- Online and offline classification
- Effective penalties
- Append-only penalty audit history
- Online, offline, and combined average calculations
- Materialized user statistics used by matchmaking

### Matchmaking

Owns:

- Queue entry and exit
- The one-active-queue-entry invariant
- Search expansion over waiting time
- Candidate selection
- Atomic candidate claiming
- Creation of a match through the matches application interface

Candidate selection depends on an interface such as
`MatchmakingMetricProvider`. The solves module implements that interface. The
bucket algorithm is one implementation of a `MatchmakingStrategy`, allowing it
to be replaced without changing queue or match behavior.

### Matches

Owns:

- The match aggregate and state machine
- Per-participant state
- State transitions and validation
- Match deadlines
- Timing validation
- Disconnect and abandonment behavior
- Winner selection
- Match events and current-state snapshots

### Scrambles

Owns:

- The scramble-provider interface
- Buffer replenishment
- Atomic assignment of a scramble to a match
- Durable storage of assigned scrambles

### Realtime

Owns:

- Authenticated WebSocket connections
- Connection presence and leases
- Command decoding and validation
- State snapshots and ordered event delivery
- Cross-instance message fan-out

It does not own match rules. It translates client messages into application
commands and translates committed events into client messages.

### Media signaling

Owns WebRTC offer, answer, and ICE-candidate exchange. It records meaningful
connection-state changes but does not persist SDP bodies, ICE candidates, or
audio/video content as match history.

### Notifications

Owns password-reset email and future transactional notifications. Delivery is
performed asynchronously by the worker.

## Match aggregate and state machine

The match is the consistency boundary. It contains global phase and independent
participant state because participants may become ready, start, finish,
disconnect, or reconnect at different times.

```text
Match
├── id
├── version
├── global phase
├── assigned scramble
├── active phase deadline
├── first-finisher deadline
├── participant A
│   ├── connection state
│   ├── readiness and hold state
│   ├── solve start and finish
│   ├── client and server durations
│   └── result and penalty
└── participant B
    └── equivalent state
```

The state machine accepts commands and emits facts. Representative commands
include:

```text
AcknowledgeScramble
EnterCountdown
SetCountdownHold
StartSolve
FinishSolve
ApplyPenalty
RemovePenalty
DisconnectParticipant
ReconnectParticipant
ExpireDeadline
```

Representative events include:

```text
MatchCreated
ScrambleAssigned
ScrambleAcknowledged
CountdownStarted
CountdownReset
SolveStarted
SolveForcedStarted
SolveSubmitted
PenaltyApplied
PenaltyRemoved
ParticipantDisconnected
ParticipantReconnected
MatchAbandoned
MatchCompleted
```

The product specification remains authoritative for allowed transitions and
timing behavior.

### Command transaction

Every state-changing match command follows the same transaction boundary:

1. Begin a PostgreSQL transaction.
2. Lock the match row or perform an expected-version comparison.
3. Check the command's durable idempotency key.
4. Rehydrate the required aggregate state from the current snapshot.
5. Validate and execute the command.
6. Append generated events with consecutive match sequence numbers.
7. Update the current match and participant snapshots.
8. Insert, replace, or clear durable deadlines.
9. Add realtime notifications to the transactional outbox.
10. Commit.

The state version prevents two API instances from accepting conflicting
transitions. A unique constraint on the match and command ID prevents retries
from applying a command twice.

### Snapshot plus event history

The system does not require full event sourcing. Current tables support normal
reads and command handling. Append-only match events provide:

- Auditability
- Historical statistics
- Debugging of timing and reconnection problems
- Rebuilding disposable projections
- A future integration feed

Correcting a penalty updates the effective result while appending an audit
record. It never modifies the original raw time or deletes prior choices.

## Matchmaking consistency

PostgreSQL stores authoritative queue entries. A database constraint prevents
an account from having more than one active entry.

Redis maintains a disposable search index containing the queue-entry ID,
online-average value, and enqueue time. The index can be rebuilt from active
PostgreSQL entries.

A matchmaker worker performs candidate selection through the configured
strategy. Once it finds candidates, it opens a PostgreSQL transaction that:

1. Locks both active queue entries.
2. Verifies both users are still eligible.
3. Creates the match and participants.
4. Marks both queue entries as matched.
5. Appends the corresponding events and outbox records.

Only after commit are the entries removed from the Redis index. Failed or
duplicated removals are harmless, and a reconciliation job repairs drift.

The online-average value used for a queue attempt is captured when the user
enters the queue. Historical penalty corrections update future queue attempts
but do not reorder a user already waiting.

## Realtime messaging

### WebSocket connections

API instances maintain their own local connection objects. Redis stores a
leased presence record mapping an account and active gameplay session to its
owning API instance. A second gameplay connection is rejected.

The lease has a short TTL and is renewed while the socket is healthy. Cleanup
must not depend solely on receiving a graceful disconnect.

### Cross-instance delivery

Committed outbox records are published to Redis channels by a worker. Every API
instance subscribes to the channels required by its local connections and
forwards messages to the appropriate clients.

Redis Pub/Sub delivery is allowed to be transient because:

- PostgreSQL already contains the committed state.
- Every match event carries a monotonically increasing sequence number.
- Clients detect gaps and request a fresh snapshot.
- Reconnecting clients always receive a snapshot before new incremental events.

If a later consumer requires durable message delivery, it should consume the
PostgreSQL outbox or a durable stream rather than relying on Pub/Sub.

### Client commands

Every state-changing client command contains:

- A unique command ID
- Match ID
- Participant or session identity
- The client's last observed match version
- Command-specific data

The server may reject a stale command and return the latest snapshot. Repeated
delivery of the same command ID returns the already committed outcome.

## Deadlines and timers

Backend processes must not model durable deadlines using an in-memory sleep.
Every active deadline is stored as an absolute timestamp in PostgreSQL.

A worker repeatedly claims expired deadlines using transactional row locking,
then sends an idempotent `ExpireDeadline` command through the same state-machine
path used by client commands. Multiple workers may run safely.

A Redis sorted set may index upcoming deadlines to reduce database polling.
This index is disposable and can be rebuilt from PostgreSQL after failure.

This mechanism covers:

- Scramble-phase timeout
- Automatic countdown start
- Forced solve start after the release grace period
- Reconnection expiration
- Second-player finishing window
- Maximum solve duration

Clients render countdowns and timers locally for responsiveness, but client
animations never perform authoritative state transitions.

## Scramble generation

Scramble generation is accessed through a `ScrambleProvider` interface. The
initial production implementation uses WCA-compliant random-state 3x3
scrambles generated with the selected TNoodle integration.

The worker keeps a target number of unused scrambles available:

1. It detects that the Redis scramble buffer is below its configured target.
2. It invokes the TNoodle runner to generate a batch.
3. It validates and inserts the batch into the buffer.
4. Match creation atomically removes one scramble.
5. The assigned scramble is persisted with the match before it is delivered.

Unassigned buffered scrambles are disposable. Assigned scrambles are durable.
If the buffer is empty, matchmaking must either synchronously obtain a scramble
or wait for replenishment; it must never create a match without a durable
scramble assignment.

The TNoodle version and generated scramble metadata must be recorded so the
source of a historical scramble can be identified.

## WebRTC and media

FastAPI provides authenticated WebRTC signaling over the realtime connection.
Media flows directly between players when possible:

```text
Player A <──────── peer-to-peer video/audio ────────> Player B
Player A <──── TURN-relayed video/audio if needed ──> Player B
```

The system requires:

- A STUN service for connectivity discovery
- A TURN service for networks that cannot establish a direct connection
- ICE server credentials delivered securely to authenticated clients
- A signaling session bound to the match and authenticated participants

Both clients must report an established WebRTC connection before the scramble
phase begins. Loss of media after that point is recorded but does not stop the
MVP match.

The API does not proxy or record media. TURN bandwidth, rather than ordinary
API traffic, is expected to be the primary cost risk at higher concurrency.
Capacity planning must track the percentage of sessions requiring relay and
their average bitrate.

## Authentication and security

### Sessions

The initial design uses opaque server-side sessions delivered through secure,
HTTP-only cookies. This supports immediate revocation, password-reset security,
TOTP changes, and enforcement of active gameplay sessions without depending on
long-lived self-contained tokens.

Durable session records are stored in PostgreSQL. Redis may cache active
session lookups and gameplay connection leases.

### Credentials and recovery

- Passwords are hashed with Argon2id using parameters stored with each hash.
- TOTP secrets are encrypted because verification requires the original secret.
- Recovery codes are independently hashed and invalidated atomically when used.
- Password-reset tokens are random, expiring, single-use, and stored as hashes.
- Security-sensitive changes revoke relevant existing sessions.
- Secret encryption keys and email credentials are supplied by the deployment
  environment and are never committed to the repository or rendered into
  ordinary Terraform output.

The frontend and backend should be deployed under related origins where
possible so secure cookie and CSRF behavior remain understandable. State-
changing HTTP endpoints require CSRF protection in addition to authentication.
WebSocket origins and the authenticated session must be validated during the
upgrade request.

## Data model outline

Exact schemas will be designed with migrations, but the expected durable
entities are:

```text
accounts
account_credentials
account_sessions
totp_credentials
recovery_codes
password_reset_tokens
user_profiles

solves
solve_penalty_events
user_solve_metrics

queue_entries
matches
match_participants
match_events
match_deadlines
scrambles

outbox_messages
processed_commands
```

Important database constraints include:

- At most one active queue entry per account
- At most one active competitive match per account
- Unique participant membership within a match
- Unique command ID within its idempotency scope
- Unique event sequence within a match
- One active deadline of a given type and scope
- Immutable raw solve duration after creation

Times and durations should be stored with explicit units. Durations should use
integer milliseconds or finer integer precision rather than floating-point
seconds.

## Runtime deployment

### Initial deployment

The initial production deployment is one 8 GB-class VPS running a single-node
K3s cluster with:

- One FastAPI API process
- One worker process
- One PostgreSQL instance
- One Redis instance
- One TNoodle runner or generation job
- One STUN/TURN deployment or external service
- The separately deployed Next.js frontend

PostgreSQL uses a local persistent volume and is backed up to storage outside
the VPS. Redis and K3s indexes may also use local persistence, but remain
reconstructable from PostgreSQL where the architecture identifies them as
disposable.

This deployment is not highly available. The initial budget does not support
independent high-availability replicas for every dependency. A VPS or local
disk failure causes downtime and requires restoration on a replacement node.
The application design still permits additional API and worker instances
without changing domain code when the deployment later expands beyond one
node.

### Horizontal growth

The API is horizontally scalable because:

- Durable state is external.
- WebSocket ownership is leased through Redis.
- Events are fanned out across instances.
- Client commands are idempotent.
- Sticky HTTP sessions are not required.

WebSocket connections remain attached to one API instance for their lifetime,
and the load balancer must support WebSocket upgrades and appropriate idle
timeouts.

Workers scale through transactional claiming. PostgreSQL and Redis capacity
should be measured before they are enlarged or partitioned. A target of 1,000
concurrent matches does not by itself justify database sharding.

### Failure behavior

| Failure | Expected behavior |
| --- | --- |
| API instance exits | Its sockets disconnect; clients may reconnect to another instance. |
| Worker exits | Deadlines and outbox records remain durable and are claimed after restart. |
| Redis restarts | Presence, indexes, and buffered scrambles are rebuilt; PostgreSQL state remains valid. |
| PostgreSQL unavailable | State-changing operations stop rather than accepting unrecorded transitions. |
| TNoodle unavailable | Existing buffered scrambles continue to be assigned; new matches pause if the buffer empties. |
| TURN unavailable | Direct WebRTC may still work; matches requiring relay cannot establish mandatory video. |
| Pub/Sub message missed | Client detects a sequence gap or reconnects and loads the current snapshot. |

Full transparent preservation of both players' connections through a backend
deployment is not an MVP promise. Durable state and reconnectable snapshots
provide the foundation for that later goal.

## Repository layout

The backend repository uses `src/` directly as the application root:

```text
speedsolve/
├── src/
│   ├── accounts/
│   │   ├── domain/
│   │   ├── application/
│   │   └── api/
│   ├── users/
│   ├── solves/
│   ├── matchmaking/
│   ├── matches/
│   ├── scrambles/
│   ├── realtime/
│   ├── media_signaling/
│   ├── notifications/
│   ├── infrastructure/
│   │   ├── postgres/
│   │   ├── redis/
│   │   ├── email/
│   │   └── tnoodle/
│   ├── worker/
│   ├── config/
│   └── main.py
├── tests/
│   ├── unit/
│   ├── integration/
│   ├── state_machine/
│   └── end_to_end/
├── migrations/
├── infra/
│   ├── terraform/
│   └── kubernetes/
├── docker/
├── scripts/
├── docs/
│   ├── product-spec.md
│   ├── architecture.md
│   └── adr/
├── pyproject.toml
├── Dockerfile
└── compose.yaml
```

Each directory under `src/` is an application module. `src/` is not required to
be a nested `speedsolve` Python package. Packaging and import configuration must
be made explicit in `pyproject.toml`, and tests must run against the installed
application configuration rather than relying on accidental working-directory
imports.

Terraform remains in this repository initially so application and
infrastructure changes can be reviewed and deployed together. Secrets and
environment-specific values must not be committed.

## Testing strategy

The state machine receives the highest testing priority.

### Unit tests

- Every valid and invalid state transition
- Countdown resets and forced starts
- Deadline expiration
- Disconnect and abandonment paths
- Duplicate and stale commands
- Winner and tie rules
- Penalty audit behavior
- Online-average trimming and DNF substitution
- Matchmaking expansion boundaries

State-machine tests use a controlled clock and deterministic IDs. Domain tests
must not require PostgreSQL, Redis, WebSockets, or wall-clock sleeps.

### Integration tests

- PostgreSQL transactions and constraints
- Concurrent match and queue commands
- Outbox publication
- Redis index rebuilding
- Cross-instance realtime fan-out
- Worker deadline claiming
- Session, TOTP, recovery-code, and password-reset flows
- TNoodle adapter and scramble assignment

### End-to-end tests

- Two clients queue, match, connect media, and complete a solve
- Countdown reset and forced-start scenarios
- One client disconnects and reconnects
- Disconnect grace expiration converts both attempts to offline solves
- Multiple-tab gameplay rejection

## CI/CD

Pull-request checks should run in this order:

1. Formatting and linting
2. Static type checking
3. Unit tests
4. Integration tests with disposable PostgreSQL and Redis services
5. Migration validation
6. Container build

Deployment from the protected main branch should:

1. Build the immutable application image once.
2. Publish it with a commit-based tag.
3. Produce and review a Terraform plan when infrastructure changed.
4. Run backward-compatible database migrations as a single deployment job.
5. Deploy API and worker processes using the same image tag.
6. Perform health checks and a smoke test.

Terraform state must be remote, encrypted, locked, and access-controlled.
Deployments should reference secrets from the hosting environment or a secret
manager instead of placing secret values directly in Terraform-managed files.

## Observability

Structured logs should include correlation ID, account ID where safe, match ID,
command ID, match version, and event sequence. Sensitive authentication and
WebRTC signaling contents must be redacted.

Initial metrics should include:

- Active HTTP and WebSocket connections
- Active and queued matches
- Matchmaking wait-time distribution
- State-transition and command-rejection counts
- Deadline processing delay
- Reconnect and abandonment rates
- Client/server duration discrepancies
- Outbox backlog and publication latency
- Redis and PostgreSQL operation latency
- Scramble-buffer depth
- WebRTC connection success and TURN relay rate

The system should support tracing context across HTTP/WebSocket command
handling, database transactions, outbox publication, and worker execution even
if distributed tracing is not enabled for the first deployment.

## Extraction criteria

A module should become an independently deployed service only when at least one
of these is demonstrated:

- It requires a different runtime, as TNoodle may.
- It has materially different scaling characteristics.
- Its failure isolation needs differ from the core application.
- It requires independent deployment frequency.
- A separate team owns it.
- The operational benefit exceeds the cost of network calls, event delivery,
  schema compatibility, and independent observability.

Likely future extraction order:

1. TNoodle scramble producer
2. Realtime match coordinator, if WebSocket scaling becomes distinct from HTTP
3. Notifications, if delivery workload grows substantially
4. Machine-learning analysis, consuming completed-match events asynchronously

Accounts, profiles, solves, and match history should remain together until a
measured need justifies separation.

## Required architecture decision records

The following choices should receive short ADRs before implementation:

- Python dependency, packaging, and import strategy for the direct `src/`
  layout
- ASGI server and process model
- Database access and migration libraries
- Worker and job-queue implementation
- Exact TNoodle invocation, versioning, and distribution strategy
- Redis Pub/Sub versus a durable stream for each message category
- Opaque session format, cookie scope, and CSRF strategy
- TOTP secret-encryption and deployment-key strategy
- STUN/TURN provider or self-hosted deployment
- Hosting provider and initial production topology
- Kubernetes manifest packaging and deployment strategy
- Terraform state backend and deployment approval policy
- Observability and error-reporting provider

## Open capacity and product inputs

The following product values must be selected before their associated code is
finalized:

- Fractional trim-count rounding rule
- Scramble-phase timeout
- Countdown-phase timeout
- Maximum solve duration

Load testing must determine practical limits for:

- WebSocket connections per API instance
- Match commands and broadcasts per second
- Deadline processing delay
- PostgreSQL connection-pool size
- Redis Pub/Sub fan-out
- Scramble generation and replenishment rate
- TURN bandwidth and cost
