#include "capture.cc"
#include <cassert>
#include <iostream>
#include <vector>

struct Sim {
    cxxrtl_design::p_capture d;
    std::vector<unsigned> bytes;
    unsigned completions = 0;
    void tick(int n = 1) {
        while (n--) {
            d.p_clk.set(false); d.step();
            d.p_clk.set(true); d.step();
            if (d.p_mem__we.get<bool>()) {
                assert(d.p_mem__addr.get<unsigned>() == bytes.size());
                bytes.push_back(d.p_mem__data.get<unsigned>());
            }
            completions += d.p_done.get<bool>();
        }
    }
    Sim() { d.p_reset.set(true); tick(8); d.p_reset.set(false); tick(8); }
    void arm(int mode = 0) {
        bytes.clear(); completions = 0;
        d.p_msb__first.set(mode & 1); d.p_falling__edge.set((mode >> 1) & 1);
        d.p_arm.set(true); tick(); d.p_arm.set(false); tick(12);
        assert(d.p_busy.get<bool>());
    }
    void nibble(unsigned v, bool fall = false, bool unstable = false, int half = 4) {
        d.p_pclk.set(fall); d.p_data.set(v); tick(half);
        d.p_pclk.set(!fall);
        if (unstable) { tick(); d.p_data.set(v ^ 15); tick(half - 1); }
        else tick(half);
    }
    void frame(int mode = 0, int lines = 4, int nibbles = 32, bool simultaneous = false) {
        d.p_vsync.set(true); tick(12);
        for (int y = 0; y < lines; ++y) {
            d.p_href.set(true); tick(8);
            for (int x = 0; x < nibbles; ++x) {
                unsigned pixel = (y * 16 + x / 2) * 73 & 255;
                unsigned value = ((x & 1) ^ (mode & 1)) ? pixel >> 4 : pixel & 15;
                nibble(value, mode & 2);
            }
            d.p_pclk.set(bool(mode & 2)); tick(8);
            d.p_href.set(false);
            if (simultaneous && y == lines - 1) d.p_vsync.set(false);
            tick(12);
        }
        d.p_vsync.set(false); tick(12);
    }
    void varied_frame(unsigned seed, int mode, int fault_wire = -1,
                      int fault_offset = 0, int fault_width = 0) {
        auto random = [&]() {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5;
            return seed;
        };
        bool fall = mode & 2;
        d.p_pclk.set(fall);
        d.p_vsync.set(true); tick(8 + random() % 8);
        for (unsigned y = 0; y < 4; ++y) {
            d.p_href.set(true); tick(8 + random() % 8);
            for (unsigned x = 0; x < 32; ++x) {
                unsigned pixel = ((y * 16 + x / 2) * 73) & 255;
                unsigned value = ((x & 1) ^ (mode & 1)) ? pixel >> 4 : pixel & 15;
                unsigned setup = 4 + random() % 5, hold = 4 + random() % 5;
                d.p_pclk.set(fall); d.p_data.set(value); tick(setup);
                d.p_pclk.set(!fall);
                for (unsigned t = 0; t < hold; ++t) {
                    bool inject = y == 1 && x == 7 && fault_wire >= 0 &&
                                  int(t) >= fault_offset && int(t) < fault_offset + fault_width;
                    d.p_data.set(value ^ (inject ? (1U << fault_wire) : 0));
                    tick();
                }
            }
            d.p_pclk.set(fall); tick(8);
            d.p_href.set(false); tick(8 + random() % 8);
        }
        d.p_vsync.set(false); tick(12);
    }
    bool exact_frame() const {
        if (bytes.size() != 64) return false;
        for (unsigned i = 0; i < 64; ++i)
            if (bytes[i] != ((i * 73) & 255)) return false;
        return true;
    }
};

