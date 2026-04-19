#pragma once

#include <nvector/nvector_serial.h>

static inline N_Vector N_VNew_OpenMP(sunindextype vec_length, int num_threads, SUNContext sunctx)
{
    (void)num_threads;
    return N_VNew_Serial(vec_length, sunctx);
}

#ifndef NV_DATA_OMP
#define NV_DATA_OMP(v) NV_DATA_S(v)
#endif
