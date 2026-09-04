//! Graph algorithms — the half of the graph SQL/PGQ does not reach.
//!
//! `ai-query-layer/brief.md` §3 draws the line this file lives on: SQL/PGQ owns
//! pattern matching, `pgvector` owns similarity, and `pgrx` is "reserved for
//! graph *algorithms* Postgres has no native operator for". Two facts make that
//! more than a preference. PG19's `GRAPH_TABLE` rejects quantified path
//! patterns outright, so anything past one hop is already a `WITH RECURSIVE`;
//! and a recursive CTE can enumerate a frontier but cannot *rank*, *bound* or
//! *stop* — the three things every algorithm below is made of.
//!
//! Everything here reads through one structure: a CSR adjacency snapshot built
//! from `aiq.nodes` and `aiq.edges` and cached in the backend. Three properties
//! of that snapshot are load-bearing and are stated here because each one is a
//! way this file could be wrong rather than slow:
//!
//! 1. **It is built through SPI as the caller**, so RLS applies. It is also
//!    *cached*, and a cache built under one tenant's policies and read under
//!    another's is a silent cross-tenant read — the read-side twin of the write
//!    `world-model-ingestion/graph-index.md` §11 records. Every entry point
//!    therefore checks the caller's identity (role + JWT claims) before reuse
//!    and rebuilds rather than serving someone else's graph. A rebuild for a
//!    NEW identity also drops the previous one's build filter, so a subset one
//!    caller chose cannot narrow the next caller's answers.
//! 2. **It is a stale read by construction.** The snapshot carries the
//!    table's tuple-modification counters, so an edge written since the build
//!    normally forces a rebuild — but those counters come from the stats
//!    collector and lag. `stale` in the result is a fact about the snapshot,
//!    not a guarantee about the graph.
//! 3. **Every algorithm is anytime.** A budget in milliseconds and edge visits
//!    bounds each one, and every result says whether it converged. "Nothing is
//!    related" and "I ran out of budget" are two different answers, and the
//!    dialect's own `unresolved` field exists because collapsing that
//!    distinction is how an agent gets confidently misled.

use pgrx::prelude::*;
use pgrx::{JsonB, Uuid};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::time::Instant;

// ===========================================================================
// §0. A hasher, because SipHash is 40% of a snapshot build
//
// The only hashed key in this file is a 16-byte UUID, hashed once per node at
// build time and never in an inner loop. SipHash's DoS resistance buys nothing
// against keys that came out of our own `nodes` table, and it measurably costs:
// FxHash is the same function rustc uses on itself, in ten lines, with no
// dependency to add to a crate whose whole dependency list is serde.
// ===========================================================================

const FX_SEED: u64 = 0x51_7c_c1_b7_27_22_0a_95;

#[derive(Default, Clone, Copy)]
pub struct FxHasher {
    hash: u64,
}

impl FxHasher {
    #[inline]
    fn add(&mut self, w: u64) {
        self.hash = (self.hash.rotate_left(5) ^ w).wrapping_mul(FX_SEED);
    }
}

impl std::hash::Hasher for FxHasher {
    #[inline]
    fn write(&mut self, bytes: &[u8]) {
        for chunk in bytes.chunks(8) {
            let mut buf = [0u8; 8];
            buf[..chunk.len()].copy_from_slice(chunk);
            self.add(u64::from_le_bytes(buf));
        }
    }
    #[inline]
    fn finish(&self) -> u64 {
        self.hash
    }
}

#[derive(Default, Clone, Copy)]
pub struct FxBuild;

impl std::hash::BuildHasher for FxBuild {
    type Hasher = FxHasher;
    #[inline]
    fn build_hasher(&self) -> FxHasher {
        FxHasher::default()
    }
}

type Map<K, V> = HashMap<K, V, FxBuild>;

fn map<K, V>() -> Map<K, V> {
    HashMap::with_hasher(FxBuild)
}

// ===========================================================================
// §1. The budget
//
// One type, carried by every algorithm, because a budget each caller invents
// is a budget that is inconsistent across the surface and absent from half of
// it. It bounds two things at once -- wall clock and edge visits -- and the
// second is not redundant: wall clock alone makes a result depend on what else
// the machine was doing, which is exactly the property a scale test cannot
// have.
//
// CHECK_FOR_INTERRUPTS lives here rather than in each loop, so `statement_timeout`
// and a client cancel still work inside a 200ms Rust loop that Postgres cannot
// otherwise see into.
// ===========================================================================

struct Budget {
    /// When the CALL started, which is not when the walk did. Everything a
    /// caller waits for happens between these two instants, and the gap is
    /// usually a snapshot build.
    call_start: Instant,
    start: Instant,
    ms: u64,
    max_ops: u64,
    ops: u64,
    since_check: u64,
    exhausted: bool,
}

impl Budget {
    /// Started at the top of the entry point, BEFORE the snapshot is fetched,
    /// so that `elapsed_ms` is what the caller waited rather than what the
    /// algorithm ran for. Measured before this existed: a first call on a
    /// four-million-edge graph took 2,689 ms and reported 96 ms with
    /// `exhausted: false` -- both true of the walk, and the number an operator
    /// would have written an SLO against.
    fn new(ms: i32, max_ops: i64) -> Self {
        let now = Instant::now();
        Budget {
            call_start: now,
            start: now,
            ms: ms.max(1) as u64,
            max_ops: if max_ops <= 0 { u64::MAX } else { max_ops as u64 },
            ops: 0,
            since_check: 0,
            exhausted: false,
        }
    }

    /// The walk's own clock starts here, after whatever setup the entry point
    /// needed. The budget bounds the WALK: a snapshot build is a one-time cost
    /// per backend and truncating it produces nothing usable, so it is
    /// reported rather than cut short.
    fn begin_walk(&mut self) {
        self.start = Instant::now();
    }

    /// Charge `n` edge visits. Returns false once the budget is spent, and
    /// every caller is expected to treat that as "stop and return what you
    /// have" rather than as an error.
    #[inline]
    fn spend(&mut self, n: u64) -> bool {
        if self.exhausted {
            return false;
        }
        self.ops += n;
        self.since_check += n;
        if self.ops > self.max_ops {
            self.exhausted = true;
            return false;
        }
        if self.since_check >= 4096 {
            self.since_check = 0;
            check_for_interrupts!();
            if self.start.elapsed().as_millis() as u64 >= self.ms {
                self.exhausted = true;
                return false;
            }
        }
        true
    }

    fn elapsed_ms(&self) -> f64 {
        self.start.elapsed().as_secs_f64() * 1000.0
    }

    /// Total wall clock for the call, including anything that happened before
    /// the walk began.
    fn call_ms(&self) -> f64 {
        self.call_start.elapsed().as_secs_f64() * 1000.0
    }

    /// Four numbers, and the two booleans mean different things on purpose.
    ///
    /// `exhausted` says the ANSWER is partial -- the walk stopped early and
    /// there is more out there. `over_budget` says the CALL took longer than
    /// it was given, which on a cold backend is the snapshot build and says
    /// nothing about the answer's completeness. Collapsing them would make a
    /// complete answer that arrived late indistinguishable from a truncated
    /// one that arrived on time, and those are opposite problems.
    fn meta(&self) -> Value {
        let build = last_build_ms();
        let call = self.call_ms();
        json!({
            "budget_ms": self.ms,
            "elapsed_ms": (call * 1000.0).round() / 1000.0,
            "walk_ms": (self.elapsed_ms() * 1000.0).round() / 1000.0,
            "build_ms": (build * 1000.0).round() / 1000.0,
            "snapshot_built": build > 0.0,
            "edge_visits": self.ops,
            "exhausted": self.exhausted,
            "over_budget": call > self.ms as f64,
        })
    }
}

// ===========================================================================
// §2. The snapshot -- CSR over aiq.edges
//
// Adjacency as three parallel arrays rather than a btree: a hop is a slice
// index, not a page access. The edge record is stored once and both directions
// index into it, because storing the reverse edge twice is the same mistake
// `graph-identity.md` refuses in the table ("do not store the inverse edge"),
// and here it would also double the temporal columns, which are already half
// the width.
// ===========================================================================

/// 32 bytes, and `vf`/`vt` are 16 of them. Carrying validity in the snapshot is
/// what lets a traversal honour `valid_from`/`valid_to` at edge-relax time --
/// the gap `graph-identity.md` records as stored-and-never-read. A traversal
/// that cannot see the columns cannot apply them, so they are here even though
/// they cost more than the adjacency does.
#[derive(Clone, Copy)]
struct Edge {
    src: u32,
    dst: u32,
    rel: u16,
    w: f32,
    vf: i64,
    vt: i64,
}

const T_MIN: i64 = i64::MIN;
const T_MAX: i64 = i64::MAX;

/// Scratch arrays, sized once per snapshot and reused across calls.
///
/// A local-push walk touches a few thousand nodes on a graph of millions, so a
/// per-call `vec![0.0; n]` would spend all its time in memset for work it never
/// does. Instead the arrays live as long as the snapshot and each call clears
/// only what it touched, tracked by a monotonic stamp -- the standard trick,
/// and the reason PPR's cost tracks the neighbourhood rather than the graph.
struct Scratch {
    p: Vec<f64>,
    r: Vec<f64>,
    dist: Vec<f64>,
    parent: Vec<u32>,
    stamp: Vec<u32>,
    epoch: u32,
    /// The backward frontier of a bidirectional search. A second set of
    /// arrays rather than a second call, because the two searches have to be
    /// live at the same time -- that is the whole mechanism.
    dist_b: Vec<f64>,
    parent_b: Vec<u32>,
    stamp_b: Vec<u32>,
    epoch_b: u32,
    /// Which terminal's territory a node fell into, for the Voronoi step of
    /// the connecting-subgraph approximation.
    region: Vec<u32>,
}

impl Scratch {
    fn new(n: usize) -> Self {
        Scratch {
            p: vec![0.0; n],
            r: vec![0.0; n],
            dist: vec![0.0; n],
            parent: vec![u32::MAX; n],
            stamp: vec![0; n],
            epoch: 0,
            dist_b: vec![0.0; n],
            parent_b: vec![u32::MAX; n],
            stamp_b: vec![0; n],
            epoch_b: 0,
            region: vec![u32::MAX; n],
        }
    }
    fn bytes(&self) -> usize {
        self.p.len() * 8 * 4 + self.parent.len() * 8 + self.stamp.len() * 8 + self.region.len() * 4
    }
    /// A fresh generation of the stamp, which is how a call "clears" the
    /// arrays without touching them. Wrapping is handled by re-zeroing, which
    /// happens once every four billion calls.
    fn bump(&mut self) -> u32 {
        self.epoch = self.epoch.wrapping_add(1);
        if self.epoch == 0 {
            for x in self.stamp.iter_mut() {
                *x = 0;
            }
            self.epoch = 1;
        }
        self.epoch
    }
    fn bump_b(&mut self) -> u32 {
        self.epoch_b = self.epoch_b.wrapping_add(1);
        if self.epoch_b == 0 {
            for x in self.stamp_b.iter_mut() {
                *x = 0;
            }
            self.epoch_b = 1;
        }
        self.epoch_b
    }
}

static mut SCRATCH: *mut Scratch = std::ptr::null_mut();

/// Scratch sized for the current snapshot. Separate from the snapshot itself
/// so that an algorithm can borrow the graph immutably and the scratch mutably
/// -- one struct holding both makes every algorithm signature fight the borrow
/// checker for no gain.
fn scratch(n: usize) -> &'static mut Scratch {
    unsafe {
        if SCRATCH.is_null() || (*SCRATCH).p.len() < n {
            if !SCRATCH.is_null() {
                drop(Box::from_raw(SCRATCH));
            }
            SCRATCH = Box::into_raw(Box::new(Scratch::new(n)));
        }
        &mut *SCRATCH
    }
}

/// What the snapshot was built over.
///
/// A snapshot of the whole edge table is not always the graph anyone wants to
/// walk. An evidence graph records a weak opinion on every pair it considered
/// -- "we looked and found nothing" is a different fact from "we never looked"
/// -- so most of its edges are below any operating threshold and none of them
/// belong in a traversal. Filtering at the query is not the same thing: it
/// narrows the answer, but the rows are still fetched, still resident, and
/// still scanned at every visit to a node that has them.
#[derive(Clone, PartialEq, Default)]
struct BuildFilter {
    relations: Option<Vec<String>>,
    weight_floor: f32,
    as_of: Option<i64>,
}

impl BuildFilter {
    fn is_empty(&self) -> bool {
        self.relations.is_none() && self.weight_floor <= 0.0 && self.as_of.is_none()
    }
    fn json(&self) -> Value {
        if self.is_empty() {
            return Value::Null;
        }
        json!({
            "relations": self.relations,
            "weight_floor": self.weight_floor,
            "as_of_us": self.as_of,
        })
    }
}

struct Snapshot {
    /// WHO built it: role and JWT claims. Reuse across a different identity is
    /// a cross-tenant read, so it is refused rather than warned about.
    ///
    /// Split from the counters below, and the split is load-bearing rather
    /// than tidy -- see `snapshot()` for what each half decides.
    identity: String,
    /// WHEN it was built, as the two tables' tuple-modification counters. A
    /// staleness hint, not a guarantee: `pg_stat_all_tables` is fed by the
    /// stats collector, which lags.
    counters: String,
    /// The admission slot this backend holds while this snapshot exists. The
    /// lock and the memory have the same lifetime on purpose.
    slot: i32,
    /// The subset this snapshot was built over, if any.
    ///
    /// It is reported by `aiq.graph_snapshot()` and NOT by the algorithms --
    /// `related` and its siblings return fixed row shapes with nowhere to put
    /// it. That is a real gap and it is stated here rather than in a claim that
    /// this field is "reported on every answer", which is what this comment
    /// used to say and what nothing in the code did. What closes the dangerous
    /// half of it is `snapshot()`: a filter now belongs to the identity that
    /// built it, so the only caller who can be answered over a subset is the
    /// one who asked for it.
    build_filter: BuildFilter,
    ids: Vec<Uuid>,
    index: Map<Uuid, u32>,
    edges: Vec<Edge>,
    out_off: Vec<u32>,
    out_eid: Vec<u32>,
    in_off: Vec<u32>,
    in_eid: Vec<u32>,
    rel_names: Vec<String>,
    build_ms: f64,
    built_at: String,
    /// Derived indexes, built on demand by their own entry points. Each is an
    /// option because each has its own build cost and its own verdict.
    reach: Option<Reach>,
    labels: Option<Labels>,
    community: Option<Vec<u32>>,
    /// Sizes, computed once when the partition is. Looking a size up by
    /// scanning the label vector is O(n) per call, which turns "what community
    /// is this node in" -- asked once per node when checking a partition
    /// against a known one -- into an O(n^2) sweep.
    community_sizes: Option<Map<u32, u32>>,
    community_ms: f64,
}

