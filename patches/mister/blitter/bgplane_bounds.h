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
// extent belonging to base_layer, ignoring every other layer entirely.
//
// The bgplane bake is restricted to exactly one layer per map -- the base
// layer (map.get_min_layer(), the only layer Entities::draw() is guaranteed
// to process before anything else has drawn to the framebuffer this frame,
// so an opaque full-screen COPY of its baked plane can never erase another
// layer's already-drawn content). See
// docs/superpowers/specs/2026-07-08-bgplane-base-layer-occlusion-design.md
// for the full rationale (this replaces a prior design that merged every
// layer's statics, plus animated-bucket extents, into one plane -- both of
// which are gone here: animated tiles are never baked regardless of layer,
// so their extent never needs to size the plane).
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
