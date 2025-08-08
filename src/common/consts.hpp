//
//  consts.hpp
//  foo_out_avfoundation
//
//  Created by pnck on 2025/8/8.
//

#pragma once

#include "pfc/pfc-lite.h"

// import random as r
// print(f"GUID g = {{0x{r.randint(0,0xFFFFFFFF):08X}, 0x{r.randint(0,0xFFFF):04X}, 0x{r.randint(0,0xFFFF):04X}, {{{','.join(f'0x{r.randint(0,255):02X}' for _ in range(8))}}}}};")

constexpr inline GUID guid_output_avfoundation = {
    0x1F059311, 0xD0DE, 0x7D80, {0xAD, 0x55, 0x10, 0xC5, 0x7E, 0x8C, 0x29, 0x3F}
};
constexpr inline GUID guid_output_device = {
    0xFCDC89BE, 0x01F0, 0xCDBB, {0x04, 0x53, 0x1A, 0xC5, 0x9D, 0xC6, 0x2E, 0x17}
};
