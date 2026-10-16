// Copyright (c) the JPEG XL Project Authors. All rights reserved.
//
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#ifndef JXL_SIMPLE_LOSSLESS_
#define JXL_SIMPLE_LOSSLESS_

#include <assert.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <thread>
#include <vector>

#include "color_encoding.h"

// Simplified version of the streaming input source from jxl/encode.h
// We only need this part to wrap the full image buffer in the standalone mode
// and this way we don't need to depend on the jxl headers.
struct JxlChunkedFrameInputSource {
  void *opaque;
  const void *(*get_color_channel_data_at)(void *opaque, size_t xpos,
                                           size_t ypos, size_t xsize,
                                           size_t ysize, size_t *row_offset);
  void (*release_buffer)(void *opaque, const void *buf);
};
// A FJxlParallelRunner must call fun(opaque, i) for all i from 0 to count. It
// may do so in parallel.
typedef void(FJxlParallelRunner)(void *runner_opaque, void *opaque,
                                 void fun(void *, size_t), size_t count);
struct JxlSimpleLosslessFrameState;

// Returned JxlSimpleLosslessFrameState must be freed by calling
// JxlSimpleLosslessFreeFrameState.
JxlSimpleLosslessFrameState *
JxlSimpleLosslessPrepareFrame(JxlChunkedFrameInputSource input, size_t width,
                              size_t height, size_t nb_chans, size_t bitdepth,
                              bool big_endian, int effort, int oneshot,
                              JxlColorEncoding color_encoding);

bool JxlSimpleLosslessProcessFrame(JxlSimpleLosslessFrameState *frame_state,
                                   bool is_last, void *runner_opaque,
                                   FJxlParallelRunner runner);

// Prepare the (image/frame) header. You may encode animations by concatenating
// the output of multiple frames, of which the first one has add_image_header =
// 1 and subsequent ones have add_image_header = 0, and all frames but the last
// one have is_last = 0.
// (when FJXL_STANDALONE=0, add_image_header has to be 0)
void JxlSimpleLosslessPrepareHeader(JxlSimpleLosslessFrameState *frame,
                                    int add_image_header, int is_last);

// Upper bound on the required output size, including any padding that may be
// required by JxlSimpleLosslessWriteOutput. Cannot be called before
// JxlSimpleLosslessPrepareHeader.
size_t
JxlSimpleLosslessMaxRequiredOutput(const JxlSimpleLosslessFrameState *frame);

// Actual size of the frame once it is encoded. This is not identical to
// JxlSimpleLosslessMaxRequiredOutput because JxlSimpleLosslessWriteOutput may
// require extra padding.
size_t JxlSimpleLosslessOutputSize(const JxlSimpleLosslessFrameState *frame);

// Writes the frame to the given output buffer. Returns the number of bytes that
// were written, which is at least 1 unless the entire output has been written
// already. It is required that `output_size >= 32` when calling this function.
// This function must be called repeatedly until it returns 0.
size_t JxlSimpleLosslessWriteOutput(JxlSimpleLosslessFrameState *frame,
                                    unsigned char *output, size_t output_size);

// Frees the provided frame state.
void JxlSimpleLosslessFreeFrameState(JxlSimpleLosslessFrameState *frame);

size_t JxlSimpleLosslessEncode(const unsigned char *rgba, size_t width,
                               size_t row_stride, size_t height,
                               size_t nb_chans, size_t bitdepth,
                               bool big_endian, int effort,
                               unsigned char **output, void *runner_opaque,
                               FJxlParallelRunner runner,
                               JxlColorEncoding color_encoding);

#endif /*JXL_SIMPLE_LOSSLESS_*/
