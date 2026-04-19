// Tiled CUDA GEMM using shared memory
// Tile size: 8x8
// C = A * B, all matrices are N x N FP32, row-major

#include <cstdio>
#include <cstdlib>
#include <cuda_runtime.h>

#define N    1024
#define TILE 8

// Each thread block loads an 8x8 tile of A and an 8x8 tile of B into shared
// memory, synchronises, computes the partial dot products, then advances to
// the next tile along the k dimension.  Global memory traffic is reduced by
// a factor of TILE compared to the naive kernel.
__global__ void gemm_tiled(const float* __restrict__ A,
                           const float* __restrict__ B,
                           float*       __restrict__ C,
                           int n)
{
    __shared__ float sA[TILE][TILE];
    __shared__ float sB[TILE][TILE];

    int row = blockIdx.y * TILE + threadIdx.y;   // global row of C / A
    int col = blockIdx.x * TILE + threadIdx.x;   // global col of C / B

    float acc = 0.0f;

    // Sweep over tiles along the k dimension.
    int num_tiles = (n + TILE - 1) / TILE;
    for (int t = 0; t < num_tiles; ++t) {

        // Load one element of A's tile: A[row][t*TILE + threadIdx.x]
        int a_col = t * TILE + threadIdx.x;
        sA[threadIdx.y][threadIdx.x] = (row < n && a_col < n)
                                       ? A[row * n + a_col] : 0.0f;

        // Load one element of B's tile: B[t*TILE + threadIdx.y][col]
        int b_row = t * TILE + threadIdx.y;
        sB[threadIdx.y][threadIdx.x] = (b_row < n && col < n)
                                       ? B[b_row * n + col] : 0.0f;

        __syncthreads();    // tile is fully loaded before any thread reads it

        // Accumulate the dot product for this tile.
        #pragma unroll
        for (int k = 0; k < TILE; ++k)
            acc += sA[threadIdx.y][k] * sB[k][threadIdx.x];

        __syncthreads();    // all threads done with shared memory before next load
    }

    if (row < n && col < n)
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

    // One thread per output element; block = TILE x TILE
    dim3 block(TILE, TILE);
    dim3 grid((n + TILE - 1) / TILE,
              (n + TILE - 1) / TILE);

    // Warm-up
    gemm_tiled<<<grid, block>>>(d_A, d_B, d_C, n);
    CUDA_CHECK(cudaDeviceSynchronize());

    // Timed run
    cudaEvent_t t0, t1;
    CUDA_CHECK(cudaEventCreate(&t0));
    CUDA_CHECK(cudaEventCreate(&t1));

    CUDA_CHECK(cudaEventRecord(t0));
    gemm_tiled<<<grid, block>>>(d_A, d_B, d_C, n);
    CUDA_CHECK(cudaEventRecord(t1));
    CUDA_CHECK(cudaEventSynchronize(t1));

    float ms = 0.0f;
    CUDA_CHECK(cudaEventElapsedTime(&ms, t0, t1));

    double flops  = 2.0 * (double)n * n * n;
    double gflops = flops / (ms * 1e-3) / 1e9;

    printf("Matrix size : %d x %d (FP32)\n", n, n);
    printf("Tile size   : %d x %d\n", TILE, TILE);
    printf("Kernel time : %.3f ms\n", ms);
    printf("Throughput  : %.2f GFLOP/s\n", gflops);

    CUDA_CHECK(cudaMemcpy(h_C, d_C, bytes, cudaMemcpyDeviceToHost));

    printf("C[0][0]     : %f\n", h_C[0]);

    cudaEventDestroy(t0);
    cudaEventDestroy(t1);
    cudaFree(d_A); cudaFree(d_B); cudaFree(d_C);
    free(h_A); free(h_B); free(h_C);
    return 0;
}
