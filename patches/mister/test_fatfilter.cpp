// Fat-AABB precise re-filter test (issue #105). Host-only, no engine, no SDL.
//
// The engine bug this guards (patch 0037): the quadtree stores fat-AABB-inflated
// bounding boxes (patch 0008, fat_margin default 8px) as a collision broad-phase
// optimization, so Quadtree::get_elements(query) returns every entity whose
// *inflated* box overlaps the query -- including entities up to fat_margin px
// OUTSIDE it. The collision path re-tests precisely, but the Lua query APIs
// (map:get_entities_in_rectangle / map:get_entities_in_region) fed the raw list
// straight to quests, leaking false positives. Patch 0037 adds a precise
// get_bounding_box().overlaps(query) re-filter on those two Lua paths.
//
// This test does NOT link the engine. It re-implements the exact contract as a
// small faithful model:
//   * the quadtree "fat" candidate set  (inflated box overlaps query),
//   * the reference set                 (REAL box overlaps query -- flag-OFF /
//                                         the documented "bounding box overlaps"
//                                         contract), and
//   * the re-filtered set               (fat candidates kept only if REAL box
//                                         overlaps query -- patch 0037),
// then asserts, over many query rectangles and margins, that the re-filtered set
// equals the reference set exactly.
//
// It has teeth: the NEGATIVE self-test asserts that WITHOUT the re-filter the fat
// candidate set actually DIVERGES from the reference (there really is a leak the
// fix removes). If the scene stopped exercising a margin-band entity that
// assertion would fail, flagging a toothless test instead of silently passing.
//
// overlaps() mirrors Solarus's Rectangle::overlaps (Rectangle.inl): half-open
// intervals [x, x+w) -- edge-touching boxes do NOT overlap (x3 < x2 && x1 < x4).
//
// Build/run:  see patches/mister/build_test_fatfilter.sh
#include <cstdio>
#include <set>
#include <vector>

static int g_fail = 0;
#define CHECK(cond, ...) do { if (!(cond)) {                    \
  std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__);     \
  std::fprintf(stderr, __VA_ARGS__); std::fprintf(stderr, "\n"); g_fail++; } } while (0)

// Faithful model of Solarus's Rectangle::overlaps (half-open AABB).
struct Rect {
  int x, y, w, h;
  bool overlaps(const Rect& o) const {
    const bool ox = (o.x < x + w) && (x < o.x + o.w);
    const bool oy = (o.y < y + h) && (y < o.y + o.h);
    return ox && oy;
  }
};

// Quadtree fat-AABB: the stored box is inflated by `margin` on every side
// (patch 0008: move() inflates by fat_margin).
static Rect inflate(const Rect& r, int m) {
  return Rect{ r.x - m, r.y - m, r.w + 2 * m, r.h + 2 * m };
}

struct Entity { int id; Rect box; };   // box = the REAL (un-inflated) bounding box

// quadtree->get_elements(query): entities whose INFLATED box overlaps the query.
static std::set<int> fat_candidates(const std::vector<Entity>& es, const Rect& q, int m) {
  std::set<int> out;
  for (const Entity& e : es) if (inflate(e.box, m).overlaps(q)) out.insert(e.id);
  return out;
}

// Reference / documented contract (flag-OFF): REAL box overlaps the query.
static std::set<int> reference(const std::vector<Entity>& es, const Rect& q) {
  std::set<int> out;
  for (const Entity& e : es) if (e.box.overlaps(q)) out.insert(e.id);
  return out;
}

// Patch 0037: take the fat candidates, drop those whose REAL box does not
// overlap the query.
static std::set<int> refiltered(const std::vector<Entity>& es, const Rect& q, int m) {
  std::set<int> out;
  for (int id : fat_candidates(es, q, m)) {
    for (const Entity& e : es)
      if (e.id == id && e.box.overlaps(q)) { out.insert(id); break; }
  }
  return out;
}

// A scene deliberately seeded with entities at, just inside, just outside, and
// well outside a ~20px trigger rectangle so a fat margin pulls some in.
static std::vector<Entity> scene() {
  return {
    { 1, {105, 105,  4,  4} },  // fully inside Q -> always in
    { 2, {125, 105,  4,  4} },  // 5px right of Q  -> real OUT, fat IN (margin leak)
    { 3, {200, 200,  4,  4} },  // far away        -> always out
    { 4, { 96, 105,  4,  4} },  // touches left edge [96,100) -> real OUT (half-open), fat IN
    { 5, { 97, 105,  4,  4} },  // overlaps by 1px  -> real IN
    { 6, {105, 125,  4,  4} },  // 5px below Q     -> real OUT, fat IN (margin leak)
    { 7, {118, 118, 10, 10} },  // straddles bottom-right corner -> real IN
  };
}

int main() {
  const std::vector<Entity> es = scene();
  const std::vector<Rect> queries = {
    {100, 100, 20, 20},   // the small trigger rectangle
    {  0,   0, 10, 10},   // empty region (nothing near) -> all sets empty
    { 90,  90, 40, 40},   // a larger "region" box
    {104, 104,  2,  2},   // tiny probe inside entity 1 only
  };
  const std::vector<int> margins = {0, 1, 8, 16};   // 8 = engine default

  bool any_leak = false;   // did the margin ever pull in a false positive?

  // ---- POSITIVE: the re-filter reproduces the reference set exactly. ----
  for (const Rect& q : queries) {
    const std::set<int> ref = reference(es, q);
    for (int m : margins) {
      const std::set<int> got = refiltered(es, q, m);
      CHECK(got == ref,
            "positive: re-filtered set != reference for query {%d,%d,%d,%d} margin %d "
            "(the fix must restore the exact bounding-box-overlap contract)",
            q.x, q.y, q.w, q.h, m);
      if (fat_candidates(es, q, m) != ref) any_leak = true;
    }
  }

  // ---- NEGATIVE self-test: without the re-filter the fat candidates DO leak. ----
  // If this fails the scene no longer exercises a margin-band entity, so the
  // positive test above would pass even against a no-op "fix".
  CHECK(any_leak,
        "negative: no query+margin produced a fat-AABB false positive -- the "
        "scene is toothless; the re-filter would pass even if it did nothing");

  // Pin the canonical case explicitly: default margin, the trigger rectangle.
  {
    const Rect q{100, 100, 20, 20};
    const std::set<int> ref = reference(es, q);          // {1,5,7}
    const std::set<int> fat = fat_candidates(es, q, 8);  // {1,2,4,5,6,7}
    const std::set<int> fix = refiltered(es, q, 8);
    CHECK(ref == (std::set<int>{1, 5, 7}), "reference set changed unexpectedly");
    CHECK(fat.count(2) && fat.count(4) && fat.count(6),
          "expected margin-band entities 2/4/6 to leak into the raw fat set");
    CHECK(fix == ref, "re-filtered canonical case must equal the reference");
  }

  if (g_fail == 0) {
    std::printf("test_fatfilter: OK (%zu queries x %zu margins, positive + negative)\n",
                queries.size(), margins.size());
  } else {
    std::fprintf(stderr, "test_fatfilter: %d FAILURE(S)\n", g_fail);
  }
  return g_fail ? 1 : 0;
}
