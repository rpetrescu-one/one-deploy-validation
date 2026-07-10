// Host<->GPU PCIe transfer bandwidth: pinned-memory cudaMemcpy in both
// directions. Validates the passthrough DATA PATH — a link that negotiated
// x16 can still transfer poorly (ASPM, NUMA misplacement, broken BAR setup).
// Output format is parsed by lib/parse_pcie_bw.yml — keep the RESULT line.
#include <cstdio>
#include <cstdlib>
#include <cuda_runtime.h>
#include <chrono>

static void checkCuda(cudaError_t e) {
    if (e != cudaSuccess) {
        fprintf(stderr, "CUDA error: %s\n", cudaGetErrorString(e));
        exit(1);
    }
}

static double copyGbs(void* dst, void* src, size_t bytes, int iters, cudaMemcpyKind kind) {
    // one warm-up copy, then timed iterations
    checkCuda(cudaMemcpy(dst, src, bytes, kind));
    checkCuda(cudaDeviceSynchronize());
    auto start = std::chrono::high_resolution_clock::now();
    for (int i = 0; i < iters; ++i) {
        checkCuda(cudaMemcpy(dst, src, bytes, kind));
    }
    checkCuda(cudaDeviceSynchronize());
    auto end = std::chrono::high_resolution_clock::now();
    double sec = std::chrono::duration<double>(end - start).count();
    return ((double)bytes * iters) / sec / 1e9;
}

int main(int argc, char** argv) {
    int sizeMb = (argc > 1) ? atoi(argv[1]) : 256;
    int iters  = (argc > 2) ? atoi(argv[2]) : 20;
    // atoi yields 0 for garbage; 0/negative would produce a fake 0.00 GB/s
    // "result" (false hardware flag) or a wrapped huge allocation.
    if (sizeMb <= 0 || sizeMb > 16384 || iters <= 0 || iters > 10000) {
        fprintf(stderr, "usage: pcie_bw [size_mb 1..16384] [iters 1..10000]\n");
        return 2;
    }
    size_t bytes = (size_t)sizeMb * 1024 * 1024;

    void* hbuf;
    void* dbuf;
    checkCuda(cudaMallocHost(&hbuf, bytes));  // pinned host memory
    checkCuda(cudaMalloc(&dbuf, bytes));

    double h2d = copyGbs(dbuf, hbuf, bytes, iters, cudaMemcpyHostToDevice);
    double d2h = copyGbs(hbuf, dbuf, bytes, iters, cudaMemcpyDeviceToHost);

    printf("RESULT: size_mb=%d iters=%d H2D=%.2f GB/s D2H=%.2f GB/s\n",
           sizeMb, iters, h2d, d2h);

    cudaFreeHost(hbuf);
    cudaFree(dbuf);
    return 0;
}
