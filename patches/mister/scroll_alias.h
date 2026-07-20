// [Stage 3a] Camera-alias scroll-offset maintenance — SINGLE SOURCE OF TRUTH.
//
// The camera alias offset is maintained at two mirrored sites in the renderer:
// MisterBlitterRenderer::draw() and ::resident_begin_frame(). They were originally
// hand-duplicated, and drifted: both reset the offset to zero ONLY inside the
// "camera surface changed" adoption branch, while refreshing it per frame only
// while a scroll is running. When a scroll ended with the camera unchanged,
// neither path fired and the offset latched its last in-scroll value forever.
//
// That surfaced on hardware as entities drawn misaligned from the background by
// the LAST transition's direction (constant magnitude, indefinitely), because the
// two consumers read the offset differently:
//   - background / tiles: Impl::scroll_bias_x/y(), which is already gated on
//     (scrollfab && g_transition_scroll) and therefore self-clears;
//   - sprites / entities: the raw alias_off_x/y field (sprite_channel_push,
//     emit_draw), which does not.
//
// Keeping the rule in one inline function means the two call sites cannot diverge
// again, and lets the host test (test_scrollalias.cpp) exercise the REAL logic
// rather than a re-modelled copy of it.
#ifndef MISTER_SCROLL_ALIAS_H
#define MISTER_SCROLL_ALIAS_H

// Update the camera-alias destination offset for this frame.
//
//   off_x/off_y          [in,out] the alias offset the renderer applies to draws
//   scrollfab            SOLARUS_SCROLLFAB — the Stage 3a gate. When false this
//                        function never writes an offset, so the shipping default
//                        path is bit-identical to pre-Stage-3a behaviour.
//   transition_scroll    g_transition_scroll: a TransitionScrolling is running
//                        (transition active AND needs_previous_surface()).
//   camera_changed       the tagged camera surface differs from the current alias
//                        target, i.e. this frame adopts a new camera (map change).
//   alias_is_tagged_cam  the alias target IS the tagged camera. Load-bearing: the
//                        legacy looks_like_promote() alias carries its own,
//                        legitimately non-zero offset (the promote blit's dst
//                        rect). Clearing that would break the non-camera alias, so
//                        the scroll rule applies to the tagged camera only.
//   new_dx/new_dy        engine-truth scroll offset published this frame for the
//                        NEW map (g_scroll_new_dx/dy).
//
// Post-condition: while a scroll runs the offset tracks engine truth; the moment
// the scroll ends the offset is zero, matching scroll_bias_x/y() so entities and
// background agree.
static inline void mister_scroll_alias_update(int& off_x, int& off_y,
                                              bool scrollfab,
                                              bool transition_scroll,
                                              bool camera_changed,
                                              bool alias_is_tagged_cam,
                                              int new_dx, int new_dy) {
  if (camera_changed) {
    // Adopting a new camera: start it at the scroll offset if a scroll is in
    // flight (the map swap happens mid-scroll), otherwise at the origin.
    if (scrollfab && transition_scroll) { off_x = new_dx; off_y = new_dy; }
    else                                { off_x = 0;      off_y = 0;      }
    alias_is_tagged_cam = true;    // adoption makes the camera the alias target
  }
  if (!scrollfab) return;          // flag OFF: never our offset to touch
  if (!alias_is_tagged_cam) return; // legacy promote alias owns its own offset
  // The scroll offset changes every frame, so refresh unconditionally while
  // scrolling -- and, critically, CLEAR it the frame the scroll ends. The missing
  // else-branch here was the latch bug.
  if (transition_scroll) { off_x = new_dx; off_y = new_dy; }
  else                   { off_x = 0;      off_y = 0;      }
}

#endif  // MISTER_SCROLL_ALIAS_H
