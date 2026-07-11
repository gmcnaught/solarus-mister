#ifndef BGPLANE_BOUNDS_H
#define BGPLANE_BOUNDS_H

// [bug #1 fix] One recorded static-tile placement, layer-tagged -- mirrors
// the fields of MisterBlitterRenderer::Impl::StaticEnt (dx,dy,w,h) plus its
// owning StaticBucket's layer, flattened here for pure bounds computation
// independent of the renderer's DDR/hardware-backed types (so this is host-
// unit-testable; MisterBlitterRenderer itself is not, per bgplane_geom_test.cpp).
typedef struct {
    int layer;
    int dx, dy, w, h;
} bgplane_tile_extent_t;

typedef struct {
    int any;              // nonzero iff >=1 extent matched base_layer
    int mw, mh;            // plane pixel dimensions (max - origin)
    int min_x, min_y;      // origin (<=0; only ever shifted to cover negatives)
} bgplane_bounds_t;

// Compute the baked-plane bounding box from every recorded static-tile
// extent belonging to base_layer (the caller's target layer -- despite the
// parameter's name, this is NOT restricted to a map's actual min/base layer),
// ignoring every other layer entirely.
//
// [Task 6, generalized] The bgplane bake now runs per LAYER, not per map: the
// host caller (res_arm_, mister_blitter_renderer.cpp) collects the distinct
// set of layers with recorded static content and calls this function once per
// layer, each time filtering to just that layer's extents, to size that
// layer's own independent plane. Each call is stateless and independent --
// two calls with different target layers over the SAME extents array never
// interfere with each other (see tests/bgplane_bounds_test.cpp's two-layer
// case). This generalizes the original design (see
// docs/superpowers/specs/2026-07-08-bgplane-base-layer-occlusion-design.md)
// that restricted the bake to exactly one hardcoded base layer per map, which
// in turn replaced an even earlier design that merged every layer's statics,
// plus animated-bucket extents, into one plane -- animated tiles are still
// never baked regardless of layer, so their extent never needs to size any
// plane.
//
// Origin is only ever shifted to cover negative coordinates, never pulled
// positive -- mirrors the single-plane implementation this replaces.
static inline bgplane_bounds_t compute_bgplane_bounds(
        const bgplane_tile_extent_t* extents, int count, int base_layer) {
    bgplane_bounds_t b; b.any = 0; b.mw = 0; b.mh = 0; b.min_x = 0; b.min_y = 0;
    for (int i = 0; i < count; ++i) {
        const bgplane_tile_extent_t* e = &extents[i];
        if (e->layer != base_layer) continue;
        int ex = e->dx + e->w, ey = e->dy + e->h;
        if (!b.any) { b.min_x = e->dx; b.min_y = e->dy; b.any = 1; }
        if (ex > b.mw) b.mw = ex;
        if (ey > b.mh) b.mh = ey;
        if (e->dx < b.min_x) b.min_x = e->dx;
        if (e->dy < b.min_y) b.min_y = e->dy;
    }
    if (b.min_x > 0) b.min_x = 0;
    if (b.min_y > 0) b.min_y = 0;
    b.mw -= b.min_x; b.mh -= b.min_y;
    return b;
}

#endif