int main() {
    Sim s;
    for (int mode = 0; mode < 4; ++mode) {
        s.arm(mode); s.frame(mode, 4, 32, mode & 1);
        assert(s.completions == 1 && !s.d.p_busy.get<bool>());
        assert(s.d.p_flags.get<unsigned>() == 0);
        assert(s.bytes.size() == 64 && s.d.p_lines__count.get<unsigned>() == 4);
        assert(s.d.p_min__line.get<unsigned>() == 32 && s.d.p_max__line.get<unsigned>() == 32);
        for (unsigned i = 0; i < 64; ++i) assert(s.bytes[i] == ((i * 73) & 255));
    }
    s.arm(); s.frame(0, 4, 31);
    assert((s.d.p_flags.get<unsigned>() & 3) == 3);
    s.arm(); s.frame(0, 3);
    assert(s.d.p_flags.get<unsigned>() & 4);
    s.arm(); s.frame(0, 4, 34);
    assert(s.d.p_flags.get<unsigned>() & 2);
    s.arm(); s.frame(0, 17);
    assert(s.d.p_flags.get<unsigned>() & 16);
    assert(s.bytes.size() == 256);
    s.arm(); s.tick(10001);
    assert(s.d.p_flags.get<unsigned>() & 128);
    assert(s.completions == 1);
    s.arm(); s.d.p_vsync.set(true); s.d.p_href.set(true); s.tick(12);
    s.nibble(3, false, true); s.nibble(4);
    assert(s.d.p_flags.get<unsigned>() & 32);
    s.nibble(7, false, false, 1); s.nibble(8, false, false, 1); s.tick(8);
    assert(s.d.p_flags.get<unsigned>() & 64);
    s.d.p_vsync.set(false); s.tick(12);
    assert(s.d.p_flags.get<unsigned>() & 8);
    s.d.p_href.set(false); s.tick(12);

    for (int mode = 0; mode < 4; ++mode) {
        for (unsigned seed = 1; seed <= 64; ++seed) {
            s.arm(mode); s.varied_frame(seed, mode);
            assert(s.completions == 1 && !s.d.p_busy.get<bool>());
            assert(s.exact_frame() && s.d.p_flags.get<unsigned>() == 0);
            assert(s.d.p_lines__count.get<unsigned>() == 4);
            assert(s.d.p_min__line.get<unsigned>() == 32 && s.d.p_max__line.get<unsigned>() == 32);
        }
        for (int wire = 0; wire < 4; ++wire) {
            for (int width = 1; width <= 2; ++width) {
                for (int offset = 0; offset < 4; ++offset) {
                    s.arm(mode); s.varied_frame(1, mode, wire, offset, width);
                    if (!s.exact_frame() && !(s.d.p_flags.get<unsigned>() & 32)) {
                        std::cerr << "undetected data corruption: mode=" << mode
                                  << " wire=" << wire << " width=" << width
                                  << " offset=" << offset << '\n';
                        return 1;
                    }
                }
            }
        }
    }

    // Arming inside an existing frame must wait for a clean frame boundary.
    s.d.p_vsync.set(true); s.d.p_href.set(true); s.tick(12);
    s.arm();
    for (int i = 0; i < 16; ++i) s.nibble(i);
    assert(s.bytes.empty());
    s.d.p_href.set(false); s.d.p_vsync.set(false); s.tick(12);
    s.frame(); assert(s.exact_frame() && s.d.p_flags.get<unsigned>() == 0);

    s.arm(); s.d.p_vsync.set(true); s.d.p_href.set(true); s.tick(12);
    s.nibble(7); s.nibble(8);
    s.d.p_reset.set(true); s.tick(12);
    assert(!s.d.p_busy.get<bool>() && !s.d.p_mem__we.get<bool>());
    s.d.p_href.set(false); s.d.p_vsync.set(false); s.d.p_reset.set(false); s.tick(12);
    s.arm(); s.frame(); assert(s.exact_frame() && s.d.p_flags.get<unsigned>() == 0);
    std::cout << "capture: modes, framing, recovery, 256 varied-timing frames, "
                 "128 per-wire glitch cases and injected faults passed\n";
}