impl Snapshot {
    #[inline]
    fn n(&self) -> usize {
        self.ids.len()
    }
    #[inline]
    fn m(&self) -> usize {
        self.edges.len()
    }
    #[inline]
    fn out(&self, v: u32) -> &[u32] {
        let a = self.out_off[v as usize] as usize;
        let b = self.out_off[v as usize + 1] as usize;
        &self.out_eid[a..b]
    }
    #[inline]
    fn inc(&self, v: u32) -> &[u32] {
        let a = self.in_off[v as usize] as usize;
        let b = self.in_off[v as usize + 1] as usize;
        &self.in_eid[a..b]
    }
    fn rel_id(&self, name: &str) -> Option<u16> {
        self.rel_names.iter().position(|r| r == name).map(|i| i as u16)
    }
    fn ord(&self, id: Uuid) -> Option<u32> {
        self.index.get(&id).copied()
    }
    fn bytes(&self) -> usize {
        self.edges.len() * std::mem::size_of::<Edge>()
            + (self.out_eid.len() + self.in_eid.len()) * 4
            + (self.out_off.len() + self.in_off.len()) * 4
            + self.ids.len() * 16
            + self.index.capacity() * 24
            + self.reach.as_ref().map(|r| r.bytes()).unwrap_or(0)
            + self.labels.as_ref().map(|l| l.bytes()).unwrap_or(0)
            + self.community.as_ref().map(|c| c.len() * 4).unwrap_or(0)
    }
}

/// A traversal's view of which edges exist: relation and validity.
#[derive(Clone, Copy)]
struct Filter {
    rel: Option<u16>,
    as_of: Option<i64>,
}

impl Filter {
    #[inline]
    fn keep(&self, e: &Edge) -> bool {
        if let Some(r) = self.rel {
            if e.rel != r {
                return false;
            }
        }
        if let Some(t) = self.as_of {
            if e.vf > t || e.vt <= t {
                return false;
            }
        }
        true
    }
}

// The cache is one snapshot per backend, held as a raw pointer rather than
// behind a RefCell on purpose: a Postgres error longjmps out of Rust, and a
// RefCell borrow that is live at that moment is never released -- so the first
// cancelled query would poison the cache for the life of the connection. A
// backend is single-threaded, so the pointer is as safe as the RefCell was and
// has no state to corrupt.
static mut SNAP: *mut Snapshot = std::ptr::null_mut();

/// What the snapshot build in the current call cost, or zero if it reused one.
///
/// Backend-local and reset at the top of every entry point, because the
/// question it answers is "did THIS call pay for a build" -- which is what
/// separates a 2.7 second first call from a 96 millisecond second one, and is
/// invisible in any number that only measures the algorithm.
static mut LAST_BUILD_MS: f64 = 0.0;

/// A slot that has been TAKEN but not yet attached to a snapshot.
///
/// `acquire_slot()` runs before `build()`, and `build()` does not always
/// return: the snapshot ceiling raises deliberately, `check_for_interrupts!`
/// raises on a cancelled query, and a cursor fetch can raise on its own. A
/// raise in pgrx is a longjmp, so `install()` never runs -- and the slot is
/// then recorded on no snapshot at all, which means `drop_cached()`, whose
/// only source of a slot number is `SNAP`, cannot give it back.
///
/// That made the leak worst exactly where it hurt most: the ceiling error
/// tells the operator to "retry, or release one with select
/// aiq.graph_snapshot_drop()", and neither could recover the slot that error
/// had just burned. Six of them on one pooled backend exhausted the
/// cluster-wide admission control until the session ended.
///
/// So a freshly taken slot is written down BEFORE the build that may not
/// return, and released by whichever gets there first: `install()`, which
/// adopts it, or the next entry point, which finds it still pending. Only a
/// FRESHLY ACQUIRED slot is ever pending -- a rebuild that reuses the cached
/// snapshot's slot must not mark it, because that slot is still owned by a
/// live `SNAP` and releasing it would be giving away one we are still using.
static mut PENDING_SLOT: i32 = -1;

fn mark_pending(slot: i32) -> i32 {
    unsafe { PENDING_SLOT = slot }
    slot
}

/// Give back a slot taken for a build that never installed one.
///
/// Called from the two functions that can CREATE a pending slot -- `snapshot()`
/// and `snapshot_filtered()` -- and from `graph_snapshot_drop()`, rather than
/// from every entry point. It used to hang off `reset_build_clock()`, and that
/// was wrong twice over: slot accounting is not clock accounting, and three
/// entry points that read an existing snapshot (`p8_graph_distance`,
/// `p8_graph_community_of`, `p8_graph_induced`) reset no clock -- so a slot
/// burned by a raised build reached one of them, `snapshot()` acquired a
/// second, and `mark_pending` OVERWROTE the record of the first. The leak the
/// pending slot exists to close was still open, one entry point along, and the
/// overwritten slot could not be recovered by anything short of ending the
/// session.
///
/// Releasing where the slot is taken rather than where control happens to land
/// is what makes that structural instead of remembered: a new entry point
/// cannot forget, because the only way to take a pending slot is to go through
/// a function that has already given the last one back.
fn release_pending_slot() {
    unsafe {
        if PENDING_SLOT >= 0 {
            let slot = PENDING_SLOT;
            PENDING_SLOT = -1;
            release_slot(slot);
        }
    }
}

fn reset_build_clock() {
    unsafe { LAST_BUILD_MS = 0.0 }
}

fn last_build_ms() -> f64 {
    unsafe { LAST_BUILD_MS }
}

fn cached() -> Option<&'static mut Snapshot> {
    unsafe { SNAP.as_mut() }
}

fn install(mut s: Snapshot, slot: i32) -> &'static mut Snapshot {
    unsafe {
        // The build returned, so the slot is this snapshot's now rather than
        // owed back by the next entry point. Cleared before anything below can
        // itself raise.
        PENDING_SLOT = -1;
        LAST_BUILD_MS += s.build_ms;
        // The outgoing snapshot's slot is reused rather than released and
        // retaken: a backend that already holds one is not a new admission,
        // and releasing first would let another backend take it and leave this
        // one refused for a rebuild it was already entitled to make.
        //
        // The `prev != slot` arm is unreachable from the two callers below,
        // which pass the cached snapshot's own slot whenever there is one --
        // so `prev` and `slot` are the same number in every path that exists
        // today. Kept rather than collapsed because it is the arm that keeps
        // the accounting right for a caller that acquires independently, and
        // an install that silently dropped one of two held slots would be a
        // leak of the same shape PENDING_SLOT above exists to close.
        if !SNAP.is_null() {
            let prev = (*SNAP).slot;
            drop(Box::from_raw(SNAP));
            SNAP = std::ptr::null_mut();
            if prev >= 0 && prev != slot {
                release_slot(slot);
                s.slot = prev;
            } else {
                s.slot = slot;
            }
        } else {
            s.slot = slot;
        }
        SNAP = Box::into_raw(Box::new(s));
        &mut *SNAP
    }
}

fn drop_cached() -> bool {
    unsafe {
        if SNAP.is_null() {
            return false;
        }
        let slot = (*SNAP).slot;
        drop(Box::from_raw(SNAP));
        SNAP = std::ptr::null_mut();
        if slot >= 0 {
            release_slot(slot);
        }
        true
    }
}

/// Role and claims: the tenancy guard.
///
/// These two decide WHO a snapshot belongs to, and a change in them is the one
/// case where the cached build filter must NOT be carried forward -- a filter
/// is one caller's choice about their own graph, and inheriting it hands the
/// next caller a subset they did not ask for and cannot see.
fn identity() -> String {
    Spi::get_one::<String>(
        "select current_user::text
             || '|' || coalesce(current_setting('request.jwt.claims', true), '')",
    )
    .unwrap_or(None)
    .unwrap_or_default()
}

/// The two tables' modification counters: the staleness hint.
///
/// A hint, and it says so: `pg_stat_all_tables` is fed by the stats collector,
/// which lags, so a snapshot can be behind the graph for as long as that lag.
/// Recorded rather than papered over -- the alternative, `count(*)` per call,
/// costs more than most of the algorithms it would be guarding.
///
/// A change here means the same caller's graph moved, which is a reason to
/// rebuild and NOT a reason to discard the filter they built it with.
fn counters() -> String {
    Spi::get_one::<String>(
        "select coalesce((select sum(n_tup_ins + n_tup_upd + n_tup_del)::text
                            from pg_stat_all_tables
                           where schemaname = 'aiq'
                             and relname in ('nodes', 'edges')), '')",
    )
    .unwrap_or(None)
    .unwrap_or_default()
}

/// Build the CSR. Two cursors, two passes, no intermediate materialization of
/// the whole edge set as SPI tuples -- a 10M-row `select` through
/// `SpiClient::select` would hold every row in the SPI context at once.
fn build(bf: &BuildFilter) -> Snapshot {
    let t0 = Instant::now();
    let mut ids: Vec<Uuid> = Vec::new();
    let mut index: Map<Uuid, u32> = map();
    let mut edges: Vec<Edge> = Vec::new();
    let mut rel_names: Vec<String> = Vec::new();
    let mut rel_ids: Map<String, u16> = map();

    Spi::connect(|client| {
        let mut cur = client.open_cursor("select id from aiq.nodes", &[]);
        loop {
            let tbl = cur.fetch(65_536).expect("aiq.nodes cursor");
            if tbl.is_empty() {
                break;
            }
            for row in tbl {
                if let Ok(Some(id)) = row.get::<Uuid>(1) {
                    if !index.contains_key(&id) {
                        index.insert(id, ids.len() as u32);
                        ids.push(id);
                    }
                }
            }
            check_for_interrupts!();
        }

        // The filter is pushed into the query rather than applied after the
        // fetch: the point of it is that the rows never arrive, so neither the
        // fetch nor the resident bytes are paid for a graph nobody walks.
        // Bound parameters rather than an interpolated predicate -- the
        // relation list arrives from a caller, and a snapshot builder is the
        // last place to be assembling SQL out of one.
        let args: Vec<pgrx::datum::DatumWithOid> = vec![
            bf.relations.clone().into(),
            bf.weight_floor.into(),
            bf.as_of.into(),
        ];
        let mut cur = client.open_cursor(
            "select src_id, dst_id, relation, weight,
                    coalesce((extract(epoch from valid_from) * 1000000)::bigint, (-9223372036854775808)::bigint),
                    coalesce((extract(epoch from valid_to)   * 1000000)::bigint,   9223372036854775807::bigint)
               from aiq.edges
              where ($1::text[] is null or relation = any($1::text[]))
                and weight >= $2::real
                and ($3::bigint is null
                     or (coalesce((extract(epoch from valid_from) * 1000000)::bigint,
                                  (-9223372036854775808)::bigint) <= $3::bigint
                     and coalesce((extract(epoch from valid_to) * 1000000)::bigint,
                                  9223372036854775807::bigint) > $3::bigint))",
            &args,
        );
        loop {
            let tbl = cur.fetch(65_536).expect("aiq.edges cursor");
            if tbl.is_empty() {
                break;
            }
            for row in tbl {
                let src = match row.get::<Uuid>(1) { Ok(Some(v)) => v, _ => continue };
                let dst = match row.get::<Uuid>(2) { Ok(Some(v)) => v, _ => continue };
                let (s, d) = match (index.get(&src), index.get(&dst)) {
                    (Some(s), Some(d)) => (*s, *d),
                    // An endpoint outside the node set is not a data error: RLS
                    // may have shown us the edge and hidden the node. Dropping
                    // it is the only correct reading -- a walk cannot land on a
                    // node this caller may not see.
                    _ => continue,
                };
                let rel = row.get::<String>(3).ok().flatten().unwrap_or_default();
                let rid = match rel_ids.get(&rel) {
                    Some(r) => *r,
                    None => {
                        let r = rel_names.len() as u16;
                        rel_names.push(rel.clone());
                        rel_ids.insert(rel, r);
                        r
                    }
                };
                let w = row.get::<f32>(4).ok().flatten().unwrap_or(1.0);
                let vf = row.get::<i64>(5).ok().flatten().unwrap_or(T_MIN);
                let vt = row.get::<i64>(6).ok().flatten().unwrap_or(T_MAX);
                edges.push(Edge { src: s, dst: d, rel: rid, w, vf, vt });
            }
            // Checked per batch rather than per row, and against the ARRIVING
            // size rather than a pre-count: a `count(*)` to decide whether to
            // build costs a scan of the thing we are about to scan anyway, and
            // an estimate from reltuples is wrong in exactly the direction
            // that matters.
            //
            // The final structure is bigger than this (the two index arrays
            // and the id map add roughly a third), so the check charges for
            // them here rather than discovering them after the point of no
            // return.
            let projected = edges.len() * std::mem::size_of::<Edge>() * 4 / 3
                + ids.len() * 40;
            if projected > snapshot_max_bytes() {
                error!(
                    "the graph does not fit in one backend's snapshot ceiling of {} MiB \
                     ({} edges so far). Build over a subset instead: \
                     aiq.graph_snapshot(true, p_relations => array[...], p_weight_floor => 0.5). \
                     The ceiling exists because this memory is outside work_mem, so \
                     exceeding it is an OOM kill and a cluster restart rather than a \
                     slow query; raise it with percolate.graph_snapshot_max_mb if the \
                     machine has the memory -- see graph-algorithms.md 2.3.",
                    snapshot_max_bytes() / (1024 * 1024),
                    edges.len()
                );
            }
            check_for_interrupts!();
        }
    });

    let n = ids.len();
    let m = edges.len();
    let mut out_off = vec![0u32; n + 1];
    let mut in_off = vec![0u32; n + 1];
    for e in &edges {
        out_off[e.src as usize + 1] += 1;
        in_off[e.dst as usize + 1] += 1;
    }
    for i in 0..n {
        out_off[i + 1] += out_off[i];
        in_off[i + 1] += in_off[i];
    }
    let mut out_eid = vec![0u32; m];
    let mut in_eid = vec![0u32; m];
    let mut oc = out_off.clone();
    let mut ic = in_off.clone();
    for (i, e) in edges.iter().enumerate() {
        out_eid[oc[e.src as usize] as usize] = i as u32;
        oc[e.src as usize] += 1;
        in_eid[ic[e.dst as usize] as usize] = i as u32;
        ic[e.dst as usize] += 1;
    }

    // clock_timestamp(), not now(): now() is the transaction's start time, so
    // two snapshots built in one transaction -- which is exactly what happens
    // when a session changes tenant mid-transaction -- reported the same
    // built_at while holding different graphs. The tenancy test caught it, and
    // the field it caught it with is the one an operator would have trusted.
    let built_at = Spi::get_one::<String>("select clock_timestamp()::text")
        .unwrap_or(None)
        .unwrap_or_default();
    Snapshot {
        identity: identity(),
        counters: counters(),
        slot: -1,
        build_filter: bf.clone(),
        ids,
        index,
        edges,
        out_off,
        out_eid,
        in_off,
        in_eid,
        rel_names,
        build_ms: t0.elapsed().as_secs_f64() * 1000.0,
        built_at,
        reach: None,
        labels: None,
        community: None,
        community_sizes: None,
        community_ms: 0.0,
    }
}

