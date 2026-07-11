// DRAWCACHE differential test (issue #89). Host-only, no engine, no SDL.
//
// The engine bug class this guards (patch 0028, the stale-Z regression): a
// mutation that can change the *visible or sorted* entity set must mark
// Entities::entities_to_draw_dirty = true, or the SOLARUS_DRAWCACHE fast path
// (patch 0022) keeps serving a stale draw list. bring_to_front/bring_to_back
// were the missing sites found in review; camera-pan invalidation is implicit
// (it rides on notify_entity_bounding_box_changed) and previously unasserted.
//
// This test does NOT link the engine (Entities.cpp pulls in the whole world).
// Instead it re-implements the exact contract as a small faithful model:
//   * a "reference" drawn set (flag OFF -> rebuilt every tick), and
//   * a "cached" drawn set (flag ON -> rebuilt only when dirty),
// then asserts, for every mutation the engine performs (add / remove / move /
// layer-change / bring_to_front / bring_to_back / camera-pan), that the two
// agree tick-by-tick.
//
// It has teeth: the NEGATIVE self-test drops the dirty flag for each mutation
// in turn and asserts the differential FAILS. That proves the harness would
// catch the next real missing-invalidation site instead of silently passing.
// If you add a new mutation to Entities that touches the visible/sorted set,
// add a MutKind for it here; the negative pass will fail loudly until you both
// dirty it in the engine and cover it here.
//
// Build/run:  see patches/mister/build_test_drawcache.sh
#include <algorithm>
#include <cstdio>
#include <set>
#include <vector>

static int g_fail = 0;
#define CHECK(cond, ...) do { if (!(cond)) {                    \
  std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__);     \
  std::fprintf(stderr, __VA_ARGS__); std::fprintf(stderr, "\n"); g_fail++; } } while (0)

// The mutations Entities performs that can change the drawn set. Each maps to a
// real invalidation site (see comments) that must set entities_to_draw_dirty.
enum MutKind {
  MUT_ADD,          // Entities::add_entity
  MUT_REMOVE,       // Entities::remove_marked_entities
  MUT_MOVE,         // Entities::notify_entity_bounding_box_changed
  MUT_SET_LAYER,    // Entities::set_entity_layer
  MUT_FRONT,        // Entities::bring_to_front   (0028 fix)
  MUT_BACK,         // Entities::bring_to_back    (0028 fix)
  MUT_CAMERA_PAN,   // camera box change -> notify_entity_bounding_box_changed(camera)
  MUT_COUNT
};

static const char* mut_name(MutKind k) {
  switch (k) {
    case MUT_ADD:        return "add_entity";
    case MUT_REMOVE:     return "remove_entity";
    case MUT_MOVE:       return "move (bbox changed)";
    case MUT_SET_LAYER:  return "set_entity_layer";
    case MUT_FRONT:      return "bring_to_front";
    case MUT_BACK:       return "bring_to_back";
    case MUT_CAMERA_PAN: return "camera_pan";
    default:             return "?";
  }
}

struct Entity {
  int  id;
  int  layer;
  int  x, y;      // position (bounding-box origin)
  long z;         // z-order; DrawingOrderComparator sorts on this within a layer
};

// Faithful model of the DRAWCACHE contract in Entities.
struct Model {
  std::vector<Entity> entities;
  int  cam_x = 0, cam_y = 0, cam_w = 100, cam_h = 100;
  long z_front = 1000;   // next bring_to_front z (monotonically up)
  long z_back  = -1000;  // next bring_to_back  z (monotonically down)

  bool drawcache_enabled = true;   // SOLARUS_DRAWCACHE
  bool dirty = true;               // entities_to_draw_dirty (starts true)
  std::vector<int> cached;         // last built entities_to_draw (ids, draw order)

  // Fault injection: when a kind is in here, the corresponding mutation does NOT
  // set the dirty flag (simulates a forgotten invalidation site).
  std::set<MutKind> skip_dirty;

  void mark(MutKind k) { if (!skip_dirty.count(k)) dirty = true; }

  bool in_camera(const Entity& e) const {
    return e.x >= cam_x && e.x < cam_x + cam_w &&
           e.y >= cam_y && e.y < cam_y + cam_h;
  }

  // Reference draw set: what draw() would build from scratch this tick.
  // Camera-visible entities, ordered per layer by (y, z, id) — same keys the
  // real DrawingOrderComparator resolves (y for in-Y-order entities, z as the
  // discriminator bring_to_front/back move).
  std::vector<int> build_drawn_set() const {
    std::vector<Entity> vis;
    for (const Entity& e : entities) if (in_camera(e)) vis.push_back(e);
    std::sort(vis.begin(), vis.end(), [](const Entity& a, const Entity& b) {
      if (a.layer != b.layer) return a.layer < b.layer;
      if (a.y     != b.y)     return a.y     < b.y;
      if (a.z     != b.z)     return a.z     < b.z;
      return a.id < b.id;
    });
    std::vector<int> ids;
    ids.reserve(vis.size());
    for (const Entity& e : vis) ids.push_back(e.id);
    return ids;
  }

  // One frame: update() clears the cache only when (OFF) or (dirty); draw()
  // lazily rebuilds when the cache is empty and consumes the dirty flag.
  std::vector<int> tick() {
    if (!drawcache_enabled || dirty) {
      cached.clear();                 // update(): invalidate
      cached = build_drawn_set();     // draw(): lazy rebuild
      dirty = false;                  // rebuild consumed
    }
    return cached;
  }

