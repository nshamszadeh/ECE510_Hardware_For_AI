// Naive CUDA GEMM: one thread per output element
// C = A * B, all matrices are N x N FP32, row-major

#include <cstdio>
#include <cstdlib>
#include <cuda_runtime.h>

#define N 1024

// Each thread computes one element C[row][col].
__global__ void gemm_naive(const float* __restrict__ A,
                           const float* __restrict__ B,
                           float*       __restrict__ C,
                           int n)
{
    int col = blockIdx.x * blockDim.x + threadIdx.x;
    int row = blockIdx.y * blockDim.y + threadIdx.y;

    if (row >= n || col >= n) return;

    float acc = 0.0f;
    for (int k = 0; k < n; ++k)
        acc += A[row * n + k] * B[k * n + col];

    C[row * n + col] = acc;
}

// ── helpers ──────────────────────────────────────────────────────────────────

static void fill_random(float* m, int size)
{
    for (int i = 0; i < size; ++i)
        m[i] = (float)rand() / RAND_MAX;
}

#define CUDA_CHECK(call)                                                  \
    do {                                                                  \
        cudaError_t err = (call);                                         \
        if (err != cudaSuccess) {                                         \
            fprintf(stderr, "CUDA error %s:%d: %s\n",                    \
                    __FILE__, __LINE__, cudaGetErrorString(err));         \
            exit(1);                                                      \
        }                                                                 \
    } while (0)

// ── main ─────────────────────────────────────────────────────────────────────

int main()
{
    const int n        = N;
    const size_t bytes = (size_t)n * n * sizeof(float);

    // Host buffers
    float* h_A = (float*)malloc(bytes);
    float* h_B = (float*)malloc(bytes);
    float* h_C = (float*)malloc(bytes);

    srand(42);
    fill_random(h_A, n * n);
    fill_random(h_B, n * n);

    // Device buffers
    float *d_A, *d_B, *d_C;
    CUDA_CHECK(cudaMalloc(&d_A, bytes));
    CUDA_CHECK(cudaMalloc(&d_B, bytes));
    CUDA_CHECK(cudaMalloc(&d_C, bytes));

    CUDA_CHECK(cudaMemcpy(d_A, h_A, bytes, cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_B, h_B, bytes, cudaMemcpyHostToDevice));

    // 16x16 threads per block → 64x64 blocks for 1024x1024
    dim3 block(16, 16);
    dim3 grid((n + block.x - 1) / block.x,
              (n + block.y - 1) / block.y);

    // Warm-up
    gemm_naive<<<grid, block>>>(d_A, d_B, d_C, n);
    CUDA_CHECK(cudaDeviceSynchronize());

    // Timed run
    cudaEvent_t t0, t1;
    CUDA_CHECK(cudaEventCreate(&t0));
    CUDA_CHECK(cudaEventCreate(&t1));

    CUDA_CHECK(cudaEventRecord(t0));
    gemm_naive<<<grid, block>>>(d_A, d_B, d_C, n);
    CUDA_CHECK(cudaEventRecord(t1));
    CUDA_CHECK(cudaEventSynchronize(t1));

    float ms = 0.0f;
    CUDA_CHECK(cudaEventElapsedTime(&ms, t0, t1));

    // 2*N^3 FLOPs for a square GEMM
    double flops     = 2.0 * (double)n * n * n;
    double gflops    = flops / (ms * 1e-3) / 1e9;

    printf("Matrix size : %d x %d (FP32)\n", n, n);
    printf("Kernel time : %.3f ms\n", ms);
    printf("Throughput  : %.2f GFLOP/s\n", gflops);

    CUDA_CHECK(cudaMemcpy(h_C, d_C, bytes, cudaMemcpyDeviceToHost));

    // Spot-check: print one element
    printf("C[0][0]     : %f\n", h_C[0]);

    cudaEventDestroy(t0);
    cudaEventDestroy(t1);
    cudaFree(d_A); cudaFree(d_B); cudaFree(d_C);
    free(h_A); free(h_B); free(h_C);
    return 0;
}