/// How much a single backend may spend on one snapshot before it refuses.
///
/// This is not a tuning knob, it is a crash guard, and it was added after
/// watching the alternative. Eight concurrent callers against a 3.94M-edge
/// graph on a 7.65 GiB machine did not produce a slow query: the OOM killer
/// took a backend with `signal 9`, and Postgres responded the way it must to
/// a backend that dies holding shared memory -- "terminating any other active
/// server processes", then recovery. One graph query took the cluster down.
///
/// The reason nothing in Postgres prevented that is structural: the snapshot
/// is Rust-allocated memory outside `work_mem`, so no existing setting sees
/// it, and the planner has no idea it exists. So the bound has to be here.
///
/// The default of 512 MiB is generous for one backend and survivable for
/// several: it holds roughly nine million edges, and eight backends at the
/// ceiling still fit a 4 GiB budget. It is a per-backend number and the
/// arithmetic that matters is `ceiling x concurrent graph callers` --
/// which is why it is `percolate.graph_snapshot_max_mb` rather than a
/// constant.

// ===========================================================================
// The two limits, as settings rather than as constants
//
// Both of these stand between a busy pool and a cluster restart, and the right
// value for each is a function of how much memory the machine has. Compiled in,
// they were a safety mechanism nobody could adjust without rebuilding the
// extension -- six slots is right for 7.65 GiB and wrong for both a laptop and
// a real server, and the failure mode of "wrong" is not a slow query.
//
// `Suset`: a DBA sets them in postgresql.conf and a superuser may change them
// for a session. Deliberately not settable by the roles that CALL these
// functions -- a limit its subject can raise is not a limit.
// ===========================================================================

static GUC_SNAPSHOT_SLOTS: pgrx::guc::GucSetting<i32> = pgrx::guc::GucSetting::<i32>::new(6);
static GUC_SNAPSHOT_MAX_MB: pgrx::guc::GucSetting<i32> = pgrx::guc::GucSetting::<i32>::new(512);

pub fn register_gucs() {
    use pgrx::guc::{GucContext, GucFlags, GucRegistry};
    GucRegistry::define_int_guc(
        c"percolate.graph_snapshot_slots",
        c"How many backends may hold a graph adjacency snapshot at once.",
        c"Each slot is a backend holding an adjacency snapshot, whose memory is outside work_mem and therefore invisible to every other Postgres limit. A backend that cannot take a slot is refused rather than admitted. Size it as (available memory / roughly twice one snapshot); ai-query-layer/graph-algorithms.md 2.3 has the arithmetic and the measurement that produced it.",
        &GUC_SNAPSHOT_SLOTS,
        1,
        1024,
        GucContext::Suset,
        GucFlags::default(),
    );
    GucRegistry::define_int_guc(
        c"percolate.graph_snapshot_max_mb",
        c"The largest adjacency snapshot one backend may build, in megabytes.",
        c"Checked against the arriving size during the build, so a graph too large for one backend is refused with a pointer to the snapshot filter rather than discovered by the OOM killer. This bounds ONE backend; percolate.graph_snapshot_slots is what bounds several.",
        &GUC_SNAPSHOT_MAX_MB,
        16,
        1024 * 64,
        GucContext::Suset,
        GucFlags::default(),
    );
}

fn snapshot_slots() -> i32 {
    GUC_SNAPSHOT_SLOTS.get()
}

fn snapshot_max_bytes() -> usize {
    (GUC_SNAPSHOT_MAX_MB.get().max(1) as usize) * 1024 * 1024
}

/// How many backends on this cluster may hold a snapshot at once.
///
/// A per-backend ceiling stops ONE pathological graph from taking the box. It
/// does nothing about N ordinary callers, and N ordinary callers is what took
/// the box: eight concurrent queries against a 3.94M-edge graph, each well
/// inside the ceiling, ended in `signal 9` and "terminating any other active
/// server processes". Sizing per backend and hoping is not admission control.
///
/// So this is admission control, built out of the primitive Postgres already
/// has. A backend takes one of `SNAPSHOT_SLOTS` session-level advisory locks
/// before it builds, and holds it for as long as it holds the snapshot; a
/// backend that cannot get one is REFUSED with a sentence rather than allowed
/// to find out what happens next. Session-level locks are released when the
/// connection ends, which is also when the memory goes back, so the lock and
/// the thing it guards have exactly the same lifetime.
///
/// Six is the default because the peak during a build is roughly twice the
/// resident snapshot -- the edge array, the two index arrays and the id map
/// are all live at once -- so six large snapshots is about 3 GiB of transient
/// on a graph this size. It is the number to raise with memory, and the number
/// that stops mattering when the snapshot moves into shared memory, which this
/// measurement promoted from "the next thing to build" to a requirement above
/// single-digit concurrency. Set with `percolate.graph_snapshot_slots`.

/// Namespace for the advisory locks, chosen to be recognisable in
/// `pg_locks.objid` rather than to be random.
const SNAPSHOT_LOCK_KEY: i32 = 0x7038_9A11u32 as i32;

/// Take a slot, or refuse. Returns the slot held, for release on drop.
fn acquire_slot() -> i32 {
    let slots = snapshot_slots();
    for slot in 0..slots {
        let got = Spi::get_one_with_args::<bool>(
            "select pg_try_advisory_lock($1, $2)",
            &[SNAPSHOT_LOCK_KEY.into(), slot.into()],
        )
        .unwrap_or(None)
        .unwrap_or(false);
        if got {
            return slot;
        }
    }
    error!(
        "all {} graph snapshot slots on this cluster are held (see \
         percolate.graph_snapshot_slots). Each one is a \
         backend holding an adjacency snapshot, and the memory is outside \
         work_mem -- so admitting this call is how a graph query becomes an OOM \
         kill and a cluster restart rather than a slow query. Retry, or release \
         one with select aiq.graph_snapshot_drop() in a session that is done \
         with it. See ai-query-layer/graph-algorithms.md 2.3.",
        slots
    );
}

fn release_slot(slot: i32) {
    let _ = Spi::get_one_with_args::<bool>(
        "select pg_advisory_unlock($1, $2)",
        &[SNAPSHOT_LOCK_KEY.into(), slot.into()],
    );
}

/// The query path's way in -- every algorithm below, none of which passes a
/// filter, because none of them is asking for a subset.
///
/// Rebuilds when either half of the old fingerprint moved, and the two halves
/// mean different things on the way back:
///
///   * **The counters moved.** Same caller, their graph changed. Rebuild, and
///     KEEP the filter -- an operator who built over a subset because the whole
///     graph does not fit the ceiling (§2.3) must not have that undone by
///     somebody inserting an edge. This is the case the inheritance exists for.
///
///   * **The identity moved.** A different role or claim set, which through a
///     pooler is the ordinary case rather than an unusual one. Rebuild over the
///     WHOLE graph. Carrying the filter here was a real bug and not a
///     theoretical one: one session's `graph_snapshot(true, relations => ...)`
///     narrowed every subsequent algorithm call on that backend, for every
///     later caller, and nothing in any answer said so. `aiq.related('acme')`
///     returned ten rows on a fresh backend and one row on that one -- the
///     same question, the same data, a different answer decided by what
///     somebody else did earlier on the connection they happened to get.
///
/// The distinction is exactly the one `identity()` and `counters()` already
/// draw: a filter is a caller's choice about their own graph, so it survives
/// their own writes and does not outlive them.
fn snapshot(refresh: bool) -> &'static mut Snapshot {
    // A slot owed back by a build that raised, before this call can take
    // another. Safe unconditionally: PENDING_SLOT is only ever set on the
    // acquire arm below and is cleared by install(), so a non-negative value
    // here means a previous build longjmped and nothing owns that slot.
    release_pending_slot();
    let id = identity();
    let ct = counters();
    if !refresh {
        if let Some(s) = cached() {
            if s.identity == id && s.counters == ct {
                return s;
            }
        }
    }
    let bf = match cached() {
        Some(s) if s.identity == id => s.build_filter.clone(),
        _ => BuildFilter::default(),
    };
    // mark_pending only on the acquire arm: a slot inherited from the cached
    // snapshot is already owned by a live SNAP, and marking it would hand it
    // back on the next entry point while we were still using it.
    let slot = match cached() {
        Some(c) if c.slot >= 0 => c.slot,
        _ => mark_pending(acquire_slot()),
    };
    install(build(&bf), slot)
}

/// The builder's way in: a filter is an instruction to build, not a preference
/// to be matched against a cache, so a different filter always rebuilds.
fn snapshot_filtered(bf: BuildFilter, refresh: bool) -> &'static mut Snapshot {
    // Same as snapshot(): give back a slot a raised build never installed,
    // before taking one of our own.
    release_pending_slot();
    let id = identity();
    let ct = counters();
    if !refresh {
        if let Some(s) = cached() {
            if s.identity == id && s.counters == ct && s.build_filter == bf {
                return s;
            }
        }
    }
    // mark_pending only on the acquire arm: a slot inherited from the cached
    // snapshot is already owned by a live SNAP, and marking it would hand it
    // back on the next entry point while we were still using it.
    let slot = match cached() {
        Some(c) if c.slot >= 0 => c.slot,
        _ => mark_pending(acquire_slot()),
    };
    install(build(&bf), slot)
}

// ===========================================================================
// §3. Shared traversal primitives
// ===========================================================================

use std::cmp::Ordering;
use std::collections::{BinaryHeap, HashSet};

type Set<K> = HashSet<K, FxBuild>;

fn set<K>() -> Set<K> {
    HashSet::with_hasher(FxBuild)
}

/// A min-heap entry. `total_cmp` rather than `partial_cmp`, because a NaN
/// distance from a zero or negative weight would otherwise make the heap's
/// ordering inconsistent and silently drop entries.
struct QItem(f64, u32);
impl PartialEq for QItem {
    fn eq(&self, o: &Self) -> bool {
        self.0 == o.0 && self.1 == o.1
    }
}
impl Eq for QItem {}
impl Ord for QItem {
    fn cmp(&self, o: &Self) -> Ordering {
        o.0.total_cmp(&self.0).then_with(|| o.1.cmp(&self.1))
    }
}
impl PartialOrd for QItem {
    fn partial_cmp(&self, o: &Self) -> Option<Ordering> {
        Some(self.cmp(o))
    }
}

/// Neighbours of `v` as (other endpoint, weight, edge id).
///
/// Undirected by default, and that is a decision rather than laziness: the
/// edge table deliberately stores no inverse edge, and "what is this related
/// to" is not a question about arrow direction. `directed` is available for
/// the questions that are.
#[inline]
fn nbrs(g: &Snapshot, v: u32, directed: bool, f: &Filter, buf: &mut Vec<(u32, f32, u32)>) -> u64 {
    nbrs_dir(g, v, true, directed, f, buf)
}

/// Neighbours in one direction of travel. `forward` is the direction the
/// caller is walking; on an undirected graph both directions are the same
/// union, and the parameter costs nothing. It exists for the backward half of
/// a bidirectional search on a directed graph, which must follow in-edges or
/// it is searching a different graph from the forward half.
#[inline]
fn nbrs_dir(
    g: &Snapshot,
    v: u32,
    forward: bool,
    directed: bool,
    f: &Filter,
    buf: &mut Vec<(u32, f32, u32)>,
) -> u64 {
    buf.clear();
    let mut scanned = 0u64;
    if forward || !directed {
        for &eid in g.out(v) {
            scanned += 1;
            let e = &g.edges[eid as usize];
            if f.keep(e) {
                buf.push((e.dst, e.w, eid));
            }
        }
    }
    if !forward || !directed {
        for &eid in g.inc(v) {
            scanned += 1;
            let e = &g.edges[eid as usize];
            if f.keep(e) {
                buf.push((e.src, e.w, eid));
            }
        }
    }
    scanned
}

/// Edge cost: one per hop, plus the surprise of a low-confidence edge.
///
/// `weight` is documented as a confidence, so `-ln(w)` is the natural cost --
/// a path's cost is then the negative log of the product of its confidences.
/// The constant hop term is what stops a graph of confident edges from having
/// every path cost zero, which would make "shortest" meaningless; with it,
/// shortest means fewest hops, tie-broken by confidence.
#[inline]
fn cost_of(w: f32) -> f64 {
    let c = (w as f64).clamp(1.0e-6, 1.0);
    1.0 - c.ln()
}

/// Walk parent edges back from `v` to a source. Returns node ordinals from
/// source to `v`, and the edge ids used.
fn unwind(g: &Snapshot, sc: &Scratch, epoch: u32, v: u32) -> Option<(Vec<u32>, Vec<u32>)> {
    if sc.stamp[v as usize] != epoch {
        return None;
    }
    let mut nodes = vec![v];
    let mut eids: Vec<u32> = Vec::new();
    let mut cur = v;
    let mut guard = 0;
    while sc.parent[cur as usize] != u32::MAX {
        guard += 1;
        if guard > 4096 {
            return None;
        }
        let eid = sc.parent[cur as usize];
        let e = &g.edges[eid as usize];
        let prev = if e.dst == cur { e.src } else { e.dst };
        eids.push(eid);
        nodes.push(prev);
        cur = prev;
    }
    nodes.reverse();
    eids.reverse();
    Some((nodes, eids))
}