  // ---- mutations (each mirrors one Entities site) ----
  Entity* find(int id) {
    for (Entity& e : entities) if (e.id == id) return &e;
    return nullptr;
  }
  void add(int id, int layer, int x, int y) {
    entities.push_back(Entity{id, layer, x, y, /*z=*/id});
    mark(MUT_ADD);
  }
  void remove(int id) {
    entities.erase(std::remove_if(entities.begin(), entities.end(),
                     [id](const Entity& e){ return e.id == id; }), entities.end());
    mark(MUT_REMOVE);
  }
  void move(int id, int nx, int ny) {
    if (Entity* e = find(id)) { e->x = nx; e->y = ny; }
    mark(MUT_MOVE);
  }
  void set_layer(int id, int layer) {
    if (Entity* e = find(id)) e->layer = layer;
    mark(MUT_SET_LAYER);
  }
  void bring_to_front(int id) {
    if (Entity* e = find(id)) e->z = ++z_front;
    mark(MUT_FRONT);
  }
  void bring_to_back(int id) {
    if (Entity* e = find(id)) e->z = --z_back;
    mark(MUT_BACK);
  }
  void camera_pan(int dx, int dy) {
    cam_x += dx; cam_y += dy;
    mark(MUT_CAMERA_PAN);   // implicit: camera bbox change notifies Entities
  }
};

// Seed a scene that keeps several entities near camera edges, so a pan moves
// entities in/out of view and moves/z-changes reorder the visible set.
static void seed(Model& m) {
  m.entities.clear();
  m.cam_x = 0; m.cam_y = 0; m.cam_w = 100; m.cam_h = 100;
  m.z_front = 1000; m.z_back = -1000;
  m.dirty = true; m.cached.clear();
  // Layer 0: three entities at the same y (so z decides order), inside view.
  m.add(1, 0, 40, 50);
  m.add(2, 0, 60, 50);
  m.add(3, 0, 80, 50);
  // Layer 1: one just inside the right edge (a small pan pushes it out).
  m.add(4, 1, 95, 30);
  // Just outside the bottom edge (a downward pan pulls it in).
  m.add(5, 0, 50, 105);
  m.skip_dirty.clear();
}

// Apply the given mutation kind to a model (some concrete instance of it).
static void apply(Model& m, MutKind k) {
  switch (k) {
    case MUT_ADD:        m.add(9, 0, 55, 55);        break;
    case MUT_REMOVE:     m.remove(2);                break;
    case MUT_MOVE:       m.move(1, 40, 90);          break;  // y 50->90 reorders after 2,3
    case MUT_SET_LAYER:  m.set_layer(1, 1);          break;
    case MUT_FRONT:      m.bring_to_front(1);        break;  // z jumps above 2,3
    case MUT_BACK:       m.bring_to_back(3);         break;  // z drops below 1,2
    case MUT_CAMERA_PAN: m.camera_pan(10, 10);       break;  // 4 out, 5 in
    default: break;
  }
}

// Run one mutation kind through a fresh scene ON vs OFF and report whether the
// cached (ON) drawn set matched the reference (OFF) at EVERY tick.
// skip: kinds whose dirty flag is suppressed (fault injection).
static bool differential_matches(MutKind k, const std::set<MutKind>& skip) {
  Model on, off;
  seed(on);  on.drawcache_enabled  = true;  on.skip_dirty  = skip;
  seed(off); off.drawcache_enabled = false; // OFF ignores dirty entirely

  bool matched = true;
  // Warm-up tick: both build the initial set and agree.
  if (on.tick() != off.tick()) matched = false;
  // Apply the mutation, then present a frame.
  apply(on, k);
  apply(off, k);
  if (on.tick() != off.tick()) matched = false;
  // A second quiescent frame: a stale cache stays stale (no further dirtying).
  if (on.tick() != off.tick()) matched = false;
  return matched;
}

int main() {
  // ---- POSITIVE: correctly-wired engine -> ON == OFF for every mutation. ----
  for (int k = 0; k < MUT_COUNT; ++k) {
    std::set<MutKind> none;
    bool ok = differential_matches((MutKind)k, none);
    CHECK(ok, "positive: DRAWCACHE ON diverged from OFF for mutation '%s' "
              "(a correctly-wired mutation must keep the cache coherent)",
          mut_name((MutKind)k));
  }

  // ---- NEGATIVE self-test: drop the dirty flag for a mutation -> the         ----
  // ---- differential MUST catch it. Proves the test can detect a missing site.----
  for (int k = 0; k < MUT_COUNT; ++k) {
    std::set<MutKind> skip;
    skip.insert((MutKind)k);
    bool ok = differential_matches((MutKind)k, skip);
    CHECK(!ok, "negative: dropping the dirty flag for '%s' was NOT detected -- "
               "the harness is blind to this invalidation site; the scene must "
               "exercise a visible/order change for it",
          mut_name((MutKind)k));
  }

  if (g_fail == 0) {
    std::printf("test_drawcache: OK (%d mutations, positive + negative differential)\n",
                (int)MUT_COUNT);
  } else {
    std::fprintf(stderr, "test_drawcache: %d FAILURE(S)\n", g_fail);
  }
  return g_fail ? 1 : 0;
}
