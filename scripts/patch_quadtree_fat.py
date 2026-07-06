#!/usr/bin/env python3
"""Apply the fat-AABB broad-phase hysteresis edit (SOLARUS_QTREE_MARGIN) to an
upstream Solarus Quadtree checkout, in place and idempotently.

Usage: patch_quadtree_fat.py <Quadtree.h> <Quadtree.inl>

move() stores an inflated ("fat") box and skips the remove+add reinsert while the
entity's true box stays inside it; margin 0 keeps the exact original behavior.
Correctness + rationale: docs/superpowers/plans/2026-07-05-quadtree-fat-aabb.md.

Touches disjoint regions from the "#26 vector+sort" edit (includes / move() /
members, NOT get_elements), so the two never conflict and order does not matter.
Idempotent: a no-op if `fat_margin` is already present.
"""
import sys


def main(hp, ip):
    h = open(hp).read()
    s = open(ip).read()
    # Idempotent per file: only apply where the sentinel is absent, so a partial
    # state (one file patched, the other pristine) still self-heals instead of
    # being skipped wholesale.
    if "fat_margin" in h and "fat_margin" in s:
        return  # both already applied
    if "fat_margin" in h:
        _patch_inl(ip, s)
        return
    if "fat_margin" in s:
        _patch_h(hp, h)
        return
    _patch_h(hp, h)
    _patch_inl(ip, s)


def _patch_h(hp, h):
    # (a) include <cstdlib> for std::getenv/atoi in read_fat_margin_env.
    old = "#include <array>\n#include <map>"
    new = "#include <array>\n#include <cstdlib>\n#include <map>"
    assert old in h, "Quadtree.h include anchor not found"
    h = h.replace(old, new, 1)

    # (b) public accessors after move().
    old = """    bool move(const T& element, const Rectangle& bounding_box);

    std::vector<T> get_elements("""
    new = """    bool move(const T& element, const Rectangle& bounding_box);

    void set_fat_margin(int margin);
    int get_fat_margin() const;
    long long get_move_reinsert_count() const;

    std::vector<T> get_elements("""
    assert old in h, "Quadtree.h public-accessor anchor not found"
    h = h.replace(old, new, 1)

    # (c) private members after root.
    old = """    Node root;                              /** The root node of the tree. */

};"""
    new = """    Node root;                              /** The root node of the tree. */

    static int read_fat_margin_env();

    int fat_margin = read_fat_margin_env();   /**< Broad-phase inflation in px.
                                               * Default 8 (HW-validated); 0
                                               * disables (exact behavior). */
    long long move_reinsert_count = 0;         /**< move() calls that did an
                                               * actual remove+add. */

};"""
    assert old in h, "Quadtree.h private-member anchor not found"
    h = h.replace(old, new, 1)
    open(hp, "w").write(h)


def _patch_inl(ip, s):
    # (d) accessor + env-reader definitions right after the namespace open.
    old = "namespace Solarus {\n"
    new = ('namespace Solarus {\n\n'
           'template<typename T, typename Comparator>\n'
           'int Quadtree<T, Comparator>::read_fat_margin_env() {\n'
           '  // HW-validated default ON (8px). Set SOLARUS_QTREE_MARGIN=0 to opt out.\n'
           '  const char* e = std::getenv("SOLARUS_QTREE_MARGIN");\n'
           '  return e != nullptr ? std::atoi(e) : 8;\n'
           '}\n\n'
           'template<typename T, typename Comparator>\n'
           'void Quadtree<T, Comparator>::set_fat_margin(int margin) {\n'
           '  fat_margin = margin;\n'
           '}\n\n'
           'template<typename T, typename Comparator>\n'
           'int Quadtree<T, Comparator>::get_fat_margin() const {\n'
           '  return fat_margin;\n'
           '}\n\n'
           'template<typename T, typename Comparator>\n'
           'long long Quadtree<T, Comparator>::get_move_reinsert_count() const {\n'
           '  return move_reinsert_count;\n'
           '}\n')
    assert old in s, "Quadtree.inl namespace anchor not found"
    s = s.replace(old, new, 1)

    # (e) move(): fat-AABB hysteresis body.
    old = """  const auto& it = elements.find(element);
  if (it == elements.end()) {
    // Not in the quadtree: error.
    return false;
  }
  else {
    if (it->second.bounding_box == bounding_box) {
      // Already in the quadtree and no change.
      return true;
    }

    if (!remove(element)) {
      // Failed to remove.
      return false;
    }
  }

  if (!add(element, bounding_box)) {
    // Failed to add.
    return false;
  }
  return true;"""
    new = """  const auto& it = elements.find(element);
  if (it == elements.end()) {
    // Not in the quadtree: error.
    return false;
  }

  const Rectangle stored_box = it->second.bounding_box;  // copy: remove() erases it

  if (fat_margin <= 0) {
    // Feature disabled: original exact behavior.
    if (stored_box == bounding_box) {
      // Already in the quadtree and no change.
      return true;
    }
  }
  else {
    // Fat-AABB hysteresis: skip the reinsert while the true box stays inside
    // the stored (inflated) box. Correct because the stored box always
    // contains the true box, so get_elements still returns this element for
    // any query overlapping the true box; consumers re-test precisely.
    if (stored_box.contains(bounding_box)) {
      return true;
    }
  }

  if (!remove(element)) {
    // Failed to remove.
    return false;
  }

  Rectangle new_box = bounding_box;
  if (fat_margin > 0) {
    new_box.add_xy(-fat_margin, -fat_margin);
    new_box.add_width(2 * fat_margin);
    new_box.add_height(2 * fat_margin);
  }

  if (!add(element, new_box)) {
    // Failed to add.
    return false;
  }
  ++move_reinsert_count;
  return true;"""
    assert old in s, "Quadtree.inl move() anchor not found"
    s = s.replace(old, new, 1)
    open(ip, "w").write(s)
    print("Quadtree fat-AABB hysteresis patched")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: patch_quadtree_fat.py <Quadtree.h> <Quadtree.inl>")
    main(sys.argv[1], sys.argv[2])