/// Bidirectional Dijkstra.
///
/// Added after measuring: the single-source version answered a random pair on
/// a 400k-edge graph in 148 ms at the median and exhausted its budget on one
/// call in five, because an unreachable or distant target makes a one-sided
/// search settle the entire component before it can say so. Two frontiers
/// meeting in the middle settle roughly the square root of that volume, and
/// the stopping rule -- top(forward) + top(backward) >= best-so-far -- is what
/// makes the answer still exact rather than merely fast.
#[allow(clippy::too_many_arguments)]
fn bidi(
    g: &Snapshot,
    sc: &mut Scratch,
    src: u32,
    dst: u32,
    banned_edges: &Set<u32>,
    banned_nodes: &Set<u32>,
    directed: bool,
    f: &Filter,
    b: &mut Budget,
) -> Option<(Vec<u32>, Vec<u32>, f64)> {
    if src == dst {
        return Some((vec![src], Vec::new(), 0.0));
    }
    if banned_nodes.contains(&src) || banned_nodes.contains(&dst) {
        return None;
    }
    let ef = sc.bump();
    let eb = sc.bump_b();
    let mut hf: BinaryHeap<QItem> = BinaryHeap::new();
    let mut hb: BinaryHeap<QItem> = BinaryHeap::new();
    sc.stamp[src as usize] = ef;
    sc.dist[src as usize] = 0.0;
    sc.parent[src as usize] = u32::MAX;
    sc.stamp_b[dst as usize] = eb;
    sc.dist_b[dst as usize] = 0.0;
    sc.parent_b[dst as usize] = u32::MAX;
    hf.push(QItem(0.0, src));
    hb.push(QItem(0.0, dst));
    let mut done_f: Set<u32> = set();
    let mut done_b: Set<u32> = set();
    let mut best = f64::INFINITY;
    let mut meet: Option<u32> = None;
    let mut buf: Vec<(u32, f32, u32)> = Vec::new();

    while !hf.is_empty() && !hb.is_empty() {
        let tf = hf.peek().map(|q| q.0).unwrap_or(f64::INFINITY);
        let tb = hb.peek().map(|q| q.0).unwrap_or(f64::INFINITY);
        if tf + tb >= best {
            break;
        }
        let forward = tf <= tb;
        let (d, v) = {
            let q = if forward { hf.pop() } else { hb.pop() }.unwrap();
            (q.0, q.1)
        };
        let already = if forward { !done_f.insert(v) } else { !done_b.insert(v) };
        if already {
            continue;
        }
        let cur = if forward { sc.dist[v as usize] } else { sc.dist_b[v as usize] };
        if d > cur {
            continue;
        }
        let scanned = nbrs_dir(g, v, forward, directed, f, &mut buf);
        if !b.spend(scanned) {
            break;
        }
        for &(u, w, eid) in buf.iter() {
            if banned_nodes.contains(&u) || banned_edges.contains(&eid) {
                continue;
            }
            let nd = d + cost_of(w);
            if forward {
                if sc.stamp[u as usize] != ef || nd < sc.dist[u as usize] {
                    sc.stamp[u as usize] = ef;
                    sc.dist[u as usize] = nd;
                    sc.parent[u as usize] = eid;
                    hf.push(QItem(nd, u));
                }
                if sc.stamp_b[u as usize] == eb {
                    let tot = nd + sc.dist_b[u as usize];
                    if tot < best {
                        best = tot;
                        meet = Some(u);
                    }
                }
            } else {
                if sc.stamp_b[u as usize] != eb || nd < sc.dist_b[u as usize] {
                    sc.stamp_b[u as usize] = eb;
                    sc.dist_b[u as usize] = nd;
                    sc.parent_b[u as usize] = eid;
                    hb.push(QItem(nd, u));
                }
                if sc.stamp[u as usize] == ef {
                    let tot = nd + sc.dist[u as usize];
                    if tot < best {
                        best = tot;
                        meet = Some(u);
                    }
                }
            }
        }
    }

    let m = meet?;
    let (mut nodes, mut eids) = unwind(g, sc, ef, m)?;
    // The backward half is stored pointing at dst, so it is walked forward
    // from the meeting point rather than reversed like the front half.
    let mut cur = m;
    let mut guard = 0;
    while sc.stamp_b[cur as usize] == eb && sc.parent_b[cur as usize] != u32::MAX {
        guard += 1;
        if guard > 4096 {
            return None;
        }
        let eid = sc.parent_b[cur as usize];
        let e = &g.edges[eid as usize];
        let next = if e.src == cur { e.dst } else { e.src };
        eids.push(eid);
        nodes.push(next);
        cur = next;
    }
    if *nodes.last()? != dst {
        return None;
    }
    let cost: f64 = eids.iter().map(|&e| cost_of(g.edges[e as usize].w)).sum();
    Some((nodes, eids, cost))
}

fn path_json(g: &Snapshot, nodes: &[u32], eids: &[u32]) -> Value {
    let mut hops = Vec::new();
    for (i, &eid) in eids.iter().enumerate() {
        let e = &g.edges[eid as usize];
        hops.push(json!({
            "from": g.ids[nodes[i] as usize].to_string(),
            "to": g.ids[nodes[i + 1] as usize].to_string(),
            "relation": g.rel_names[e.rel as usize],
            "weight": e.w,
            "reversed": e.dst == nodes[i],
        }));
    }
    json!({
        "hops": hops.len(),
        "nodes": nodes.iter().map(|&v| g.ids[v as usize].to_string()).collect::<Vec<_>>(),
        "path": hops,
    })
}

// ===========================================================================
// §4. Personalised PageRank -- "what is related to this", properly
//
// Andersen-Chung-Lang local push. The important property is not the ranking
// but the *locality*: a push walk touches the neighbourhood the mass actually
// reaches, never the whole graph, so its cost is a function of the seed's
// surroundings rather than of the corpus. That is what makes it affordable as
// a per-query operation on a graph a recursive CTE cannot even enumerate.
//
// It is anytime by construction. The residual vector is the unpushed mass, so
// stopping early returns an under-estimate of every score rather than a wrong
// ranking, and `converged` says which one you have.
// ===========================================================================

fn ppr(
    g: &Snapshot,
    sc: &mut Scratch,
    seeds: &[u32],
    alpha: f64,
    eps: f64,
    directed: bool,
    f: &Filter,
    b: &mut Budget,
) -> (Vec<(u32, f64)>, u64) {
    let epoch = sc.bump();
    let mut queue: Vec<u32> = Vec::new();
    let mut queued: Set<u32> = set();
    let mut touched: Vec<u32> = Vec::new();
    let share = 1.0 / seeds.len().max(1) as f64;
    let mut buf: Vec<(u32, f32, u32)> = Vec::new();

    for &s in seeds {
        if sc.stamp[s as usize] != epoch {
            sc.stamp[s as usize] = epoch;
            sc.p[s as usize] = 0.0;
            sc.r[s as usize] = 0.0;
            touched.push(s);
        }
        sc.r[s as usize] += share;
        if queued.insert(s) {
            queue.push(s);
        }
    }

    let mut head = 0usize;
    let mut pushes = 0u64;
    while head < queue.len() {
        let v = queue[head];
        head += 1;
        queued.remove(&v);
        let rv = sc.r[v as usize];
        if rv <= 0.0 {
            continue;
        }
        let scanned = nbrs(g, v, directed, f, &mut buf);
        if !b.spend(scanned) {
            break;
        }
        let deg: f64 = buf.len() as f64;
        // The ACL threshold: a node is worth pushing only while its residual
        // is large relative to its degree. Without it a hub re-enters the
        // queue forever for mass that will never change a ranking.
        if deg > 0.0 && rv < eps * deg {
            continue;
        }
        pushes += 1;
        sc.r[v as usize] = 0.0;
        sc.p[v as usize] += alpha * rv;
        let mass = (1.0 - alpha) * rv;
        if deg == 0.0 {
            sc.p[v as usize] += mass;
            continue;
        }
        let wsum: f64 = buf.iter().map(|&(_, w, _)| (w as f64).max(1.0e-6)).sum();
        for &(u, w, _) in buf.iter() {
            if sc.stamp[u as usize] != epoch {
                sc.stamp[u as usize] = epoch;
                sc.p[u as usize] = 0.0;
                sc.r[u as usize] = 0.0;
                touched.push(u);
            }
            sc.r[u as usize] += mass * (w as f64).max(1.0e-6) / wsum;
            if queued.insert(u) {
                queue.push(u);
            }
        }
        // The queue is compacted rather than grown without bound: a walk on a
        // hub-heavy graph can otherwise hold millions of dead entries.
        if head > 1_000_000 {
            queue.drain(..head);
            head = 0;
        }
    }

    let mut out: Vec<(u32, f64)> = touched
        .iter()
        .filter(|&&v| sc.p[v as usize] > 0.0)
        .map(|&v| (v, sc.p[v as usize]))
        .collect();
    out.sort_by(|a, b| b.1.total_cmp(&a.1));
    (out, pushes)
}

// ===========================================================================
// §5. Top-k shortest paths -- the mode PGQ cannot express at all
//
// `GRAPH_TABLE` has no quantified path pattern, so "how are these two
// connected" is already a recursive CTE; and a recursive CTE can enumerate
// paths but cannot rank them, so "the three best" means enumerating everything
// and sorting -- which on a connected graph is not a query, it is an outage.
//
// Yen's algorithm over bidirectional-capable Dijkstra, budgeted. The temporal
// filter is applied at edge relax, which is the only place it can be applied
// correctly: filtering the result set afterwards returns the *k best paths
// including expired edges*, minus the ones that happened to be expired.
// ===========================================================================

#[allow(clippy::too_many_arguments)]
fn k_shortest(
    g: &Snapshot,
    sc: &mut Scratch,
    src: u32,
    dst: u32,
    k: usize,
    max_hops: usize,
    directed: bool,
    f: &Filter,
    b: &mut Budget,
) -> Vec<(Vec<u32>, Vec<u32>, f64)> {
    let empty_e: Set<u32> = set();
    let empty_n: Set<u32> = set();
    let mut found: Vec<(Vec<u32>, Vec<u32>, f64)> = Vec::new();

    match bidi(g, sc, src, dst, &empty_e, &empty_n, directed, f, b) {
        Some((nodes, eids, c)) if eids.len() <= max_hops => found.push((nodes, eids, c)),
        _ => return found,
    }

    let mut candidates: Vec<(Vec<u32>, Vec<u32>, f64)> = Vec::new();
    while found.len() < k {
        let prev = found.last().unwrap().clone();
        for i in 0..prev.0.len().saturating_sub(1) {
            if b.exhausted {
                break;
            }
            let spur = prev.0[i];
            let root: Vec<u32> = prev.0[..=i].to_vec();
            let root_e: Vec<u32> = prev.1[..i].to_vec();
            let mut banned_e: Set<u32> = set();
            for p in found.iter().chain(candidates.iter()) {
                if p.0.len() > i && p.0[..=i] == root[..] {
                    if let Some(&e) = p.1.get(i) {
                        banned_e.insert(e);
                    }
                }
            }
            let mut banned_n: Set<u32> = set();
            for &v in &root[..i] {
                banned_n.insert(v);
            }
            let spur_path = bidi(g, sc, spur, dst, &banned_e, &banned_n, directed, f, b);
            if let Some((mut nodes, mut eids, _)) = spur_path {
                let mut full_n = root.clone();
                full_n.extend(nodes.drain(1..));
                let mut full_e = root_e.clone();
                full_e.append(&mut eids);
                if full_e.len() > max_hops {
                    continue;
                }
                let cost: f64 = full_e.iter().map(|&e| cost_of(g.edges[e as usize].w)).sum();
                if !found.iter().any(|p| p.1 == full_e) && !candidates.iter().any(|p| p.1 == full_e) {
                    candidates.push((full_n, full_e, cost));
                }
            }
        }
        if candidates.is_empty() || b.exhausted {
            break;
        }
        candidates.sort_by(|a, c| a.2.total_cmp(&c.2));
        found.push(candidates.remove(0));
    }
    found
}

// ===========================================================================
// §6. Dense subgraph -- k-core, then cliques inside the densest part
//
// `brief.md` §3 names "clique/collusion detection" as a pgrx case, and it is
// the clearest one: maximal clique enumeration is NP-hard, so it cannot be a
// query, only a budgeted search. The budget is structural as well as temporal
// -- the induced subgraph is capped first, by expanding a frontier from the
// seed, so the exponential part only ever runs on a bounded neighbourhood.
// ===========================================================================

struct Local {
    nodes: Vec<u32>,
    /// local index -> local neighbours, deduplicated and self-loop free
    adj: Vec<Vec<u32>>,
}

fn induce(g: &Snapshot, seed: u32, max_nodes: usize, f: &Filter, b: &mut Budget) -> Local {
    let mut order: Vec<u32> = vec![seed];
    let mut seen: Set<u32> = set();
    seen.insert(seed);
    let mut head = 0;
    let mut buf: Vec<(u32, f32, u32)> = Vec::new();
    while head < order.len() && order.len() < max_nodes {
        let v = order[head];
        head += 1;
        let scanned = nbrs(g, v, false, f, &mut buf);
        if !b.spend(scanned) {
            break;
        }
        for &(u, _, _) in buf.iter() {
            if order.len() >= max_nodes {
                break;
            }
            if seen.insert(u) {
                order.push(u);
            }
        }
    }
    let mut local: Map<u32, u32> = map();
    for (i, &v) in order.iter().enumerate() {
        local.insert(v, i as u32);
    }
    let mut adj: Vec<Vec<u32>> = vec![Vec::new(); order.len()];
    for (i, &v) in order.iter().enumerate() {
        nbrs(g, v, false, f, &mut buf);
        for &(u, _, _) in buf.iter() {
            if let Some(&j) = local.get(&u) {
                if j as usize != i {
                    adj[i].push(j);
                }
            }
        }
        adj[i].sort_unstable();
        adj[i].dedup();
    }
    Local { nodes: order, adj }
}

/// k-core by peeling. O(V + E) on the induced subgraph, and the core number is
/// the honest "how dense is the company this node keeps" -- a triangle count
/// says the same thing about one node, a core number says it about a group.
fn k_core(l: &Local) -> Vec<u32> {
    let n = l.nodes.len();
    let mut deg: Vec<u32> = l.adj.iter().map(|a| a.len() as u32).collect();
    let mut core = vec![0u32; n];
    let mut removed = vec![false; n];
    let mut heap: BinaryHeap<QItem> = BinaryHeap::new();
    for i in 0..n {
        heap.push(QItem(deg[i] as f64, i as u32));
    }
    let mut k = 0u32;
    while let Some(QItem(d, v)) = heap.pop() {
        let v = v as usize;
        if removed[v] || d as u32 != deg[v] {
            continue;
        }
        k = k.max(deg[v]);
        core[v] = k;
        removed[v] = true;
        for &u in &l.adj[v] {
            let u = u as usize;
            if !removed[u] && deg[u] > 0 {
                deg[u] -= 1;
                heap.push(QItem(deg[u] as f64, u as u32));
            }
        }
    }
    core
}

