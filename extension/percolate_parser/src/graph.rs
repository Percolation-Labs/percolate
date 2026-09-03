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
//!    therefore checks a fingerprint (role + JWT claims) before reuse and
//!    rebuilds rather than serving someone else's graph.
//! 2. **It is a stale read by construction.** The fingerprint carries the
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
    start: Instant,
    ms: u64,
    max_ops: u64,
    ops: u64,
    since_check: u64,
    exhausted: bool,
}

impl Budget {
    fn new(ms: i32, max_ops: i64) -> Self {
        Budget {
            start: Instant::now(),
            ms: ms.max(1) as u64,
            max_ops: if max_ops <= 0 { u64::MAX } else { max_ops as u64 },
            ops: 0,
            since_check: 0,
            exhausted: false,
        }
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

    fn meta(&self) -> Value {
        json!({
            "budget_ms": self.ms,
            "elapsed_ms": (self.elapsed_ms() * 1000.0).round() / 1000.0,
            "edge_visits": self.ops,
            "exhausted": self.exhausted,
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
        }
    }
    fn bytes(&self) -> usize {
        self.p.len() * 8 * 3 + self.parent.len() * 4 + self.stamp.len() * 4
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

struct Snapshot {
    /// Who built it: role, claims, and the tuple counters of the two tables.
    /// Reuse across a different fingerprint is a cross-tenant read, so it is
    /// refused rather than warned about.
    fingerprint: String,
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

fn cached() -> Option<&'static mut Snapshot> {
    unsafe { SNAP.as_mut() }
}

fn install(s: Snapshot) -> &'static mut Snapshot {
    unsafe {
        if !SNAP.is_null() {
            drop(Box::from_raw(SNAP));
            SNAP = std::ptr::null_mut();
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
        drop(Box::from_raw(SNAP));
        SNAP = std::ptr::null_mut();
        true
    }
}

/// Role, claims and the two tables' modification counters.
///
/// The first two are the tenancy guard. The counters are the staleness hint,
/// and they are a hint: `pg_stat_all_tables` is fed by the stats collector,
/// which lags, so a snapshot can be behind the graph for as long as that lag.
/// Recorded rather than papered over -- the alternative, `count(*)` per call,
/// costs more than most of the algorithms it would be guarding.
fn fingerprint() -> String {
    Spi::get_one::<String>(
        "select current_user::text
             || '|' || coalesce(current_setting('request.jwt.claims', true), '')
             || '|' || coalesce((select sum(n_tup_ins + n_tup_upd + n_tup_del)::text
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
fn build() -> Snapshot {
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

        let mut cur = client.open_cursor(
            "select src_id, dst_id, relation, weight,
                    coalesce((extract(epoch from valid_from) * 1000000)::bigint, (-9223372036854775808)::bigint),
                    coalesce((extract(epoch from valid_to)   * 1000000)::bigint,   9223372036854775807::bigint)
               from aiq.edges",
            &[],
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

    let built_at = Spi::get_one::<String>("select now()::text").unwrap_or(None).unwrap_or_default();
    Snapshot {
        fingerprint: fingerprint(),
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
        community_ms: 0.0,
    }
}

/// The one way in. Rebuilds when the fingerprint moved, which covers both the
/// tenancy case (a different role or claim set) and the ordinary staleness one.
fn snapshot(refresh: bool) -> &'static mut Snapshot {
    let fp = fingerprint();
    if !refresh {
        if let Some(s) = cached() {
            if s.fingerprint == fp {
                return s;
            }
        }
    }
    install(build())
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
    buf.clear();
    let mut scanned = 0u64;
    for &eid in g.out(v) {
        scanned += 1;
        let e = &g.edges[eid as usize];
        if f.keep(e) {
            buf.push((e.dst, e.w, eid));
        }
    }
    if !directed {
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

/// Single-source Dijkstra over the snapshot, writing into scratch.
///
/// Returns the stamp epoch it wrote under; `sc.stamp[v] == epoch` means `v`
/// was settled, `sc.dist[v]` is its distance and `sc.parent[v]` the edge it
/// arrived by. Stops on budget, on `stop_at`, or when the heap empties.
#[allow(clippy::too_many_arguments)]
fn dijkstra(
    g: &Snapshot,
    sc: &mut Scratch,
    sources: &[u32],
    stop_at: Option<u32>,
    banned_edges: &Set<u32>,
    banned_nodes: &Set<u32>,
    directed: bool,
    f: &Filter,
    b: &mut Budget,
) -> u32 {
    let epoch = sc.bump();
    let mut heap: BinaryHeap<QItem> = BinaryHeap::new();
    let mut buf: Vec<(u32, f32, u32)> = Vec::new();
    for &s in sources {
        if banned_nodes.contains(&s) {
            continue;
        }
        sc.stamp[s as usize] = epoch;
        sc.dist[s as usize] = 0.0;
        sc.parent[s as usize] = u32::MAX;
        heap.push(QItem(0.0, s));
    }
    let mut settled: Set<u32> = set();
    while let Some(QItem(d, v)) = heap.pop() {
        if settled.contains(&v) {
            continue;
        }
        if sc.stamp[v as usize] == epoch && d > sc.dist[v as usize] {
            continue;
        }
        settled.insert(v);
        if Some(v) == stop_at {
            return epoch;
        }
        let scanned = nbrs(g, v, directed, f, &mut buf);
        if !b.spend(scanned) {
            break;
        }
        for &(u, w, eid) in buf.iter() {
            if banned_nodes.contains(&u) || banned_edges.contains(&eid) {
                continue;
            }
            let nd = d + cost_of(w);
            if sc.stamp[u as usize] != epoch || nd < sc.dist[u as usize] {
                sc.stamp[u as usize] = epoch;
                sc.dist[u as usize] = nd;
                sc.parent[u as usize] = eid;
                heap.push(QItem(nd, u));
            }
        }
    }
    epoch
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

    let epoch = dijkstra(g, sc, &[src], Some(dst), &empty_e, &empty_n, directed, f, b);
    match unwind(g, sc, epoch, dst) {
        Some((nodes, eids)) if eids.len() <= max_hops => {
            let c = sc.dist[dst as usize];
            found.push((nodes, eids, c));
        }
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
            let ep = dijkstra(g, sc, &[spur], Some(dst), &banned_e, &banned_n, directed, f, b);
            if let Some((mut nodes, mut eids)) = unwind(g, sc, ep, dst) {
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

fn trust(
    g: &Snapshot,
    sc: &mut Scratch,
    seeds: &[u32],
    floor: f64,
    directed: bool,
    f: &Filter,
    b: &mut Budget,
) -> Vec<(u32, f64, usize)> {
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
    let mut settled: Set<u32> = set();
    while let Some(QItem(d, v)) = heap.pop() {
        if !settled.insert(v) || d > sc.dist[v as usize] {
            continue;
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
    // Corroboration, computed once over the settled set rather than during the
    // walk: a node's support is a property of who reached it, which is not
    // known until the walk stops.
    let mut out: Vec<(u32, f64, usize)> = Vec::new();
    for &v in touched.iter() {
        if sc.stamp[v as usize] != epoch || !sc.dist[v as usize].is_finite() {
            continue;
        }
        let conf = (-sc.dist[v as usize]).exp();
        if conf < floor {
            continue;
        }
        nbrs(g, v, directed, f, &mut buf);
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
    out
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

fn connect(
    g: &Snapshot,
    sc: &mut Scratch,
    terms: &[u32],
    f: &Filter,
    b: &mut Budget,
) -> (Vec<u32>, Vec<u32>, usize) {
    let empty_e: Set<u32> = set();
    let empty_n: Set<u32> = set();
    let t = terms.len();
    // One Dijkstra per terminal, copied out of scratch because the next one
    // overwrites it. Bounded by |T|, which the entry point caps.
    let mut trees: Vec<Map<u32, (f64, u32)>> = Vec::with_capacity(t);
    for &s in terms {
        let epoch = dijkstra(g, sc, &[s], None, &empty_e, &empty_n, false, f, b);
        let mut m: Map<u32, (f64, u32)> = map();
        for &u in terms {
            if sc.stamp[u as usize] == epoch {
                // Record the whole path back, not just the endpoint: expanding
                // an MST edge needs every parent pointer along it.
                let mut cur = u;
                let mut guard = 0;
                while sc.stamp[cur as usize] == epoch && guard < 4096 {
                    guard += 1;
                    m.insert(cur, (sc.dist[cur as usize], sc.parent[cur as usize]));
                    if sc.parent[cur as usize] == u32::MAX {
                        break;
                    }
                    let e = &g.edges[sc.parent[cur as usize] as usize];
                    cur = if e.dst == cur { e.src } else { e.dst };
                }
            }
        }
        trees.push(m);
        if b.exhausted {
            break;
        }
    }

    // Prim over the metric closure. Terminals the walk never reached are left
    // out and counted, rather than silently making the answer look connected.
    let reached = trees.len();
    let mut in_tree = vec![false; t];
    let mut mst: Vec<(usize, usize)> = Vec::new();
    in_tree[0] = true;
    for _ in 1..t {
        let mut best: Option<(f64, usize, usize)> = None;
        for i in 0..t.min(reached) {
            if !in_tree[i] {
                continue;
            }
            for j in 0..t {
                if in_tree[j] {
                    continue;
                }
                if let Some(&(d, _)) = trees[i].get(&terms[j]) {
                    if best.map(|(bd, _, _)| d < bd).unwrap_or(true) {
                        best = Some((d, i, j));
                    }
                }
            }
        }
        match best {
            Some((_, i, j)) => {
                in_tree[j] = true;
                mst.push((i, j));
            }
            None => break,
        }
    }

    let mut nodes: Set<u32> = terms.iter().copied().collect();
    let mut eids: Set<u32> = set();
    for &(i, j) in mst.iter() {
        let mut cur = terms[j];
        let mut guard = 0;
        while let Some(&(_, pe)) = trees[i].get(&cur) {
            guard += 1;
            if pe == u32::MAX || guard > 4096 {
                break;
            }
            eids.insert(pe);
            let e = &g.edges[pe as usize];
            let prev = if e.dst == cur { e.src } else { e.dst };
            nodes.insert(prev);
            nodes.insert(cur);
            cur = prev;
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

const HLL_P: usize = 4;
const HLL_M: usize = 1 << HLL_P; // 16 registers, ~26% relative error

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
    let alpha = 0.673; // m = 16
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

fn build_labels(g: &Snapshot, b: &mut Budget) -> Labels {
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
#[pg_extern]
fn p8_graph_snapshot(refresh: default!(bool, false)) -> JsonB {
    let g = snapshot(refresh);
    let mut m = snap_meta(g);
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
    let mut b = Budget::new(budget_ms, 0);
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
    let mut b = Budget::new(budget_ms, 0);
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
    let g = snapshot(false);
    let f = match filter_of(g, relation, None) {
        Ok(f) => f,
        Err(e) => return err(e),
    };
    let s = match g.ord(seed) {
        Some(s) => s,
        None => return JsonB(json!({"ok": true, "unresolved": [seed.to_string()], "snapshot": snap_meta(g)})),
    };
    let mut b = Budget::new(budget_ms, 0);
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
    let mut b = Budget::new(budget_ms, 0);
    let out = trust(g, sc, &ords, floor, directed, &f, &mut b);
    let rows: Vec<Value> = out
        .iter()
        .take(k.max(0) as usize)
        .map(|&(v, c, s)| json!({
            "node_id": g.ids[v as usize].to_string(),
            "confidence": (c * 100000.0).round() / 100000.0,
            "support": s
        }))
        .collect();
    let mut meta = b.meta();
    meta["reached"] = json!(out.len());
    JsonB(json!({"ok": true, "unresolved": missing, "rows": rows, "meta": meta, "snapshot": snap_meta(g)}))
}

/// The smallest subgraph connecting a set of nodes.
#[pg_extern]
fn p8_graph_connect(
    terminals: pgrx::Array<'_, Uuid>,
    budget_ms: default!(i32, 500),
    relation: default!(Option<&str>, "NULL"),
) -> JsonB {
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
    let mut b = Budget::new(budget_ms, 0);
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
    let g = snapshot(false);
    let mut b = Budget::new(budget_ms, 0);
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
        let mut b = Budget::new(budget_ms, 0);
        let (n, complete) = exact_reach(g, sc, v, d, &mut b);
        out["exact"] = json!(n);
        out["exact_complete"] = json!(complete);
        out["meta"] = b.meta();
    }
    JsonB(out)
}

/// Build pruned landmark labels.
#[pg_extern]
fn p8_graph_labels_build(budget_ms: default!(i32, 60000)) -> JsonB {
    let g = snapshot(false);
    let mut b = Budget::new(budget_ms, 0);
    let l = build_labels(g, &mut b);
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
    let g = snapshot(false);
    let mut b = Budget::new(budget_ms, 0);
    let (lbl, count, rounds, ms) = label_prop(g, iters.clamp(1, 100) as usize, &mut b);
    let mut sizes: Map<u32, usize> = map();
    for &l in lbl.iter() {
        *sizes.entry(l).or_insert(0) += 1;
    }
    let mut top: Vec<(u32, usize)> = sizes.into_iter().collect();
    top.sort_by_key(|&(_, s)| std::cmp::Reverse(s));
    let out = json!({
        "ok": true,
        "communities": count,
        "rounds": rounds,
        "build_ms": (ms * 1000.0).round() / 1000.0,
        "largest": top.iter().take(10).map(|&(_, s)| s).collect::<Vec<_>>(),
        "meta": b.meta(),
        "snapshot": snap_meta(g)
    });
    g.community = Some(lbl);
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
            let size = c.iter().filter(|&&x| x == l).count();
            JsonB(json!({"ok": true, "community": l, "size": size}))
        }
    }
}
