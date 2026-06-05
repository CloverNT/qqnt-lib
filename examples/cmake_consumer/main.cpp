// Minimal check that the QQNT headers are wired up via the <QQNT/...> prefix.
// node_version.h is dependency-free (just macros), so this compiles cleanly and
// proves the include path resolves. For real use, pull in <QQNT/node_api.h>
// (N-API) or <QQNT/v8.h> (V8 C++ API).
#include <QQNT/node_version.h>
#include <cstdio>

int main() {
  std::printf("QQNT SDK headers OK - bundled Node %s (NODE_MODULE_VERSION %d)\n",
              NODE_VERSION, NODE_MODULE_VERSION);
  return 0;
}
