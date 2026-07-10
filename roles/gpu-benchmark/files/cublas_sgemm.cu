#include <cstdio>
#include <cstdlib>
#include <cuda_runtime.h>
#include <cublas_v2.h>
#include <chrono>

static void checkCuda(cudaError_t e) {
    if (e != cudaSuccess) {
        fprintf(stderr, "CUDA error: %s\n", cudaGetErrorString(e));
        exit(1);
    }
}

static void checkCublas(cublasStatus_t s) {
    if (s != CUBLAS_STATUS_SUCCESS) {
        fprintf(stderr, "cuBLAS error: %d\n", s);
        exit(1);
    }
}

int main(int argc, char** argv) {
    int N     = (argc > 1) ? atoi(argv[1]) : 16384;
    int iters = (argc > 2) ? atoi(argv[2]) : 20;
    size_t bytes = (size_t)N * N * sizeof(float);

    float *A, *B, *C;
    checkCuda(cudaMalloc(&A, bytes));
    checkCuda(cudaMalloc(&B, bytes));
    checkCuda(cudaMalloc(&C, bytes));

    cublasHandle_t h;
    checkCublas(cublasCreate(&h));
    const float alpha = 1.0f;
    const float beta  = 0.0f;

    checkCublas(cublasSgemm(h, CUBLAS_OP_N, CUBLAS_OP_N, N, N, N, &alpha, A, N, B, N, &beta, C, N));
    checkCuda(cudaDeviceSynchronize());

    auto start = std::chrono::high_resolution_clock::now();
    for (int i = 0; i < iters; ++i) {
        checkCublas(cublasSgemm(h, CUBLAS_OP_N, CUBLAS_OP_N, N, N, N, &alpha, A, N, B, N, &beta, C, N));
    }
    checkCuda(cudaDeviceSynchronize());
    auto end = std::chrono::high_resolution_clock::now();

    double sec = std::chrono::duration<double>(end - start).count();
    double flops = 2.0 * (double)N * (double)N * (double)N;
    double gflops = (flops * iters) / sec / 1e9;
    printf("RESULT: N=%d iters=%d total=%.3f s avg=%.3f s GFLOP/s=%.2f\n",
           N, iters, sec, sec / iters, gflops);

    cublasDestroy(h);
    cudaFree(A);
    cudaFree(B);
    cudaFree(C);
    return 0;
}
