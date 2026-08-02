// Minimal SYCL execution test.
//
// Unlike the sycl-compile-* tests, which only prove the toolchain can generate
// code for a target, this actually runs a kernel on a real device. It is
// deliberately strict about *where* it ran: a silent fallback to the host or to
// a different backend fails the test rather than passing it, which is the whole
// point of running it on real hardware.
//
// Set SYCL_EXPECT_BACKEND to the backend the caller requires (opencl,
// level_zero, cuda, hip). Leave it unset to accept any GPU.

#include <sycl/sycl.hpp>

#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

const char *backendName(sycl::backend b) {
  switch (b) {
  case sycl::backend::opencl:
    return "opencl";
  case sycl::backend::ext_oneapi_level_zero:
    return "level_zero";
  case sycl::backend::ext_oneapi_cuda:
    return "cuda";
  case sycl::backend::ext_oneapi_hip:
    return "hip";
  default:
    return "other";
  }
}

const char *envOr(const char *name, const char *fallback) {
  const char *v = std::getenv(name);
  return (v && *v) ? v : fallback;
}

} // namespace

int main() {
  const char *expected = std::getenv("SYCL_EXPECT_BACKEND");

  std::vector<sycl::device> gpus;
  try {
    for (const sycl::platform &p : sycl::platform::get_platforms())
      for (const sycl::device &d : p.get_devices())
        if (d.is_gpu())
          gpus.push_back(d);
  } catch (const sycl::exception &e) {
    std::fprintf(stderr, "device enumeration failed: %s\n", e.what());
    return 1;
  }

  if (gpus.empty()) {
    std::fprintf(stderr,
                 "no SYCL GPU device found (ONEAPI_DEVICE_SELECTOR=%s)\n",
                 envOr("ONEAPI_DEVICE_SELECTOR", "<unset>"));
    return 1;
  }

  const sycl::device &dev = gpus.front();
  const std::string name = dev.get_info<sycl::info::device::name>();
  const char *backend = backendName(dev.get_backend());
  std::printf("device:  %s\nbackend: %s\n", name.c_str(), backend);

  if (expected && std::strcmp(expected, backend) != 0) {
    std::fprintf(stderr, "expected backend '%s' but ran on '%s'\n", expected,
                 backend);
    return 1;
  }

  constexpr std::size_t N = 4096;
  try {
    sycl::queue q{dev};
    int *buf = sycl::malloc_shared<int>(N, q);
    if (!buf) {
      std::fprintf(stderr, "malloc_shared(%zu) returned null\n", N);
      return 1;
    }

    for (std::size_t i = 0; i < N; ++i)
      buf[i] = static_cast<int>(i);

    q.parallel_for(sycl::range<1>{N},
                   [=](sycl::id<1> i) { buf[i] = buf[i] * 2 + 1; })
        .wait_and_throw();

    for (std::size_t i = 0; i < N; ++i) {
      const int want = static_cast<int>(i) * 2 + 1;
      if (buf[i] != want) {
        std::fprintf(stderr, "mismatch at %zu: got %d, want %d\n", i, buf[i],
                     want);
        sycl::free(buf, q);
        return 1;
      }
    }

    sycl::free(buf, q);
  } catch (const sycl::exception &e) {
    std::fprintf(stderr, "kernel execution failed: %s\n", e.what());
    return 1;
  }

  std::printf("OK: kernel ran on the GPU and produced correct results\n");
  return 0;
}