/// Bron-Kerbosch with pivoting, over a node subset, budgeted.
///
/// The recursion is bounded twice -- by the subset it runs on and by the
/// budget -- because the failure mode of clique enumeration is not slowness,
/// it is a query that never returns on a graph that looked ordinary.
fn cliques(l: &Local, subset: &[u32], min_size: usize, b: &mut Budget) -> Vec<Vec<u32>> {
    let inset: Set<u32> = subset.iter().copied().collect();
    let mut out: Vec<Vec<u32>> = Vec::new();
    fn go(
        l: &Local,
        inset: &Set<u32>,
        r: &mut Vec<u32>,
        p: Vec<u32>,
        x: Vec<u32>,
        min_size: usize,
        out: &mut Vec<Vec<u32>>,
        b: &mut Budget,
    ) {
        if b.exhausted || out.len() >= 64 {
            return;
        }
        if p.is_empty() && x.is_empty() {
            if r.len() >= min_size {
                out.push(r.clone());
            }
            return;
        }
        if !b.spend((p.len() + x.len()) as u64) {
            return;
        }
        let pivot = p
            .iter()
            .chain(x.iter())
            .copied()
            .max_by_key(|&u| l.adj[u as usize].len())
            .unwrap();
        let pivot_nbrs: Set<u32> = l.adj[pivot as usize].iter().copied().collect();
        let cand: Vec<u32> = p.iter().copied().filter(|v| !pivot_nbrs.contains(v)).collect();
        let mut p = p;
        let mut x = x;
        for v in cand {
            let nv: Set<u32> = l.adj[v as usize]
                .iter()
                .copied()
                .filter(|u| inset.contains(u))
                .collect();
            r.push(v);
            let np: Vec<u32> = p.iter().copied().filter(|u| nv.contains(u)).collect();
            let nx: Vec<u32> = x.iter().copied().filter(|u| nv.contains(u)).collect();
            go(l, inset, r, np, nx, min_size, out, b);
            r.pop();
            p.retain(|&u| u != v);
            x.push(v);
            if b.exhausted {
                return;
            }
        }
    }
    let mut r: Vec<u32> = Vec::new();
    go(l, &inset, &mut r, subset.to_vec(), Vec::new(), min_size, &mut out, b);
    out.sort_by_key(|c| std::cmp::Reverse(c.len()));
    out
}

// ===========================================================================
// §7. Trust propagation -- how much of this answer is a model's guess
//
// Every extracted edge carries a weight and a provenance; every resolution
// carries a tier. `graph-index.md` §5 throws away what does not resolve, but
// what survives is still a mixture of registry matches and model guesses, and
// nothing downstream can currently tell them apart *after a traversal*, which
// is exactly where the mixing happens.
//
// Two numbers, and they answer different questions. `confidence` is the
// best single path, computed as max-product -- a Dijkstra in -ln(w) space, no
// hop constant, because a long chain of certain edges should not be penalised
// for its length. `support` is noisy-OR over the distinct neighbours that
// carry belief into the node: two independent paths saying the same thing is
// evidence, and a single path repeated is not.
// ===========================================================================

#[allow(clippy::too_many_arguments)]
fn trust(
    g: &Snapshot,
    sc: &mut Scratch,
    seeds: &[u32],
    floor: f64,
    top_k: usize,
    directed: bool,
    f: &Filter,
    b: &mut Budget,
) -> (Vec<(u32, f64, usize)>, usize) {
    let epoch = sc.bump();
    let mut heap: BinaryHeap<QItem> = BinaryHeap::new();
    let mut buf: Vec<(u32, f32, u32)> = Vec::new();
    let mut touched: Vec<u32> = Vec::new();
    let max_cost = -floor.max(1.0e-9).ln();
    for &s in seeds {
        sc.stamp[s as usize] = epoch;
        sc.dist[s as usize] = 0.0;
        sc.parent[s as usize] = u32::MAX;
        touched.push(s);
        heap.push(QItem(0.0, s));
    }
    // The walk settles in increasing cost, which is decreasing confidence, so
    // the first k nodes it settles ARE the k most confident. Stopping there is
    // exact for the ranking and turns an exploration of the component into a
    // bounded one -- which is the difference between 277 ms with the budget
    // exhausted on every call and a few milliseconds.
    //
    // A confidence floor does NOT do this, and that is the measurement that
    // rewrote this function: on a small-world graph a floor of 0.2 and a floor
    // of 0.05 both reached two thirds of a million nodes, because five hops of
    // 0.65-weight edges still clears either. A floor bounds belief; only a rank
    // bound bounds work.
    //
    // The margin over top_k is for the corroboration step, which can lift a
    // node above nodes settled before it.
    let settle_cap = (top_k * 4).max(256);
    let mut settled: Set<u32> = set();
    while let Some(QItem(d, v)) = heap.pop() {
        if !settled.insert(v) || d > sc.dist[v as usize] {
            continue;
        }
        if settled.len() > settle_cap {
            break;
        }
        let scanned = nbrs(g, v, directed, f, &mut buf);
        if !b.spend(scanned) {
            break;
        }
        for &(u, w, _) in buf.iter() {
            let nd = d - (w as f64).clamp(1.0e-6, 1.0).ln();
            if nd > max_cost {
                continue;
            }
            if sc.stamp[u as usize] != epoch {
                sc.stamp[u as usize] = epoch;
                sc.dist[u as usize] = f64::INFINITY;
                touched.push(u);
            }
            if nd < sc.dist[u as usize] {
                sc.dist[u as usize] = nd;
                heap.push(QItem(nd, u));
            }
        }
    }
    // Corroboration is computed AFTER the ranking and only for the rows that
    // will be returned. The first version computed it for every settled node,
    // in a loop that charged nothing to the budget: on a million-node graph
    // that second pass took longer than the walk it was annotating -- 668 ms
    // against a 250 ms budget that reported itself exhausted, which is the
    // worst of both, a bound that is announced and not kept. Support is a
    // property of a row somebody reads, so it is computed for those rows.
    let mut ranked: Vec<(u32, f64)> = touched
        .iter()
        .filter(|&&v| sc.stamp[v as usize] == epoch && sc.dist[v as usize].is_finite())
        .map(|&v| (v, (-sc.dist[v as usize]).exp()))
        .filter(|&(_, c)| c >= floor)
        .collect();
    let reached = ranked.len();
    ranked.sort_by(|a, c| c.1.total_cmp(&a.1));
    ranked.truncate(top_k);

    let mut out: Vec<(u32, f64, usize)> = Vec::with_capacity(ranked.len());
    for &(v, conf) in ranked.iter() {
        let scanned = nbrs(g, v, directed, f, &mut buf);
        b.spend(scanned);
        let mut support = 0usize;
        let mut none_of_them = 1.0f64;
        for &(u, w, _) in buf.iter() {
            if sc.stamp[u as usize] != epoch || u == v {
                continue;
            }
            let cu = (-sc.dist[u as usize]).exp() * (w as f64).clamp(0.0, 1.0);
            if cu >= floor && sc.dist[u as usize] < sc.dist[v as usize] {
                support += 1;
                none_of_them *= 1.0 - cu.min(0.999);
            }
        }
        let combined = if support == 0 { conf } else { conf.max(1.0 - none_of_them) };
        out.push((v, combined, support));
    }
    out.sort_by(|a, c| c.1.total_cmp(&a.1));
    (out, reached)
}

// ===========================================================================
// §8. Minimum connecting subgraph -- "how are these N things related?"
//
// The classic 2-approximation for the Steiner tree: shortest paths between
// every pair of terminals, a minimum spanning tree over that metric closure,
// then the union of the paths with non-terminal leaves pruned. NP-hard, so it
// is budgeted by construction, and the approximation ratio is the price of
// having an answer at all.
//
// This is the operation that turns a result list into a picture. A retrieval
// returns eight entities; the honest follow-up question is not "which is most
// relevant" but "what connects them", and no amount of ranking answers it.
// ===========================================================================

/// How far the connecting walk is allowed to spread before it gives up on the
/// terminals it has not reached. A structural bound on top of the time budget,
/// because the failure it prevents is not slowness: an unbounded walk on a
/// four-million-edge graph settles the whole component and returns a partial
/// answer anyway, having spent the entire budget proving that two of the five
/// terminals are far apart.
const CONNECT_SETTLE_CAP: usize = 50_000;

fn connect(
    g: &Snapshot,
    sc: &mut Scratch,
    terms: &[u32],
    f: &Filter,
    b: &mut Budget,
) -> (Vec<u32>, Vec<u32>, usize) {
    // Mehlhorn's variant, which replaced one Dijkstra per terminal after that
    // shape took 502 ms of a 500 ms budget on every call at four million
    // edges. Same 2-approximation, one walk: a multi-source Dijkstra labels
    // every node with the terminal nearest it, and the shortest connection
    // between two terminals is then found by scanning edges that cross a
    // territory boundary -- an O(m) pass over what was settled, rather than
    // |T| separate explorations of the same neighbourhood.
    let t = terms.len();
    let epoch = sc.bump();
    let mut heap: BinaryHeap<QItem> = BinaryHeap::new();
    for (i, &v) in terms.iter().enumerate() {
        sc.stamp[v as usize] = epoch;
        sc.dist[v as usize] = 0.0;
        sc.parent[v as usize] = u32::MAX;
        sc.region[v as usize] = i as u32;
        heap.push(QItem(0.0, v));
    }
    let mut settled: Set<u32> = set();
    let mut order: Vec<u32> = Vec::new();
    let mut buf: Vec<(u32, f32, u32)> = Vec::new();
    while let Some(QItem(d, v)) = heap.pop() {
        if d > sc.dist[v as usize] || !settled.insert(v) {
            continue;
        }
        order.push(v);
        if order.len() >= CONNECT_SETTLE_CAP {
            break;
        }
        let scanned = nbrs(g, v, false, f, &mut buf);
        if !b.spend(scanned) {
            break;
        }
        let rv = sc.region[v as usize];
        for &(u, w, eid) in buf.iter() {
            let nd = d + cost_of(w);
            if sc.stamp[u as usize] != epoch || nd < sc.dist[u as usize] {
                sc.stamp[u as usize] = epoch;
                sc.dist[u as usize] = nd;
                sc.parent[u as usize] = eid;
                sc.region[u as usize] = rv;
                heap.push(QItem(nd, u));
            }
        }
    }

    // The metric closure, read off the boundaries between territories.
    let mut closure: Map<(u32, u32), (f64, u32)> = map();
    for &v in order.iter() {
        let rv = sc.region[v as usize];
        if rv == u32::MAX {
            continue;
        }
        let scanned = nbrs(g, v, false, f, &mut buf);
        if !b.spend(scanned) {
            break;
        }
        for &(u, w, eid) in buf.iter() {
            if sc.stamp[u as usize] != epoch || !settled.contains(&u) {
                continue;
            }
            let ru = sc.region[u as usize];
            if ru == u32::MAX || ru == rv {
                continue;
            }
            let cost = sc.dist[v as usize] + cost_of(w) + sc.dist[u as usize];
            let key = (rv.min(ru), rv.max(ru));
            match closure.get(&key) {
                Some(&(c, _)) if c <= cost => {}
                _ => {
                    closure.insert(key, (cost, eid));
                }
            }
        }
    }

    // Prim over the terminals. A terminal whose territory never met another's
    // is simply not joined, and is counted rather than quietly dropped.
    let mut in_tree = vec![false; t];
    in_tree[0] = true;
    let mut chosen: Vec<u32> = Vec::new();
    for _ in 1..t {
        let mut best: Option<(f64, u32, usize)> = None;
        for i in 0..t {
            if !in_tree[i] {
                continue;
            }
            for j in 0..t {
                if in_tree[j] {
                    continue;
                }
                let key = ((i as u32).min(j as u32), (i as u32).max(j as u32));
                if let Some(&(c, eid)) = closure.get(&key) {
                    if best.map(|(bc, _, _)| c < bc).unwrap_or(true) {
                        best = Some((c, eid, j));
                    }
                }
            }
        }
        match best {
            Some((_, eid, j)) => {
                in_tree[j] = true;
                chosen.push(eid);
            }
            None => break,
        }
    }

    let mut nodes: Set<u32> = terms.iter().copied().collect();
    let mut eids: Set<u32> = set();
    for &eid in chosen.iter() {
        eids.insert(eid);
        let e = &g.edges[eid as usize];
        // Both ends walk home to their own terminal through the parent tree.
        for &end in [e.src, e.dst].iter() {
            nodes.insert(end);
            let mut cur = end;
            let mut guard = 0;
            while sc.stamp[cur as usize] == epoch && sc.parent[cur as usize] != u32::MAX {
                guard += 1;
                if guard > 4096 {
                    break;
                }
                let pe = sc.parent[cur as usize];
                eids.insert(pe);
                let pedge = &g.edges[pe as usize];
                let prev = if pedge.dst == cur { pedge.src } else { pedge.dst };
                nodes.insert(prev);
                cur = prev;
            }
        }
    }

    // Prune: a non-terminal leaf is a path that went somewhere and came back.
    let termset: Set<u32> = terms.iter().copied().collect();
    loop {
        let mut deg: Map<u32, usize> = map();
        for &e in eids.iter() {
            let ed = &g.edges[e as usize];
            *deg.entry(ed.src).or_insert(0) += 1;
            *deg.entry(ed.dst).or_insert(0) += 1;
        }
        let leaves: Vec<u32> = deg
            .iter()
            .filter(|(v, &d)| d == 1 && !termset.contains(v))
            .map(|(&v, _)| v)
            .collect();
        if leaves.is_empty() {
            break;
        }
        let leafset: Set<u32> = leaves.iter().copied().collect();
        eids.retain(|&e| {
            let ed = &g.edges[e as usize];
            !leafset.contains(&ed.src) && !leafset.contains(&ed.dst)
        });
        for v in leaves {
            nodes.remove(&v);
        }
    }

    let connected = in_tree.iter().filter(|&&x| x).count();
    (nodes.into_iter().collect(), eids.into_iter().collect(), connected)
}

// ===========================================================================
// §9. Reach sketches -- how big is the frontier, answered before the walk
//
// The reason a DEPTH-3 traversal falls over is not that three hops is hard; it
// is that nobody knows the frontier is 400,000 nodes until they are holding
// it. HyperANF gives that number in O(1) at query time for the price of a few
// passes at build time, and it is the input a planner or a dialect needs to
// refuse or downgrade a query *before* spending the budget -- the same
// "convert a quiet failure into a refusal" discipline the modes are built on.
//
// Only the cardinality is kept, not the sketch. The registers are needed to
// UNION neighbourhoods during the build; afterwards, four bytes per node per
// depth answers the question, and 16 bytes per node per depth does not answer
// it any better. (A variant that keeps the registers buys neighbourhood
// Jaccard similarity as well -- worth having, not built here.)
// ===========================================================================

// 64 registers: 16 was measured at a 16% median and 51% p95 relative error on
// the scale fixture, which is too loose to gate a query on -- the p95 is the
// number that decides, and half a magnitude is not a bound. 64 costs nothing
// at rest (the registers are not kept) and four times the transient memory
// during the build, which is the cheapest part of the index.
const HLL_P: usize = 6;
const HLL_M: usize = 1 << HLL_P;

struct Reach {
    depth: usize,
    est: Vec<f32>, // n * depth, row-major by depth
    build_ms: f64,
}

impl Reach {
    fn bytes(&self) -> usize {
        self.est.len() * 4
    }
    fn at(&self, v: u32, d: usize) -> f32 {
        if d == 0 || d > self.depth {
            return f32::NAN;
        }
        self.est[(d - 1) * (self.est.len() / self.depth) + v as usize]
    }
}

