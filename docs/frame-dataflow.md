# Frame data flow (post-#19 SDRAM second-bus)

How a frame is generated end-to-end, reflecting the current architecture and
assuming the #19 PSX-pattern SDRAM second-bus controller lands.

> **Issue map:** the SDRAM controller is **#19** (`issue19-psx-sdram-controller`).
> **#26** is the LuaJIT-baseline + profiling work that *diagnosed* motion as
> fabric-bound (fabric ~30–40 ms vs A9 ~8–12 ms while scrolling) and motivated #19.
> Related levers in the diagram: #21 (off-screen bg-cache flatten), #14 (DDR
> texture allocator `blt_alloc`).

## Component + dataflow view

```mermaid
flowchart TB
    subgraph A9["A9 CPU — libsolarus.so (armhf, LuaJIT)"]
        direction TB
        ENG["Solarus engine<br/>(quest + Lua, software compositing model)"]
        REND["MisterBlitterRenderer<br/>(decorator over SDLRenderer)<br/>intercepts clear/fill/draw/present"]
        BG["bg-cache state machine #21<br/>LEARN → SNAPSHOT → ACTIVE<br/>cuts 6×→~2× overdraw:<br/>off-screen compose + scroll-shift copy + edge strips"]
        EM["blt_emitter<br/>packs ~32-byte commands → ring<br/>uploads surfaces as RGB565 via blt_alloc #14"]
        SDL["SDLRenderer fallback<br/>(NativeVideoWriter → DDR)<br/>used on 'escaped' frames"]
        ENG --> REND --> BG --> EM
        REND -. escape (per-pixel alpha,<br/>RTT, ADD/MULTIPLY, rotate) .-> SDL
    end

    subgraph DDR3["DDR3 — shared HPS f2h bus @ 0x3A000000+"]
        RING["command ring + BLTCTRL control block<br/>(incl. C_SRCSEL select bit)"]
        TEX["texture heap (blt_alloc regions)"]
        BGC["off-screen bg-cache region<br/>(OFF_BGCACHE 0x3BF00000)"]
        FB["target framebuffers (double-buffered)"]
    end

    subgraph SDRAM["DE10-Nano SDRAM — dedicated 2nd bus (VRAM-like) #19"]
        SDC["sdram_src_arb → sdram_psx controller<br/>(PSX pattern: BL=2×N line reads,<br/>page-open reuse, refresh@boundary)"]
        CHIP["MT48LC16M16 @100MHz<br/>holds blitter SOURCE textures"]
        SDC --- CHIP
    end

    subgraph FAB["FPGA fabric — blitter_top.sv"]
        FETCH["fetch commands + control words"]
        SRCSEL{"SOURCE SELECT<br/>(runtime C_SRCSEL bit)"}
        RC["DDR3 readcache<br/>(shipping default, analog-clean)"]
        COMP["compositor<br/>COPY / BLEND / COLORKEY / CONST_ALPHA"]
        FETCH --> COMP
        COMP --> SRCSEL
        SRCSEL -- "0: default" --> RC
        SRCSEL -- "1: #19" --> SDC
    end

    subgraph OUT["Scanout — MiSTer core (ascal)"]
        SCAN["scanout reader → HDMI + analog YPbPr<br/>(clk_pix; analog-margin gate = the #19 risk)"]
    end

    EM -- "DDR copy: ring + ctrl,<br/>then doorbell (submit_seq)" --> RING
    EM -- upload textures --> TEX
    EM -. mirror source textures .-> CHIP
    SDL --> FB

    RING --> FETCH
    BG -. C_TARGET=2 compose .-> BGC
    BGC --> COMP
    TEX --> RC
    RC --> COMP
    CHIP --> COMP
    COMP -- "write composited pixels" --> FB
    COMP -. done_seq .-> RING
    FB --> SCAN
```

## Per-frame sequence

```mermaid
sequenceDiagram
    autonumber
    participant ENG as Solarus engine
    participant R as MisterBlitterRenderer
    participant EM as blt_emitter
    participant DDR as DDR3 (ring/ctrl/fb)
    participant FAB as blitter_top
    participant SRC as Source (DDR3 readcache ▸ or ▸ SDRAM #19)
    participant OUT as Scanout (HDMI/analog)

    ENG->>R: clear(screen) → begin frame
    loop each draw/fill (tens–hundreds)
        R->>R: bg-cache: cacheable? skip / copy-shift / edge-strip
        R->>EM: emit ~32B blit command
    end
    Note over R,EM: per-pixel-alpha / RTT / ADD → mark frame "escaped"
    ENG->>R: present(window)
    alt frame escaped or emitter overflow
        R->>DDR: SDL software composite → framebuffer (fallback)
    else accelerated
        EM->>DDR: copy ring + control block
        EM->>DDR: store submit_seq (doorbell, last)
        FAB->>DDR: fetch commands + C_SRCSEL
        loop each command
            FAB->>SRC: read source line (BL=2×N if SDRAM)
            SRC-->>FAB: pixels
            FAB->>DDR: composite → target framebuffer
        end
        FAB->>DDR: store done_seq
    end
    DDR->>OUT: scanout target framebuffer → display
    Note over OUT: double-buffer swap; analog vsync must stay roll-free
```

## What #19 changes vs. the original design

Blitter **source** reads — the dominant fabric cost during scrolling — move off
the contended DDR3 f2h bus onto the dedicated SDRAM module via the runtime
`C_SRCSEL` mux. DDR3 still carries the command ring, control block, bg-cache, and
target framebuffers; the DDR3 readcache stays the analog-clean default that one
register write falls back to. The remaining gate is purely on-device: the analog
YPbPr path staying roll-free with SDRAM active.

## References

- `docs/blitter-renderer-integration.md` — the host-side renderer binding.
- `docs/superpowers/specs/2026-06-15-issue19-psx-sdram-controller-design.md` — #19 design.
- `docs/superpowers/specs/2026-06-14-issue21-offscreen-flatten-design.md` — #21 bg-cache.
- `docs/superpowers/specs/2026-06-15-ddr-texture-allocator-design.md` — #14 `blt_alloc`.
