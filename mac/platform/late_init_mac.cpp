#include <cstdlib>
// Linked last, so that its constructor runs after the static initializers of every other translation unit.
void macshade_attach_late();

__attribute__((constructor)) static void late_init() { macshade_attach_late(); }