#[inline]
fn hll_estimate(regs: &[u8]) -> f64 {
    let m = regs.len() as f64;
    let mut sum = 0.0f64;
    let mut zeros = 0usize;
    for &r in regs {
        sum += 2.0f64.powi(-(r as i32));
        if r == 0 {
            zeros += 1;
        }
    }
    // The standard bias constant for m >= 64; the small-m values (0.673 at 16,
    // 0.697 at 32) differ enough to matter, so this is not a constant to carry
    // over unchanged if HLL_P moves down.
    let alpha = 0.7213 / (1.0 + 1.079 / m);
    let e = alpha * m * m / sum;
    // Linear counting below the raw estimator's usable range. Most
    // neighbourhoods in a real graph are small, so this branch is the common
    // one and leaving it out would make the index wrong exactly where it is
    // most used.
    if e <= 2.5 * m && zeros > 0 {
        m * (m / zeros as f64).ln()
    } else {
        e
    }
}

fn build_reach(g: &Snapshot, depth: usize, b: &mut Budget) -> Option<Reach> {
    let t0 = Instant::now();
    let n = g.n();
    if n == 0 {
        return None;
    }
    let mut cur = vec![0u8; n * HLL_M];
    let mut next = vec![0u8; n * HLL_M];
    for v in 0..n {
        let mut h = FxHasher::default();
        std::hash::Hasher::write(&mut h, &(v as u64).to_le_bytes());
        let x = std::hash::Hasher::finish(&h);
        let idx = (x >> (64 - HLL_P)) as usize;
        let rho = ((x << HLL_P) | (1 << (HLL_P - 1))).leading_zeros() as u8 + 1;
        cur[v * HLL_M + idx] = rho;
    }
    let f = Filter { rel: None, as_of: None };
    let mut est = vec![0f32; n * depth];
    let mut buf: Vec<(u32, f32, u32)> = Vec::new();
    for d in 0..depth {
        next.copy_from_slice(&cur);
        for v in 0..n {
            let scanned = nbrs(g, v as u32, false, &f, &mut buf);
            if !b.spend(scanned.max(1)) {
                return None;
            }
            for &(u, _, _) in buf.iter() {
                for j in 0..HLL_M {
                    let a = next[v * HLL_M + j];
                    let c = cur[u as usize * HLL_M + j];
                    if c > a {
                        next[v * HLL_M + j] = c;
                    }
                }
            }
        }
        std::mem::swap(&mut cur, &mut next);
        for v in 0..n {
            est[d * n + v] = hll_estimate(&cur[v * HLL_M..(v + 1) * HLL_M]) as f32;
        }
    }
    Some(Reach { depth, est, build_ms: t0.elapsed().as_secs_f64() * 1000.0 })
}

/// Exact reach, for checking the sketch. Budgeted, because on a hub it is the
/// query the sketch exists to avoid.
fn exact_reach(g: &Snapshot, sc: &mut Scratch, v: u32, depth: usize, b: &mut Budget) -> (usize, bool) {
    let epoch = sc.bump();
    let f = Filter { rel: None, as_of: None };
    let mut frontier = vec![v];
    sc.stamp[v as usize] = epoch;
    let mut seen = 1usize;
    let mut buf: Vec<(u32, f32, u32)> = Vec::new();
    for _ in 0..depth {
        let mut nextf: Vec<u32> = Vec::new();
        for &x in frontier.iter() {
            let scanned = nbrs(g, x, false, &f, &mut buf);
            if !b.spend(scanned) {
                return (seen, false);
            }
            for &(u, _, _) in buf.iter() {
                if sc.stamp[u as usize] != epoch {
                    sc.stamp[u as usize] = epoch;
                    seen += 1;
                    nextf.push(u);
                }
            }
        }
        frontier = nextf;
        if frontier.is_empty() {
            break;
        }
    }
    (seen, true)
}

// ===========================================================================
// §10. Pruned landmark labeling -- exact distance, if it will build
//
// The most attractive index on paper: distance between any two nodes by
// intersecting two sorted lists, microseconds, no traversal. The whole
// question is whether the build survives contact with a real graph, and
// whether the labels fit. It is included here to be *measured*, not because
// the outcome is assumed -- an index whose build cost is superlinear on the
// graphs this system actually holds is not an index, it is a research note.
// ===========================================================================

struct Labels {
    lab: Vec<Vec<(u32, u8)>>,
    roots: usize,
    entries: usize,
    build_ms: f64,
    complete: bool,
}

impl Labels {
    fn bytes(&self) -> usize {
        self.entries * 8 + self.lab.len() * 24
    }
    /// Distance by merge-intersection of two sorted label lists.
    fn query(&self, u: u32, v: u32) -> Option<u32> {
        let (a, b) = (&self.lab[u as usize], &self.lab[v as usize]);
        let (mut i, mut j) = (0usize, 0usize);
        let mut best = u32::MAX;
        while i < a.len() && j < b.len() {
            match a[i].0.cmp(&b[j].0) {
                Ordering::Less => i += 1,
                Ordering::Greater => j += 1,
                Ordering::Equal => {
                    best = best.min(a[i].1 as u32 + b[j].1 as u32);
                    i += 1;
                    j += 1;
                }
            }
        }
        if best == u32::MAX {
            None
        } else {
            Some(best)
        }
    }
}

fn build_labels(g: &Snapshot, b: &mut Budget, max_entries: usize) -> Labels {
    let t0 = Instant::now();
    let n = g.n();
    let mut lab: Vec<Vec<(u32, u8)>> = vec![Vec::new(); n];
    let mut order: Vec<u32> = (0..n as u32).collect();
    // Highest degree first: the standard ordering, and the one the pruning
    // argument depends on -- a hub covers most pairs, so later roots prune
    // almost immediately. A bad order does not make the index wrong, it makes
    // it enormous.
    order.sort_by_key(|&v| std::cmp::Reverse(g.out(v).len() + g.inc(v).len()));
    let f = Filter { rel: None, as_of: None };
    let mut dist = vec![u8::MAX; n];
    let mut touched: Vec<u32> = Vec::new();
    let mut buf: Vec<(u32, f32, u32)> = Vec::new();
    let mut roots = 0usize;
    let mut entries = 0usize;
    let mut complete = true;

    for (rank, &root) in order.iter().enumerate() {
        if b.exhausted {
            complete = false;
            break;
        }
        // A second ceiling, on memory rather than time. The label set is the
        // thing that decides whether this index is usable, and an index that
        // needs gigabytes to answer a hop count has already failed -- better
        // to stop and report the size than to find out by being killed.
        if entries > max_entries {
            complete = false;
            break;
        }
        roots += 1;
        let mut frontier = vec![root];
        dist[root as usize] = 0;
        touched.push(root);
        lab[root as usize].push((rank as u32, 0));
        entries += 1;
        let mut d = 0u8;
        while !frontier.is_empty() && d < 254 {
            d += 1;
            let mut nextf: Vec<u32> = Vec::new();
            for &x in frontier.iter() {
                let scanned = nbrs(g, x, false, &f, &mut buf);
                if !b.spend(scanned) {
                    complete = false;
                    break;
                }
                for &(u, _, _) in buf.iter() {
                    if dist[u as usize] != u8::MAX {
                        continue;
                    }
                    // The prune: if what is already labelled explains this
                    // distance, the label adds nothing.
                    let known = {
                        let (a, bb) = (&lab[root as usize], &lab[u as usize]);
                        let (mut i, mut j) = (0usize, 0usize);
                        let mut best = u32::MAX;
                        while i < a.len() && j < bb.len() {
                            match a[i].0.cmp(&bb[j].0) {
                                Ordering::Less => i += 1,
                                Ordering::Greater => j += 1,
                                Ordering::Equal => {
                                    best = best.min(a[i].1 as u32 + bb[j].1 as u32);
                                    i += 1;
                                    j += 1;
                                }
                            }
                        }
                        best
                    };
                    dist[u as usize] = d;
                    touched.push(u);
                    if known <= d as u32 {
                        continue;
                    }
                    lab[u as usize].push((rank as u32, d));
                    entries += 1;
                    nextf.push(u);
                }
            }
            if b.exhausted {
                complete = false;
                break;
            }
            frontier = nextf;
        }
        // STOPPING AT THE DEPTH CAP IS AN INCOMPLETE INDEX, NOT A FINISHED ONE.
        //
        // Distances are u8, so a root's BFS stops at 254 hops. The two ceilings
        // above -- the budget and the entry count -- both say so by setting
        // `complete = false`; this one said nothing, and `complete` is exactly
        // what p8_graph_distance reports as `exact`.
        //
        // So a pair further apart than the cap answered `{"distance": null,
        // "exact": true}` -- no common landmark, rendered as no path, and
        // marked as a proven answer. MEASURED on a 300-node path:
        //
        //     n1 -> n200 (199 hops)  -> distance 199, exact true   (right)
        //     n1 -> n300 (299 hops)  -> distance null, exact true   (wrong,
        //                                and the two nodes are plainly joined)
        //
        // `exact` exists to separate a proof from an upper bound, so the one
        // state it must never describe is a wrong answer. A graph with a
        // diameter past 254 is unusual -- a lineage or document chain is where
        // it happens -- and being unusual is what makes reporting it matter,
        // because nobody is going to notice it any other way.
        //
        // The cap itself stays: distances are a byte because the label set is
        // what decides whether this index is usable at all (see the entry
        // ceiling above), and widening them to answer a rare case would cost
        // memory on every common one. Refusing to claim exactness is the honest
        // form of the same limit.
        if !frontier.is_empty() {
            complete = false;
        }
        for &v in touched.iter() {
            dist[v as usize] = u8::MAX;
        }
        touched.clear();
    }
    Labels {
        lab,
        roots,
        entries,
        build_ms: t0.elapsed().as_secs_f64() * 1000.0,
        complete,
    }
}

// ===========================================================================
// §11. Communities -- label propagation
//
// Not Leiden. Label propagation is O(m) per round with a small constant, and
// the thing communities are wanted for here is locality: a partition good
// enough to cluster the edge table by, and to answer "what neighbourhood is
// this in" as a column rather than a walk. Modularity to three decimal places
// is not what makes REPACK pay off.
// ===========================================================================

/// Newman modularity of a partition, in one pass over the edges.
///
/// The metric that decides whether a partition is worth having. "How big is
/// the largest community" does not: on a graph with a hub, label propagation
/// happily returns one community containing 91% of the nodes and several
/// hundred singletons, which looks like a result and is not one. Q near zero
/// says exactly that, and it says it without needing a fixture whose true
/// communities are known.
fn modularity(g: &Snapshot, lbl: &[u32]) -> f64 {
    let m = g.m() as f64;
    if m == 0.0 {
        return 0.0;
    }
    let mut inside = 0.0f64;
    let mut dsum: Map<u32, f64> = map();
    for e in g.edges.iter() {
        let (a, c) = (lbl[e.src as usize], lbl[e.dst as usize]);
        if a == c {
            inside += 1.0;
        }
        *dsum.entry(a).or_insert(0.0) += 1.0;
        *dsum.entry(c).or_insert(0.0) += 1.0;
    }
    let m2 = 2.0 * m;
    inside / m - dsum.values().map(|d| (d / m2) * (d / m2)).sum::<f64>()
}

fn label_prop(g: &Snapshot, iters: usize, b: &mut Budget) -> (Vec<u32>, usize, usize, f64) {
    let t0 = Instant::now();
    let n = g.n();
    let mut lbl: Vec<u32> = (0..n as u32).collect();
    let f = Filter { rel: None, as_of: None };
    let mut buf: Vec<(u32, f32, u32)> = Vec::new();
    let mut tally: Map<u32, f64> = map();
    let mut rounds = 0usize;
    for _ in 0..iters {
        rounds += 1;
        let mut changed = 0usize;
        // A fixed coprime stride instead of a shuffle: asynchronous updates
        // need an order that is not the adjacency order (which makes labels
        // sweep across the graph), but it must also be reproducible or a scale
        // number cannot be compared with the next one.
        let stride = 1_000_003u64;
        for k in 0..n as u64 {
            let v = ((k.wrapping_mul(stride)) % n.max(1) as u64) as u32;
            let scanned = nbrs(g, v, false, &f, &mut buf);
            if !b.spend(scanned.max(1)) {
                return (lbl, 0, rounds, t0.elapsed().as_secs_f64() * 1000.0);
            }
            if buf.is_empty() {
                continue;
            }
            tally.clear();
            for &(u, w, _) in buf.iter() {
                *tally.entry(lbl[u as usize]).or_insert(0.0) += (w as f64).max(1.0e-6);
            }
            // Ties broken by the smaller label, so the result does not depend
            // on hash iteration order.
            let best = tally
                .iter()
                .max_by(|a, c| a.1.total_cmp(c.1).then_with(|| c.0.cmp(a.0)))
                .map(|(&l, _)| l)
                .unwrap();
            if best != lbl[v as usize] {
                lbl[v as usize] = best;
                changed += 1;
            }
        }
        if changed * 1000 < n {
            break;
        }
    }
    let uniq: Set<u32> = lbl.iter().copied().collect();
    (lbl, uniq.len(), rounds, t0.elapsed().as_secs_f64() * 1000.0)
}

// ===========================================================================
// §12. Entry points
//
// Every one returns JSONB with the same shape: `ok`, a `meta` block carrying
// the budget outcome and the snapshot it ran against, and the result. The
// uniformity is the point -- a caller that has to remember which functions
// report exhaustion and which do not will read the ones that do not as
// complete answers.
// ===========================================================================

fn resolve(g: &Snapshot, arr: pgrx::Array<'_, Uuid>) -> (Vec<u32>, Vec<String>) {
    let mut ords = Vec::new();
    let mut missing = Vec::new();
    for id in arr.iter().flatten() {
        match g.ord(id) {
            Some(o) => ords.push(o),
            // Same distinction the dialect's `unresolved` keeps: a node this
            // caller cannot see and a node that does not exist look identical
            // from here, and both are different from "it has no edges".
            None => missing.push(id.to_string()),
        }
    }
    (ords, missing)
}

fn snap_meta(g: &Snapshot) -> Value {
    json!({
        "nodes": g.n(),
        "edges": g.m(),
        "relations": g.rel_names.len(),
        "build_ms": (g.build_ms * 1000.0).round() / 1000.0,
        "built_at": g.built_at,
        "bytes": g.bytes(),
        "filter": g.build_filter.json(),
    })
}

fn filter_of(g: &Snapshot, relation: Option<&str>, as_of_us: Option<i64>) -> Result<Filter, String> {
    let rel = match relation {
        None => None,
        Some(r) => match g.rel_id(r) {
            Some(id) => Some(id),
            // A relation nobody has written is not an empty result, it is a
            // typo. Refusing it is the same rule the dialect applies to a
            // modifier that means nothing for a mode.
            None => {
                return Err(format!(
                    "no edge in this snapshot has relation '{}' -- known: {}",
                    r,
                    g.rel_names.join(", ")
                ))
            }
        },
    };
    Ok(Filter { rel, as_of: as_of_us })
}

