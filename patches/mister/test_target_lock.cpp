// Models the root-target lock contract (retained-scene Stage 1, Task 1).
// Host-only, no engine link, no SDL -- a faithful model of
// mister_blitter_renderer.cpp's Impl::is_fpga_target(). Proves the engine tag
// beats the first-wins heuristic, and (negative self-test) that dropping the
// tag check is actually caught.
#include <cstdio>

static int failures = 0;
#define CHECK(c,m) do{ if(!(c)){ std::printf("FAIL: %s (line %d)\n", m, __LINE__); failures++; } }while(0)

static const int FB_W = 320, FB_H = 240;

// Model of a SurfaceImpl: only the properties is_fpga_target inspects.
struct Surf { int w, h; bool has_texture; };

// Model of the lock. `use_tag` lets the negative self-test simulate the fix
// being dropped.
struct Lock {
    const Surf* tagged_root = nullptr;   // g_tagged_root
    const Surf* fpga_target = nullptr;   // first-wins fallback
    bool use_tag = true;

    bool is_fpga_target(const Surf& dst) {
        if (dst.w != FB_W || dst.h != FB_H) return false;
        if (!dst.has_texture) return false;              // screen surface -> not us
        if (use_tag && tagged_root) return &dst == tagged_root;
        if (!fpga_target) fpga_target = &dst;
        return &dst == fpga_target;
    }
};

int main() {
    Surf real_root{FB_W, FB_H, true};
    Surf decoy{FB_W, FB_H, true};            // transient 320x240 render texture
    Surf screen{FB_W, FB_H, false};          // window surface: null texture
    Surf small{160, 120, true};

    // (a) Tagged: the real root wins even though the decoy was drawn FIRST.
    {
        Lock l; l.tagged_root = &real_root;
        CHECK(!l.is_fpga_target(decoy),     "tagged: decoy drawn first is NOT the target");
        CHECK( l.is_fpga_target(real_root), "tagged: real root IS the target");
        CHECK(!l.is_fpga_target(decoy),     "tagged: decoy still rejected after root seen");
    }

    // (b) Untagged fallback preserves today's first-wins behaviour.
    {
        Lock l;   // no tag
        CHECK( l.is_fpga_target(decoy),     "untagged: first 320x240 texture wins");
        CHECK(!l.is_fpga_target(real_root), "untagged: real root loses to the decoy");
    }

    // (c) Non-candidates are rejected under both modes.
    {
        Lock l; l.tagged_root = &real_root;
        CHECK(!l.is_fpga_target(screen), "screen surface (null texture) rejected");
        CHECK(!l.is_fpga_target(small),  "wrong-size surface rejected");
    }

    // (d) NEGATIVE SELF-TEST: dropping the tag check must reintroduce the
    //     mis-lock. If this passes, the test is not actually gating anything.
    {
        Lock l; l.tagged_root = &real_root; l.use_tag = false;
        bool decoy_stole = l.is_fpga_target(decoy) && !l.is_fpga_target(real_root);
        CHECK(decoy_stole, "negative self-test: without the tag check the decoy steals the lock");
    }

    std::printf(failures ? "FAILED (%d)\n" : "ok target_lock (tag beats first-wins)\n", failures);
    return failures ? 1 : 0;
}
