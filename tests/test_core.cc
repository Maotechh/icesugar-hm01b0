#include "core.cc"
#include <cassert>
#include <iostream>
#include <vector>

unsigned crc16(const std::vector<unsigned>& data) {
    unsigned c = 65535;
    for (auto b : data) {
        c ^= b << 8;
        for (int k = 0; k < 8; ++k) c = ((c << 1) ^ ((c & 0x8000) ? 0x1021 : 0)) & 65535;
    }
    return c;
}
uint32_t crc32(const std::vector<unsigned>& data, size_t len) {
    uint32_t c = ~uint32_t(0);
    for (size_t i = 0; i < len; ++i) {
        c ^= data[i];
        for (int k = 0; k < 8; ++k) c = (c >> 1) ^ ((c & 1) ? 0xedb88320U : 0);
    }
    return ~c;
}
uint32_t le32(const std::vector<unsigned>& v, size_t i) {
    return v.at(i) | (v.at(i+1) << 8) | (v.at(i+2) << 16) | (v.at(i+3) << 24);
}
struct Sim {
    cxxrtl_design::p_camera__core d;
    std::vector<unsigned> received;
    int rx_wait = 0, rx_bit = 0;
    unsigned rx_byte = 0;
    bool prev_tx = true, decoding = false;
    void tick(int n = 1) {
        while (n--) {
            d.p_scl__in.set(!d.p_scl__low.get<bool>());
            d.p_sda__in.set(!d.p_sda__low.get<bool>());
            d.p_clk.set(false); d.step(); d.p_clk.set(true); d.step();
            bool tx = d.p_uart__tx.get<bool>();
            if (!decoding && prev_tx && !tx) {
                decoding = true; rx_wait = 24; rx_bit = 0; rx_byte = 0;
            } else if (decoding && --rx_wait == 0) {
                if (rx_bit == 8) {
                    assert(tx); received.push_back(rx_byte); decoding = false;
                } else { rx_byte |= unsigned(tx) << rx_bit++; rx_wait = 16; }
            }
            prev_tx = tx;
        }
    }
    Sim() { d.p_uart__rx.set(true); d.p_reset.set(true); tick(16); d.p_reset.set(false); tick(16); }
    void byte(unsigned b) {
        d.p_uart__rx.set(false); tick(16);
        for (int i = 0; i < 8; ++i) { d.p_uart__rx.set((b >> i) & 1); tick(16); }
        d.p_uart__rx.set(true); tick(16);
    }
    void request(unsigned op, unsigned value = 0, bool corrupt = false) {
        received.clear();
        std::vector<unsigned> v{0x48,0x43,op,0x57,0x01,0x00,value};
        auto c = crc16(v) ^ unsigned(corrupt); v.push_back(c >> 8); v.push_back(c & 255);
        for (auto b : v) byte(b);
    }
    std::vector<unsigned> response(unsigned op, unsigned status = 0) {
        for (int i = 0; i < 30000000; ++i) {
            if (received.size() >= 9 && received.size() == le32(received,5) + 13) break;
            tick();
        }
        assert(received.size() >= 13);
        assert(received[0] == 0x48 && received[1] == 0x43);
        assert(received[2] == op && received[3] == 0x57 && received[4] == status);
        assert(received.size() == le32(received,5) + 13);
        assert(crc32(received,received.size()-4) == le32(received,received.size()-4));
        tick(32);
        return {received.begin()+9, received.end()-4};
    }
};

int main() {
    Sim s;
    s.request(0); auto status = s.response(0);
    assert(status.size() == 16 && status[0] == 1 && status[1] == 0);
    assert(le32(status,12) == 48000000);
    s.request(2); s.response(2,0x30);
    s.request(0,0,true); s.tick(6000); assert(s.received.empty());
    s.byte(0x48); s.byte(0x48); s.byte(0x77); s.request(0); status = s.response(0);
    assert(status[4] == 1 && status[5] == 0);
    s.byte(0x48); s.byte(0x43); s.tick(4800100);
    s.request(0); status = s.response(0);
    assert(status[6] == 1 && status[7] == 0);
    s.request(3,1); assert(s.response(3)[0] == 1 && s.d.p_enabled.get<bool>());
    s.request(2); s.response(2,0x10);
    s.request(4);
    s.request(0); // Deliberate command while capture is busy: no second response.
    auto timeout = s.response(4);
    assert(timeout.size() == 16 && (timeout[10] & 128));
    s.request(0); status = s.response(0);
    assert(status[8] == 1 && status[9] == 0);
    s.request(4);
    s.tick(32);
    s.d.p_cam__vsync.set(true); s.tick(12);
    for (unsigned y = 0; y < 244; ++y) {
        s.d.p_cam__href.set(true); s.tick(8);
        for (unsigned x = 0; x < 324; ++x) {
            unsigned pixel = ((y * 324 + x) * 73 + y) & 255;
            for (unsigned k = 0; k < 2; ++k) {
                s.d.p_cam__pclk.set(false); s.d.p_cam__d.set((pixel >> (k * 4)) & 15); s.tick(4);
                s.d.p_cam__pclk.set(true); s.tick(4);
            }
        }
        s.d.p_cam__pclk.set(false); s.tick(8);
        s.d.p_cam__href.set(false); s.tick(12);
    }
    s.d.p_cam__vsync.set(false); s.tick(12);
    auto frame = s.response(4);
    assert(frame.size() == 16 + 324 * 244 && le32(frame,0) == 324 * 244);
    assert(frame[4] == 244 && frame[5] == 0 && frame[10] == 0);
    for (unsigned i = 0; i < 324 * 244; ++i)
        assert(frame[16 + i] == ((i * 73 + i / 324) & 255));
    s.request(0x7f); s.response(0x7f,0x31);
    s.request(3,0); s.response(3); assert(!s.d.p_enabled.get<bool>());
    std::cout << "core: UART, CRC16/32, commands, timeout and full 324x244 frame byte comparison passed\n";
}