fn err(msg: String) -> JsonB {
    JsonB(json!({ "ok": false, "error": msg }))
}

/// Build or report the adjacency snapshot this backend is using.
///
/// The three filter arguments are what make this more than an inspection
/// function. Supplying any of them is an instruction to build over that subset
/// -- and the subset is then the graph every other function in this module
/// walks, until the next build. That stickiness is deliberate: a query that
/// silently widened the graph it was handed would be answering a different
/// question from the one the caller set up.
#[pg_extern]
fn p8_graph_snapshot(
    refresh: default!(bool, false),
    relations: default!(Option<Vec<String>>, "NULL"),
    weight_floor: default!(f64, 0.0),
    as_of_us: default!(Option<i64>, "NULL"),
) -> JsonB {
    reset_build_clock();
    let bf = BuildFilter {
        relations: relations.filter(|r| !r.is_empty()),
        weight_floor: weight_floor as f32,
        as_of: as_of_us,
    };
    let g = if bf.is_empty() && !refresh {
        snapshot(false)
    } else {
        snapshot_filtered(bf, refresh)
    };
    let mut m = snap_meta(g);
    // Whether THIS call paid for a build, as distinct from `build_ms`, which
    // is what the snapshot in hand cost whenever it was made. An operator
    // pre-warming a pool needs the first; one sizing memory needs the second.
    m["built_now"] = json!(last_build_ms() > 0.0);
    // Reported separately from the snapshot's own bytes because it is a
    // different kind of cost: the snapshot is the graph, the scratch is what
    // one query needs to walk it, and only the second scales with concurrency.
    m["scratch_bytes"] = json!(scratch(g.n()).bytes());
    JsonB(json!({ "ok": true, "snapshot": m }))
}

/// Release the snapshot. Backend-local memory, so this is the only way to give
/// it back short of ending the session -- which matters, because the snapshot
/// is the largest allocation this extension makes.
#[pg_extern]
fn p8_graph_snapshot_drop() -> JsonB {
    // A slot owed back by a build that raised is released here too, and that
    // is the point rather than tidiness: the snapshot ceiling's own error
    // message names this function as the remedy, and until PENDING_SLOT
    // existed the slot that error had just burned was the one thing this
    // could not give back.
    release_pending_slot();
    let had = drop_cached();
    JsonB(json!({ "ok": true, "dropped": had }))
}

/// Personalised PageRank from one or more seeds.
#[pg_extern]
#[allow(clippy::too_many_arguments)]
fn p8_graph_ppr(
    seeds: pgrx::Array<'_, Uuid>,
    alpha: default!(f64, 0.15),
    epsilon: default!(f64, 0.000001),
    k: default!(i32, 50),
    budget_ms: default!(i32, 250),
    directed: default!(bool, false),
    relation: default!(Option<&str>, "NULL"),
    as_of_us: default!(Option<i64>, "NULL"),
) -> JsonB {
    reset_build_clock();
    let mut b = Budget::new(budget_ms, 0);
    let g = snapshot(false);
    let (ords, missing) = resolve(g, seeds);
    let f = match filter_of(g, relation, as_of_us) {
        Ok(f) => f,
        Err(e) => return err(e),
    };
    if ords.is_empty() {
        return JsonB(json!({
            "ok": true, "unresolved": missing, "rows": [],
            "meta": {"note": "no seed resolved to a node"}, "snapshot": snap_meta(g)
        }));
    }
    let sc = scratch(g.n());
    b.begin_walk();
    let (scores, pushes) = ppr(g, sc, &ords, alpha, epsilon, directed, &f, &mut b);
    let rows: Vec<Value> = scores
        .iter()
        .take(k.max(0) as usize)
        .map(|&(v, s)| json!({"node_id": g.ids[v as usize].to_string(), "score": s}))
        .collect();
    let mut meta = b.meta();
    meta["pushes"] = json!(pushes);
    meta["reached"] = json!(scores.len());
    JsonB(json!({
        "ok": true, "unresolved": missing, "rows": rows,
        "meta": meta, "snapshot": snap_meta(g)
    }))
}

/// The k best paths between two nodes, cheapest first.
#[pg_extern]
#[allow(clippy::too_many_arguments)]
fn p8_graph_paths(
    src: Uuid,
    dst: Uuid,
    k: default!(i32, 3),
    max_hops: default!(i32, 6),
    budget_ms: default!(i32, 250),
    directed: default!(bool, false),
    relation: default!(Option<&str>, "NULL"),
    as_of_us: default!(Option<i64>, "NULL"),
) -> JsonB {
    reset_build_clock();
    let mut b = Budget::new(budget_ms, 0);
    let g = snapshot(false);
    let f = match filter_of(g, relation, as_of_us) {
        Ok(f) => f,
        Err(e) => return err(e),
    };
    let (s, d) = match (g.ord(src), g.ord(dst)) {
        (Some(s), Some(d)) => (s, d),
        _ => {
            let mut missing: Vec<String> = Vec::new();
            if g.ord(src).is_none() {
                missing.push(src.to_string());
            }
            if g.ord(dst).is_none() {
                missing.push(dst.to_string());
            }
            return JsonB(json!({
                "ok": true, "paths": [], "unresolved": missing, "snapshot": snap_meta(g)
            }));
        }
    };
    let sc = scratch(g.n());
    b.begin_walk();
    let paths = k_shortest(g, sc, s, d, k.max(1) as usize, max_hops.max(1) as usize, directed, &f, &mut b);
    let out: Vec<Value> = paths
        .iter()
        .map(|(n, e, c)| {
            let mut j = path_json(g, n, e);
            j["cost"] = json!((c * 10000.0).round() / 10000.0);
            j
        })
        .collect();
    JsonB(json!({ "ok": true, "paths": out, "meta": b.meta(), "snapshot": snap_meta(g) }))
}

/// The densest structure around a node: core numbers, then cliques inside the
/// densest core.
#[pg_extern]
fn p8_graph_dense(
    seed: Uuid,
    max_nodes: default!(i32, 2000),
    min_clique: default!(i32, 3),
    budget_ms: default!(i32, 250),
    relation: default!(Option<&str>, "NULL"),
) -> JsonB {
    reset_build_clock();
    let mut b = Budget::new(budget_ms, 0);
    let g = snapshot(false);
    let f = match filter_of(g, relation, None) {
        Ok(f) => f,
        Err(e) => return err(e),
    };
    let s = match g.ord(seed) {
        Some(s) => s,
        None => return JsonB(json!({"ok": true, "unresolved": [seed.to_string()], "snapshot": snap_meta(g)})),
    };
    b.begin_walk();
    let l = induce(g, s, max_nodes.max(2) as usize, &f, &mut b);
    let core = k_core(&l);
    let kmax = core.iter().copied().max().unwrap_or(0);
    let top: Vec<u32> = (0..l.nodes.len() as u32).filter(|&i| core[i as usize] >= kmax).collect();
    let cl = cliques(&l, &top, min_clique.max(2) as usize, &mut b);
    JsonB(json!({
        "ok": true,
        "induced": l.nodes.len(),
        "max_core": kmax,
        "core_members": top.iter().take(200).map(|&i| g.ids[l.nodes[i as usize] as usize].to_string()).collect::<Vec<_>>(),
        "cliques": cl.iter().take(10).map(|c| json!({
            "size": c.len(),
            "nodes": c.iter().map(|&i| g.ids[l.nodes[i as usize] as usize].to_string()).collect::<Vec<_>>()
        })).collect::<Vec<_>>(),
        "meta": b.meta(),
        "snapshot": snap_meta(g)
    }))
}

/// Confidence and corroboration propagated from a set of trusted seeds.
#[pg_extern]
#[allow(clippy::too_many_arguments)]
fn p8_graph_trust(
    seeds: pgrx::Array<'_, Uuid>,
    floor: default!(f64, 0.01),
    k: default!(i32, 50),
    budget_ms: default!(i32, 250),
    directed: default!(bool, false),
    relation: default!(Option<&str>, "NULL"),
    as_of_us: default!(Option<i64>, "NULL"),
) -> JsonB {
    reset_build_clock();
    let mut b = Budget::new(budget_ms, 0);
    let g = snapshot(false);
    let (ords, missing) = resolve(g, seeds);
    let f = match filter_of(g, relation, as_of_us) {
        Ok(f) => f,
        Err(e) => return err(e),
    };
    if ords.is_empty() {
        return JsonB(json!({"ok": true, "unresolved": missing, "rows": [], "snapshot": snap_meta(g)}));
    }
    let sc = scratch(g.n());
    b.begin_walk();
    let (out, reached) = trust(g, sc, &ords, floor, k.max(0) as usize, directed, &f, &mut b);
    let rows: Vec<Value> = out
        .iter()
        .map(|&(v, c, s)| json!({
            "node_id": g.ids[v as usize].to_string(),
            "confidence": (c * 100000.0).round() / 100000.0,
            "support": s
        }))
        .collect();
    let mut meta = b.meta();
    meta["reached"] = json!(reached);
    JsonB(json!({"ok": true, "unresolved": missing, "rows": rows, "meta": meta, "snapshot": snap_meta(g)}))
}

/// The smallest subgraph connecting a set of nodes.
#[pg_extern]
fn p8_graph_connect(
    terminals: pgrx::Array<'_, Uuid>,
    budget_ms: default!(i32, 500),
    relation: default!(Option<&str>, "NULL"),
) -> JsonB {
    reset_build_clock();
    let mut b = Budget::new(budget_ms, 0);
    let g = snapshot(false);
    let (ords, missing) = resolve(g, terminals);
    let f = match filter_of(g, relation, None) {
        Ok(f) => f,
        Err(e) => return err(e),
    };
    if ords.len() < 2 {
        return JsonB(json!({
            "ok": false, "unresolved": missing,
            "error": "connect needs at least two resolved terminals"
        }));
    }
    // Capped, because the walk count is linear in the terminal count and each
    // walk is a full Dijkstra. Twenty is already more entities than a result
    // set a person is reading.
    let terms: Vec<u32> = ords.iter().copied().take(20).collect();
    let sc = scratch(g.n());
    b.begin_walk();
    let (nodes, eids, connected) = connect(g, sc, &terms, &f, &mut b);
    JsonB(json!({
        "ok": true,
        "unresolved": missing,
        "terminals": terms.len(),
        "connected": connected,
        "nodes": nodes.iter().map(|&v| g.ids[v as usize].to_string()).collect::<Vec<_>>(),
        "edges": eids.iter().map(|&e| {
            let ed = &g.edges[e as usize];
            json!({
                "src": g.ids[ed.src as usize].to_string(),
                "dst": g.ids[ed.dst as usize].to_string(),
                "relation": g.rel_names[ed.rel as usize],
                "weight": ed.w
            })
        }).collect::<Vec<_>>(),
        "meta": b.meta(),
        "snapshot": snap_meta(g)
    }))
}

/// Build the reach sketches.
#[pg_extern]
fn p8_graph_reach_build(depth: default!(i32, 3), budget_ms: default!(i32, 60000)) -> JsonB {
    reset_build_clock();
    let mut b = Budget::new(budget_ms, 0);
    let g = snapshot(false);
    b.begin_walk();
    let d = depth.clamp(1, 6) as usize;
    let r = build_reach(g, d, &mut b);
    match r {
        Some(r) => {
            let out = json!({
                "ok": true, "depth": d,
                "build_ms": (r.build_ms * 1000.0).round() / 1000.0,
                "bytes": r.bytes(), "registers": HLL_M,
                "meta": b.meta(), "snapshot": snap_meta(g)
            });
            g.reach = Some(r);
            JsonB(out)
        }
        None => JsonB(json!({
            "ok": false, "error": "reach build exhausted its budget",
            "meta": b.meta(), "snapshot": snap_meta(g)
        })),
    }
}

/// Estimated (or exact) size of the k-hop frontier around a node.
#[pg_extern]
fn p8_graph_frontier(
    seed: Uuid,
    depth: default!(i32, 2),
    exact: default!(bool, false),
    budget_ms: default!(i32, 250),
) -> JsonB {
    reset_build_clock();
    let mut b = Budget::new(budget_ms, 0);
    let g = snapshot(false);
    let v = match g.ord(seed) {
        Some(v) => v,
        None => return JsonB(json!({"ok": true, "unresolved": [seed.to_string()]})),
    };
    let d = depth.clamp(1, 6) as usize;
    let est = g.reach.as_ref().map(|r| r.at(v, d) as f64);
    let mut out = json!({"ok": true, "depth": d, "estimate": est});
    if exact {
        let sc = scratch(g.n());
        b.begin_walk();
        let (n, complete) = exact_reach(g, sc, v, d, &mut b);
        out["exact"] = json!(n);
        out["exact_complete"] = json!(complete);
        out["meta"] = b.meta();
    }
    JsonB(out)
}

/// Build pruned landmark labels.
#[pg_extern]
fn p8_graph_labels_build(
    budget_ms: default!(i32, 60000),
    max_entries: default!(i64, 20000000),
) -> JsonB {
    reset_build_clock();
    let mut b = Budget::new(budget_ms, 0);
    let g = snapshot(false);
    b.begin_walk();
    let l = build_labels(g, &mut b, max_entries.max(0) as usize);
    let out = json!({
        "ok": true,
        "complete": l.complete,
        "roots_processed": l.roots,
        "nodes": g.n(),
        "label_entries": l.entries,
        "labels_per_node": if g.n() > 0 { l.entries as f64 / g.n() as f64 } else { 0.0 },
        "build_ms": (l.build_ms * 1000.0).round() / 1000.0,
        "bytes": l.bytes(),
        "meta": b.meta(),
        "snapshot": snap_meta(g)
    });
    g.labels = Some(l);
    JsonB(out)
}

/// Hop distance between two nodes from the label index.
#[pg_extern]
fn p8_graph_distance(a: Uuid, b: Uuid) -> JsonB {
    let g = snapshot(false);
    let (x, y) = match (g.ord(a), g.ord(b)) {
        (Some(x), Some(y)) => (x, y),
        _ => return JsonB(json!({"ok": true, "distance": Value::Null, "unresolved": true})),
    };
    match &g.labels {
        None => JsonB(json!({"ok": false, "error": "no label index -- call p8_graph_labels_build() first"})),
        Some(l) => {
            let t0 = Instant::now();
            let d = l.query(x, y);
            JsonB(json!({
                "ok": true,
                "distance": d,
                // An incomplete build answers with an upper bound, never a
                // proof of distance -- and a caller that is not told cannot
                // know the difference.
                "exact": l.complete,
                "us": t0.elapsed().as_secs_f64() * 1_000_000.0
            }))
        }
    }
}

