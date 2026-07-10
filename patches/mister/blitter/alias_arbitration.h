#ifndef ALIAS_ARBITRATION_H
#define ALIAS_ARBITRATION_H
/* Pure decision logic for choosing the fabric alias target each frame.
 * Host-testable (no SDL/engine deps). See
 * docs/superpowers/specs/2026-07-10-title-fabric-alias-design.md.
 *
 * The renderer aliases ONE full-FB surface as the DDR framebuffer so per-sprite
 * draws composite on the fabric. Two candidate sources exist:
 *   - the deterministic camera TAG (Game::draw) — authoritative for gameplay;
 *   - a behaviorally-detected full-FB "promote" surface (menus/title) — used
 *     when the tag is absent or DEAD (received no draws last frame).
 * alias_decide() picks, from LAST frame's observations, what the alias should
 * be for the new frame. It never steals the alias from a LIVE tagged camera, so
 * gameplay is unchanged (at most a 1-frame adoption lag, which only occurs at
 * map-change/transition boundaries where aliasing is already disabled). */

typedef enum {
  ALIAS_KEEP = 0,       /* leave alias_target unchanged */
  ALIAS_ADOPT_TAG,      /* set alias_target := tagged camera surface */
  ALIAS_ADOPT_PROMOTE   /* set alias_target := detected promote surface */
} alias_action_t;

typedef struct {
  /* camera tag (deterministic, from Game::draw) */
  int tag_present;   /* camera_tag enabled AND g_tagged_camera != NULL */
  int tag_is_alias;  /* g_tagged_camera == current alias_target */
  int tag_live;      /* tagged surface received >=1 draw LAST frame */
  /* behavioral promote candidate (detected LAST frame) */
  int cand_present;  /* a qualifying full-FB promote candidate exists */
  int cand_is_alias; /* candidate == current alias_target */
} alias_obs_t;

/* A promote candidate qualifies only if it is FB-sized, geometrically a 1:1
 * opaque full-frame copy, was re-established this frame (hw-cleared OR covered
 * by a leading full-FB opaque draw) before its incremental draws, AND actually
 * received draws. */
static inline int alias_cand_eligible(int fb_sized, int geom_ok,
                                      int reestablished, int drawn) {
  return (fb_sized && geom_ok && reestablished && drawn) ? 1 : 0;
}

static inline alias_action_t alias_decide(alias_obs_t o) {
  /* 1. A LIVE tag is authoritative (unchanged gameplay): adopt if not already
   *    the alias. */
  if (o.tag_present && o.tag_live && !o.tag_is_alias)
    return ALIAS_ADOPT_TAG;
  /* 2. Tag absent or DEAD: if a behavioral candidate is live and not already
   *    the alias, adopt it (fixes the title's dead-tag hijack). */
  if ((!o.tag_present || !o.tag_live) && o.cand_present && !o.cand_is_alias)
    return ALIAS_ADOPT_PROMOTE;
  /* 3. Otherwise keep the current alias. */
  return ALIAS_KEEP;
}

#endif /* ALIAS_ARBITRATION_H */
