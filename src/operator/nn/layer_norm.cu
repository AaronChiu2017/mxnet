/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */

/*!
 * Copyright (c) 2015 by Contributors
 * \file layer_norm.cu
 * \brief Implements Ba et. al, Layer Normalization (https://arxiv.org/abs/1607.06450).
*/
#include "./layer_norm-inl.h"

using namespace mshadow::cuda;

namespace mxnet {
namespace op {

template <typename DType>
__device__ __forceinline__ DType WARP_SHFL(DType value, int src_lane,
                                           int width = 32, unsigned int mask = 0xffffffff) {
#if CUDA_VERSION >= 9000
  return __shfl_sync(mask, value, src_lane, width);
#else
  return __shfl(value, src_lane, width);
#endif
}

template <typename DType>
__device__ __forceinline__ DType WARP_SHFL_XOR(DType value, int laneMask,
                                               int width = 32, unsigned int mask = 0xffffffff) {
#if CUDA_VERSION >= 9000
  return __shfl_xor_sync(mask, value, laneMask, width);
#else
  return __shfl_xor(value, laneMask, width);
#endif
}

template<typename DType>
__device__ __forceinline__ DType rsqrt(DType v) {
  return DType(1) / sqrt(v);
}

template<>
__device__ __forceinline__ float rsqrt(float v) {
  return rsqrtf(v);
}

template<>
__device__ __forceinline__ double rsqrt(double v) {
  return rsqrt(v);
}


/* A single updating step of the Welford's online algorithm to calculate the mean and variance.
 * The value 'curr' will be accumulated to the (mean, sigma2, count) triplet.
 *
 */
template<typename DType>
__device__ __forceinline__ void StepWelfordOnlineSum(const DType curr,
                                                     DType& mean,
                                                     DType& sigma2,
                                                     DType& count) {
  count += DType(1);
  DType delta = curr - mean;
  mean += delta / count;
  sigma2 += delta * (curr - mean);
}

/* Merge the mean/variance of two partitions. It's the key step of the Chan's parallel algorithm.
 * The (lhs_mean, lhs_sigma2, lhs_count) will be merged into (rhs_mean, rhs_sigma2, rhs_count)
 *
 * See https://en.wikipedia.org/wiki/Algorithms_for_calculating_variance for more details.
 *
 *  TODO(sxjscience) Explore the possibility of int lhs_count and rhs_count
 */
template<typename DType>
__device__ __inline__ void ChanMergePartition(const DType lhs_mean,
                                                const DType lhs_sigma2,
                                                const DType lhs_count,
                                                DType& rhs_mean,
                                                DType& rhs_sigma2,
                                                DType& rhs_count) {
  DType delta = rhs_mean - lhs_mean;
  DType nA = lhs_count;
  DType nB = rhs_count;
  rhs_count = nA + nB;
  if (rhs_count > DType(0)) {
    nA = nA / rhs_count;
    nB = nB / rhs_count;
    rhs_mean = nA * lhs_mean + nB * rhs_mean;
    rhs_sigma2 = rhs_sigma2 + lhs_sigma2 + delta * delta * nA * nB * rhs_count;
  } else {
    rhs_mean = DType(0);
    rhs_sigma2 = DType(0);
  }
}


template<typename AType, typename DType, typename IType>
__device__ __forceinline__ void BlockWelfordOnlineSum(const int tid,
                                                      const int nthread,
                                                      const DType* __restrict__ col_vals,
                                                      const int nchannel,
                                                      AType& mean,
                                                      AType& sigma2,
                                                      IType& count) {
  // Each thread takes charge of 4 consecutive numbers. This should optimize the loading speed using
  // vectorized types like float4.
  // Also, to minimize branch divergence, we split the for-loop into two parts.
  int l = 4 * tid;
  for (; l + 3 < nchannel; l += 4 * nthread) {
#pragma unroll
    for (int i = 0; i < 4; ++i) {
      StepWelfordOnlineSum(col_vals[l + i], mean, sigma2, count);
    }
  }
  for(; l < nchannel; ++l) {
    StepWelfordOnlineSum(col_vals[l], mean, sigma2, count);
  }
}

/* Fused CUDA kernel for the forward pass of layer normalization.
 * It computes the LayerNorm when axis=-1, i.e., contiguous reduction scenario.
 * Shape of the input tensors:
 *      in_data = (nbatch, nchannel)
 *      gamma = (nchannel,)
 *      beta = (nchannel,)
 *      out_data = (nchannel,)
 *      mean_data = (nbatch,)
 *      var_data = (nbatch,)
 *  It's always launched with (blockDim.x, blockDim.y) = (WARP_SIZE, blockDim.y)
 *  Also, when blockDim.y > 1, it requires shared memory that has size:
 *      sizeof(DType) * blockDim.y + sizeof(DType) * blockDim.y / 2
 */
template<typename DType>
__global__ void LayerNormFusedForwardKernelContig(const int nbatch,
                                                  const int nchannel,
                                                  const DType eps,
                                                  const DType* __restrict__ in_data,
                                                  const DType* __restrict__ gamma,
                                                  const DType* __restrict__ beta,
                                                  DType* __restrict__ out_data,
                                                  DType* __restrict__ mean_data,
                                                  DType* __restrict__ std_data) {
  int bid = blockIdx.x + blockIdx.y * gridDim.x;
  const int nthread = blockDim.x * blockDim.y;
  DType count = 0;
  DType mean = 0;
  DType sigma2 = 0;

  if (bid < nbatch) {
    extern __shared__ char buf[];  // Shared memory
    int tid = threadIdx.x + threadIdx.y * blockDim.x;
    const DType* col_vals = in_data + bid * nchannel;
    BlockWelfordOnlineSum(tid, nthread, col_vals, nchannel, mean, sigma2, count);

    // Merge the mean/sigma2 within a warp
    // Use the Chan's Parallel Algorithm to merge all (mean, sigma2, counts)
    // within a warp of threads.
    // After calling the function, threadIdx.x == 0 will store the result of
    // the aggregated (mean, sigma2, counts).
#pragma unroll
    for (int l = 0; l <= 4; ++l) {
      int src_lane = (threadIdx.x + (1<<l)) & 31;
      DType meanB = WARP_SHFL(mean, src_lane);
      DType sigma2B = WARP_SHFL(sigma2, src_lane);
      DType countB = WARP_SHFL(count, src_lane);
      ChanMergePartition(meanB, sigma2B, countB, mean, sigma2, count);
    }
    if (blockDim.y == 1) {
      mean = WARP_SHFL(mean, 0);
      sigma2 = WARP_SHFL(sigma2 / nchannel, 0); // Calculate the variance
    } else {
      // Inter-warp reduction. Copy the upper-half of the warps to shared memory
      // and merge with the lower-half warp
      DType* mean_buf = reinterpret_cast<DType*>(buf);
      DType* sigma2_buf = reinterpret_cast<DType*>(buf + sizeof(DType) * blockDim.y / 2);
      DType* count_buf = reinterpret_cast<DType*>(buf + sizeof(DType) * blockDim.y);
      for (int offset = blockDim.y / 2; offset > 0; offset /= 2) {
        if (threadIdx.x == 0 && threadIdx.y >= offset && threadIdx.y < 2 * offset) {
          const int idx = threadIdx.y - offset;
          mean_buf[idx] = mean;
          sigma2_buf[idx] = sigma2;
          count_buf[idx] = count;
        }
        __syncthreads();
        if (threadIdx.x == 0 && threadIdx.y < offset) {
          ChanMergePartition(mean_buf[threadIdx.y],
                             sigma2_buf[threadIdx.y],
                             count_buf[threadIdx.y], mean, sigma2, count);
        }
        __syncthreads();
      }
      // Broadcast the result to all threads
      if (threadIdx.x == 0 && threadIdx.y == 0) {
        mean_buf[0] = mean;
        sigma2_buf[0] = sigma2;
      }
      __syncthreads();
      mean = mean_buf[0];
      sigma2 = sigma2_buf[0] / nchannel;
    }
    // Calculate the out_data: gamma * (x - mean) / sqrt(var + eps) + beta
    DType std_eps = sqrt(sigma2 + eps);
    DType invstd_eps = DType(1.0) / std_eps;
    DType* out_col_val = out_data + bid * nchannel;

    if (gamma != NULL && beta != NULL) {
      for (int i = tid; i < nchannel; i += nthread) {
        out_col_val[i] = gamma[i] * invstd_eps * (col_vals[i] - mean) + beta[i];
      }
    } else if (gamma == NULL && beta != NULL) {
      for (int i = tid; i < nchannel; i += nthread) {
        out_col_val[i] = invstd_eps * (col_vals[i] - mean) + beta[i];
      }
    } else if (gamma != NULL && beta == NULL) {
      for (int i = tid; i < nchannel; i += nthread) {
        out_col_val[i] = gamma[i] * invstd_eps * (col_vals[i] - mean);
      }
    } else {
      for (int i = tid; i < nchannel; i += nthread) {
        out_col_val[i] = invstd_eps * (col_vals[i] - mean);
      }
    }
    // Write the out_data and var_data
    if(threadIdx.x == 0 && threadIdx.y == 0) {
      mean_data[bid] = mean;
      std_data[bid] = std_eps;
    }
  }
}

void LayerNormGPUContig(const LayerNormParam param,
                        const OpContext& ctx, const std::vector<TBlob>& inputs,
                        const std::vector<OpReqType>& req,
                        const std::vector<TBlob>& outputs) {
  using namespace mshadow;
  CHECK_EQ(inputs.size(), 3U);
  mxnet::TShape data_shape(2);
  mxnet::TShape mean_shape(1);
  size_t in_ndim = inputs[layernorm::kData].ndim();
  data_shape[0] = mean_shape[0] = inputs[layernorm::kData].shape_.ProdShape(0, in_ndim - 1);
  data_shape[1] = inputs[layernorm::kData].shape_[in_ndim - 1];
  const TBlob in_data = inputs[layernorm::kData].reshape(data_shape);
  const TBlob gamma = inputs[layernorm::kGamma];
  const TBlob beta = inputs[layernorm::kBeta];
  const TBlob out_data = outputs[layernorm::kOut].reshape(data_shape);
  const TBlob mean_data = outputs[layernorm::kMean].reshape(mean_shape);
  const TBlob std_data = outputs[layernorm::kStd].reshape(mean_shape);
  // Make sure the inputs are contiguous
  CHECK_EQ(in_data.CheckContiguous(), true);
  CHECK_EQ(gamma.CheckContiguous(), true);
  CHECK_EQ(beta.CheckContiguous(), true);
  CHECK_EQ(out_data.CheckContiguous(), true);
  CHECK_EQ(mean_data.CheckContiguous(), true);
  CHECK_EQ(std_data.CheckContiguous(), true);

  // Lauch the kernel. The dynamic shared memory size is
  // sizeof(DType) * blockDim.y + sizeof(DType) * blockDim.y / 2
  int nbatch = data_shape[0];
  int nchannel = data_shape[1];
  float eps = param.eps;
  int ngrid_x = (nbatch > kMaxGridDim) ? (nbatch + kBaseGridNum - 1) / kBaseGridNum : nbatch;
  int ngrid_y = (nbatch > kMaxGridDim) ? kBaseGridNum : 1;
  int nthread_y = 0;
  const dim3 dimGrid(ngrid_x, ngrid_y);
  if(nchannel <= 32) {
    nthread_y = 1;
  } else {
    nthread_y = 2;
  }
  cudaStream_t stream = Stream<gpu>::GetStream(ctx.get_stream<gpu>());
  const dim3 dimBlock(32, nthread_y);
  MSHADOW_REAL_TYPE_SWITCH(in_data.type_flag_, DType, {
    int nshared = nthread_y > 1 ? nthread_y * sizeof(DType) + (nthread_y / 2) * sizeof(DType) : 0;
    CheckLaunchParam(dimGrid, dimBlock);
    LayerNormFusedForwardKernelContig<<<dimGrid, dimBlock, nshared, stream>>>
     (nbatch, nchannel, static_cast<DType>(eps),
      in_data.dptr<DType>(), gamma.dptr<DType>(), beta.dptr<DType>(),
      out_data.dptr<DType>(), mean_data.dptr<DType>(), std_data.dptr<DType>());
  });
  MSHADOW_CUDA_POST_KERNEL_CHECK(LayerNormFusedForwardKernelContig);
}

template<>
void LayerNormCompute<gpu>(const nnvm::NodeAttrs& attrs,
                           const OpContext& ctx, const std::vector<TBlob>& inputs,
                           const std::vector<OpReqType>& req,
                           const std::vector<TBlob>& outputs) {
  const LayerNormParam& param = nnvm::get<LayerNormParam>(attrs.parsed);
  if (req[0] == kNullOp) return;
  CHECK_NE(req[0], kAddTo);
  int axis = param.axis;
  if (axis < 0) {
    axis += static_cast<int>(inputs[0].ndim());
  }
  CHECK(axis >= 0 && axis < inputs[0].ndim()) << "Channel axis out of range: " << param.axis;
  if(axis == inputs[0].ndim() - 1) {
    // Try to use the accelerated CUDA kernels
    return LayerNormGPUContig(param, ctx, inputs, req, outputs);
  }
  return LayerNormComputeGeneral<gpu>(attrs, ctx, inputs, req, outputs);
}


/* Fused CUDA kernel for calculating the gradient w.r.t gamma/beta in LayerNorm
 * It calculates the result for
 *
 */
template<typename DType>
__global__ void LayerNormFusedBackwardKernel_PartGammaBeta(const int nbatch,
                                                           const int nchannel,
                                                           const int row_repeat,
                                                           const DType* __restrict__ in_data,
                                                           const DType* __restrict__ out_grad,
                                                           const DType* __restrict__ mean_data,
                                                           const DType* __restrict__ std_data,
                                                           DType* part_gamma_grad,
                                                           DType* part_beta_grad) {
  extern __shared__ char buf[];
  DType* d_buf = reinterpret_cast<DType*>(buf);
  const int npart = gridDim.y;
  const int block_row_num = (nbatch + npart - 1) / npart;
  const int nthread = blockDim.x * blockDim.y;
  const int tid = threadIdx.y * blockDim.x + threadIdx.x;
  // The rows are divided into `npart` parts. Each threadblock calculates the reduction result
  // within the corresponding row ranges.
  const int c = blockIdx.x * blockDim.x + threadIdx.x;
  int r_begin = blockIdx.y * block_row_num;
  int r_end = min((blockIdx.y + 1) * block_row_num, nbatch);
  DType* buf_mean_data = d_buf;
  DType* buf_std_data = d_buf + blockDim.y * row_repeat;
  DType* buf_gamma_grad = d_buf + 2 * blockDim.y * row_repeat;
  DType* buf_beta_grad = d_buf + 2 * blockDim.y * row_repeat + blockDim.y * blockDim.x;
  // Initialize the buf_gamma_grad/buf_beta_grad to be all zero
  buf_gamma_grad[tid] = 0;
  buf_beta_grad[tid] = 0;
  for(int r_b = r_begin; r_b < r_end; r_b += blockDim.y * row_repeat) {
    int inner_r_end = min(blockDim.y * row_repeat, r_end - r_b);
    for(int i=tid; i < inner_r_end; i += nthread) {
      buf_mean_data[i] = mean_data[r_b + i];
      buf_std_data[i] = std_data[r_b + i];
    }
    __syncthreads();
    if(c < nchannel) {
      for(int i = 0; i < row_repeat; ++i) {
        int r_offset = i * blockDim.y + blockIdx.y;
        int r = r_b + r_offset;
        if(r < r_end) {
          int read_idx = r * nchannel + c;
          int write_idx = r_offset * blockDim.x + threadIdx.x;
          buf_gamma_grad[write_idx] +=
            (in_data[read_idx] - buf_mean_data[r_offset]) / buf_std_data[r_offset]
            * out_grad[read_idx];
          buf_beta_grad[write_idx] += out_grad[read_idx];
        }
      }
    }
    __syncthreads();
  }
  for(int offset = blockDim.y/2;  offset > 1;  offset /= 2) {
    if(threadIdx.y < offset) {
      int idx1 = threadIdx.y * blockDim.x + threadIdx.x;
      int idx2 = (threadIdx.y + offset) * blockDim.x + threadIdx.x;
      buf_gamma_grad[idx1] += buf_gamma_grad[idx2];
      buf_beta_grad[idx1] += buf_beta_grad[idx2];
    }
    __syncthreads();
  }
  if(threadIdx.y == 0 && c < nchannel) {
    part_gamma_grad[blockIdx.y * nchannel + c] = buf_gamma_grad[threadIdx.x];
    part_beta_grad[blockIdx.y * nchannel + c] = buf_beta_grad[threadIdx.x];
  }
}

template<bool gamma_addto, bool beta_addto, typename DType>
__global__ void LayerNormFusedBackwardKernel_GammaBeta(const int nbatch,
                                                       const int nchannel,
                                                       const int npart,
                                                       const DType* __restrict__ part_gamma_grad,
                                                       const DType* __restrict__ part_beta_grad,
                                                       DType* gamma_grad,
                                                       DType* beta_grad) {
  const int c = blockIdx.x * blockDim.x + threadIdx.x;
  const int tid = threadIdx.y * blockDim.x + threadIdx.x;
  if(c < nchannel) {
    extern __shared__ char buf[];
    DType* buf_gamma_grad = reinterpret_cast<DType*>(buf);
    DType* buf_beta_grad = reinterpret_cast<DType*>(buf) + blockDim.x * blockDim.y;
    buf_gamma_grad[tid] = 0;
    buf_beta_grad[tid] = 0;
    for(int r = threadIdx.y; r < npart; r += blockDim.y) {
      buf_gamma_grad[tid] += part_gamma_grad[r * nchannel + c];
      buf_beta_grad[tid] += part_beta_grad[r * nchannel + c];
    }
    __syncthreads();
    // Begin for inter-warp reduce
    if(npart > 1) {
      for(int offset = blockDim.y/2; offset > 1; offset /= 2) {
        if(threadIdx.y < offset) {
          int idx1 = tid;
          int idx2 = tid + offset * blockDim.x;
          buf_gamma_grad[idx1] += buf_gamma_grad[idx2];
          buf_beta_grad[idx1] += buf_beta_grad[idx2];
        }
        __syncthreads();
      }
    }
    if(threadIdx.y == 0) {
      if(gamma_grad) {
        if(gamma_addto) {
          gamma_grad[c] += buf_gamma_grad[threadIdx.x];
        } else {
          gamma_grad[c] = buf_gamma_grad[threadIdx.x];
        }
      }
      if(beta_grad) {
        if(beta_addto) {
          beta_grad[c] += buf_beta_grad[threadIdx.x];
        } else {
          beta_grad[c] = buf_beta_grad[threadIdx.x];
        }
      }
    }
  }

}

/*
 *
 */
template<int LOAD_UNROLL, bool gamma_addto, bool beta_addto, typename DType>
__global__ void LayerNormFusedBackwardKernel_GammaBetaOld(const int nbatch,
                                                          const int nchannel,
                                                          const DType* __restrict__ in_data,
                                                          const DType* __restrict__ out_grad,
                                                          const DType* __restrict__ mean_data,
                                                          const DType* __restrict__ std_data,
                                                          DType* gamma_grad,
                                                          DType* beta_grad) {
  const int nthread = blockDim.x * blockDim.y;
  const int tid = threadIdx.x + threadIdx.y * blockDim.x;
  DType local_gamma_grad[LOAD_UNROLL];
  DType local_beta_grad[LOAD_UNROLL];
  const bool need_gamma_grad = (gamma_grad != nullptr);
  const bool need_beta_grad = (beta_grad != nullptr);
  int l = LOAD_UNROLL * tid;
  // We try to load the data using vectorized types like float4
  for(; l + LOAD_UNROLL - 1 < nchannel; l += LOAD_UNROLL * nthread) {
    // Initialize the shared memory
#pragma unroll
    for(int i = 0; i < LOAD_UNROLL; i++) {
      if(need_gamma_grad) {
        local_gamma_grad[i] = 0;
      }
      if(need_beta_grad) {
        local_beta_grad[i] = 0;
      }
    }
    // Summation
    for(int b = 0; b < nbatch; ++b) {
      DType local_mean = 0;
      DType local_std = 0;
      if(need_gamma_grad) {
        local_mean = mean_data[b];
        local_std = std_data[b];
      }
#pragma unroll
      for(int i = 0; i < LOAD_UNROLL; ++i) {
        DType ele_og = out_grad[b * nchannel + l + i];
        DType ele_x = in_data[b * nchannel + l + i];
        if(need_gamma_grad) {
          local_gamma_grad[i] += (ele_x - local_mean) / local_std * ele_og;
        }
        if(need_beta_grad) {
          local_beta_grad[i] += ele_og;
        }
      }
    }
    // Write to destination
    for(int i = 0; i < LOAD_UNROLL; ++i) {
      if(need_gamma_grad) {
        if(gamma_addto) {
          gamma_grad[l + i] += local_gamma_grad[i];
        } else {
          gamma_grad[l + i] = local_gamma_grad[i];
        }
      }
      if(need_beta_grad) {
        if(beta_addto) {
          beta_grad[l + i] += local_beta_grad[i];
        } else {
          beta_grad[l + i] = local_beta_grad[i];
        }
      }
    }
  }
  // Handle the rest elements that cannot be divided by LOAD_UNROLL
  for(; l < nchannel; ++l) {
    local_gamma_grad[0] = 0;
    local_beta_grad[0] = 0;
    for(int b = 0; b < nbatch; ++b) {
      DType ele_og = out_grad[b * nchannel + l];
      DType ele_x = in_data[b * nchannel + l];
      DType local_mean = 0;
      DType local_std = 0;
      if(need_gamma_grad) {
        local_mean = mean_data[b];
        local_std = std_data[b];
      }
      if(need_gamma_grad) {
        local_gamma_grad[0] += (ele_x - local_mean) / local_std * ele_og;
      }
      if(need_beta_grad) {
        local_beta_grad[0] += ele_og;
      }
    }
    if(need_gamma_grad) {
      if(gamma_addto) {
        gamma_grad[l] += local_gamma_grad[0];
      } else {
        gamma_grad[l] = local_gamma_grad[0];
      }
    }
    if(need_beta_grad) {
      if(beta_addto) {
        beta_grad[l] += local_beta_grad[0];
      } else {
        beta_grad[l] = local_beta_grad[0];
      }
    }
  }
}

/*
 *
 *
 */
template<int LOAD_UNROLL, bool data_addto, typename DType>
__global__ void LayerNormFusedBackwardKernel_Data(const int nbatch,
                                                  const int nchannel,
                                                  const DType* __restrict__ in_data,
                                                  const DType* __restrict__ out_grad,
                                                  const DType* __restrict__ mean_data,
                                                  const DType* __restrict__ std_data,
                                                  const DType* __restrict__ gamma,
                                                  DType* data_grad) {
  int bid = blockIdx.x + blockIdx.y * gridDim.x;
  const int nthread = blockDim.x * blockDim.y;
  if(bid < nbatch) {
    extern __shared__ char buf[];  // Shared memory with size blockDim.y * blockDim.x * sizeof(DType)
    int tid = threadIdx.x + threadIdx.y * blockDim.x;
    // 1. Calculate: mean(out_grad * gamma / std, axis=-1)
    //               mean(out_grad * gamma / std * (x - mean) / std, axis=-1)
    DType sum_val0 = 0;  // Stores mean(out_grad * gamma / std, axis=-1)
    DType sum_val1 = 0;  // Stores mean(out_grad * gamma / std * (x - mean) / std, axis=-1)
    DType mean = mean_data[bid];
    DType invstd_eps = DType(1) / std_data[bid];
    int l = LOAD_UNROLL * tid;
    for(; l + LOAD_UNROLL - 1 < nchannel; l += nthread * LOAD_UNROLL) {
#pragma unroll
      for(int i = 0; i < LOAD_UNROLL; ++i) {
        DType ele_og = out_grad[bid * nchannel + l + i];
        DType ele_x = in_data[bid * nchannel + l + i];
        DType ele_gamma = gamma[l + i];
        sum_val0 += ele_og * ele_gamma * invstd_eps;
        sum_val1 += ele_og * ele_gamma * (ele_x - mean) * invstd_eps * invstd_eps;
      }
    }
    for(; l < nchannel; ++l) {
      DType ele_og = out_grad[bid * nchannel + l];
      DType ele_x = in_data[bid * nchannel + l];
      DType ele_gamma = gamma[l];
      sum_val0 += ele_og * ele_gamma * invstd_eps;
      sum_val1 += ele_og * ele_gamma * (ele_x - mean) * invstd_eps * invstd_eps;
    }
    // Intra-warp reduction (all-reduce)
    for(int mask = blockDim.x / 2; mask > 0; mask /= 2) {
      sum_val0 += WARP_SHFL_XOR(sum_val0, mask);
      sum_val1 += WARP_SHFL_XOR(sum_val1, mask);
    }
    // Inter-warp reduction (all-reduce)
    if(blockDim.y > 1) {
      DType* sum_val0_buf = reinterpret_cast<DType*>(buf);
      DType* sum_val1_buf =
        reinterpret_cast<DType*>(buf + blockDim.y / 2 * blockDim.x * sizeof(DType));
      for (int offset = blockDim.y / 2; offset > 0; offset /= 2) {
        if (threadIdx.y >= offset && threadIdx.y < 2 * offset) {
          const int idx = (threadIdx.y - offset) * blockDim.x + threadIdx.x;
          sum_val0_buf[idx] = sum_val0;
          sum_val1_buf[idx] = sum_val1;
        }
        __syncthreads();
        if (threadIdx.y < offset) {
          const int idx = threadIdx.y * blockDim.x + threadIdx.x;
          sum_val0 += sum_val0_buf[idx];
          sum_val1 += sum_val1_buf[idx];
        }
        __syncthreads();
      }
      if(threadIdx.y == 0) {
        sum_val0_buf[threadIdx.x] = sum_val0;
        sum_val1_buf[threadIdx.x] = sum_val1;
      }
      __syncthreads();
      if(threadIdx.y != 0) {
        sum_val0 = sum_val0_buf[threadIdx.x];
        sum_val1 = sum_val1_buf[threadIdx.x];
      }
    }
    sum_val0 /= nchannel;
    sum_val1 /= nchannel;
    // 2. Calculate the gradient as
    //      out_grad * gamma / std - sum_val0 - (x - mean) / std * sum_val1
    for(int l = tid; l < nchannel; l += nthread) {
      DType ele_out_grad = out_grad[bid * nchannel + l];
      DType ele_x = in_data[bid * nchannel + l];
      if(data_addto) {
        data_grad[bid * nchannel + l] +=
          ele_out_grad * gamma[l] * invstd_eps - sum_val0
                                               - (ele_x - mean) * invstd_eps * sum_val1;
      } else {
        data_grad[bid * nchannel + l] =
          ele_out_grad * gamma[l] * invstd_eps - sum_val0
                                               - (ele_x - mean) * invstd_eps * sum_val1;
      }
    }
  }
}

void GetGammaBetaGradKernelParams(const int nbatch, const int nchannel,
                                  dim3* part_grad_block_dim, dim3* part_grad_grid_dim,
                                  dim3* gb_block_dim, dim3* gb_grid_dim,
                                  int* row_repeat, int* npart) {
  *npart = 16;
  *part_grad_block_dim = dim3(32, 16);
  *part_grad_grid_dim = dim3((nchannel + 32 - 1) / 32, *npart);
  *row_repeat = 16;
  *gb_block_dim = dim3(32, *npart);
  *gb_grid_dim = dim3((nchannel + 32 - 1) / 32);
  CheckLaunchParam(*part_grad_grid_dim, *part_grad_block_dim);
  CheckLaunchParam(*gb_grid_dim, *gb_block_dim);
}

void LayerNormGradGPUContig(const LayerNormParam param,
                            const OpContext& ctx, const std::vector<TBlob>& inputs,
                            const std::vector<OpReqType>& req,
                            const std::vector<TBlob>& outputs) {
  using namespace mshadow;
  CHECK_EQ(inputs.size(), 5U);
  const TBlob out_grad = inputs[0];
  const TBlob in_data = inputs[1];
  const TBlob gamma = inputs[2];
  const TBlob mean_data = inputs[3];
  const TBlob std_data = inputs[4];
  const TBlob data_grad = outputs[0];
  const TBlob gamma_grad = outputs[1];
  const TBlob beta_grad = outputs[2];

  // Make sure the inputs are contiguous
  CHECK_EQ(out_grad.CheckContiguous(), true);
  CHECK_EQ(in_data.CheckContiguous(), true);
  CHECK_EQ(gamma.CheckContiguous(), true);
  CHECK_EQ(mean_data.CheckContiguous(), true);
  CHECK_EQ(std_data.CheckContiguous(), true);
  int nbatch = in_data.shape_.ProdShape(0, in_data.ndim() - 1);
  int nchannel = in_data.shape_[in_data.ndim() - 1];
  int data_grad_req = req[0];
  int gamma_grad_req = req[1];
  int beta_grad_req = req[2];
  CHECK_NE(data_grad_req, kWriteInplace);
  CHECK_NE(gamma_grad_req, kWriteInplace);
  CHECK_NE(beta_grad_req, kWriteInplace);
  Stream<gpu> *s = ctx.get_stream<gpu>();
  cudaStream_t stream = Stream<gpu>::GetStream(s);

  // Calculate the gradient for gamma/beta
  CHECK_EQ(gamma_grad.CheckContiguous(), true);
  CHECK_EQ(beta_grad.CheckContiguous(), true);
  dim3 part_grad_block_dim, part_grad_grid_dim, gb_block_dim, gb_grid_dim;
  int row_repeat, npart;
  GetGammaBetaGradKernelParams(nbatch, nchannel, &part_grad_block_dim, &part_grad_grid_dim,
                               &gb_block_dim, &gb_grid_dim, &row_repeat, &npart);
  if(gamma_grad_req != kNullOp || beta_grad_req != kNullOp) {
    MSHADOW_REAL_TYPE_SWITCH(in_data.type_flag_, DType, {
      Tensor<gpu, 1, DType> workspace =
        ctx.requested[0].get_space_typed<gpu, 1, DType>(Shape1(2 * npart * nchannel), s);
      DType* part_gamma_grad_ptr = workspace.dptr_;
      DType* part_beta_grad_ptr = workspace.dptr_ + npart * nchannel;
      const int nshared_K1 = (2 * part_grad_block_dim.y * row_repeat
                              + 2 * part_grad_block_dim.x * part_grad_block_dim.y) * sizeof(DType);
      const int nshared_K2 = 2 * gb_block_dim.x * gb_block_dim.y * sizeof(DType);
      DType* gamma_grad_ptr = (gamma_grad_req != kNullOp) ? gamma_grad.dptr<DType>() : nullptr;
      DType* beta_grad_ptr = (beta_grad_req != kNullOp) ? beta_grad.dptr<DType>() : nullptr;
      LayerNormFusedBackwardKernel_PartGammaBeta
        <<<part_grad_grid_dim, part_grad_block_dim, nshared_K1, stream>>>
        (nbatch, nchannel, row_repeat, in_data.dptr<DType>(), out_grad.dptr<DType>(),
         mean_data.dptr<DType>(), std_data.dptr<DType>(), part_gamma_grad_ptr, part_beta_grad_ptr);
      MSHADOW_CUDA_POST_KERNEL_CHECK(LayerNormFusedBackwardKernel_PartGammaBeta);
      if(gamma_grad_req == kAddTo && beta_grad_req != kAddTo) {
        LayerNormFusedBackwardKernel_GammaBeta<true, false>
          <<<gb_grid_dim, gb_block_dim, nshared_K2, stream>>>
          (nbatch, nchannel, npart, part_gamma_grad_ptr, part_beta_grad_ptr,
           gamma_grad_ptr, beta_grad_ptr);
      } else if(gamma_grad_req != kAddTo && beta_grad_req == kAddTo) {
        LayerNormFusedBackwardKernel_GammaBeta<false, true>
          <<<gb_grid_dim, gb_block_dim, nshared_K2, stream>>>
          (nbatch, nchannel, npart, part_gamma_grad_ptr, part_beta_grad_ptr,
            gamma_grad_ptr, beta_grad_ptr);
      } else if(gamma_grad_req == kAddTo && beta_grad_req == kAddTo) {
        LayerNormFusedBackwardKernel_GammaBeta<true, true>
          <<<gb_grid_dim, gb_block_dim, nshared_K2, stream>>>
          (nbatch, nchannel, npart, part_gamma_grad_ptr, part_beta_grad_ptr,
            gamma_grad_ptr, beta_grad_ptr);
      } else {
        LayerNormFusedBackwardKernel_GammaBeta<false, false>
          <<<gb_grid_dim, gb_block_dim, nshared_K2, stream>>>
          (nbatch, nchannel, npart, part_gamma_grad_ptr, part_beta_grad_ptr,
            gamma_grad_ptr, beta_grad_ptr);
      }
    });
    MSHADOW_CUDA_POST_KERNEL_CHECK(LayerNormFusedBackwardKernel_GammaBeta);
  }

  // Calculate the gradient for data
  CHECK_EQ(data_grad.CheckContiguous(), true);
  int ngrid_x = (nbatch > kMaxGridDim) ? (nbatch + kBaseGridNum - 1) / kBaseGridNum : nbatch;
  int ngrid_y = (nbatch > kMaxGridDim) ? kBaseGridNum : 1;
  const dim3 data_grid_dim(ngrid_x, ngrid_y);
  int nthread_y = 0;
  if(nchannel <= 32) {
    nthread_y = 1;
  } else {
    nthread_y = 2;
  }
  const dim3 data_block_dim(32, nthread_y);
  const int LOAD_UNROLL = 4;
  if(data_grad_req != kNullOp) {
    MSHADOW_REAL_TYPE_SWITCH(in_data.type_flag_, DType, {
      int nshared = data_block_dim.y > 1 ? data_block_dim.y * data_block_dim.x * sizeof(DType) : 0;
      CheckLaunchParam(data_grid_dim, data_block_dim);
      if(data_grad_req == kAddTo) {
        LayerNormFusedBackwardKernel_Data<LOAD_UNROLL, true>
          <<<data_grid_dim, data_block_dim, nshared, stream>>>
          (nbatch, nchannel, in_data.dptr<DType>(), out_grad.dptr<DType>(), mean_data.dptr<DType>(),
           std_data.dptr<DType>(), gamma.dptr<DType>(), data_grad.dptr<DType>());
      } else {
        LayerNormFusedBackwardKernel_Data<LOAD_UNROLL, false>
          <<<data_grid_dim, data_block_dim, nshared, stream>>>
          (nbatch, nchannel, in_data.dptr<DType>(), out_grad.dptr<DType>(), mean_data.dptr<DType>(),
           std_data.dptr<DType>(), gamma.dptr<DType>(), data_grad.dptr<DType>());
      }
    });
    MSHADOW_CUDA_POST_KERNEL_CHECK(LayerNormFusedBackwardKernel_Data);
  }
}

template<>
void LayerNormGradCompute<gpu>(const nnvm::NodeAttrs& attrs,
                               const OpContext& ctx, const std::vector<TBlob>& inputs,
                               const std::vector<OpReqType>& req,
                               const std::vector<TBlob>& outputs) {
  const LayerNormParam& param = nnvm::get<LayerNormParam>(attrs.parsed);
  if (req[0] == kNullOp) return;
  CHECK_NE(req[0], kAddTo);
  int axis = param.axis;
  if (axis < 0) {
    axis += static_cast<int>(inputs[0].ndim());
  }
  CHECK(axis >= 0 && axis < inputs[0].ndim()) << "Channel axis out of range: " << param.axis;
  if(axis == inputs[0].ndim() - 1) {
    // Try to use the accelerated CUDA kernels
    return LayerNormGradGPUContig(param, ctx, inputs, req, outputs);
  }
  return LayerNormGradComputeGeneral<gpu>(attrs, ctx, inputs, req, outputs);
}


NNVM_REGISTER_OP(LayerNorm)
.set_attr<FCompute>("FCompute<gpu>", LayerNormCompute<gpu>);

NNVM_REGISTER_OP(_backward_LayerNorm)
.set_attr<FCompute>("FCompute<gpu>", LayerNormGradCompute<gpu>);

}  // namespace op
}  // namespace mxnet