/// Partition the graph by label propagation.
#[pg_extern]
fn p8_graph_communities(iters: default!(i32, 10), budget_ms: default!(i32, 60000)) -> JsonB {
    reset_build_clock();
    let mut b = Budget::new(budget_ms, 0);
    let g = snapshot(false);
    b.begin_walk();
    let (lbl, count, rounds, ms) = label_prop(g, iters.clamp(1, 100) as usize, &mut b);
    let q = modularity(g, &lbl);
    let mut sizes: Map<u32, u32> = map();
    for &l in lbl.iter() {
        *sizes.entry(l).or_insert(0) += 1;
    }
    let mut top: Vec<(u32, u32)> = sizes.iter().map(|(&k, &v)| (k, v)).collect();
    top.sort_by_key(|&(_, s)| std::cmp::Reverse(s));
    let out = json!({
        "ok": true,
        "communities": count,
        "modularity": (q * 10000.0).round() / 10000.0,
        "rounds": rounds,
        "build_ms": (ms * 1000.0).round() / 1000.0,
        "largest": top.iter().take(10).map(|&(_, s)| s).collect::<Vec<_>>(),
        "meta": b.meta(),
        "snapshot": snap_meta(g)
    });
    g.community = Some(lbl);
    g.community_sizes = Some(sizes);
    g.community_ms = ms;
    JsonB(out)
}

/// The community a node landed in, and how big it is.
#[pg_extern]
fn p8_graph_community_of(node: Uuid) -> JsonB {
    let g = snapshot(false);
    let v = match g.ord(node) {
        Some(v) => v,
        None => return JsonB(json!({"ok": true, "unresolved": [node.to_string()]})),
    };
    match &g.community {
        None => JsonB(json!({"ok": false, "error": "no partition -- call p8_graph_communities() first"})),
        Some(c) => {
            let l = c[v as usize];
            let size = g.community_sizes.as_ref().and_then(|s| s.get(&l).copied()).unwrap_or(0);
            JsonB(json!({"ok": true, "community": l, "size": size}))
        }
    }
}

// ===========================================================================
// §13. Deny by default
//
// These functions are created by a SUPERUSER-installed extension, so they
// arrive with PUBLIC EXECUTE like every other C function -- and unlike the
// parser, they are not pure computation over a string. The first call in a
// backend builds an adjacency snapshot, which at four million edges is 225 MB
// and three and a half seconds; RLS makes that not a disclosure problem, and
// leaves it a resource one, reachable by `web_anon`.
//
// So the extension revokes itself. `app_owner` -- the role that owns the
// schema half and therefore owns the wrappers -- gets it back WITH GRANT
// OPTION, which is what lets `aiq.enable_graph_algorithms()` hand it onward
// without a superuser being in the room. If that role does not exist, the
// functions stay superuser-only, which is the right failure direction.
//
// The revoke is written against the catalog rather than a list of twelve
// signatures on purpose: a list is a thing that goes stale one function at a
// time, silently, in the direction of more access.
extension_sql!(
    r#"
do $$
declare r record;
begin
    for r in select p.oid::regprocedure as sig
               from pg_proc p
               join pg_namespace n on n.oid = p.pronamespace
              where p.proname like 'p8\_graph\_%'
                and n.nspname = current_schema()
    loop
        execute format('revoke execute on function %s from public', r.sig);
        if exists (select 1 from pg_roles where rolname = 'app_owner') then
            execute format('grant execute on function %s to app_owner with grant option', r.sig);
        end if;
    end loop;
end $$;
"#,
    name = "graph_algorithms_deny_by_default",
    requires = [
        p8_graph_snapshot,
        p8_graph_snapshot_drop,
        p8_graph_ppr,
        p8_graph_paths,
        p8_graph_dense,
        p8_graph_trust,
        p8_graph_connect,
        p8_graph_reach_build,
        p8_graph_frontier,
        p8_graph_labels_build,
        p8_graph_distance,
        p8_graph_communities,
        p8_graph_community_of,
    ],
);

// ===========================================================================
// §14. Two primitives the shipped six do not cover
//
// Both were asked for by a consumer building entity fusion on top of this
// surface, and both are here because they are the generic shape of that ask
// rather than the specific one: connected components and an induced subgraph
// are what every clustering, blocking or repair pass is built out of, and
// neither is expressible as a bounded query.
// ===========================================================================

/// Connected components by union-find with path halving.
///
/// Linear, and the cheapest useful thing on this list. It is also the one that
/// most needs §2's snapshot filter in front of it: components over an
/// unfiltered evidence graph are one giant blob, because the near-zero edges
/// that a threshold exists to ignore connect everything to everything.
///
/// The component is named by the smallest node id in it, which makes the
/// naming stable across runs and independent of iteration order -- a component
/// id that moves between two runs over the same graph is not an id.
#[pg_extern]
fn p8_graph_components(
    min_size: default!(i32, 2),
    budget_ms: default!(i32, 30000),
) -> TableIterator<'static, (name!(node_id, Uuid), name!(component, Uuid), name!(size, i32))> {
    reset_build_clock();
    let mut b = Budget::new(budget_ms, 0);
    let g = snapshot(false);
    b.begin_walk();
    let n = g.n();
    let mut parent: Vec<u32> = (0..n as u32).collect();

    fn find(parent: &mut [u32], mut x: u32) -> u32 {
        while parent[x as usize] != x {
            // Path halving: one pointer update per step, no second pass, and
            // it gives the same near-constant amortised cost as full
            // compression without the recursion.
            parent[x as usize] = parent[parent[x as usize] as usize];
            x = parent[x as usize];
        }
        x
    }

    for (i, e) in g.edges.iter().enumerate() {
        if i % 8192 == 0 && !b.spend(8192) {
            break;
        }
        let (a, c) = (find(&mut parent, e.src), find(&mut parent, e.dst));
        if a != c {
            // Union by id rather than by rank, so the representative is the
            // smaller ordinal and therefore the smallest uuid -- the stability
            // property above falls out of the merge rather than a final pass.
            if a < c {
                parent[c as usize] = a;
            } else {
                parent[a as usize] = c;
            }
        }
    }

    let mut root: Vec<u32> = vec![0; n];
    let mut size: Map<u32, i32> = map();
    for v in 0..n as u32 {
        let r = find(&mut parent, v);
        root[v as usize] = r;
        *size.entry(r).or_insert(0) += 1;
    }

    let floor = min_size.max(1);
    let rows: Vec<(Uuid, Uuid, i32)> = (0..n as u32)
        .filter_map(|v| {
            let r = root[v as usize];
            let sz = *size.get(&r).unwrap_or(&0);
            if sz < floor {
                return None;
            }
            Some((g.ids[v as usize], g.ids[r as usize], sz))
        })
        .collect();
    TableIterator::new(rows)
}

/// The edges internal to a supplied set of nodes.
///
/// One call answers many clusters at once when the clusters are components,
/// because an edge internal to the union of disjoint components is internal to
/// exactly one of them -- so a repair pass over thousands of small clusters is
/// one round trip, not thousands.
#[pg_extern]
fn p8_graph_induced(
    node_ids: pgrx::Array<'_, Uuid>,
    relation: default!(Option<&str>, "NULL"),
    as_of_us: default!(Option<i64>, "NULL"),
) -> TableIterator<'static, (
    name!(src_id, Uuid),
    name!(dst_id, Uuid),
    name!(relation, String),
    name!(weight, f64),
)> {
    let g = snapshot(false);
    let f = match filter_of(g, relation, as_of_us) {
        Ok(f) => f,
        // A relation nobody wrote is a typo, and this shape cannot report one
        // the way the JSONB entry points do -- so it returns nothing rather
        // than everything, which is the safe direction for a set difference.
        Err(_) => return TableIterator::new(Vec::new()),
    };
    let mut inside: Set<u32> = set();
    for id in node_ids.iter().flatten() {
        if let Some(o) = g.ord(id) {
            inside.insert(o);
        }
    }
    let mut seen: Set<u32> = set();
    let mut rows: Vec<(Uuid, Uuid, String, f64)> = Vec::new();
    for &v in inside.iter() {
        for &eid in g.out(v).iter().chain(g.inc(v).iter()) {
            let e = &g.edges[eid as usize];
            if !f.keep(e) || !inside.contains(&e.src) || !inside.contains(&e.dst) {
                continue;
            }
            // Both endpoints are in the set, so every internal edge is reached
            // twice -- once from each end.
            if !seen.insert(eid) {
                continue;
            }
            rows.push((
                g.ids[e.src as usize],
                g.ids[e.dst as usize],
                g.rel_names[e.rel as usize].clone(),
                e.w as f64,
            ));
        }
    }
    TableIterator::new(rows)
}

// Run INSIDE Postgres, as `#[pg_test]`, not as a plain `#[test]`.
//
// The first version of these was `#[cfg(test)] mod tests` with `#[test]`, on
// the reasoning that `build_labels` is pure -- it takes a graph and returns an
// index, and touches no SQL. The crate would not link:
//
//     undefined reference to `PG_exception_stack'
//     undefined reference to `CopyErrorData'
//
// Pure at the level of what it MEANS is not pure at the level of what it
// LINKS. The walk reaches pgrx's FFI guard, and those symbols live in the
// postgres binary, which a plain test harness is not running inside. The
// existing pure tests in `plan_graph.rs` link because they stop at the
// tokeniser and never cross that boundary.
//
// The module must be called `tests`: pgrx's harness looks the generated
// functions up as `tests.<name>()` whatever the module is called, so a
// `graph_tests` module compiles, installs into a `graph_tests` schema, and then
// fails three times with "function tests.<name>() does not exist".
//
// Attribution here was worth the two builds it cost. The reasonable-sounding
// deduction -- that `plan_graph.rs` already has a `#[cfg(test)] mod tests`, so
// the lib-test target predates this and the failure must be environmental --
// was wrong, and a baseline build without this module said so: 44 passed, exit
// 0. `#[pg_test]` runs the same assertions in a real backend, which is where
// the symbols are.
#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use super::*;
    use pgrx::prelude::*;

    /// An n-node path as the CSR the algorithms actually read: node i has the
    /// single out-edge i and the single in-edge i-1, so an undirected walk from
    /// either end crosses n-1 hops and nothing shorter exists.
    ///
    /// Built by hand rather than through `snapshot()` because `snapshot()`
    /// reads two SQL tables and takes an admission slot. The point of this
    /// fixture is that the label builder is pure -- given a graph it either
    /// finishes or says it did not -- and a pure function deserves a test that
    /// runs in milliseconds without a database.
    fn path(n: usize) -> Snapshot {
        let ids: Vec<Uuid> = (0..n)
            .map(|i| {
                let mut b = [0u8; 16];
                b[12..].copy_from_slice(&(i as u32).to_be_bytes());
                Uuid::from_bytes(b)
            })
            .collect();
        let mut index: Map<Uuid, u32> = Map::default();
        for (i, id) in ids.iter().enumerate() {
            index.insert(*id, i as u32);
        }
        let edges: Vec<Edge> = (0..n.saturating_sub(1))
            .map(|i| Edge {
                src: i as u32,
                dst: i as u32 + 1,
                rel: 0,
                w: 1.0,
                vf: T_MIN,
                vt: T_MAX,
            })
            .collect();
        let (mut out_off, mut out_eid) = (Vec::with_capacity(n + 1), Vec::new());
        for i in 0..n {
            out_off.push(out_eid.len() as u32);
            if i + 1 < n {
                out_eid.push(i as u32);
            }
        }
        out_off.push(out_eid.len() as u32);
        let (mut in_off, mut in_eid) = (Vec::with_capacity(n + 1), Vec::new());
        for i in 0..n {
            in_off.push(in_eid.len() as u32);
            if i > 0 {
                in_eid.push(i as u32 - 1);
            }
        }
        in_off.push(in_eid.len() as u32);
        Snapshot {
            identity: String::new(),
            counters: String::new(),
            slot: -1,
            build_filter: BuildFilter { relations: None, weight_floor: 0.0, as_of: None },
            ids,
            index,
            edges,
            out_off,
            out_eid,
            in_off,
            in_eid,
            rel_names: vec!["chain_rel".to_string()],
            build_ms: 0.0,
            built_at: String::new(),
            reach: None,
            labels: None,
            community: None,
            community_sizes: None,
            community_ms: 0.0,
        }
    }

    /// Room to finish: neither the time budget nor the entry ceiling should be
    /// what stops these builds, or the test would pass for the wrong reason.
    fn roomy() -> Budget {
        Budget::new(60_000, 20_000_000)
    }

    /// The graph module had no test of any kind before this one -- snapshot,
    /// labels, distance, BFS and HLL alike -- which is how a label index could
    /// stop at its depth cap and still report itself complete. The SQL suite
    /// covers the same invariant end to end, but it runs against the parser
    /// compiled into the last RELEASED image, so it cannot see a fix until one
    /// ships. This runs on the source in the tree.
    #[pg_test]
    fn a_build_that_stops_at_the_depth_cap_is_not_complete() {
        let g = path(300);
        let labels = build_labels(&g, &mut roomy(), usize::MAX);
        assert!(
            !labels.complete,
            "a 300-node path is 299 hops end to end and distances are a u8, so the \
             BFS stops at 254 -- the index cannot answer every pair and must not \
             claim it can. `complete` is what p8_graph_distance reports as `exact`, \
             and an answer marked exact that is wrong is the one state it may never \
             describe."
        );
    }

    /// The other half, and the one that makes the assertion above mean
    /// something: a build with room to finish says so, and answers correctly.
    /// Without this, `complete = false` everywhere would pass the first test.
    #[pg_test]
    fn a_build_within_the_cap_is_complete_and_right() {
        let g = path(50);
        let labels = build_labels(&g, &mut roomy(), usize::MAX);
        assert!(labels.complete, "a 49-hop path is well inside the 254-hop cap");
        assert_eq!(
            labels.query(0, 49),
            Some(49),
            "the only route from one end of a 50-node path to the other is 49 hops"
        );
        assert_eq!(labels.query(10, 20), Some(10));
        assert_eq!(labels.query(7, 7), Some(0));
    }

    /// The cap is on a ROOT's BFS depth, not on the graph -- so an over-deep
    /// graph still answers the pairs it did reach. Pinning this keeps the fix
    /// from being "mark everything inexact", which would also pass the first
    /// test and would make the index useless.
    #[pg_test]
    fn an_over_deep_graph_still_answers_the_pairs_it_reached() {
        let g = path(300);
        let labels = build_labels(&g, &mut roomy(), usize::MAX);
        assert_eq!(
            labels.query(100, 120),
            Some(20),
            "two nodes 20 hops apart are well within any root's reach; the depth \
             ceiling costs exactness, not every answer"
        );
    }
}
