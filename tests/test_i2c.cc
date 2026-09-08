#include "i2c_register.cc"
#include <cassert>
#include <iostream>
#include <vector>

struct Sim {
    cxxrtl_design::p_i2c__register d;
    bool old_scl = true, old_sda = true, slave_low = false;
    bool active = false, transmitting = false, stuck = false, stretch = false;
    unsigned bits = 0, shift = 0, starts = 0, stops = 0, done = 0;
    int nack = -1;
    std::vector<unsigned> bytes;
    void tick(int n = 1) {
        while (n--) {
            d.p_scl__in.set(!d.p_scl__low.get<bool>() && !stretch);
            d.p_sda__in.set(!d.p_sda__low.get<bool>() && !slave_low && !stuck);
            d.p_clk.set(false); d.step(); d.p_clk.set(true); d.step();
            bool scl = !d.p_scl__low.get<bool>() && !stretch;
            bool sda = !d.p_sda__low.get<bool>() && !slave_low && !stuck;
            if (scl && old_scl && old_sda && !sda) {
                ++starts; active = true; transmitting = false; bits = shift = 0;
            }
            if (scl && old_scl && !old_sda && sda) { ++stops; active = false; }
            if (active && !old_scl && scl) {
                if (bits < 8 && !transmitting) shift = (shift << 1) | sda;
                if (++bits == 8 && !transmitting) bytes.push_back(shift);
                if (bits == 9 && transmitting) assert(sda); // master NACK
            }
            if (active && old_scl && !scl) {
                if (bits == 9) {
                    if (!transmitting && !bytes.empty() && bytes.back() == 0x49) transmitting = true;
                    else if (transmitting) transmitting = false;
                    bits = shift = 0;
                    slave_low = transmitting && !(0xa6 & 0x80);
                } else if (bits == 8) {
                    slave_low = !transmitting && int(bytes.size() - 1) != nack;
                } else if (transmitting) slave_low = !(0xa6 & (0x80 >> bits));
            }
            old_scl = scl;
            old_sda = !d.p_sda__low.get<bool>() && !slave_low && !stuck;
            done += d.p_done.get<bool>();
        }
    }
    Sim() { d.p_reset.set(true); tick(10); d.p_reset.set(false); tick(10); }
    void start(bool read = false) {
        d.p_address.set(0x1234); d.p_write__data.set(0x5a); d.p_read__op.set(read);
        d.p_start.set(true); tick(); d.p_start.set(false);
    }
    void finish() { for (int i = 0; !done && i < 21000; ++i) tick(); assert(done == 1); }
};

int main() {
    { Sim s; s.start(); s.finish();
      assert(s.d.p_error.get<unsigned>() == 0);
      assert((s.bytes == std::vector<unsigned>{0x48,0x12,0x34,0x5a}));
      assert(s.starts == 1 && s.stops == 1); }
    { Sim s; s.start(true); s.finish();
      assert(s.d.p_error.get<unsigned>() == 0 && s.d.p_read__data.get<unsigned>() == 0xa6);
      assert((s.bytes == std::vector<unsigned>{0x48,0x12,0x34,0x49}));
      assert(s.starts == 2 && s.stops == 1); }
    for (int byte = 0; byte < 4; ++byte) {
        Sim s; s.nack = byte; s.start(); s.finish();
        assert(s.d.p_error.get<unsigned>() == unsigned(0x10 | byte));
        assert(s.bytes.size() == unsigned(byte + 1) && s.stops == 1);
    }
    { Sim s; s.start(); s.tick(100); s.stretch = true; s.tick(100);
      s.stretch = false; s.finish(); assert(s.d.p_error.get<unsigned>() == 0); }
    { Sim s; s.stuck = true; s.tick(10); s.start(); s.finish();
      assert(s.d.p_error.get<unsigned>() == 0x20); }
    { Sim s; s.start(); s.tick(20); s.stretch = true; s.finish();
      assert(s.d.p_error.get<unsigned>() == 0x21);
      assert(!s.d.p_scl__low.get<bool>() && !s.d.p_sda__low.get<bool>()); }
    std::cout << "i2c: write, repeated-start read, ACK/NACK, stretch and timeout passed\n";
}
